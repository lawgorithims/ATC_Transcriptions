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
}

/// A localizer/ILS record — frequency + course + antenna position.
struct CIFPILS: Equatable {
    let runway: String     // "RW04R"
    let ident: String      // "IBOS"
    let freqMHz: Double?
    let course: Double?    // magnetic
    let coord: Coord?
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
        guard sqlite3_prepare_v2(db, "SELECT seq,fix,lat,lon,leg_type,course_mag,alt FROM leg WHERE procedure_id=?1 ORDER BY seq", -1, &st, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_int64(st, 1, Int64(procedureID))
        var out: [CIFPLeg] = []
        while sqlite3_step(st) == SQLITE_ROW {
            let hasCoord = sqlite3_column_type(st, 2) != SQLITE_NULL
            out.append(CIFPLeg(seq: Int(sqlite3_column_int(st, 0)), fix: text(st, 1),
                               coord: hasCoord ? Coord(lat: sqlite3_column_double(st, 2), lon: sqlite3_column_double(st, 3)) : nil,
                               legType: text(st, 4),
                               course: sqlite3_column_type(st, 5) != SQLITE_NULL ? sqlite3_column_double(st, 5) : nil,
                               altitude: text(st, 6)))
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
