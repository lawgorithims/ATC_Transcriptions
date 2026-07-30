import Foundation
import SQLite3

/// sqlite copies the bound bytes. Never pass a nil destructor (SQLITE_STATIC) for a Swift String.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

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
    private static func open() -> OpaquePointer? {
        // A verified downloaded cycle when one is installed, else the bundled copy (see NavDataUpdate).
        guard let path = NavDataUpdate.activeURL(.apt)?.path else { return nil }
        var handle: OpaquePointer?
        // sqlite3_open_v2 ALLOCATES the handle even when it fails, and its contract says the caller must
        // close it regardless — returning nil without closing leaked it (and the error string with it).
        // Once per process on a failure path, so this is correctness rather than pressure: the failure
        // path is a corrupt or half-written downloaded cycle, which is exactly when we do not want to be
        // holding a handle to it.
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return nil
        }
        return handle
    }
    private static var dbHandle: OpaquePointer? = open()
    private static var db: OpaquePointer? { dbHandle }

    /// Test-only: re-resolve the handle after a NavDataUpdate install/revert so a fixture DB does not
    /// leak into later tests. Production resolves once per launch (see CIFP.reopenForTests).
    static func reopenForTests() {
        if let h = dbHandle { sqlite3_close(h) }
        dbHandle = open()
    }

    /// NASR keys airports by FAA identifier ("DFW"), not ICAO ("KDFW"). Look up both.
    ///
    /// The US ICAO prefix is not only K: Alaska is PA, Hawaii PH, Guam PG, Puerto Rico and the Virgin
    /// Islands TJ/TI. Stripping only a leading K left every airport in those regions — PANC, PHNL, PGUM,
    /// TJSJ — resolving to nothing at all.
    private static let icaoPrefixes = ["K", "PA", "PH", "PG", "PM", "PO", "PW", "TJ", "TI"]
    private static func keys(_ ident: String) -> (String, String) {
        let s = ident.uppercased()
        guard s.count == 4 else { return (s, s) }
        for p in icaoPrefixes where s.hasPrefix(p) && s.count - p.count >= 2 {
            return (s, String(s.dropFirst(p.count)))
        }
        return (s, s)
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

    /// One published runway, with the surface that decides whether it is drawn on the chart symbol.
    struct Runway: Equatable {
        let designator: String      // "04L/22R", or "H1" for a helipad
        let lengthFt: Double?
        let widthFt: Double?
        let surface: String         // NASR SURFACE_TYPE_CODE: "ASPH", "TURF", "ASPH-TURF", …
        let condition: String       // "GOOD" / "FAIR" / "POOR" / "FAILED" / ""
        var lights: String = ""     // NASR RWY_LGT_CODE: "HIGH"/"MED"/"LOW"/"NSTD"/…; "" = unlit

        /// A hyphenated NASR surface names its components PRIMARY-first, so "ASPH-TURF" is a paved
        /// runway with a turf shoulder and "TURF-ASPH" is a grass strip with some paving. Reading only
        /// the first component gets that right without enumerating every combination.
        var isPaved: Bool {
            let primary = surface.uppercased().split(separator: "-").first.map(String.init) ?? ""
            return ["ASPH", "CONC", "PEM"].contains(primary)
        }

        /// A helipad is published in this table but is not a runway, and drawing runway lines for one
        /// puts a strip across an airport that has none.
        var isHelipad: Bool { designator.uppercased().hasPrefix("H") }

        /// Out of service — the FAA still publishes the record, but nothing should be flown to it.
        var isFailed: Bool { condition.uppercased() == "FAILED" }

        /// Magnetic bearing from the runway NUMBER ("04L/22R" -> 40°). The published true alignment is
        /// only present on 32% of ends, whereas the designator is the number a pilot reads off the
        /// chart and is on every real runway. Nil for helipads and compass-named strips ("N/S", "E/W").
        var bearingDeg: Double? {
            let head = designator.uppercased().split(separator: "/").first.map(String.init) ?? ""
            let digits = head.prefix { $0.isNumber }
            guard digits.count >= 1, digits.count <= 2, let n = Int(digits), n >= 1, n <= 36 else { return nil }
            return Double(n) * 10
        }
    }

    /// Every published runway at the field, in NASR order.
    static func runways(airport: String) -> [Runway] {
        let (a, b) = keys(airport)
        return query("""
            SELECT designator, length_ft, width_ft, COALESCE(surface,''), COALESCE(condition,''),
                   COALESCE(lights,'')
            FROM runway WHERE ident=?1 OR ident=?2 ORDER BY designator
            """, a, b) { st in
            Runway(designator: text(st, 0), lengthFt: dbl(st, 1), widthFt: dbl(st, 2),
                   surface: text(st, 3), condition: text(st, 4), lights: text(st, 5))
        }
    }

    /// The runways an airport SYMBOL should draw: paved, in service, and an actual runway.
    ///
    /// The chart symbol is a statement about where an aircraft can land. Drawing every published
    /// runway put grass strips, gravel, helipads and out-of-service pavement on the same footing as
    /// the one runway a pilot would actually use — KTCS drew five, of which four are gravel.
    static func drawableRunways(airport: String) -> [Runway] {
        runways(airport: airport).filter { $0.isPaved && !$0.isHelipad && !$0.isFailed && $0.bearingDeg != nil }
    }

    /// One NASR facility record — the airport-level attributes (`airport` table). These columns sat
    /// unread in the database until the NRST engine needed them; this is the first Swift accessor.
    struct Airport: Equatable {
        let ident: String           // FAA identifier, "DFW" — the primary key convention
        let icao: String            // "KDFW", or "" (16,711 of 19,436 rows have no ICAO)
        let name: String
        let coord: Coord
        let elevationFt: Double?
        let ownership: String       // "PU" public / "PR" private / "MA","MN","MR" military / "CG"
        let use: String             // FACILITY_USE_CODE: "PU" open to the public / "PR" private
        let status: String          // "O" operational / "CI","CP" closed
        let tower: String           // TWR_TYPE_CODE: "ATCT"* towered / "NON-ATCT"
        let fuel: String            // comma list, "100LL,A"; "" = none published
        let siteType: String        // SITE_TYPE_CODE: "A" airport, "H" heliport, "C" seaplane,
                                    // "G" glider, "U" ultralight, "B" balloonport; "" on a DB cycle
                                    // built before the column existed (see airportColumns fallback)
        let far139: String          // FAR_139_TYPE_CODE "I E" = cert class + ARFF index; "" = none

        var isOperational: Bool { status.uppercased() == "O" }
        var isTowered: Bool { tower.uppercased().hasPrefix("ATCT") }
        var isPublicUse: Bool { use.uppercased() == "PU" }
        var hasFuel: Bool { !fuel.isEmpty }
        /// Part-139 certificated — the only NASR signal that fire/rescue equipment is ON the field.
        var isCertificated: Bool { !far139.isEmpty }
        /// True when the record is known to be a non-airplane facility. An empty siteType (older DB
        /// cycle) is UNKNOWN, not airplane — callers needing certainty must also inspect runways.
        var isNonAirplaneFacility: Bool { ["H", "C", "B", "U"].contains(siteType.uppercased()) }
    }

    /// `site_type`/`far139` shipped with the 2026-07-09 rebuild, but `NavDataUpdate` can resolve to a
    /// DOWNLOADED cycle installed before they existed. Selecting a missing column fails the whole
    /// prepare, so probe once and fall back to empty-string literals — the reader then behaves as if
    /// the columns were blank, which is exactly what "unknown" means here.
    private static let hasSiteTypeColumns: Bool = {
        guard let db else { return false }
        var st: OpaquePointer?
        let ok = sqlite3_prepare_v2(db, "SELECT site_type, far139 FROM airport LIMIT 1", -1, &st, nil) == SQLITE_OK
        sqlite3_finalize(st)
        return ok
    }()

    /// Whether the airport table can actually be read right now.
    ///
    /// Every accessor here degrades to an empty result, which is right for the cosmetic consumers it
    /// was written for (a thin frequency list, a blank caption) but NOT for a caller that presents
    /// the absence of rows as a fact. The NRST engine-out list is one: "no landable airports within
    /// 87 NM" and "the airport database did not open" must not look identical to a pilot in a glide.
    static var isQueryable: Bool {
        guard let db else { return false }
        var st: OpaquePointer?
        let ok = sqlite3_prepare_v2(db, "SELECT ident FROM airport LIMIT 1", -1, &st, nil) == SQLITE_OK
        defer { sqlite3_finalize(st) }
        guard ok else { return false }
        return sqlite3_step(st) == SQLITE_ROW    // an empty table is as unusable as a missing one
    }

    /// Operational-and-not filtering is the CALLER's job — this returns every facility in the box,
    /// nearest first, because "closed" and "heliport" are ranking decisions, not lookup decisions.
    ///
    /// A bounded full-scan bbox query (19,436 rows, no spatial index) — a few milliseconds. Same cost
    /// contract as `NavDatabase.nearby`: call once per need, off the hot path, never per frame.
    static func airportsNear(_ center: Coord, radiusNm: Double, limit: Int = 64) -> [Airport] {
        assert(radiusNm > 0 && radiusNm <= 500, "radius in NM, bounded")
        assert(limit > 0 && limit <= 512, "limit bounded")
        guard let db, radiusNm > 0, limit > 0 else { return [] }
        let dLat = radiusNm / 60.0
        // Longitude degrees shrink with latitude; the 0.2 cos floor keeps the box finite near the
        // poles (house convention — see AirportContextStore.nearbyRanked).
        let dLon = radiusNm / (60.0 * max(0.2, cos(center.lat * .pi / 180)))
        let cols = hasSiteTypeColumns ? "COALESCE(site_type,''), COALESCE(far139,'')" : "'', ''"
        let sql = """
            SELECT ident, COALESCE(icao,''), COALESCE(name,''), lat, lon, elev_ft,
                   COALESCE(ownership,''), COALESCE(use,''), COALESCE(status,''),
                   COALESCE(tower,''), COALESCE(fuel,''), \(cols)
            FROM airport WHERE lat BETWEEN ?1 AND ?2 AND lon BETWEEN ?3 AND ?4
            """
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_double(st, 1, center.lat - dLat)
        sqlite3_bind_double(st, 2, center.lat + dLat)
        sqlite3_bind_double(st, 3, center.lon - dLon)
        sqlite3_bind_double(st, 4, center.lon + dLon)
        var out: [Airport] = []
        while sqlite3_step(st) == SQLITE_ROW, out.count < 4096 {    // bounded (rule 2)
            guard sqlite3_column_type(st, 3) != SQLITE_NULL,
                  sqlite3_column_type(st, 4) != SQLITE_NULL else { continue }
            out.append(Airport(ident: text(st, 0), icao: text(st, 1), name: text(st, 2),
                               coord: Coord(lat: sqlite3_column_double(st, 3),
                                            lon: sqlite3_column_double(st, 4)),
                               elevationFt: dbl(st, 5), ownership: text(st, 6), use: text(st, 7),
                               status: text(st, 8), tower: text(st, 9), fuel: text(st, 10),
                               siteType: text(st, 11), far139: text(st, 12)))
        }
        // The box is square; rank by true great-circle distance and keep the nearest `limit`.
        return out
            .map { (a: $0, d: Geo.nmBetween(center, $0.coord)) }
            .filter { $0.d <= radiusNm }
            .sorted { $0.d < $1.d }
            .prefix(limit)
            .map(\.a)
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
        // SQLITE_TRANSIENT, never SQLITE_STATIC (a nil destructor). `(a as NSString).utf8String`
        // returns a pointer INTO a temporary NSString that Swift is free to release the moment this
        // statement ends — SQLITE_STATIC promises sqlite the buffer outlives the query, so the bound
        // parameter became a dangling pointer. It read as garbage intermittently, which is exactly the
        // shape of the failure: whole groups of database-backed results coming back empty, escalating
        // as the process ran. TRANSIENT makes sqlite copy the bytes, which is what this needs.
        if let a { sqlite3_bind_text(st, 1, a, -1, SQLITE_TRANSIENT) }
        if let b { sqlite3_bind_text(st, 2, b, -1, SQLITE_TRANSIENT) }
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
