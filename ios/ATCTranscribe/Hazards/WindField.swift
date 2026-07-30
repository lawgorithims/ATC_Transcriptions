import Foundation

/// A geographic box in degrees. Deliberately UIKit/MapKit-free so the fetch geometry stays pure and
/// unit-testable (the hosts convert their own region types, exactly as `RadarRegion` does for the radar).
struct WindBBox: Equatable, Codable, Sendable {
    let minLat, minLon, maxLat, maxLon: Double

    var latSpan: Double { maxLat - minLat }
    var lonSpan: Double { maxLon - minLon }

    func contains(lat: Double, lon: Double) -> Bool {
        lat >= minLat && lat <= maxLat && lon >= minLon && lon <= maxLon
    }

    /// Whether `other` fits entirely inside this box — the test for "the cached field still covers the
    /// screen", which is what decides whether a pan needs a new download.
    func contains(_ other: WindBBox) -> Bool {
        other.minLat >= minLat && other.maxLat <= maxLat
            && other.minLon >= minLon && other.maxLon <= maxLon
    }
}

/// One level's horizontal wind, as a regular latitude/longitude grid of U (eastward) and V (northward)
/// components in metres per second — the model's native form. Row 0 is the SOUTHERN edge and column 0 the
/// WESTERN edge; `Grib2Decoder` normalises the scan so that always holds.
struct WindField: Sendable {
    let level: WindLevel
    let minLat, minLon, dLat, dLon: Double
    let ni: Int          // points per row (longitude)
    let nj: Int          // rows (latitude)
    let u: [Float]       // ni * nj, row-major
    let v: [Float]

    static let mpsToKt: Float = 1.943_844

    var bbox: WindBBox {
        WindBBox(minLat: minLat, minLon: minLon,
                 maxLat: minLat + Double(nj - 1) * dLat,
                 maxLon: minLon + Double(ni - 1) * dLon)
    }

    /// Bilinearly interpolated wind at a coordinate, in **metres per second** (`x` = eastward,
    /// `y` = northward). nil outside the grid — the caller (the particle renderer) uses nil to respawn a
    /// particle rather than to draw a zero, because a stalled particle at the data edge reads as calm air.
    ///
    /// Nearest-neighbour would be visibly blocky at 0.25° (≈15 NM cells fill a quarter of the screen at
    /// approach zooms), so the interpolation is worth its cost even in the per-particle inner loop.
    func sample(lat: Double, lon: Double) -> SIMD2<Float>? {
        assert(dLat > 0 && dLon > 0, "WindField: non-positive grid step")
        assert(u.count == v.count, "WindField: component buffers disagree")
        let fx = (lon - minLon) / dLon
        let fy = (lat - minLat) / dLat
        guard fx >= 0, fy >= 0, fx <= Double(ni - 1), fy <= Double(nj - 1) else { return nil }
        let i0 = min(Int(fx), ni - 2), j0 = min(Int(fy), nj - 2)
        let tx = Float(fx - Double(i0)), ty = Float(fy - Double(j0))
        let a = j0 * ni + i0, b = a + 1, c = a + ni, d = c + 1
        guard d < u.count else { return nil }
        let uu = lerp(lerp(u[a], u[b], tx), lerp(u[c], u[d], tx), ty)
        let vv = lerp(lerp(v[a], v[b], tx), lerp(v[c], v[d], tx), ty)
        return SIMD2<Float>(uu, vv)
    }

    /// Speed in knots at a coordinate, for the readout and the colour ramp. nil outside the grid.
    func speedKt(lat: Double, lon: Double) -> Float? {
        guard let w = sample(lat: lat, lon: lon) else { return nil }
        assert(w.x.isFinite && w.y.isFinite, "WindField: non-finite sample")
        return (w.x * w.x + w.y * w.y).squareRoot() * Self.mpsToKt
    }

    /// Meteorological direction — the compass bearing the wind blows FROM, which is the only convention a
    /// pilot reads ("wind two-seven-zero at twenty"). Returned in 0…<360; a due-north wind is 0, and it is
    /// the readout's job to render that as the conventional "360". nil outside the grid.
    func directionFromDeg(lat: Double, lon: Double) -> Float? {
        guard let w = sample(lat: lat, lon: lon) else { return nil }
        assert(w.x.isFinite && w.y.isFinite, "WindField: non-finite sample")
        let deg = atan2(-w.x, -w.y) * 180 / .pi
        let wrapped = deg < 0 ? deg + 360 : deg
        assert(wrapped >= 0 && wrapped < 360.001, "WindField: direction escaped its range")
        return wrapped == 0 ? 0 : wrapped          // collapse atan2's signed zero
    }

    @inline(__always) private func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float {
        a + (b - a) * t
    }
}

/// Every level from one download, plus the model provenance the status chip shows. Held whole because a
/// single GRIB-filter request returns all ten levels (~1 MB): moving the altitude slider re-reads memory
/// and never touches the network, which is the entire reason the slider feels instant.
struct WindFieldSet: Sendable {
    let fields: [WindField]
    let bbox: WindBBox
    /// The model run this came from, UTC.
    let cycle: Date
    /// Forecast projection from `cycle`, in hours.
    let forecastHours: Int
    /// When the data is valid for — `cycle + forecastHours`.
    let validTime: Date
    /// When it was downloaded (or restored from disk).
    let fetchedAt: Date

    func field(_ level: WindLevel) -> WindField? {
        assert(fields.count <= WindLevel.allCases.count, "WindFieldSet: more fields than levels")
        return fields.first { $0.level == level }
    }

    /// Provenance for the status chip: "GFS 06z +9h".
    var cycleLabel: String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let hour = cal.component(.hour, from: cycle)
        assert(hour >= 0 && hour < 24, "WindFieldSet: cycle hour out of range")
        return String(format: "GFS %02dz +%dh", hour, forecastHours)
    }

    /// Pair the decoded U/V messages by level into fields. nil when nothing usable survived, so the caller
    /// can treat a structurally-valid-but-empty download as a failure and keep the last good set.
    ///
    /// GRIB2 discipline 0, category 2 (momentum): parameter 2 = U-component, 3 = V-component.
    static func build(from messages: [Grib2Decoder.Message], bbox: WindBBox, fetchedAt: Date) -> WindFieldSet? {
        assert(messages.count <= Grib2Decoder.maxMessages, "WindFieldSet: message count exceeded its cap")
        assert(bbox.latSpan >= 0, "WindFieldSet: inverted bbox")
        var fields: [WindField] = []
        var cycle: Date?
        var fcst = 0
        for level in WindLevel.allCases {                       // bounded: 10 levels (rule 2)
            let (type, value) = level.levelTypeAndValue
            let group = messages.filter { $0.levelType == type && $0.levelValue == value && $0.paramCategory == 2 }
            guard let um = group.first(where: { $0.paramNumber == 2 }),
                  let vm = group.first(where: { $0.paramNumber == 3 }),
                  um.ni == vm.ni, um.nj == vm.nj,
                  um.values.count == vm.values.count else { continue }
            fields.append(WindField(level: level, minLat: um.minLat, minLon: um.minLon,
                                    dLat: um.dLat, dLon: um.dLon, ni: um.ni, nj: um.nj,
                                    u: um.values, v: vm.values))
            if cycle == nil { cycle = um.referenceTime; fcst = um.forecastHours }
        }
        guard !fields.isEmpty, let cycle else { return nil }
        let valid = cycle.addingTimeInterval(TimeInterval(fcst) * 3600)
        return WindFieldSet(fields: fields, bbox: bbox, cycle: cycle, forecastHours: fcst,
                            validTime: valid, fetchedAt: fetchedAt)
    }
}
