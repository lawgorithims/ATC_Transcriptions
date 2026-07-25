import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A coded terminal procedure (approach / SID / STAR) for one airport, from the bundled CIFP DB.
struct CIFPProcedure: Identifiable, Equatable {
    let id: Int            // rowid (identifies this procedure+transition; use with `CIFP.legs`)
    let airport: String
    let kind: String       // "IAP" (approach) | "SID" | "STAR"
    let ident: String      // ARINC ident, e.g. "H33LX"
    let name: String       // readable, e.g. "RNAV (GPS) RWY 33L"
    let runway: String     // "33L" (approaches)
    let transition: String // enroute transition, e.g. "BBOGG"
}

/// One sequenced leg of a procedure — a fix with (usually) a georeferenced coordinate, so the path
/// draws on the map perfectly aligned with the chart.
struct CIFPLeg: Identifiable {
    let id = UUID()
    let seq: Int
    let fix: String
    let coord: Coord?      // resolved from CIFP's fix records; nil for a few unresolvable/vector legs
    let legType: String    // ARINC path terminator: IF/TF/CF/DF/FA/CA/RF/HM/VA…
    let course: Double?    // magnetic, degrees
    let altitude: String
    /// ARINC waypoint-description code (4 chars). Char 4 carries the SEGMENT ROLE published by the FAA:
    /// `A` = initial approach fix, `F` = final approach fix, `M` = missed-approach point, `I` =
    /// intermediate fix. This is the authoritative marker — it is read, never inferred.
    var wpDesc: String = ""
    /// The published role of this leg, if the source marks one.
    var role: LegRole { LegRole(wpDesc: wpDesc) }
}

/// The segment role the FAA publishes for a leg, from the waypoint-description code's 4th character.
/// `.none` means the source marks no role for this leg — which is the common case and is NOT a defect.
enum LegRole: String {
    case initialApproachFix, finalApproachFix, missedApproachPoint, intermediateFix, none

    init(wpDesc: String) {
        let c = wpDesc.count >= 4 ? Array(wpDesc)[3] : " "
        switch c {
        case "A": self = .initialApproachFix
        case "F": self = .finalApproachFix
        case "M": self = .missedApproachPoint
        case "I": self = .intermediateFix
        default:  self = .none
        }
    }
}

/// A localizer/ILS record — frequency + course + antenna position.
struct CIFPILS: Equatable {
    let runway: String     // "RW04R"
    let ident: String      // "IBOS"
    let freqMHz: Double?
    let course: Double?    // magnetic
    let coord: Coord?
}

/// One runway END from the CIFP `runway` table: threshold position + published magnetic bearing +
/// length. Both ends of a runway are separate rows, so TRUE headings can be derived from the two
/// threshold coordinates (see `RunwayGeometry.pairs`) without a magnetic-variation model.
struct CIFPRunway: Equatable, Sendable {
    let designator: String   // "RW04L"
    let coord: Coord
    let bearingMag: Double?
    let lengthFt: Int?
}

/// Read-only reader for the bundled `cifp.sqlite` (built by `Tools/build_cifp.py` from the FAA CIFP).
/// One shared read-only + full-mutex connection, like `MBTilesReader`. Missing DB → empty results.
enum CIFP {
    private static let db: OpaquePointer? = open()
    static var available: Bool { db != nil }

    private static func open() -> OpaquePointer? {
        guard let path = (Bundle.main.url(forResource: "cifp", withExtension: "sqlite", subdirectory: "nav")
                          ?? Bundle.main.url(forResource: "cifp", withExtension: "sqlite"))?.path else { return nil }
        var h: OpaquePointer?
        guard sqlite3_open_v2(path, &h, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if h != nil { sqlite3_close(h) }
            return nil
        }
        return h
    }

    /// All coded procedures for an airport (every approach/SID/STAR + each transition).
    static func procedures(airport: String) -> [CIFPProcedure] {
        query("SELECT id,airport,kind,ident,name,runway,transition FROM procedure WHERE airport=?1 ORDER BY kind,ident,transition",
              airport) { st in
            CIFPProcedure(id: Int(sqlite3_column_int64(st, 0)), airport: text(st, 1), kind: text(st, 2),
                          ident: text(st, 3), name: text(st, 4), runway: text(st, 5), transition: text(st, 6))
        }
    }

    /// The sequenced legs of one procedure (by rowid), in flight order.
    static func legs(procedureID: Int) -> [CIFPLeg] {
        guard let db else { return [] }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT seq,fix,lat,lon,leg_type,course_mag,alt,COALESCE(wp_desc,'') FROM leg WHERE procedure_id=?1 ORDER BY seq", -1, &st, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_int64(st, 1, Int64(procedureID))
        var out: [CIFPLeg] = []
        while sqlite3_step(st) == SQLITE_ROW {
            let hasCoord = sqlite3_column_type(st, 2) != SQLITE_NULL
            out.append(CIFPLeg(seq: Int(sqlite3_column_int(st, 0)), fix: text(st, 1),
                               coord: hasCoord ? Coord(lat: sqlite3_column_double(st, 2), lon: sqlite3_column_double(st, 3)) : nil,
                               legType: text(st, 4),
                               course: sqlite3_column_type(st, 5) != SQLITE_NULL ? sqlite3_column_double(st, 5) : nil,
                               altitude: text(st, 6), wpDesc: text(st, 7)))
        }
        return out
    }

    /// Distinct navigation-fix idents referenced by an airport's coded procedures — the on-approach /
    /// on-departure vocabulary ATC uses ("cleared direct BOSOX", "hold at CRLTN"). Excludes the
    /// runway-threshold pseudo-fixes (RW*) that are leg endpoints, not spoken fixes. Grounds SlotSnap's
    /// fix slot and the corrector's procedures block.
    static func fixes(airport: String) -> [String] {
        query("""
              SELECT DISTINCT leg.fix FROM leg JOIN procedure ON leg.procedure_id = procedure.id
              WHERE procedure.airport = ?1 AND leg.fix <> '' AND leg.fix NOT LIKE 'RW%'
              ORDER BY leg.fix
              """, airport) { text($0, 0) }
    }

    /// Named terminal/approach fixes (SID/STAR/approach waypoints) whose coordinate falls in `box`, for
    /// the map's zoomed-in fix layer — the deduplicated, lat-indexed `terminal_fix` table (see
    /// build_cifp.py), so this is a cheap range scan even though it's over 45k fixes. Returns `.waypoint`
    /// NavPoints so they render as fix triangles, matching the enroute fixes. Bounded by `limit`.
    static func terminalFixes(inRegion box: BBox, limit: Int = 120) -> [NavPoint] {
        assert(box.minLat <= box.maxLat && box.minLon <= box.maxLon, "terminalFixes: degenerate box")
        assert(limit > 0, "terminalFixes: limit must be positive")
        guard let db else { return [] }
        let cLat = (box.minLat + box.maxLat) / 2, cLon = (box.minLon + box.maxLon) / 2
        var out: [NavPoint] = []
        var st: OpaquePointer?
        // ORDER BY proximity to the box centre before the cap, so the kept fixes are the NEAREST ones —
        // a plain LIMIT walks the lat index and would return only the southernmost band (leaving the north
        // of a dense terminal area blank + pop-in on pan). The box holds only a few hundred rows, cheap sort.
        let sql = """
            SELECT DISTINCT fix, lat, lon FROM terminal_fix
            WHERE lat BETWEEN ?1 AND ?2 AND lon BETWEEN ?3 AND ?4
            ORDER BY (lat-?6)*(lat-?6) + (lon-?7)*(lon-?7) LIMIT ?5
            """
        if sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK {
            sqlite3_bind_double(st, 1, box.minLat); sqlite3_bind_double(st, 2, box.maxLat)
            sqlite3_bind_double(st, 3, box.minLon); sqlite3_bind_double(st, 4, box.maxLon)
            sqlite3_bind_int(st, 5, Int32(limit))
            sqlite3_bind_double(st, 6, cLat); sqlite3_bind_double(st, 7, cLon)
            while sqlite3_step(st) == SQLITE_ROW {                             // bounded by LIMIT (rule 2)
                let f = text(st, 0)
                if !f.isEmpty {
                    out.append(NavPoint(ident: f, coord: Coord(lat: sqlite3_column_double(st, 1),
                                                               lon: sqlite3_column_double(st, 2)), kind: .waypoint))
                }
            }
        }
        sqlite3_finalize(st)
        assert(out.count <= limit, "terminalFixes: LIMIT not honored")
        return out
    }

    /// Legs of a procedure re-found by its stable (airport, ident, transition) keys — robust to the rowid
    /// changing when the CIFP DB is rebuilt for a new AIRAC cycle. Prefers an exact transition match, else
    /// any transition of the same ident. Empty when not found. Bounded scans (rule 2).
    static func legs(airport: String, ident: String, transition: String) -> [CIFPLeg] {
        guard !airport.isEmpty, !ident.isEmpty else { return [] }
        let procs = procedures(airport: airport)
        for p in procs.prefix(4096) where p.ident == ident && p.transition == transition {
            return legs(procedureID: p.id)
        }
        for p in procs.prefix(4096) where p.ident == ident {   // transition may have been stored empty
            return legs(procedureID: p.id)
        }
        return []
    }

    /// Where the coded-procedure data came from and when it expires — read from the `meta` table the
    /// builder stamps. Loaded once. A database without the table (an older bundle) yields `.unknown`,
    /// which the UI renders as "Undated" rather than as a reassuring "Current".
    static let provenance: DataProvenance = {
        guard let db else { return .unknown }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT key,value FROM meta", -1, &st, nil) == SQLITE_OK else {
            return .unknown
        }
        defer { sqlite3_finalize(st) }
        var m: [String: String] = [:]
        while sqlite3_step(st) == SQLITE_ROW {                       // bounded by the table (< 32 rows)
            m[text(st, 0)] = text(st, 1)
            if m.count > 64 { break }
        }
        assert(m.count <= 64, "cifp meta unexpectedly large")
        return DataProvenance(meta: m)
    }()

    /// The published approaches at an airport, one entry per approach IDENT (its transitions collapsed).
    /// This is the list an "activate approach" picker shows; use `transitions(airport:ident:)` for that
    /// approach's entry options. Bounded (rule 2).
    static func approaches(airport: String) -> [CIFPProcedure] {
        var seen = Set<String>()
        var out: [CIFPProcedure] = []
        for p in procedures(airport: airport).prefix(4096) where p.kind == "IAP" {
            guard seen.insert(p.ident).inserted else { continue }
            out.append(p)
        }
        assert(out.count <= 4096, "approaches: unexpectedly many")
        return out
    }

    /// The transition idents (the published IAF entries) for ONE approach. The approach-proper record —
    /// the one with an empty transition, which carries final + missed — is deliberately excluded.
    static func transitions(airport: String, ident: String) -> [String] {
        guard !ident.isEmpty else { return [] }
        var out: [String] = []
        for p in procedures(airport: airport).prefix(4096)
        where p.kind == "IAP" && p.ident == ident && !p.transition.isEmpty {
            out.append(p.transition)
        }
        assert(out.count <= 4096, "transitions: unexpectedly many")
        return out
    }

    /// The approach-proper record (empty transition) — final approach with the missed appended.
    static func approachProper(airport: String, ident: String) -> CIFPProcedure? {
        for p in procedures(airport: airport).prefix(4096)
        where p.kind == "IAP" && p.ident == ident && p.transition.isEmpty {
            return p
        }
        return nil
    }

    /// All runway ends for an airport (one row per end; pair them via `RunwayGeometry.pairs`).
    static func runways(airport: String) -> [CIFPRunway] {
        query("SELECT designator,lat,lon,bearing_mag,length_ft FROM runway WHERE airport=?1 ORDER BY designator",
              airport) { st in
            CIFPRunway(designator: text(st, 0),
                       coord: Coord(lat: sqlite3_column_double(st, 1), lon: sqlite3_column_double(st, 2)),
                       bearingMag: sqlite3_column_type(st, 3) != SQLITE_NULL ? sqlite3_column_double(st, 3) : nil,
                       lengthFt: sqlite3_column_type(st, 4) != SQLITE_NULL ? Int(sqlite3_column_int64(st, 4)) : nil)
        }
    }

    /// Localizer/ILS records for an airport (frequency + course + position).
    static func ils(airport: String) -> [CIFPILS] {
        query("SELECT runway,ident,freq_mhz,course_mag,lat,lon FROM ils WHERE airport=?1", airport) { st in
            let hasCoord = sqlite3_column_type(st, 4) != SQLITE_NULL
            return CIFPILS(runway: text(st, 0), ident: text(st, 1),
                           freqMHz: sqlite3_column_type(st, 2) != SQLITE_NULL ? sqlite3_column_double(st, 2) : nil,
                           course: sqlite3_column_type(st, 3) != SQLITE_NULL ? sqlite3_column_double(st, 3) : nil,
                           coord: hasCoord ? Coord(lat: sqlite3_column_double(st, 4), lon: sqlite3_column_double(st, 5)) : nil)
        }
    }

    /// Test seam / lazy-load probe (0 when the DB is missing).
    static var procedureCount: Int {
        guard let db else { return 0 }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM procedure", -1, &st, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(st) }
        return sqlite3_step(st) == SQLITE_ROW ? Int(sqlite3_column_int64(st, 0)) : 0
    }

    // MARK: helpers

    private static func query<T>(_ sql: String, _ airport: String, _ row: (OpaquePointer?) -> T) -> [T] {
        guard let db else { return [] }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_text(st, 1, airport.trimmingCharacters(in: .whitespaces).uppercased(), -1, SQLITE_TRANSIENT)
        var out: [T] = []
        while sqlite3_step(st) == SQLITE_ROW { out.append(row(st)) }
        return out
    }

    private static func text(_ st: OpaquePointer?, _ i: Int32) -> String {
        guard let c = sqlite3_column_text(st, i) else { return "" }
        return String(cString: c)
    }
}
