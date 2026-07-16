import Foundation
import SQLite3

/// One enroute airway's ordered geometry (a V/J/T/Q route as fix chain), from the bundled `cifp.sqlite`
/// `airway` table (built by `Tools/build_cifp.py` from the FAA CIFP ER records).
struct AirwaySegment: Equatable {
    let ident: String          // "V1", "J121", "Q822"
    let points: [Coord]        // ordered by the CIFP sequence number
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
        var idents: [String] = []
        var st: OpaquePointer?
        let sql = "SELECT DISTINCT ident FROM airway WHERE lat BETWEEN ?1 AND ?2 AND lon BETWEEN ?3 AND ?4 LIMIT ?5"
        if sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK {
            sqlite3_bind_double(st, 1, box.minLat); sqlite3_bind_double(st, 2, box.maxLat)
            sqlite3_bind_double(st, 3, box.minLon); sqlite3_bind_double(st, 4, box.maxLon)
            sqlite3_bind_int(st, 5, Int32(limit))
            while sqlite3_step(st) == SQLITE_ROW {
                if let c = sqlite3_column_text(st, 0) { idents.append(String(cString: c)) }
            }
        }
        sqlite3_finalize(st)
        var out: [AirwaySegment] = []
        for ident in idents.prefix(limit) {                                   // bounded (rule 2)
            let pts = points(of: ident)
            if pts.count >= 2 { out.append(AirwaySegment(ident: ident, points: pts)) }
        }
        return out
    }

    /// The full ordered geometry of one airway (≤400 points — the longest US airway is well under that).
    static func points(of ident: String) -> [Coord] {
        guard let db, !ident.isEmpty else { return [] }
        var out: [Coord] = []
        var st: OpaquePointer?
        let sql = "SELECT lat, lon FROM airway WHERE ident=?1 ORDER BY seq LIMIT 400"
        if sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK {
            sqlite3_bind_text(st, 1, ident, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            while sqlite3_step(st) == SQLITE_ROW {
                out.append(Coord(lat: sqlite3_column_double(st, 0), lon: sqlite3_column_double(st, 1)))
            }
        }
        sqlite3_finalize(st)
        assert(out.count <= 400, "airway geometry bound respected")
        return out
    }
}
