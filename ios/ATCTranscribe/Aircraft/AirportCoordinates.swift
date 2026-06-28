import Foundation

/// Resolves an ICAO ident (e.g. "KBOS") to a coordinate, from a bundled compact table. Used to
/// center the 30 NM ADS-B query on the typed airport when no curated `AirportConfig` carries
/// lat/lon. Device GPS will sit *ahead* of this later — `ADSBService` only ever receives a `Coord`,
/// so swapping the source needs no service change.
enum AirportCoordinates {
    private static let table: [String: [Double]] = load()

    /// Coordinate for an ICAO ident, or nil when unknown (→ no polling, empty traffic).
    static func coordinate(icao: String) -> Coord? {
        let key = icao.trimmingCharacters(in: .whitespaces).uppercased()
        guard let pair = table[key], pair.count == 2 else { return nil }
        return Coord(lat: pair[0], lon: pair[1])
    }

    /// Test seam: the count of bundled airports (0 if the resource is missing).
    static var count: Int { table.count }

    private static func load() -> [String: [Double]] {
        let url = Bundle.main.url(forResource: "icao_coords", withExtension: "json", subdirectory: "airports")
            ?? Bundle.main.url(forResource: "icao_coords", withExtension: "json")
        guard let url, let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: [Double]].self, from: data) else { return [:] }
        return dict
    }
}
