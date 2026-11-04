import Foundation

/// A GRIB2 reader scoped to EXACTLY the two shapes this app meets — NCEP's NOMADS GRIB-filter output for
/// GFS wind fields, and NOAA's MRMS radar grids — and deliberately nothing more. A general GRIB2 library
/// is thousands of lines (a dozen grid projections, six packing schemes, JPEG2000 payloads, complex
/// spatial differencing); this decoder handles
///
///   * section 0 discipline 0 and 209 — meteorological products, and NCEP's local-use space (MRMS)
///   * section 3 template 3.0  — regular latitude/longitude grid
///   * section 4 template 4.0  — analysis/forecast at one level, one time
///   * section 5 template 5.0  — simple packing, `value = (R + X·2^E) / 10^D`
///   * section 5 template 5.41 — the same arithmetic, with X carried as a greyscale PNG raster
///   * section 6 indicator 255 — no bitmap (every grid point has data)
///
/// which is what `filter_gfs_0p25_1hr.pl?var_UGRD=on&var_VGRD=on` and
/// `mrms/data/2D/EchoTop_30/*.grib2.gz` produced on every probe. Anything else — a different template, a
/// bitmap, a truncated message, a foreign discipline — is DROPPED rather than guessed at, on the same
/// principle as the METAR decoder: a wind arrow drawn from a misread payload is worse than no wind arrow,
/// because the pilot cannot tell the difference.
///
/// # Two entry points, and why the second one exists
///
/// `messages(from:)` decodes whole fields and is what the wind layer uses: a 281 × 141 regional box is
/// 39,621 points and materialising it is nothing. `windows(from:latRange:lonRange:)` decodes a lat/lon
/// rectangle instead, and exists because the MRMS CONUS grid is **7000 × 3500 = 24.5 M points** — 98 MB
/// as `[Float]`, for a question about a 200-mile box. The windowed path never builds the whole field; for
/// a PNG payload it streams scanlines through `PNGGrayRows` and stops at the southern edge of the window.
/// `maxGridPoints` deliberately rejects the MRMS grid on the `messages(from:)` path, so there is no way
/// to ask for it by accident.
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
        /// Section 0's discipline. 0 = meteorological products (GFS); 209 = NCEP local use (MRMS).
        /// ⚠️ The parameter tables are PER DISCIPLINE, so `paramCategory`/`paramNumber` mean nothing
        /// without it: discipline 0 category 2 number 2 is wind, and discipline 209 category 3 number 45
        /// is an MRMS echo top. A decoder that ignored this would read radar heights as metres per second.
        let discipline: Int
        /// Parameter identity within `discipline`. Discipline 0: category 2 = momentum, number 2 = UGRD,
        /// 3 = VGRD.
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
    /// Cap for the WHOLE-FIELD path. ⚠️ The MRMS CONUS grid is 24.5 M points and is therefore rejected
    /// here on purpose — it must be read through `windows(from:latRange:lonRange:)` or not at all.
    static let maxGridPoints = 1_000_000        // 60°×40° at 0.25° = 38,801 — vast slack
    /// Cap for the WINDOWED path. A 6° × 8° box at MRMS's 0.01° is 600 × 800 = 480,000.
    static let maxWindowPoints = 600_000
    /// Points on a single grid row, either path. MRMS CONUS is 7000.
    static let maxRowPoints = 16_384
    static let maxSectionsPerMessage = 24       // GRIB2 defines 8; repeated 2..7 groups add a few
    static let maxBitsPerValue = 32

    /// Section 0 disciplines this decoder will read. 0 is the standard meteorological space; 209 is
    /// NCEP's local-use discipline, which is what every MRMS product is published under.
    static let supportedDisciplines: Set<Int> = [0, 209]

    /// How section 7 carries the packed integers. Both templates share the section-5 header layout and
    /// the same `value = (R + X·2^E) / 10^D` arithmetic — only the payload encoding differs.
    enum Packing: Sendable, Equatable {
        /// Template 5.0: X is a big-endian bit field, `bits` wide, with no padding between values.
        case simple
        /// Template 5.41: X is a greyscale PNG raster, `ni` wide by `nj` tall, `bits` deep.
        case png
    }

    /// One rectangular sub-grid, normalised south-up and west-to-east like `Message.values`.
    ///
    /// `values` may contain `.nan` where the source grid had no value to give — which, on the windowed
    /// PNG path, is how a short or malformed scanline is reported rather than as a plausible number.
    /// Callers must treat NaN as "no data", never as zero.
    struct Window: Sendable {
        let referenceTime: Date?
        let discipline: Int
        let paramCategory: Int
        let paramNumber: Int
        let levelType: Int
        let levelValue: Int
        /// Window shape. `ni` = points per row (longitude), `nj` = rows (latitude).
        let ni: Int
        let nj: Int
        /// The WINDOW's south-west corner, not the source grid's.
        let minLat: Double
        let minLon: Double
        let dLat: Double
        let dLon: Double
        /// `ni * nj` values in the field's native unit, row-major, index `j * ni + i` at latitude
        /// `minLat + j·dLat`, longitude `minLon + i·dLon`.
        let values: [Float]

        func lat(ofRow j: Int) -> Double {
            assert(j >= 0 && j < nj, "Grib2Decoder.Window: row out of range")
            return minLat + Double(j) * dLat
        }
        func lon(ofCol i: Int) -> Double {
            assert(i >= 0 && i < ni, "Grib2Decoder.Window: column out of range")
            return minLon + Double(i) * dLon
        }
        /// The value at a window cell, or nil where the source had none.
        func value(row j: Int, col i: Int) -> Float? {
            assert(j >= 0 && j < nj && i >= 0 && i < ni, "Grib2Decoder.Window: index out of range")
            let v = values[j * ni + i]
            return v.isFinite ? v : nil
        }
    }

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
        var discipline = 0
        var grid: Grid?
        var product: Product?
        var drs: DRS?
        var bitmapIndicator = 255
        var dataStart = -1
        var dataCount = 0
    }
    private struct Grid { let ni, nj: Int; let la1, lo1, dLat, dLon: Double; let scanMode: Int }
    private struct Product { let category, number, levelType, levelValue: Int }
    private struct DRS { let r: Double, e: Int, d: Int, bits: Int, points: Int; let packing: Packing }

    /// Walk one message's sections into `Parts`. Shared by both entry points so the two cannot drift on
    /// which templates they accept.
    private static func parse(_ b: [UInt8], start: Int, total: Int) -> Parts? {
        assert(total >= 16, "Grib2Decoder: message shorter than its indicator section")
        assert(start + total <= b.count, "Grib2Decoder: message overruns the buffer")
        guard b[start + 7] == 2 else { return nil }                      // GRIB edition 2
        let discipline = Int(b[start + 6])
        guard supportedDisciplines.contains(discipline) else { return nil }
        var parts = Parts()
        parts.discipline = discipline
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
        return parts
    }

    private static func message(_ b: [UInt8], start: Int, total: Int) -> Message? {
        guard let parts = parse(b, start: start, total: total) else { return nil }
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
        // The whole-field path reads simple packing only. A PNG payload belongs to a grid big enough
        // that materialising it is the thing `windows(...)` exists to avoid, so it is refused here
        // rather than quietly allocating 98 MB.
        guard d.packing == .simple else { return nil }
        guard let raw = unpackSimple(b, start: parts.dataStart, count: parts.dataCount,
                                     points: points, drs: d) else { return nil }
        assert(raw.count == points, "Grib2Decoder: unpacked count disagrees with the grid")
        guard let norm = normalise(raw, g) else { return nil }
        let sw = southWest(g)
        return Message(referenceTime: parts.referenceTime, forecastHours: parts.forecastHours,
                       discipline: parts.discipline,
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
        // Bound each axis BEFORE anything multiplies them. `u32` yields up to 4_294_967_295, so a section 3
        // claiming that on both axes overflows `ni * nj` past Int.max — and Swift traps on overflow, which
        // in a decoder fed by the network (or by a truncated disk snapshot from a previous run) is a crash
        // on data we should simply be refusing. `assemble` still applies the real cap to the product;
        // this only guarantees the product can be computed at all. 1e6 squared is 1e12, comfortably inside
        // Int64, and the real GFS 0.25° grid is 1440 x 721.
        guard ni > 1, nj > 1, ni <= maxGridPoints, nj <= maxGridPoints else { return nil }
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

    /// Section 5 templates 5.0 (simple packing) and 5.41 (PNG payload).
    ///
    /// ⚠️ THE TWO TEMPLATES HAVE AN IDENTICAL HEADER LAYOUT, which is the only reason this is one
    /// function: octets 12-15 are R, 16-17 E, 18-19 D, octet 20 the bit width and octet 21 the original
    /// field type, in both. They differ solely in what section 7 holds. That is also the trap — a decoder
    /// that accepted 5.41 by widening this template check alone, and left `unpackSimple` to read the
    /// payload, would read a PNG's signature and IHDR as packed data and produce a grid of plausible
    /// nonsense. Hence `DRS.packing`, which `assemble` and `fill` both switch on.
    ///
    /// For 5.41 the bit width is the PNG's own depth, because NCEP's encoder rounds the requested width
    /// up to 8, 16, 24 or 32 before writing it here. Greyscale covers 8 and 16; 24 and 32 are written as
    /// RGB/RGBA rasters and are rejected by `PNGGrayRows.header`, not here, so a future MRMS product in
    /// that shape fails loudly on decode rather than being misread.
    private static func drs(_ b: [UInt8], _ p: Int, _ len: Int) -> DRS? {
        assert(len >= 5, "Grib2Decoder: section 5 shorter than its header")
        assert(maxBitsPerValue <= 32, "Grib2Decoder: bit cap exceeds the accumulator width")
        guard len >= 21 else { return nil }
        let packing: Packing
        switch u16(b, p + 9) {
        case 0:  packing = .simple
        case 41: packing = .png
        default: return nil
        }
        let bits = Int(b[p + 19])
        guard bits <= maxBitsPerValue else { return nil }
        return DRS(r: f32(b, p + 11), e: sm16(b, p + 15), d: sm16(b, p + 17),
                   bits: bits, points: u32(b, p + 5), packing: packing)
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

    // MARK: - the windowed path

    /// Decode only the values inside a lat/lon rectangle, from every message in the stream that can
    /// supply them.
    ///
    /// This is what makes MRMS usable on a phone. The CONUS echo-top grid is 7000 × 3500; a 6° × 8° box
    /// around the aircraft is 480,000 points, 0.5 MB as `[Float]` instead of 98 MB, and on the PNG path
    /// the scanlines north of the window are inflated into a 14 KB buffer and discarded while the ones
    /// south of it are never inflated at all.
    ///
    /// The ranges are inclusive and in the app's convention: latitude −90…90, longitude −180…180. Cells
    /// that straddle an edge are INCLUDED rather than excluded — the caller is asking "what weather is
    /// near me", and clipping a cell out of the answer because its centre fell 300 m outside the box is
    /// the wrong direction to round in.
    ///
    /// ⚠️ A grid that wraps the antimeridian after normalisation (a global GFS field, where the western
    /// edge normalises to 0° and the data runs east past 180°) is NOT handled: such a request returns no
    /// window rather than a wrong one. Every grid this app windows is regional.
    static func windows(from data: Data,
                        latRange: ClosedRange<Double>,
                        lonRange: ClosedRange<Double>) -> [Window] {
        assert(maxWindowPoints > 0, "Grib2Decoder: window cap must be positive")
        guard latRange.lowerBound >= -90, latRange.upperBound <= 90,
              lonRange.lowerBound >= -180, lonRange.upperBound <= 180 else { return [] }
        guard data.count >= 16 else { return [] }
        let bytes = [UInt8](data)
        assert(bytes.count == data.count, "Grib2Decoder: byte copy changed length")
        var out: [Window] = []
        var pos = 0
        while pos + 16 <= bytes.count && out.count < maxMessages {   // bounded: pos strictly increases
            guard bytes[pos] == 0x47, bytes[pos + 1] == 0x52,        // "GRIB"
                  bytes[pos + 2] == 0x49, bytes[pos + 3] == 0x42 else { break }
            let total = u64(bytes, pos + 8)
            guard total >= 16, total <= bytes.count - pos else { break }
            if let w = window(bytes, start: pos, total: total,
                              latRange: latRange, lonRange: lonRange) { out.append(w) }
            pos += total
        }
        return out
    }

    /// The window's extent in GEOGRAPHIC index space: `jg` counts north from the grid's southern edge,
    /// `ig` east from its western edge, both independent of the scan order.
    private struct IndexBox { let jgLo, jgHi, igLo, igHi: Int }

    private static func indexBox(_ g: Grid, _ sw: (lat: Double, lon: Double),
                                 latRange: ClosedRange<Double>,
                                 lonRange: ClosedRange<Double>) -> IndexBox? {
        assert(g.dLat > 0 && g.dLon > 0, "Grib2Decoder: steps must be positive")
        assert(g.ni > 1 && g.nj > 1, "Grib2Decoder: degenerate grid reached the index box")
        // floor on the low side and ceil on the high side, so a cell straddling either edge is kept.
        let jgLoRaw = ((latRange.lowerBound - sw.lat) / g.dLat).rounded(.down)
        let jgHiRaw = ((latRange.upperBound - sw.lat) / g.dLat).rounded(.up)
        let igLoRaw = ((lonRange.lowerBound - sw.lon) / g.dLon).rounded(.down)
        let igHiRaw = ((lonRange.upperBound - sw.lon) / g.dLon).rounded(.up)
        // Clamp through Double before converting: a request far off the grid produces a ratio that
        // would overflow Int on conversion, and Swift traps on that.
        let jgLo = Int(max(0, min(Double(g.nj - 1), jgLoRaw)))
        let jgHi = Int(max(0, min(Double(g.nj - 1), jgHiRaw)))
        let igLo = Int(max(0, min(Double(g.ni - 1), igLoRaw)))
        let igHi = Int(max(0, min(Double(g.ni - 1), igHiRaw)))
        // An empty intersection clamps to a degenerate box at one edge; reject it rather than return
        // a one-cell window of weather 2,000 miles away.
        guard jgHiRaw >= 0, igHiRaw >= 0,
              jgLoRaw <= Double(g.nj - 1), igLoRaw <= Double(g.ni - 1),
              jgLo <= jgHi, igLo <= igHi else { return nil }
        return IndexBox(jgLo: jgLo, jgHi: jgHi, igLo: igLo, igHi: igHi)
    }

    private static func window(_ b: [UInt8], start: Int, total: Int,
                               latRange: ClosedRange<Double>,
                               lonRange: ClosedRange<Double>) -> Window? {
        guard let parts = parse(b, start: start, total: total),
              let g = parts.grid, let pr = parts.product, let d = parts.drs,
              parts.bitmapIndicator == 255,              // a bitmap means missing points — unsupported
              parts.dataStart >= 0, parts.dataCount > 0 else { return nil }
        guard g.ni <= maxRowPoints else { return nil }
        let points = g.ni * g.nj
        guard points > 0, d.points == points else { return nil }
        let sw = southWest(g)
        guard let box = indexBox(g, sw, latRange: latRange, lonRange: lonRange) else { return nil }
        let wni = box.igHi - box.igLo + 1, wnj = box.jgHi - box.jgLo + 1
        guard wni > 0, wnj > 0, wni * wnj <= maxWindowPoints else { return nil }

        let values: [Float]?
        switch d.packing {
        case .simple: values = fillSimple(b, parts, g, d, box, wni: wni, wnj: wnj)
        case .png:    values = fillPNG(b, parts, g, d, box, wni: wni, wnj: wnj)
        }
        guard let values else { return nil }
        assert(values.count == wni * wnj, "Grib2Decoder: window buffer sized wrong")
        return Window(referenceTime: parts.referenceTime, discipline: parts.discipline,
                      paramCategory: pr.category, paramNumber: pr.number,
                      levelType: pr.levelType, levelValue: pr.levelValue,
                      ni: wni, nj: wnj,
                      minLat: sw.lat + Double(box.jgLo) * g.dLat,
                      minLon: sw.lon + Double(box.igLo) * g.dLon,
                      dLat: g.dLat, dLon: g.dLon, values: values)
    }

    /// Template 5.0 into a window: every value is at a computable bit offset, so only the ones inside the
    /// box are touched.
    private static func fillSimple(_ b: [UInt8], _ parts: Parts, _ g: Grid, _ d: DRS,
                                   _ box: IndexBox, wni: Int, wnj: Int) -> [Float]? {
        assert(d.packing == .simple, "Grib2Decoder: wrong filler for the packing")
        assert(wni > 0 && wnj > 0, "Grib2Decoder: empty window reached the filler")
        let scale = pow(2.0, Double(d.e)) / pow(10.0, Double(d.d))
        let offset = d.r / pow(10.0, Double(d.d))
        // `bits == 0` is a legal constant field: every point equals `R / 10^D`.
        guard d.bits > 0 else { return [Float](repeating: Float(offset), count: wni * wnj) }
        let iNegative = (g.scanMode & 0x80) != 0
        let jPositive = (g.scanMode & 0x40) != 0
        var out = [Float](repeating: .nan, count: wni * wnj)
        for jg in box.jgLo...box.jgHi {                          // bounded by the window cap (rule 2)
            let jn = jPositive ? jg : (g.nj - 1 - jg)
            let rowBase = jn * g.ni
            let dstRow = (jg - box.jgLo) * wni
            for ig in box.igLo...box.igHi {
                let inx = iNegative ? (g.ni - 1 - ig) : ig
                guard let x = packed(b, start: parts.dataStart, count: parts.dataCount,
                                     bitOffset: (rowBase + inx) * d.bits, width: d.bits) else {
                    return nil
                }
                out[dstRow + (ig - box.igLo)] = Float(offset + Double(x) * scale)
            }
        }
        return out
    }

    /// Template 5.41 into a window: scanlines stream past in the PNG's own order, the ones inside the box
    /// are sampled, and the decode is stopped the moment the box is behind us.
    private static func fillPNG(_ b: [UInt8], _ parts: Parts, _ g: Grid, _ d: DRS,
                                _ box: IndexBox, wni: Int, wnj: Int) -> [Float]? {
        assert(d.packing == .png, "Grib2Decoder: wrong filler for the packing")
        assert(wni > 0 && wnj > 0, "Grib2Decoder: empty window reached the filler")
        let end = parts.dataStart + parts.dataCount
        guard parts.dataStart >= 0, end <= b.count else { return nil }
        let png = Array(b[parts.dataStart..<end])
        guard let h = PNGGrayRows.header(png) else { return nil }
        // The raster must BE the grid. A mismatch means the two sections disagree about the field's
        // shape, and there is no safe way to choose which one is lying.
        guard h.width == g.ni, h.height == g.nj, h.bitDepth == d.bits else { return nil }

        let scale = pow(2.0, Double(d.e)) / pow(10.0, Double(d.d))
        let offset = d.r / pow(10.0, Double(d.d))
        let iNegative = (g.scanMode & 0x80) != 0
        let jPositive = (g.scanMode & 0x40) != 0
        let bps = h.bytesPerSample
        // The STORED row span the window needs; on a north-down grid it is the mirror of the
        // geographic one, and reading it the other way up puts Texas weather over Minnesota.
        let jnLo = jPositive ? box.jgLo : (g.nj - 1 - box.jgHi)
        let jnHi = jPositive ? box.jgHi : (g.nj - 1 - box.jgLo)
        assert(jnLo >= 0 && jnHi < g.nj && jnLo <= jnHi, "Grib2Decoder: stored row span out of range")

        var out = [Float](repeating: .nan, count: wni * wnj)
        var rowsFilled = 0
        let intact = PNGGrayRows.forEachRow(png) { jn, row in
            guard jn >= jnLo else { return true }                // still north of the window
            guard jn <= jnHi else { return false }               // past it (defensive; we stop below)
            let jg = jPositive ? jn : (g.nj - 1 - jn)
            let dstRow = (jg - box.jgLo) * wni
            for ig in box.igLo...box.igHi {                      // bounded by the window cap (rule 2)
                let inx = iNegative ? (g.ni - 1 - ig) : ig
                let o = inx * bps
                guard o + bps <= row.count else { return false }
                // PNG samples are big-endian within the row, like every other integer in GRIB2.
                let x: UInt32 = bps == 2 ? (UInt32(row[o]) << 8 | UInt32(row[o + 1]))
                                         : UInt32(row[o])
                out[dstRow + (ig - box.igLo)] = Float(offset + Double(x) * scale)
            }
            rowsFilled += 1
            return jn < jnHi                                     // false on the last one we need
        }
        guard intact, rowsFilled == jnHi - jnLo + 1 else { return nil }
        return out
    }

    /// Read a `width`-bit big-endian field at an arbitrary bit offset into section 7's payload.
    ///
    /// Simple packing leaves no padding between values, so a 10-bit field straddles byte boundaries three
    /// times in four — which is exactly the case a byte-aligned reader gets subtly wrong rather than
    /// obviously wrong. Returns nil if the field would run past the section.
    @inline(__always)
    private static func packed(_ b: [UInt8], start: Int, count: Int,
                               bitOffset: Int, width: Int) -> UInt32? {
        assert(width > 0 && width <= maxBitsPerValue, "Grib2Decoder: bit width out of range")
        assert(bitOffset >= 0, "Grib2Decoder: negative bit offset")
        let firstByte = bitOffset >> 3
        let lastByte = (bitOffset + width - 1) >> 3
        guard firstByte >= 0, lastByte < count, start + lastByte < b.count else { return nil }
        // width ≤ 32 plus a ≤ 7-bit lead spans at most 5 octets, so 40 bits — inside UInt64.
        var acc: UInt64 = 0
        var k = firstByte
        while k <= lastByte {                                    // bounded: ≤ 5 iterations (rule 2)
            acc = (acc << 8) | UInt64(b[start + k])
            k += 1
        }
        let spanBits = (lastByte - firstByte + 1) * 8
        let shift = spanBits - (bitOffset & 7) - width
        assert(shift >= 0, "Grib2Decoder: bit field span computed short")
        let mask: UInt64 = (UInt64(1) << UInt64(width)) - 1
        return UInt32(truncatingIfNeeded: (acc >> UInt64(shift)) & mask)
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
