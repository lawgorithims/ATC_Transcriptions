import Foundation

/// One published FAA terminal procedure/chart for an airport (from the bundled d-TPP index).
struct AirportProcedure: Identifiable, Equatable {
    /// The ForeFlight-style tab a chart is grouped under.
    enum Category: String, CaseIterable { case airport, departure, arrival, approach, other }

    let code: String        // raw FAA d-TPP chart_code: IAP/DP/ODP/STR/APD/MIN/LAH/HOT/CVFP/DVA
    let name: String        // e.g. "ILS OR LOC RWY 04R", "TAKEOFF MINIMUMS", "HOT SPOT"
    let pdf: String         // plate filename, e.g. "00058IL4R.PDF"
    var id: String { code + "|" + name + "|" + pdf }

    /// Bucket the raw FAA chart code into a display tab. The combined MIN booklet is split by its
    /// chart name — takeoff minimums → Departure, alternate minimums → Arrival, the rest → Other —
    /// so it appears where a pilot looks for it (matches the user's tab spec).
    var category: Category {
        switch code {
        case "IAP", "CVFP":       return .approach
        case "DP", "ODP":         return .departure
        case "STR":               return .arrival
        case "APD", "HOT", "LAH": return .airport
        case "MIN":
            let n = name.uppercased()
            if n.contains("ALTERNATE") { return .arrival }
            if n.contains("TAKEOFF") || n.contains("DEPARTURE") { return .departure }
            return .other
        default:                  return .other
        }
    }

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
        let from: String?          // cycle effective date, ISO "2026-07-09"
        let to: String?            // cycle expiry date, ISO "2026-08-06"
        let airports: [String: [Rec]]
        let regions: [String: [String]]?    // region name → [ICAO] for bundle downloads
        struct Rec: Decodable { let c: String; let n: String; let f: String }
    }
    private static let data: DTO = load()

    /// The FAA chart cycle the bundled index was built for (e.g. "2607"); "" when missing.
    static var cycle: String { data.cycle }

    /// Published charts for an airport, in the file's order (FAA groups them by kind already).
    static func forAirport(_ ident: String) -> [AirportProcedure] {
        let key = ident.trimmingCharacters(in: .whitespaces).uppercased()
        return (data.airports[key] ?? []).map { AirportProcedure(code: $0.c, name: $0.n, pdf: $0.f) }
    }

    /// Test seam / lazy-load probe (0 when the resource is missing).
    static var airportCount: Int { data.airports.count }

    // MARK: - Chart cycle validity (28-day d-TPP cycle)

    static var effectiveDate: Date? { Self.parseISO(data.from) }
    static var expiryDate: Date? { Self.parseISO(data.to) }
    /// Past the cycle's expiry date? (false when no date is bundled — don't nag without data.)
    static func isExpired(asOf now: Date = Date()) -> Bool {
        guard let exp = expiryDate else { return false }
        return now >= exp
    }
    /// Whole days until the cycle expires (negative once expired; nil when unknown).
    static func daysUntilExpiry(asOf now: Date = Date()) -> Int? {
        guard let exp = expiryDate else { return nil }
        return Calendar.current.dateComponents([.day], from: now, to: exp).day
    }

    // MARK: - Region bundles

    static var regionNames: [String] { (data.regions?.keys).map { $0.sorted() } ?? [] }
    static func airports(inRegion region: String) -> [String] { data.regions?[region] ?? [] }

    private static func parseISO(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)
    }

    private static func load() -> DTO {
        let url = Bundle.main.url(forResource: "procedures", withExtension: "json", subdirectory: "nav")
            ?? Bundle.main.url(forResource: "procedures", withExtension: "json")
        guard let url, let d = try? Data(contentsOf: url),
              let dto = try? JSONDecoder().decode(DTO.self, from: d)
        else { return DTO(cycle: "", from: nil, to: nil, airports: [:], regions: nil) }
        return dto
    }
}
