import Foundation
import SQLite3

/// One enroute airway's ordered geometry (a V/J/T/Q route as fix chain), from the bundled `cifp.sqlite`
/// `airway` table (built by `Tools/build_cifp.py` from the FAA CIFP ER records). `area` (USA/PAC/…)
/// disambiguates same-ident airways in different regions — the East Coast V1 and the Hawaii V1 are
/// different routes; merging them would draw a bogus trans-Pacific line.
struct AirwaySegment: Equatable {
    let area: String           // ARINC area code, e.g. "USA", "PAC"
    let ident: String          // "V1", "J121", "Q822"
    let points: [Coord]        // ordered by the CIFP sequence number
    var key: String { "\(area)|\(ident)" }
}

/// Reader for the enroute-airway table — powers the map's airways layer (polylines + tap-to-identify).
/// Same read-only full-mutex handle pattern as `CIFP`. Queries are REGION-scoped and bounded, and are
/// called off-main once per settled map region (never per frame). A missing table degrades to empty.
enum Airways {
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

    /// The airways with at least one point inside `box`, each with its FULL ordered geometry (so a route
    /// crossing the screen edge doesn't get clipped mid-segment). Bounded: at most `limit` airways, each
    /// at most 400 points. Zoom-gated by the caller (airways clutter a continent-level view).
    static func inRegion(_ box: BBox, limit: Int = 80) -> [AirwaySegment] {
        assert(box.minLat <= box.maxLat && box.minLon <= box.maxLon, "inRegion: degenerate box")
        assert(limit > 0, "inRegion: limit must be positive")
        guard let db else { return [] }
        var keys: [(area: String, ident: String)] = []
        var st: OpaquePointer?
        let sql = "SELECT DISTINCT area, ident FROM airway WHERE lat BETWEEN ?1 AND ?2 AND lon BETWEEN ?3 AND ?4 LIMIT ?5"
        if sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK {
            sqlite3_bind_double(st, 1, box.minLat); sqlite3_bind_double(st, 2, box.maxLat)
            sqlite3_bind_double(st, 3, box.minLon); sqlite3_bind_double(st, 4, box.maxLon)
            sqlite3_bind_int(st, 5, Int32(limit))
            while sqlite3_step(st) == SQLITE_ROW {
                if let a = sqlite3_column_text(st, 0), let i = sqlite3_column_text(st, 1) {
                    keys.append((String(cString: a), String(cString: i)))
                }
            }
        }
        sqlite3_finalize(st)
        var out: [AirwaySegment] = []
        for k in keys.prefix(limit) {                                         // bounded (rule 2)
            let pts = points(of: k.ident, area: k.area)
            if pts.count >= 2 { out.append(AirwaySegment(area: k.area, ident: k.ident, points: pts)) }
        }
        return out
    }

    /// The airway's coded altitude band: the minimum-enroute-altitude range across its segments (MEA
    /// varies leg to leg) and the maximum authorized altitude, in feet. nils when the data carries none.
    static func altitudes(of ident: String, area: String = "USA") -> (meaLow: Int?, meaHigh: Int?, maa: Int?) {
        guard let db, !ident.isEmpty else { return (nil, nil, nil) }
        var st: OpaquePointer?
        var out: (Int?, Int?, Int?) = (nil, nil, nil)
        let sql = "SELECT MIN(mea), MAX(mea), MAX(maa) FROM airway WHERE ident=?1 AND area=?2"
        if sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK {
            sqlite3_bind_text(st, 1, ident, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(st, 2, area, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            if sqlite3_step(st) == SQLITE_ROW {
                func col(_ i: Int32) -> Int? {
                    sqlite3_column_type(st, i) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(st, i))
                }
                out = (col(0), col(1), col(2))
            }
        }
        sqlite3_finalize(st)
        return out
    }

    /// The full ordered geometry of one airway within one AREA (≤400 points — the longest US airway is
    /// well under that). Area-scoped so same-ident airways in different regions never mix.
    static func points(of ident: String, area: String = "USA") -> [Coord] {
        guard let db, !ident.isEmpty else { return [] }
        var out: [Coord] = []
        var st: OpaquePointer?
        let sql = "SELECT lat, lon FROM airway WHERE ident=?1 AND area=?2 ORDER BY seq LIMIT 400"
        if sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK {
            sqlite3_bind_text(st, 1, ident, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(st, 2, area, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            while sqlite3_step(st) == SQLITE_ROW {
                out.append(Coord(lat: sqlite3_column_double(st, 0), lon: sqlite3_column_double(st, 1)))
            }
        }
        sqlite3_finalize(st)
        assert(out.count <= 400, "airway geometry bound respected")
        return out
    }
}
