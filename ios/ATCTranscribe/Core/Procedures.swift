import Foundation

/// One published FAA terminal procedure for an airport (from the bundled d-TPP index).
struct AirportProcedure: Identifiable, Equatable {
    enum Category: String { case approach, departure, arrival, diagram }
    let category: Category
    let name: String        // e.g. "ILS OR LOC RWY 04R", "LOGAN SIX DEPARTURE"
    let pdf: String         // plate filename, e.g. "00058IL4R.PDF"
    var id: String { category.rawValue + "|" + name + "|" + pdf }

    /// The FAA plate PDF for the bundled chart cycle (nil when there's no cycle/plate on file).
    var plateURL: URL? {
        guard !pdf.isEmpty, !Procedures.cycle.isEmpty else { return nil }
        return URL(string: "https://aeronav.faa.gov/d-tpp/\(Procedures.cycle)/\(pdf)")
    }
}

/// Lazy reader for the bundled `procedures.json` (built by `Tools/build_procedures.py` from the FAA
/// d-TPP metafile), keyed by ICAO ident. This is the procedure LIST + plate references — not coded
/// ARINC-424 geometry. A missing resource degrades to empty. Mirrors `NavMeta`'s load-once pattern.
enum Procedures {
    private struct DTO: Decodable {
        let cycle: String
        let airports: [String: [Rec]]
        struct Rec: Decodable { let c: String; let n: String; let f: String }
    }
    private static let data: DTO = load()

    /// The FAA chart cycle the bundled index was built for (e.g. "2607"); "" when missing.
    static var cycle: String { data.cycle }

    /// Published procedures for an airport, in the file's order (FAA groups them by kind already).
    static func forAirport(_ ident: String) -> [AirportProcedure] {
        let key = ident.trimmingCharacters(in: .whitespaces).uppercased()
        return (data.airports[key] ?? []).compactMap { r in
            AirportProcedure.Category(rawValue: r.c).map { AirportProcedure(category: $0, name: r.n, pdf: r.f) }
        }
    }

    /// Test seam / lazy-load probe (0 when the resource is missing).
    static var airportCount: Int { data.airports.count }

    private static func load() -> DTO {
        let url = Bundle.main.url(forResource: "procedures", withExtension: "json", subdirectory: "nav")
            ?? Bundle.main.url(forResource: "procedures", withExtension: "json")
        guard let url, let d = try? Data(contentsOf: url),
              let dto = try? JSONDecoder().decode(DTO.self, from: d) else { return DTO(cycle: "", airports: [:]) }
        return dto
    }
}
