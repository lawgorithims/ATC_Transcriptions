import Foundation

/// A precomputed georeference for one plate PDF: the placement that lands the plate's plan view on
/// the map (center of the full page in lat/lon, the geographic width the page spans, and a
/// clockwise-from-north rotation ≈ 0 since FAA plan views are north-up), plus the fit's residual and
/// control-point count for a confidence read.
struct PlateGeorefEntry {
    let centerLat: Double
    let centerLon: Double
    let widthMeters: Double
    let rotationDeg: Double
    let rmsMeters: Double
    let inliers: Int
}

/// Bundled lookup of the offline plate-georeference table (`nav/plate_georef.json`, built by
/// `Tools/build_plate_georef` — OCR the plate, match its fixes to CIFP coords, solve a similarity).
/// Only high-confidence fits are in the table, so a hit means the plate can be auto-aligned; a miss
/// means the pilot hand-aligns it. Load-once, like `NavMeta`/`Procedures`.
enum PlateGeoref {
    private struct DTO: Decodable {
        let cycle: String
        let plates: [String: Entry]
        struct Entry: Decodable {
            let centerLat: Double; let centerLon: Double; let widthMeters: Double
            let rotationDeg: Double; let rmsMeters: Double; let inliers: Int
        }
    }
    private static let data: DTO = load()

    /// The chart cycle the table was built for ("" when the resource is absent).
    static var cycle: String { data.cycle }
    /// How many plates have a georeference (0 when the resource is absent).
    static var count: Int { data.plates.count }

    /// The precomputed placement for a plate's PDF filename, or nil if it wasn't confidently fit.
    static func lookup(pdf: String) -> PlateGeorefEntry? {
        guard let e = data.plates[pdf] else { return nil }
        return PlateGeorefEntry(centerLat: e.centerLat, centerLon: e.centerLon, widthMeters: e.widthMeters,
                                rotationDeg: e.rotationDeg, rmsMeters: e.rmsMeters, inliers: e.inliers)
    }

    private static func load() -> DTO {
        let url = Bundle.main.url(forResource: "plate_georef", withExtension: "json", subdirectory: "nav")
            ?? Bundle.main.url(forResource: "plate_georef", withExtension: "json")
        guard let url, let d = try? Data(contentsOf: url),
              let dto = try? JSONDecoder().decode(DTO.self, from: d) else { return DTO(cycle: "", plates: [:]) }
        return dto
    }
}
