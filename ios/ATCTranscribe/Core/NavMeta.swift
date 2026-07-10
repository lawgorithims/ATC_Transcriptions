import Foundation

/// Descriptive metadata for a navaid (VOR/VORTAC/NDB/…), shown in the map's tap-to-identify sheet.
struct NavaidMeta: Equatable {
    let type: String            // "VOR", "VOR-DME", "VORTAC", "TACAN", "DME", "NDB", "NDB-DME"
    let name: String?
    /// Frequency in MHz for VHF navaids, kHz for NDBs (unit picked by `isNDB`); nil if unpublished.
    let frequency: Double?
    /// Magnetic variation (deg, west negative). Bundled but unused until the map adds magnetic bearings.
    let magVar: Double?

    var isNDB: Bool { type.contains("NDB") }

    /// e.g. "VOR/DME", "VORTAC", "NDB".
    var typeLabel: String {
        switch type {
        case "VOR-DME": return "VOR/DME"
        case "NDB-DME": return "NDB/DME"
        default:        return type
        }
    }

    /// e.g. "112.70 MHz" or "385 kHz".
    var frequencyText: String? {
        guard let f = frequency else { return nil }
        return isNDB ? "\(Int(f.rounded())) kHz" : String(format: "%.2f MHz", f)
    }
}

/// Descriptive metadata for an airport that complements `airport_ctx.json` (runways + frequencies).
struct AirportMeta: Equatable {
    let name: String?
    let elevationFt: Int?
}

/// Lazy-loaded readers for the bundled `navaid_meta.json` / `airport_meta.json` tables (built by
/// `Tools/build_nav_meta.py` from OurAirports). Mirrors `NavDatabase`'s load-once-on-first-access
/// pattern; a missing resource degrades to empty (info sheet just shows ident + coordinates).
enum NavMeta {
    private struct NavaidDTO: Decodable { let t: String; let n: String?; let f: Double?; let mv: Double? }
    private struct AirportDTO: Decodable { let n: String?; let e: Int? }

    private static let navaids: [String: NavaidDTO] = load("navaid_meta")
    private static let airports: [String: AirportDTO] = load("airport_meta")

    static func navaid(_ ident: String) -> NavaidMeta? {
        guard let d = navaids[key(ident)] else { return nil }
        return NavaidMeta(type: d.t, name: d.n, frequency: d.f, magVar: d.mv)
    }

    static func airport(_ ident: String) -> AirportMeta? {
        guard let d = airports[key(ident)] else { return nil }
        return AirportMeta(name: d.n, elevationFt: d.e)
    }

    /// Idents whose airport/navaid NAME contains `query` (case-insensitive) — for the map search box.
    /// Names that START with the query rank first, then shorter names. Call off-main (debounced).
    static func identsMatchingName(_ query: String, limit: Int = 30) -> [String] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard q.count >= 2 else { return [] }
        var out: [(id: String, name: String)] = []
        for (id, d) in airports { if let n = d.n, n.lowercased().contains(q) { out.append((id, n)) } }
        for (id, d) in navaids  { if let n = d.n, n.lowercased().contains(q) { out.append((id, n)) } }
        out.sort {
            (($0.name.lowercased().hasPrefix(q) ? 0 : 1), $0.name.count, $0.name)
                < (($1.name.lowercased().hasPrefix(q) ? 0 : 1), $1.name.count, $1.name)
        }
        return Array(out.prefix(limit).map(\.id))
    }

    /// Test seams / lazy-load probes (0 when the resource is missing).
    static var navaidCount: Int { navaids.count }
    static var airportCount: Int { airports.count }

    private static func key(_ ident: String) -> String {
        ident.trimmingCharacters(in: .whitespaces).uppercased()
    }

    private static func load<T: Decodable>(_ name: String) -> [String: T] {
        let url = Bundle.main.url(forResource: name, withExtension: "json", subdirectory: "nav")
            ?? Bundle.main.url(forResource: name, withExtension: "json")
        guard let url, let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: T].self, from: data) else { return [:] }
        return dict
    }
}
