import Foundation

/// A GRIB2 reader scoped to EXACTLY the shape NCEP's NOMADS GRIB-filter returns for GFS wind fields, and
/// deliberately nothing more. A general GRIB2 library is thousands of lines (a dozen grid projections, six
/// packing schemes, JPEG2000 and PNG payloads, complex spatial differencing); this decoder handles
///
///   * section 3 template 3.0  — regular latitude/longitude grid
///   * section 4 template 4.0  — analysis/forecast at one level, one time
///   * section 5 template 5.0  — simple packing, `value = (R + X·2^E) / 10^D`
///   * section 6 indicator 255 — no bitmap (every grid point has data)
///
/// which is what `filter_gfs_0p25_1hr.pl?var_UGRD=on&var_VGRD=on` produced on every probe. Anything else —
/// a different template, a bitmap, a truncated message, a foreign discipline — is DROPPED rather than
/// guessed at, on the same principle as the METAR decoder: a wind arrow drawn from a misread payload is
/// worse than no wind arrow, because the pilot cannot tell the difference.
///
/// Two GRIB2 encoding traps are handled explicitly, both of which silently produce plausible-but-wrong
/// numbers if you assume C semantics:
///   1. signed integers are SIGN-MAGNITUDE (high bit = negative), not two's complement — so a southern-
///      hemisphere latitude read with `Int32(bitPattern:)` comes out as ~+2147 °;
///   2. the scanning-mode flags decide row order, so a grid read without normalising them is mirrored
///      north-for-south.
///
/// NASA/JPL Power-of-10: every loop is statically bounded by a named cap or a strictly-decreasing cursor;
/// no recursion; every offset is range-checked against the enclosing section length before it is read
/// (malformed network data must return nil, never trap); invariant asserts throughout.
enum Grib2Decoder {

    /// One decoded field: a single parameter, at a single level, on a normalised grid.
    struct Message: Sendable {
        /// The model cycle (GRIB "reference time"), UTC. nil if section 1 was unreadable.
        let referenceTime: Date?
        /// Forecast projection from `referenceTime`, in hours.
        let forecastHours: Int
        /// GRIB2 discipline-0 parameter identity. Category 2 = momentum; number 2 = UGRD, 3 = VGRD.
        let paramCategory: Int
        let paramNumber: Int
        /// Fixed-surface identity: type 100 = isobaric (value in Pa), 103 = height above ground (m).
        let levelType: Int
        let levelValue: Int
        /// Grid shape. `ni` = points per row (longitude), `nj` = rows (latitude).
        let ni: Int
        let nj: Int
        /// South-west corner and step, in degrees. Always positive steps after normalisation.
        let minLat: Double
        let minLon: Double
        let dLat: Double
        let dLon: Double
        /// `ni * nj` values in the field's native unit (m/s for wind), row-major, **normalised** so that
        /// index `j * ni + i` is latitude `minLat + j·dLat`, longitude `minLon + i·dLon`.
        let values: [Float]
    }

    // Hard caps so every loop below is statically bounded (rule 2).
    static let maxMessages = 40                 // 10 levels × U/V = 20; slack for a wider request
    static let maxGridPoints = 1_000_000        // 60°×40° at 0.25° = 38,801 — vast slack
    static let maxSectionsPerMessage = 24       // GRIB2 defines 8; repeated 2..7 groups add a few
    static let maxBitsPerValue = 32

    /// Decode every message in a concatenated GRIB2 stream, skipping any this decoder does not support.
    /// Returns an empty array (never throws, never traps) on garbage input.
    static func messages(from data: Data) -> [Message] {
        assert(maxMessages > 0, "Grib2Decoder: message cap must be positive")
        guard data.count >= 16 else { return [] }
        let bytes = [UInt8](data)
        assert(bytes.count == data.count, "Grib2Decoder: byte copy changed length")
        var out: [Message] = []
        var pos = 0
        while pos + 16 <= bytes.count && out.count < maxMessages {   // bounded: pos strictly increases (rule 2)
            guard bytes[pos] == 0x47, bytes[pos + 1] == 0x52,        // "GRIB"
                  bytes[pos + 2] == 0x49, bytes[pos + 3] == 0x42 else { break }
            let total = u64(bytes, pos + 8)
            guard total >= 16, total <= bytes.count - pos else { break }
            if let m = message(bytes, start: pos, total: total) { out.append(m) }
            pos += total
        }
        return out
    }

    // MARK: - one message

    /// The section parts a supported message needs. Assembled by the section walk, then validated together.
    private struct Parts {
        var referenceTime: Date?
        var forecastHours = 0
        var grid: Grid?
        var product: Product?
        var drs: DRS?
        var bitmapIndicator = 255
        var dataStart = -1
        var dataCount = 0
    }
    private struct Grid { let ni, nj: Int; let la1, lo1, dLat, dLon: Double; let scanMode: Int }
    private struct Product { let category, number, levelType, levelValue: Int }
    private struct DRS { let r: Double, e: Int, d: Int, bits: Int, points: Int }

    private static func message(_ b: [UInt8], start: Int, total: Int) -> Message? {
        assert(total >= 16, "Grib2Decoder: message shorter than its indicator section")
        assert(start + total <= b.count, "Grib2Decoder: message overruns the buffer")
        guard b[start + 7] == 2, b[start + 6] == 0 else { return nil }   // GRIB2, meteorological products
        var parts = Parts()
        var p = start + 16
        var sections = 0
        let end = start + total
        while p + 5 <= end && sections < maxSectionsPerMessage {     // bounded: p strictly increases (rule 2)
            if b[p] == 0x37, b[p + 1] == 0x37, b[p + 2] == 0x37, b[p + 3] == 0x37 { break }   // "7777"
            let len = u32(b, p)
            guard len >= 5, p + len <= end else { return nil }
            absorb(b, at: p, len: len, into: &parts)
            p += len
            sections += 1
        }
        return assemble(b, parts)
    }

    /// Route one section to its parser. Unknown/local sections (2) are ignored by design.
    private static func absorb(_ b: [UInt8], at p: Int, len: Int, into parts: inout Parts) {
        assert(len >= 5, "Grib2Decoder: section shorter than its header")
        assert(p >= 0, "Grib2Decoder: negative section offset")
        switch Int(b[p + 4]) {
        case 1:
            if len >= 21 {
                parts.referenceTime = referenceTime(b, p)
            }
        case 3: parts.grid = grid(b, p, len)
        case 4:
            if let pr = product(b, p, len) {
                parts.product = pr
                parts.forecastHours = forecastHours(b, p, len)
            }
        case 5: parts.drs = drs(b, p, len)
        case 6: if len >= 6 { parts.bitmapIndicator = Int(b[p + 5]) }
        case 7: parts.dataStart = p + 5; parts.dataCount = len - 5
        default: break
        }
    }

    /// Cross-validate the parts and unpack. nil unless every supported-shape precondition holds.
    private static func assemble(_ b: [UInt8], _ parts: Parts) -> Message? {
        assert(maxGridPoints > 0, "Grib2Decoder: grid-point cap must be positive")
        guard let g = parts.grid, let pr = parts.product, let d = parts.drs,
              parts.bitmapIndicator == 255,                 // a bitmap means missing points — unsupported
              parts.dataStart >= 0, parts.dataCount >= 0 else { return nil }
        let points = g.ni * g.nj
        guard points > 0, points <= maxGridPoints, d.points == points else { return nil }
        guard let raw = unpackSimple(b, start: parts.dataStart, count: parts.dataCount,
                                     points: points, drs: d) else { return nil }
        assert(raw.count == points, "Grib2Decoder: unpacked count disagrees with the grid")
        guard let norm = normalise(raw, g) else { return nil }
        let sw = southWest(g)
        return Message(referenceTime: parts.referenceTime, forecastHours: parts.forecastHours,
                       paramCategory: pr.category, paramNumber: pr.number,
                       levelType: pr.levelType, levelValue: pr.levelValue,
                       ni: g.ni, nj: g.nj,
                       minLat: sw.lat, minLon: sw.lon,
                       dLat: g.dLat, dLon: g.dLon, values: norm)
    }

    /// The grid's south-west corner in the app's coordinate convention: latitude −90…90, longitude
    /// −180…180. GRIB2 states the FIRST point, which is the corner the scan starts from — the north-west
    /// corner on a −j grid and the east edge on a −i grid — and expresses longitude in 0…360.
    private static func southWest(_ g: Grid) -> (lat: Double, lon: Double) {
        assert(g.dLat > 0 && g.dLon > 0, "Grib2Decoder: steps must be positive after parsing")
        assert(g.ni > 1 && g.nj > 1, "Grib2Decoder: degenerate grid reached the corner helper")
        let southLat = (g.scanMode & 0x40) != 0 ? g.la1 : g.la1 - Double(g.nj - 1) * g.dLat
        var westLon = (g.scanMode & 0x80) != 0 ? g.lo1 - Double(g.ni - 1) * g.dLon : g.lo1
        if westLon > 180 { westLon -= 360 }
        if westLon < -180 { westLon += 360 }
        return (southLat, westLon)
    }

    // MARK: - sections

    /// Section 1 octets 13-20: reference time, always UTC.
    private static func referenceTime(_ b: [UInt8], _ p: Int) -> Date? {
        assert(p >= 0, "Grib2Decoder: negative section-1 offset")
        assert(p + 20 < b.count, "Grib2Decoder: section 1 overruns the buffer")
        var c = DateComponents()
        c.year = u16(b, p + 12); c.month = Int(b[p + 14]); c.day = Int(b[p + 15])
        c.hour = Int(b[p + 16]); c.minute = Int(b[p + 17]); c.second = Int(b[p + 18])
        guard let year = c.year, year > 1900, year < 2200,
              let month = c.month, month >= 1, month <= 12,
              let day = c.day, day >= 1, day <= 31 else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return cal.date(from: c)
    }

    /// Section 3 template 3.0 — regular lat/lon grid. Angles arrive in units of 1e-6 degree.
    private static func grid(_ b: [UInt8], _ p: Int, _ len: Int) -> Grid? {
        assert(len >= 5, "Grib2Decoder: section 3 shorter than its header")
        assert(p >= 0, "Grib2Decoder: negative section-3 offset")
        guard len >= 72, u16(b, p + 12) == 0 else { return nil }        // template 3.0 only
        let ni = u32(b, p + 30), nj = u32(b, p + 34)
        guard ni > 1, nj > 1 else { return nil }
        let scan = Int(b[p + 71])
        guard scan & 0x20 == 0, scan & 0x10 == 0 else { return nil }    // j-consecutive / alternating: unsupported
        let micro = 1e-6
        let la1 = Double(sm32(b, p + 46)) * micro
        let lo1 = Double(sm32(b, p + 50)) * micro
        let dLon = Double(u32(b, p + 63)) * micro
        let dLat = Double(u32(b, p + 67)) * micro
        guard dLat > 0, dLon > 0, la1 >= -90.5, la1 <= 90.5 else { return nil }
        return Grid(ni: ni, nj: nj, la1: la1, lo1: lo1, dLat: dLat, dLon: dLon, scanMode: scan)
    }

    /// Section 4 template 4.0 — parameter identity + first fixed surface.
    private static func product(_ b: [UInt8], _ p: Int, _ len: Int) -> Product? {
        assert(len >= 5, "Grib2Decoder: section 4 shorter than its header")
        assert(p >= 0, "Grib2Decoder: negative section-4 offset")
        guard len >= 34, u16(b, p + 7) == 0 else { return nil }         // template 4.0 only
        let scale = sm8(b, p + 23)
        let scaled = sm32(b, p + 24)
        // A scale factor is a power of ten applied to the surface value; GFS writes 0 for both the
        // isobaric and the height-above-ground levels we request, so anything else is out of scope.
        guard scale == 0 else { return nil }
        return Product(category: Int(b[p + 9]), number: Int(b[p + 10]),
                       levelType: Int(b[p + 22]), levelValue: scaled)
    }

    /// Section 4 octets 19-22 with the unit indicator at octet 18, converted to whole hours.
    private static func forecastHours(_ b: [UInt8], _ p: Int, _ len: Int) -> Int {
        assert(len >= 22, "Grib2Decoder: section 4 too short for a forecast time")
        assert(p + 21 < b.count, "Grib2Decoder: forecast time overruns the buffer")
        let unit = Int(b[p + 17])
        let value = u32(b, p + 18)
        switch unit {
        case 0:  return value / 60          // minutes
        case 1:  return value               // hours
        case 2:  return value * 24          // days
        case 10: return value * 3           // 3-hour periods
        case 11: return value * 6           // 6-hour periods
        case 12: return value * 12          // 12-hour periods
        default: return 0
        }
    }

    /// Section 5 template 5.0 — simple packing parameters.
    private static func drs(_ b: [UInt8], _ p: Int, _ len: Int) -> DRS? {
        assert(len >= 5, "Grib2Decoder: section 5 shorter than its header")
        assert(maxBitsPerValue <= 32, "Grib2Decoder: bit cap exceeds the accumulator width")
        guard len >= 21, u16(b, p + 9) == 0 else { return nil }         // template 5.0 only
        let bits = Int(b[p + 19])
        guard bits <= maxBitsPerValue else { return nil }
        return DRS(r: f32(b, p + 11), e: sm16(b, p + 15), d: sm16(b, p + 17),
                   bits: bits, points: u32(b, p + 5))
    }

    // MARK: - unpacking

    /// Simple packing: `value = (R + X·2^E) / 10^D`, X being the next `bits`-wide big-endian bit field.
    /// `bits == 0` is legal and means a constant field (every point equals `R / 10^D`).
    private static func unpackSimple(_ b: [UInt8], start: Int, count: Int,
                                     points: Int, drs d: DRS) -> [Float]? {
        assert(points > 0, "Grib2Decoder: unpacking an empty grid")
        assert(d.bits >= 0 && d.bits <= maxBitsPerValue, "Grib2Decoder: bit width out of range")
        let scale = pow(2.0, Double(d.e)) / pow(10.0, Double(d.d))
        let offset = d.r / pow(10.0, Double(d.d))
        guard d.bits > 0 else { return [Float](repeating: Float(offset), count: points) }
        let needBits = points * d.bits
        guard count >= (needBits + 7) / 8, start >= 0, start + count <= b.count else { return nil }
        var out = [Float](repeating: 0, count: points)
        let mask: UInt64 = d.bits == 64 ? .max : (UInt64(1) << UInt64(d.bits)) - 1
        var acc: UInt64 = 0
        var have = 0
        var byte = start
        for i in 0..<points {                                   // bounded by the grid-point cap (rule 2)
            while have < d.bits {                               // bounded: ≤ 5 iterations for bits ≤ 32
                acc = (acc << 8) | UInt64(b[byte])
                byte += 1
                have += 8
            }
            let shift = have - d.bits
            let x = (acc >> UInt64(shift)) & mask
            acc &= shift == 0 ? 0 : (UInt64(1) << UInt64(shift)) - 1
            have = shift
            out[i] = Float(offset + Double(x) * scale)
        }
        return out
    }

    /// Re-order a raw scan into the canonical south-up, west-to-east layout the sampler assumes.
    /// GFS from the NOMADS filter arrives as scan mode 0x40 (+i, +j), which needs no row flip — but a
    /// north-down grid would render the wind field upside down, so the flags are honoured rather than
    /// trusted.
    private static func normalise(_ raw: [Float], _ g: Grid) -> [Float]? {
        assert(raw.count == g.ni * g.nj, "Grib2Decoder: normalise got a mismatched buffer")
        assert(g.ni > 0 && g.nj > 0, "Grib2Decoder: normalise got an empty grid")
        let iNegative = (g.scanMode & 0x80) != 0        // rows run east → west
        let jPositive = (g.scanMode & 0x40) != 0        // rows run south → north
        if !iNegative && jPositive { return raw }       // already canonical (the GFS case)
        var out = [Float](repeating: 0, count: raw.count)
        for j in 0..<g.nj {                             // bounded by the grid-point cap (rule 2)
            let srcRow = jPositive ? j : (g.nj - 1 - j)
            let srcBase = srcRow * g.ni, dstBase = j * g.ni
            for i in 0..<g.ni {
                let srcCol = iNegative ? (g.ni - 1 - i) : i
                out[dstBase + i] = raw[srcBase + srcCol]
            }
        }
        return out
    }

    // MARK: - primitive reads (bounds guaranteed by the section-length guards above)

    @inline(__always) private static func u16(_ b: [UInt8], _ i: Int) -> Int {
        assert(i >= 0 && i + 1 < b.count, "Grib2Decoder: u16 out of range")
        return Int(b[i]) << 8 | Int(b[i + 1])
    }
    @inline(__always) private static func u32(_ b: [UInt8], _ i: Int) -> Int {
        assert(i >= 0 && i + 3 < b.count, "Grib2Decoder: u32 out of range")
        return Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3])
    }
    @inline(__always) private static func u64(_ b: [UInt8], _ i: Int) -> Int {
        assert(i >= 0 && i + 7 < b.count, "Grib2Decoder: u64 out of range")
        var v = 0
        for k in 0..<8 { v = v << 8 | Int(b[i + k]) }     // bounded: 8 (rule 2)
        return v
    }
    /// GRIB2 signed integers are sign-magnitude: the high bit is the sign, the rest the magnitude.
    @inline(__always) private static func sm8(_ b: [UInt8], _ i: Int) -> Int {
        assert(i >= 0 && i < b.count, "Grib2Decoder: sm8 out of range")
        let raw = Int(b[i])
        return (raw & 0x80) != 0 ? -(raw & 0x7F) : raw
    }
    @inline(__always) private static func sm16(_ b: [UInt8], _ i: Int) -> Int {
        let raw = u16(b, i)
        assert(raw >= 0, "Grib2Decoder: sm16 read a negative magnitude")
        return (raw & 0x8000) != 0 ? -(raw & 0x7FFF) : raw
    }
    @inline(__always) private static func sm32(_ b: [UInt8], _ i: Int) -> Int {
        let raw = u32(b, i)
        assert(raw >= 0, "Grib2Decoder: sm32 read a negative magnitude")
        return (raw & 0x8000_0000) != 0 ? -(raw & 0x7FFF_FFFF) : raw
    }
    /// IEEE 754 binary32, big-endian (GRIB edition 2 dropped the IBM format edition 1 used).
    @inline(__always) private static func f32(_ b: [UInt8], _ i: Int) -> Double {
        let bits = UInt32(truncatingIfNeeded: u32(b, i))
        let v = Float(bitPattern: bits)
        assert(i >= 0, "Grib2Decoder: negative float offset")
        return v.isFinite ? Double(v) : 0
    }
}
