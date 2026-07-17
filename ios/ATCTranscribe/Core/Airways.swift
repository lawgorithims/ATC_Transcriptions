import Foundation
import SQLite3

/// One CONTINUOUS run of an enroute airway (a V/J/T/Q route as fix chain), from the bundled `cifp.sqlite`
/// `airway` table (built by `Tools/build_cifp.py` from the FAA CIFP ER records). `area` (USA/PAC/…)
/// disambiguates same-ident airways in different regions — the East Coast V1 and the Hawaii V1 are
/// different routes; merging them would draw a bogus trans-Pacific line.
///
/// A single designator can be legally DISCONTINUOUS (revoked middle sections) yet share one ident with
/// contiguous sequence numbers, and Aleutian routes cross the antimeridian — drawing the whole chain as
/// one polyline produces fake ~900 NM legs across the country / a line around the globe. So the geometry
/// is split into runs at implausible gaps (see `splitRuns`) and each run is its own segment; `seg` is the
/// run index within (area, ident).
struct AirwaySegment: Equatable {
    let area: String           // ARINC area code, e.g. "USA", "PAC"
    let ident: String          // "V1", "J121", "Q822"
    let seg: Int               // continuous-run index within (area, ident)
    let points: [Coord]        // ordered by the CIFP sequence number, one unbroken run
    var key: String { "\(area)|\(ident)|\(seg)" }
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

    /// The airways whose geometry intersects `box`, split into continuous runs (so a revoked mid-section
    /// or an antimeridian crossing never draws a fake straight leg). The DISTINCT (area, ident) selection
    /// is proximity-RANKED to the box centre and capped at `limit`, so on a dense view the `limit` NEAREST
    /// airways are kept DETERMINISTICALLY (no north-biased index-scan drop, no pop-in on pan). Bounded:
    /// ≤`limit` idents, each ≤400 points. Zoom-gated by the caller (airways clutter a continent view).
    static func inRegion(_ box: BBox, limit: Int = 80) -> [AirwaySegment] {
        assert(box.minLat <= box.maxLat && box.minLon <= box.maxLon, "inRegion: degenerate box")
        assert(limit > 0, "inRegion: limit must be positive")
        guard let db else { return [] }
        let cLat = (box.minLat + box.maxLat) / 2, cLon = (box.minLon + box.maxLon) / 2
        var keys: [(area: String, ident: String)] = []
        var st: OpaquePointer?
        // GROUP BY + ORDER BY nearest-vertex manhattan distance to the box centre → deterministic, the
        // capped set is the closest airways rather than whatever the lat index yields first.
        let sql = """
            SELECT area, ident FROM airway WHERE lat BETWEEN ?1 AND ?2 AND lon BETWEEN ?3 AND ?4
            GROUP BY area, ident ORDER BY MIN(abs(lat-?5) + abs(lon-?6)) LIMIT ?7
            """
        if sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK {
            sqlite3_bind_double(st, 1, box.minLat); sqlite3_bind_double(st, 2, box.maxLat)
            sqlite3_bind_double(st, 3, box.minLon); sqlite3_bind_double(st, 4, box.maxLon)
            sqlite3_bind_double(st, 5, cLat); sqlite3_bind_double(st, 6, cLon)
            sqlite3_bind_int(st, 7, Int32(limit))
            while sqlite3_step(st) == SQLITE_ROW {
                if let a = sqlite3_column_text(st, 0), let i = sqlite3_column_text(st, 1) {
                    keys.append((String(cString: a), String(cString: i)))
                }
            }
        }
        sqlite3_finalize(st)
        assert(keys.count <= limit, "inRegion: LIMIT not honored")
        var out: [AirwaySegment] = []
        for k in keys.prefix(limit) {                                         // bounded (rule 2)
            let runs = splitRuns(ident: k.ident, points(of: k.ident, area: k.area))
            for (idx, run) in runs.enumerated() where run.count >= 2 && bboxIntersects(run, box) {
                out.append(AirwaySegment(area: k.area, ident: k.ident, seg: idx, points: run))
            }
        }
        return out
    }

    /// Split an ordered fix chain into continuous runs, breaking wherever a leg is implausibly long for
    /// the route class (Victor/T are VOR/RNAV low-altitude, ≤250 NM; J/Q/RNAV high-altitude, ≤500 NM) or
    /// crosses the antimeridian (|Δlon| > 180°). A break drops only the connecting leg — both sides still
    /// draw. Empirically this cuts exactly the revoked-segment jumps (V210's 929 NM Missouri→Pennsylvania
    /// leg, J6's 781 NM, …) while keeping real long oceanic/RNAV legs.
    static func splitRuns(ident: String, _ pts: [Coord]) -> [[Coord]] {
        assert(pts.count <= 400, "splitRuns: unbounded input")
        guard pts.count >= 2 else { return pts.isEmpty ? [] : [pts] }
        let maxLeg: Double = (ident.first == "V" || ident.first == "T") ? 250 : 500   // NM
        var runs: [[Coord]] = []
        var run: [Coord] = [pts[0]]
        for i in 1..<pts.count {                                              // bounded (rule 2)
            let a = pts[i - 1], b = pts[i]
            if abs(b.lon - a.lon) > 180 || legNM(a, b) > maxLeg {
                runs.append(run); run = [b]
            } else {
                run.append(b)
            }
        }
        runs.append(run)
        assert(!runs.isEmpty, "splitRuns: produced no runs")
        return runs
    }

    /// Great-circle leg distance in nautical miles (haversine).
    private static func legNM(_ a: Coord, _ b: Coord) -> Double {
        let dLat = (b.lat - a.lat) * .pi / 180, dLon = (b.lon - a.lon) * .pi / 180
        let la = a.lat * .pi / 180, lb = b.lat * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(la) * cos(lb) * sin(dLon / 2) * sin(dLon / 2)
        return 3440.065 * 2 * asin(min(1, h.squareRoot()))
    }

    /// True when a run's lat/lon bounding box overlaps the query box (so a leg passing through the view
    /// without a vertex inside it is still drawn).
    private static func bboxIntersects(_ run: [Coord], _ box: BBox) -> Bool {
        assert(!run.isEmpty, "bboxIntersects: empty run")
        var minLat = run[0].lat, maxLat = run[0].lat, minLon = run[0].lon, maxLon = run[0].lon
        for p in run {                                                        // bounded (rule 2)
            minLat = min(minLat, p.lat); maxLat = max(maxLat, p.lat)
            minLon = min(minLon, p.lon); maxLon = max(maxLon, p.lon)
        }
        return maxLat >= box.minLat && minLat <= box.maxLat && maxLon >= box.minLon && minLon <= box.maxLon
    }

    /// The airway's coded altitude band: the minimum-enroute-altitude range across its segments (MEA
    /// varies leg to leg) and the maximum authorized altitude, in feet. nils when the data carries none.
    static func altitudes(of ident: String, area: String = "USA") -> (meaLow: Int?, meaHigh: Int?, maa: Int?) {
        assert(!area.isEmpty, "altitudes: empty area would silently match nothing")
        guard let db, !ident.isEmpty else { return (nil, nil, nil) }
        var st: OpaquePointer?
        var out: (Int?, Int?, Int?) = (nil, nil, nil)
        let sql = "SELECT MIN(mea), MAX(mea), MAX(maa) FROM airway WHERE ident=?1 AND area=?2"
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        if sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK {
            let b1 = sqlite3_bind_text(st, 1, ident, -1, transient)
            let b2 = sqlite3_bind_text(st, 2, area, -1, transient)
            assert(b1 == SQLITE_OK && b2 == SQLITE_OK, "altitudes: bind failed")
            if b1 == SQLITE_OK, b2 == SQLITE_OK, sqlite3_step(st) == SQLITE_ROW {
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
