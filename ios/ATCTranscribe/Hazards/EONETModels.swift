import Foundation

// MARK: - NASA EONET natural events (satellite-observed hazards)

/// The EONET v3 event categories surfaced on the map. Raw values are EONET's category ids (used
/// verbatim in the `/events?category=` query and in the cached snapshot).
enum EONETCategory: String, CaseIterable, Sendable, Codable {
    case wildfires, severeStorms, dustHaze, volcanoes

    var label: String {
        switch self {
        case .wildfires:    return "Wildfire"
        case .severeStorms: return "Severe storm"
        case .dustHaze:     return "Dust / haze"
        case .volcanoes:    return "Volcano"
        }
    }

    /// SF Symbol for the map marker glyph + info badges.
    var glyph: String {
        switch self {
        case .wildfires:    return "flame.fill"
        case .severeStorms: return "hurricane"
        case .dustHaze:     return "sun.dust.fill"
        case .volcanoes:    return "mountain.2.fill"
        }
    }
}

/// One open EONET event, normalized to its NEWEST geometry: a representative `point` for the map
/// marker, plus the latest polygon ring (dust/ash perimeters) and the dated point series (storm
/// tracks) when present. `Codable` so the last snapshot round-trips through the disk cache;
/// `Sendable` so it crosses the `EONETService` actor boundary.
struct EONETEvent: Sendable, Equatable, Identifiable, Codable {
    let id: String            // e.g. "EONET_1234"
    let title: String
    let category: EONETCategory
    let updatedAt: Date       // date of the newest geometry entry (.distantPast when unparsable)
    let point: Coord          // latest Point, else the polygon ring's centroid
    let polygon: [Coord]      // latest Polygon outer ring, vertex-capped; [] for point events
    let track: [Coord]        // dated storm fixes, oldest→newest, capped; [] for non-storms
    let magnitudeValue: Double?   // newest geometry's magnitude (fires: acres, storms: kts); nil if none
    let magnitudeUnit: String?    // the unit STRING exactly as EONET reports it — never assume it, show it

    /// Trailing-defaulted so the demo/test constructors that predate magnitude keep compiling; the
    /// decoder passes the real values. (Codable synthesis is unaffected by an explicit init.)
    init(id: String, title: String, category: EONETCategory, updatedAt: Date,
         point: Coord, polygon: [Coord], track: [Coord],
         magnitudeValue: Double? = nil, magnitudeUnit: String? = nil) {
        self.id = id; self.title = title; self.category = category; self.updatedAt = updatedAt
        self.point = point; self.polygon = polygon; self.track = track
        self.magnitudeValue = magnitudeValue; self.magnitudeUnit = magnitudeUnit
    }

    static let maxPolygonVertices = 256   // subsample above this (rule 2 — bounded rendering)
    static let maxTrackPoints = 64
    static let maxEventsPerCategory = 100
    static let maxGeometryEntries = 512   // a long-lived storm carries hundreds of dated fixes
    static let maxResponseBytes = 20_000_000
}

// MARK: - Tolerant decode (EONET /api/v3/events)

extension EONETEvent {
    private static let iso8601 = ISO8601DateFormatter()   // thread-safe per Apple docs

    /// Decode one `/events` response for `category` (the feed is queried per category, so every
    /// event in a response shares it). Tolerant WITHIN a valid envelope like `Aircraft.decode`: a
    /// malformed event is dropped, never fatal. Returns **nil** when the body is NOT a valid EONET
    /// events envelope (unparseable, or no `events` array) — so the caller treats a 200-with-garbage
    /// (maintenance/HTML/rate-limit page) as a FAILED poll rather than an empty success that would
    /// clobber the good cached snapshot. A genuine `{"events":[]}` decodes to an empty array (not
    /// nil). GeoJSON order is [lon, lat].
    static func decode(_ data: Data, category: EONETCategory) -> [EONETEvent]? {
        assert(!category.rawValue.isEmpty, "category id must be non-empty")
        assert(data.count <= maxResponseBytes || data.count > 0, "response size sanity")
        guard data.count <= maxResponseBytes,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rawEvents = root["events"] as? [[String: Any]] else { return nil }
        var out: [EONETEvent] = []
        out.reserveCapacity(min(rawEvents.count, maxEventsPerCategory))
        for raw in rawEvents.prefix(maxEventsPerCategory) {         // bounded (rule 2)
            guard let ev = decodeOne(raw, category: category) else { continue }
            out.append(ev)
        }
        assert(out.count <= maxEventsPerCategory, "per-category cap violated")
        return out
    }

    /// One raw event → normalized `EONETEvent`, or nil when it has no id or no parsable geometry.
    /// The newest geometry wins: latest Point becomes the marker, the latest Polygon the perimeter;
    /// only storms keep their dated-point series as a track (fires also re-fix over time, but a
    /// perimeter-centroid "track" would be misleading).
    private static func decodeOne(_ raw: [String: Any], category: EONETCategory) -> EONETEvent? {
        guard let id = raw["id"] as? String, !id.isEmpty,
              let geoms = raw["geometry"] as? [[String: Any]], !geoms.isEmpty else { return nil }
        var datedPoints: [(date: Date, coord: Coord, mag: Double?, unit: String?)] = []
        var ring: [Coord] = []
        var ringDate = Date.distantPast
        var newest = Date.distantPast
        for g in geoms.suffix(maxGeometryEntries) {                 // bounded; EONET orders oldest→newest
            let date = (g["date"] as? String).flatMap { iso8601.date(from: $0) } ?? .distantPast
            if date > newest { newest = date }
            switch g["type"] as? String {
            case "Point":
                guard let c = coord(g["coordinates"]) else { continue }
                // Magnitude is per-geometry (a storm's intensity changes along its track); carry it
                // so the marker reports the NEWEST value with its real unit — never a bare number.
                datedPoints.append((date, c, double(g["magnitudeValue"]), g["magnitudeUnit"] as? String))
            case "Polygon":
                guard date >= ringDate,
                      let rings = g["coordinates"] as? [[Any]],
                      let outer = rings.first else { continue }
                let parsed = parseRing(outer)
                if parsed.count >= 3 { ring = parsed; ringDate = date }
            default:
                continue
            }
        }
        assert(datedPoints.count <= maxGeometryEntries, "point series bounded by the geometry cap")
        // Defensive sort: the ordering is documented but the marker + track depend on it.
        datedPoints.sort { $0.date < $1.date }
        let marker = datedPoints.last                               // newest fix drives point + magnitude
        guard let point = marker?.coord ?? centroid(ring) else { return nil }
        assert(ring.count <= maxPolygonVertices, "ring capped by parseRing")
        let track = (category == .severeStorms && datedPoints.count >= 2)
            ? datedPoints.suffix(maxTrackPoints).map(\.coord) : []
        return EONETEvent(id: id, title: (raw["title"] as? String) ?? category.label,
                          category: category, updatedAt: newest,
                          point: point, polygon: ring, track: track,
                          magnitudeValue: marker?.mag, magnitudeUnit: marker?.unit)
    }

    /// GeoJSON position → `Coord`. Order is [lon, lat]; longitudes are wrapped once into ±180
    /// (storm tracks cross the antimeridian), out-of-range latitudes reject the position.
    private static func coord(_ any: Any?) -> Coord? {
        guard let pair = any as? [Any], pair.count >= 2,
              let lon0 = double(pair[0]), let lat = double(pair[1]) else { return nil }
        var lon = lon0
        if lon > 180 { lon -= 360 }
        if lon < -180 { lon += 360 }
        guard (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
        return Coord(lat: lat, lon: lon)
    }

    private static func double(_ any: Any?) -> Double? {   // Any? so `double(dict[key])` needs no coercion
        (any as? NSNumber)?.doubleValue
    }

    /// Outer-ring positions → capped `[Coord]`. Above the vertex cap, stride-subsample so the
    /// shape survives at render scale without unbounded memory (rule 2).
    private static func parseRing(_ positions: [Any]) -> [Coord] {
        let step = max(1, (positions.count + maxPolygonVertices - 1) / maxPolygonVertices)
        assert(step >= 1, "stride is positive")
        var out: [Coord] = []
        out.reserveCapacity(min(positions.count, maxPolygonVertices))
        var i = 0
        while i < positions.count, out.count < maxPolygonVertices {   // explicit bound (rule 2)
            if let c = coord(positions[i]) { out.append(c) }
            i += step
        }
        assert(out.count <= maxPolygonVertices, "vertex cap enforced")
        return out
    }

    /// Vertex average for the marker — antimeridian-safe: longitudes are averaged relative to the
    /// first vertex (each delta wrapped into ±180) so a ring straddling ±180 (Aleutian/Kamchatka ash)
    /// gets a marker on the ring, not at lon 0 on the far side of the globe.
    private static func centroid(_ ring: [Coord]) -> Coord? {
        guard let first = ring.first else { return nil }
        assert(ring.count <= maxPolygonVertices, "ring capped upstream")
        var lat = 0.0, lonDelta = 0.0
        for c in ring {                                              // bounded by the vertex cap
            lat += c.lat
            var d = c.lon - first.lon
            if d > 180 { d -= 360 }
            if d < -180 { d += 360 }
            lonDelta += d
        }
        let n = Double(ring.count)
        var lon = first.lon + lonDelta / n
        if lon > 180 { lon -= 360 }
        if lon < -180 { lon += 360 }
        return Coord(lat: lat / n, lon: lon)
    }
}

// MARK: - Demo seed (--demo-hazards)

extension EONETEvent {
    /// Synthetic events near the KBOS–KORD demo route (`--demo-flightplan`) so the layer, the tap
    /// cards, and the route banner can be exercised offline (sim screenshots / manual QA).
    static func demoEvents(now: Date = Date()) -> [EONETEvent] {
        let dustRing = [Coord(lat: 42.2, lon: -78.1), Coord(lat: 42.7, lon: -78.0),
                        Coord(lat: 42.9, lon: -77.3), Coord(lat: 42.3, lon: -77.2)]
        let track = [Coord(lat: 40.8, lon: -72.6), Coord(lat: 41.2, lon: -73.3),
                     Coord(lat: 41.6, lon: -74.1)]
        return [
            EONETEvent(id: "DEMO_FIRE", title: "Finger Lakes Wildfire (demo)",
                       category: .wildfires, updatedAt: now.addingTimeInterval(-3600),
                       point: Coord(lat: 42.80, lon: -76.30), polygon: [], track: [],
                       magnitudeValue: 12_450, magnitudeUnit: "acres"),
            EONETEvent(id: "DEMO_DUST", title: "Western NY Dust Plume (demo)",
                       category: .dustHaze, updatedAt: now.addingTimeInterval(-7200),
                       point: Coord(lat: 42.55, lon: -77.65), polygon: dustRing, track: []),
            EONETEvent(id: "DEMO_STORM", title: "Tropical Storm Demo",
                       category: .severeStorms, updatedAt: now.addingTimeInterval(-1800),
                       point: Coord(lat: 41.6, lon: -74.1), polygon: [], track: track,
                       magnitudeValue: 55, magnitudeUnit: "kts"),
        ]
    }
}

// MARK: - Magnitude presentation (value + its real unit + a plain-English band; never a bare number)

extension EONETEvent {
    /// Row label for the magnitude, by category — "Size" for a fire, "Intensity" for a storm.
    var magnitudeLabel: String {
        switch category {
        case .wildfires: return "Size"
        case .severeStorms: return "Intensity"
        default: return "Magnitude"
        }
    }

    /// Human magnitude for the tap card: the value WITH its real EONET unit, plus a plain-English band.
    /// nil when the event carries no magnitude (dust, volcanoes, …). Deliberately never a bare number —
    /// "5" is meaningless; "5,000 acres" vs "55 kt" is the whole point.
    var magnitudeText: String? {
        guard let v = magnitudeValue, v.isFinite, let unit = magnitudeUnit, !unit.isEmpty else { return nil }
        assert(v.isFinite, "finite past the guard")
        assert(!unit.isEmpty, "unit non-empty past the guard")
        switch unit.lowercased() {
        case "acres":
            let word = v.rounded() == 1 ? "acre" : "acres"        // "1 acre", not "1 acres"
            return Self.grouped(v) + " " + word + (v >= 10_000 ? " · major" : "")
        case "hectare", "hectares", "ha":
            return Self.grouped(v) + " ha" + (v >= 4_000 ? " · major" : "")
        case "kts", "kt", "knots":
            // Guard the Double→Int conversion: a garbage-but-parseable feed value beyond Int range would
            // TRAP (crash in release, unlike an assert). Absurd values fall back to a plain, safe render.
            guard v >= 0, v < 1e9 else { return Self.grouped(v) + " kt" }
            let kt = Int(v.rounded())
            let band = kt >= 64 ? "Hurricane force" : kt >= 34 ? "Tropical storm" : "Depression"
            return "\(band) · \(kt) kt"
        case "nm^2", "nm2", "nmi^2":
            return Self.grouped(v) + " NM²"
        default:
            return Self.grouped(v) + " " + unit          // unknown unit — value + raw unit, still never bare
        }
    }

    /// Thousands-grouped integer rendering of a magnitude (locale decimal style, fraction digits off).
    private static func grouped(_ v: Double) -> String {
        assert(v.isFinite, "finite magnitude")
        let n = v.rounded()
        assert(abs(n) < 1e15, "within formatter range")
        // Fallback uses %.0f (never Int(n), which would trap past Int range) so this can't crash.
        return groupFormatter.string(from: NSNumber(value: n)) ?? String(format: "%.0f", n)
    }
    private static let groupFormatter: NumberFormatter = {
        let f = NumberFormatter(); f.numberStyle = .decimal; f.maximumFractionDigits = 0; return f
    }()
}
