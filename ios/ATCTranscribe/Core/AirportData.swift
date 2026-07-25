import Foundation
import SQLite3

/// Runway geometry and published frequencies from the FAA NASR subscription (`apt.sqlite`).
///
/// This fills the two gaps CIFP structurally cannot:
///
///   * RUNWAYS. CIFP codes only airports with published instrument procedures, so 9,942 of the 14,078
///     airports the app knows had no runway geometry at all. NASR covers 19,436 facilities — both ends
///     of 23,208 runways, with width, surface, displaced thresholds, TDZE and declared distances.
///   * FREQUENCIES. The community data behind the airport card gives KDFW seven; NASR carries 211 for
///     DFW alone, sectorized and tagged by use. That is not cosmetic: `SlotSnap` verifies a frequency
///     it heard against the airport's published list and ABSTAINS when it is absent, so every missing
///     frequency was a silently lost verification rather than a wrong one.
///
/// Read-only, opened lazily, and degrades to empty if the resource is missing — the same contract as
/// `CIFP`. Everything it returns is stamped with `provenance`, because it is on a 28-day cycle of its
/// own that will not always agree with CIFP's.
enum AirportData {
    private static let db: OpaquePointer? = {
        // Resources/nav ships as a folder reference, so the file keeps its `nav/` subdirectory in the
        // bundle — the same two-step lookup CIFP uses, with the flat fallback for a plain copy.
        guard let path = (Bundle.main.url(forResource: "apt", withExtension: "sqlite", subdirectory: "nav")
                          ?? Bundle.main.url(forResource: "apt", withExtension: "sqlite"))?.path
        else { return nil }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        return handle
    }()

    /// NASR keys airports by FAA identifier ("DFW"), not ICAO ("KDFW"). Look up both, since the rest of
    /// the app speaks ICAO — and a US ICAO ident is almost always the FAA one with a K in front.
    private static func keys(_ ident: String) -> (String, String) {
        let s = ident.uppercased()
        return (s, s.count == 4 && s.hasPrefix("K") ? String(s.dropFirst()) : s)
    }

    struct RunwayEnd: Equatable {
        let runway: String          // "04L/22R"
        let end: String             // "04L"
        let trueAlignmentDeg: Double?
        let coord: Coord?
        let elevationFt: Double?
        let touchdownZoneElevationFt: Double?
        let displacedThresholdFt: Double?
        let landingDistanceFt: Double?
        let vgsi: String
        let approachLights: String
    }

    struct Frequency: Equatable {
        let value: String           // "118.1"
        let use: String             // "APCH/P", "TWR", …
        let sectorization: String   // "RWY 13R", "PROPS LNDG NORTH ONLY", …
        let facility: String
    }

    static func runwayEnds(airport: String) -> [RunwayEnd] {
        let (a, b) = keys(airport)
        return query("""
            SELECT designator, end_id, true_align, lat, lon, elev_ft, tdze_ft,
                   displaced_ft, lda_ft, COALESCE(vgsi,''), COALESCE(app_lights,'')
            FROM runway_end WHERE ident=?1 OR ident=?2 ORDER BY designator, end_id
            """, a, b) { st in
            let hasCoord = sqlite3_column_type(st, 3) != SQLITE_NULL
            return RunwayEnd(runway: text(st, 0), end: text(st, 1),
                             trueAlignmentDeg: dbl(st, 2),
                             coord: hasCoord ? Coord(lat: sqlite3_column_double(st, 3),
                                                     lon: sqlite3_column_double(st, 4)) : nil,
                             elevationFt: dbl(st, 5), touchdownZoneElevationFt: dbl(st, 6),
                             displacedThresholdFt: dbl(st, 7), landingDistanceFt: dbl(st, 8),
                             vgsi: text(st, 9), approachLights: text(st, 10))
        }
    }

    /// Every published frequency for the field, in the order NASR lists them.
    static func frequencies(airport: String) -> [Frequency] {
        let (a, b) = keys(airport)
        return query("""
            SELECT freq, COALESCE(use,''), COALESCE(sectorization,''), COALESCE(facility,'')
            FROM frequency WHERE ident=?1 OR ident=?2
            """, a, b) { Frequency(value: text($0, 0), use: text($0, 1),
                                   sectorization: text($0, 2), facility: text($0, 3)) }
    }

    /// Just the numbers, deduped — what the ATC corrector needs to verify a frequency it heard.
    static func frequencyValues(airport: String) -> [String] {
        var seen = Set<String>()
        return frequencies(airport: airport).compactMap { seen.insert($0.value).inserted ? $0.value : nil }
    }

    static let provenance: DataProvenance = {
        var meta: [String: String] = [:]
        for row in query("SELECT key, value FROM meta", nil, nil, { (text($0, 0), text($0, 1)) }) {
            meta[row.0] = row.1
        }
        return meta.isEmpty ? .unknown : DataProvenance(meta: meta)
    }()

    // MARK: plumbing

    private static func query<T>(_ sql: String, _ a: String? = nil, _ b: String? = nil,
                                 _ map: (OpaquePointer?) -> T) -> [T] {
        guard let db else { return [] }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(st) }
        if let a { sqlite3_bind_text(st, 1, (a as NSString).utf8String, -1, nil) }
        if let b { sqlite3_bind_text(st, 2, (b as NSString).utf8String, -1, nil) }
        var out: [T] = []
        while sqlite3_step(st) == SQLITE_ROW, out.count < 4096 {    // bounded (rule 2)
            out.append(map(st))
        }
        return out
    }

    private static func text(_ st: OpaquePointer?, _ col: Int32) -> String {
        guard let c = sqlite3_column_text(st, col) else { return "" }
        return String(cString: c)
    }
    private static func dbl(_ st: OpaquePointer?, _ col: Int32) -> Double? {
        sqlite3_column_type(st, col) == SQLITE_NULL ? nil : sqlite3_column_double(st, col)
    }
}
