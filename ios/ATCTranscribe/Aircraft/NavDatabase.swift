import Foundation

/// Resolves a route identifier (VOR, RNAV/GPS fix, or airport) to a coordinate from the bundled
/// `nav_coords.json` table (built by `Tools/build_nav_db.py` from OurAirports + FAA NASR — see that
/// script for provenance). Identifiers aren't globally unique, so each maps to a LIST of candidate
/// coordinates and `resolve(_:near:)` picks the one nearest a reference point (the previous resolved
/// route leg), so a filed route walks the intended chain of same-named fixes.
///
/// The table (~90k idents, ~2.8 MB) loads lazily on first access — keep that OFF the app-launch /
/// main-render path (callers force the parse on a background task before rendering; see
/// `RouteMapSheet.buildRoute`). Airports still resolve via the small curated `AirportCoordinates`
/// first; this is the fallback plus the sole source of navaids/fixes.
enum NavDatabase {
    /// ident → candidate `[lat, lon]` pairs.
    private static let table: [String: [[Double]]] = load()

    /// Every candidate coordinate for an ident (empty when unknown).
    static func candidates(_ ident: String) -> [Coord] {
        let key = ident.trimmingCharacters(in: .whitespaces).uppercased()
        return (table[key] ?? []).compactMap { $0.count == 2 ? Coord(lat: $0[0], lon: $0[1]) : nil }
    }

    /// The candidate nearest `near`, or the first one when `near` is nil / there's a single candidate.
    static func resolve(_ ident: String, near: Coord?) -> Coord? {
        let cands = candidates(ident)
        guard let near, cands.count > 1 else { return cands.first }
        return cands.min { squaredDistance($0, near) < squaredDistance($1, near) }
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

    private static func load() -> [String: [[Double]]] {
        let url = Bundle.main.url(forResource: "nav_coords", withExtension: "json", subdirectory: "nav")
            ?? Bundle.main.url(forResource: "nav_coords", withExtension: "json")
        guard let url, let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: [[Double]]].self, from: data) else { return [:] }
        return dict
    }
}
