import Foundation

// MARK: - Shared geodesy (lifted from RouteMapSheet so the map + info sheet share one implementation)

/// Great-circle distance/bearing helpers. Bearings are **TRUE** (magnetic comes in a later phase, once
/// the bundled `NavMeta` magnetic variation is wired in).
enum Geo {
    /// Great-circle distance in nautical miles (haversine, R = 3440.065 NM).
    static func nmBetween(_ a: Coord, _ b: Coord) -> Double {
        let R = 3440.065
        let la1 = a.lat * .pi / 180, la2 = b.lat * .pi / 180
        let dLa = (b.lat - a.lat) * .pi / 180, dLo = (b.lon - a.lon) * .pi / 180
        let h = sin(dLa / 2) * sin(dLa / 2) + cos(la1) * cos(la2) * sin(dLo / 2) * sin(dLo / 2)
        return 2 * R * asin(min(1, sqrt(h)))
    }

    /// Initial great-circle TRUE bearing a→b, degrees 0–360.
    static func bearing(_ a: Coord, _ b: Coord) -> Double {
        let la1 = a.lat * .pi / 180, la2 = b.lat * .pi / 180
        let dLo = (b.lon - a.lon) * .pi / 180
        let y = sin(dLo) * cos(la2)
        let x = cos(la1) * sin(la2) - sin(la1) * cos(la2) * cos(dLo)
        let brg = atan2(y, x) * 180 / .pi
        return brg < 0 ? brg + 360 : brg
    }

    /// Even-odd ray-cast point-in-ring test — shared by airspace containment and EONET hazard
    /// perimeters (lifted from the `Airspace` extension below when hazards arrived).
    static func pointInRing(_ p: Coord, _ ring: [Coord]) -> Bool {
        guard ring.count > 2 else { return false }
        var inside = false
        var j = ring.count - 1
        for i in 0..<ring.count {
            let a = ring[i], b = ring[j]
            if (a.lat > p.lat) != (b.lat > p.lat) {
                let xInt = a.lon + (p.lat - a.lat) / (b.lat - a.lat) * (b.lon - a.lon)
                if p.lon < xInt { inside.toggle() }
            }
            j = i
        }
        return inside
    }
}

// MARK: - Identified map objects (result of a tap)

/// What kind of thing the user tapped. Point features (airport/vor/fix/traffic/hazard) rank above
/// the area feature (airspace) in a disambiguation list.
enum MapObjectKind: String {
    case airport, vor, fix, airspace, traffic, userPoint, hazard, tfr, airway

    /// Lower sorts first: point features before line features (airways) before the containing areas.
    var priority: Int {
        if self == .airway { return 1 }
        return (self == .airspace || self == .tfr) ? 2 : 0
    }

    var label: String {
        switch self {
        case .airport:   return "Airport"
        case .vor:       return "Navaid"
        case .fix:       return "Fix"
        case .airspace:  return "Airspace"
        case .traffic:   return "Traffic"
        case .userPoint: return "Point"
        case .hazard:    return "Hazard"
        case .tfr:       return "TFR"
        case .airway:    return "Airway"
        }
    }

    /// Map a resolved route leg's kind onto a probe kind (airways never resolve to a point).
    init(routeKind: RouteKind) {
        switch routeKind {
        case .airport: self = .airport
        case .vor:     self = .vor
        default:       self = .fix
        }
    }

    /// Anything with a location can be filed into the route; areas/lines/traffic cannot (an AIRWAY is
    /// filed by TYPING it between two fixes, not by tapping a spot on it).
    var isRoutable: Bool {
        self != .airspace && self != .traffic && self != .hazard && self != .tfr && self != .airway
    }
}

/// A "user waypoint" — an arbitrary point dropped by long-pressing the map. Stored in the route as a
/// compact `lat,lon` token (real idents never contain a comma, so it round-trips unambiguously).
enum UserPoint {
    static func parse(_ token: String) -> Coord? {
        let parts = token.split(separator: ",")
        guard parts.count == 2,
              let lat = Double(parts[0].trimmingCharacters(in: .whitespaces)),
              let lon = Double(parts[1].trimmingCharacters(in: .whitespaces)),
              (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
        return Coord(lat: lat, lon: lon)
    }
    static func token(_ c: Coord) -> String { String(format: "%.3f,%.3f", c.lat, c.lon) }   // ~100 m
    static func isUserPoint(_ ident: String) -> Bool { parse(ident) != nil }
    /// Short display form, e.g. "42.10, −71.30".
    static func label(_ ident: String) -> String {
        guard let c = parse(ident) else { return ident }
        return String(format: "%.2f, %.2f", c.lat, c.lon)
    }
}

/// One object the user tapped, with just enough to drive the info sheet + route actions. Rich detail
/// (runways/frequencies for airports, type/frequency for navaids) is looked up lazily in the sheet from
/// `AirportContextStore` / `NavMeta` by `ident`.
struct IdentifiedObject: Identifiable {
    let kind: MapObjectKind
    let ident: String
    let coord: Coord
    let onRoute: Bool                 // already a leg of the filed plan → offer "Remove from route"
    var airspace: Airspace? = nil     // populated when kind == .airspace
    var traffic: Aircraft? = nil      // populated when kind == .traffic
    var hazard: EONETEvent? = nil     // populated when kind == .hazard
    var tfr: TFR? = nil               // populated when kind == .tfr
    var airwayArea: String? = nil     // populated when kind == .airway — the ARINC area for the MEA lookup

    /// Stable across a single probe so `.sheet(item:)` / `ForEach` are well-behaved.
    var id: String { "\(kind.rawValue)|\(ident)|\(coord.lat),\(coord.lon)" }
}

/// The result of one tap: the ranked candidates under the finger. Presented via `.sheet(item:)`; the
/// sheet shows a chooser when there's more than one, else drills straight into the single object.
struct MapProbeResult: Identifiable {
    let id: String                    // distinct per tap so re-tapping the same spot re-presents
    let objects: [IdentifiedObject]
    var primary: IdentifiedObject? { objects.first }
}

// MARK: - Pure ranking (unit-tested; screen distances are computed by the map coordinator)

enum MapProbe {
    /// Keep candidates within `radius` (points), point features before airspace, nearest first.
    static func rank(_ candidates: [(object: IdentifiedObject, distance: Double)],
                     within radius: Double) -> [IdentifiedObject] {
        candidates
            .filter { $0.distance <= radius }
            .sorted { ($0.object.kind.priority, $0.distance) < ($1.object.kind.priority, $1.distance) }
            .map { $0.object }
    }
}

// MARK: - Search (ident + name → identified objects)

/// Backs the map search box: match by identifier prefix (via `NavDatabase`) then by airport/navaid
/// name (via `NavMeta`), de-duped, ident matches first. Returns objects the search sheet can center on
/// and act upon exactly like a tap.
enum MapSearch {
    static func results(_ query: String, limit: Int = 30) -> [IdentifiedObject] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        var seen = Set<String>()
        var out: [IdentifiedObject] = []

        for np in NavDatabase.search(prefix: q, limit: limit) where seen.insert(np.ident).inserted {
            out.append(IdentifiedObject(kind: MapObjectKind(routeKind: np.kind), ident: np.ident, coord: np.coord, onRoute: false))
        }
        if q.count >= 2 {
            for id in NavMeta.identsMatchingName(q, limit: limit) {
                let key = id.uppercased()
                guard seen.insert(key).inserted, let c = NavDatabase.resolve(key, near: nil) else { continue }
                out.append(IdentifiedObject(kind: MapObjectKind(routeKind: RouteLeg.classify(key)), ident: key, coord: c, onRoute: false))
            }
        }
        return Array(out.prefix(limit))
    }
}

extension Airspace {
    /// True when `c` falls inside any of this airspace's lateral rings (even-odd ray casting).
    func containsCoord(_ c: Coord) -> Bool {
        rings.contains { Geo.pointInRing(c, $0) }
    }
}
