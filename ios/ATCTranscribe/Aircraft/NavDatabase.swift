import Foundation

/// An axis-aligned lat/lon box — the map's visible region (plus a margin) used to pull only the
/// nearby navaids/airports and controlled-airspace outlines worth drawing. MapKit-free on purpose so
/// `NavDatabase` stays a pure data layer (the map builds the box from its `MKCoordinateRegion`).
struct BBox {
    let minLat, minLon, maxLat, maxLon: Double
    func contains(lat: Double, lon: Double) -> Bool {
        lat >= minLat && lat <= maxLat && lon >= minLon && lon <= maxLon
    }
    func intersects(_ o: BBox) -> Bool {
        minLat <= o.maxLat && maxLat >= o.minLat && minLon <= o.maxLon && maxLon >= o.minLon
    }
    var centerLat: Double { (minLat + maxLat) / 2 }
    var centerLon: Double { (minLon + maxLon) / 2 }
}

/// A bundled navaid / airport plotted for map context (not necessarily on the filed route).
struct NavPoint: Identifiable {
    let ident: String
    let coord: Coord
    let kind: RouteKind
    var id: String { "\(ident)|\(coord.lat)|\(coord.lon)" }
}

/// A lateral controlled-airspace outline — FAA NASR Class B / C / D (see `Tools/build_airspace_db.py`
/// for provenance). `rings` are the polygon boundaries (an airspace can be several concentric shelves);
/// `floorFt`/`ceilingFt` are the raw NASR values when numeric.
struct Airspace: Identifiable {
    let id: Int
    let cls: String        // "B" | "C" | "D"
    let name: String
    let floorFt: Int?
    let ceilingFt: Int?
    let bb: BBox
    let rings: [[Coord]]
}

/// Resolves a route identifier (VOR, RNAV/GPS fix, or airport) to a coordinate from the bundled
/// `nav_coords.json` table (built by `Tools/build_nav_db.py` from OurAirports + FAA NASR — see that
/// script for provenance). Identifiers aren't globally unique, so each maps to a LIST of candidate
/// coordinates `[lat, lon, kind]` (kind: 0=airport, 1=navaid, 2=fix) and `resolve(_:near:)` picks the
/// one nearest a reference point (the previous resolved leg), so a filed route walks the intended
/// chain of same-named fixes. Also serves the map's context layers: `nearby(_:)` (navaids/airports in
/// view) and `airspaces(intersecting:)` (Class B/C/D outlines from the separate `airspace.json`).
///
/// Both tables load lazily on first access — keep that OFF the app-launch / main-render path (callers
/// force the parse on a background task before rendering; see `RouteMapSheet.buildRoute`). Airports
/// still resolve via the small curated `AirportCoordinates` first; this is the fallback plus the sole
/// source of navaids/fixes.
enum NavDatabase {
    /// ident → candidate `[lat, lon, kind]` triples.
    private static let table: [String: [[Double]]] = load()

    /// Every candidate coordinate for an ident (empty when unknown).
    static func candidates(_ ident: String) -> [Coord] {
        let key = ident.trimmingCharacters(in: .whitespaces).uppercased()
        return (table[key] ?? []).compactMap { $0.count >= 2 ? Coord(lat: $0[0], lon: $0[1]) : nil }
    }

    /// The candidate nearest `near`, or the first one when `near` is nil / there's a single candidate.
    static func resolve(_ ident: String, near: Coord?) -> Coord? {
        let cands = candidates(ident)
        guard let near, cands.count > 1 else { return cands.first }
        return cands.min { squaredDistance($0, near) < squaredDistance($1, near) }
    }

    /// Kind code (0=airport, 1=navaid, 2=fix) → its on-chart role.
    static func kind(forCode t: Int) -> RouteKind {
        switch t {
        case 0:  return .airport
        case 1:  return .vor
        default: return .waypoint
        }
    }

    /// Navaids/airports whose coordinate falls in `region`, for map context. Scans the full table
    /// (~90k idents) — call once off-main per settled region, not per camera frame. `types` filters by
    /// kind code (0=airport, 1=navaid; fixes are excluded — too dense to plot). When more than `limit`
    /// fall in view, keeps the ones nearest the region centre.
    static func nearby(_ region: BBox, types: Set<Int> = [0, 1], limit: Int = 160) -> [NavPoint] {
        var out: [NavPoint] = []
        for (ident, cands) in table {
            for c in cands where c.count >= 3 {
                let t = Int(c[2])
                if types.contains(t), region.contains(lat: c[0], lon: c[1]) {
                    out.append(NavPoint(ident: ident, coord: Coord(lat: c[0], lon: c[1]), kind: kind(forCode: t)))
                }
            }
        }
        if out.count > limit {
            let clat = region.centerLat, clon = region.centerLon
            out.sort { squaredDistance($0.coord, Coord(lat: clat, lon: clon))
                     < squaredDistance($1.coord, Coord(lat: clat, lon: clon)) }
            out = Array(out.prefix(limit))
        }
        return out
    }

    /// Controlled-airspace outlines (Class B/C/D) whose bounding box overlaps `region`.
    static func airspaces(intersecting region: BBox) -> [Airspace] {
        airspaceTable.filter { $0.bb.intersects(region) }
    }

    /// Cheap equirectangular squared distance — accurate enough to pick the nearest of a few
    /// candidates (longitude degrees shrink with latitude, so scale them by cos(lat)).
    private static func squaredDistance(_ a: Coord, _ b: Coord) -> Double {
        let dLat = a.lat - b.lat
        let dLon = (a.lon - b.lon) * cos(b.lat * .pi / 180)
        return dLat * dLat + dLon * dLon
    }

    /// Test seam / lazy-load probe: bundled ident count (0 when the resource is missing).
    static var count: Int { table.count }
    /// Test seam: bundled airspace-feature count (0 when the resource is missing).
    static var airspaceCount: Int { airspaceTable.count }

    private static func load() -> [String: [[Double]]] {
        let url = Bundle.main.url(forResource: "nav_coords", withExtension: "json", subdirectory: "nav")
            ?? Bundle.main.url(forResource: "nav_coords", withExtension: "json")
        guard let url, let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: [[Double]]].self, from: data) else { return [:] }
        return dict
    }

    private static let airspaceTable: [Airspace] = loadAirspace()

    private struct AirspaceDTO: Decodable {
        let c: String; let n: String; let lo: Int?; let hi: Int?
        let bb: [Double]; let r: [[[Double]]]
    }

    private static func loadAirspace() -> [Airspace] {
        let url = Bundle.main.url(forResource: "airspace", withExtension: "json", subdirectory: "nav")
            ?? Bundle.main.url(forResource: "airspace", withExtension: "json")
        guard let url, let data = try? Data(contentsOf: url),
              let dtos = try? JSONDecoder().decode([AirspaceDTO].self, from: data) else { return [] }
        return dtos.enumerated().compactMap { i, d -> Airspace? in
            guard d.bb.count == 4 else { return nil }
            let rings = d.r
                .map { ring in ring.compactMap { $0.count == 2 ? Coord(lat: $0[0], lon: $0[1]) : nil } }
                .filter { $0.count >= 3 }
            guard !rings.isEmpty else { return nil }
            return Airspace(id: i, cls: d.c, name: d.n, floorFt: d.lo, ceilingFt: d.hi,
                            bb: BBox(minLat: d.bb[0], minLon: d.bb[1], maxLat: d.bb[2], maxLon: d.bb[3]),
                            rings: rings)
        }
    }
}
