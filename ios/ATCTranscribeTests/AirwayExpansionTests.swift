import XCTest
@testable import ATCTranscribe

/// A filed airway is a PATH between its two bracketing fixes, not a straight line.
///
/// `airway.fix` is 100% populated over all 19,099 rows and was never SELECTed, and `RouteResolver`
/// skipped airway tokens outright — so "GDM V1 ORW", the exact syntax the airway card tells the pilot
/// to file, drew a direct line with none of V1's fixes on it, and DIST/ETE/ETA/fuel were computed along
/// that line. Over 4,231 realistic filed sub-segments the published route is a median 0.1 NM longer
/// than the chord, a mean of 2.5, a 90th percentile of 6.9 and up to 100.6 NM.
final class AirwayExpansionTests: XCTestCase {

    private var anyAirway: (ident: String, fixes: [(fix: String, coord: Coord)])? {
        for id in ["V1", "V16", "J42", "V3", "J80", "Q105"] {
            let f = Airways.fixes(of: id)
            if f.count >= 4 { return (id, f) }
        }
        return nil
    }

    func testTheFixColumnIsNowRead() throws {
        let a = try XCTUnwrap(anyAirway, "no airway with 4+ fixes in the bundle")
        for p in a.fixes {
            XCTAssertFalse(p.fix.isEmpty, "\(a.ident) has a fix row with no ident — the column is unread")
        }
    }

    func testEveryReturnedFixHasARealCoordinate() throws {
        // build_cifp.py drops airway points whose fix has no coordinate (37 airways have such a gap),
        // and sqlite3_column_double coerces NULL to 0.0 — which would draw the airway through 0N/0E.
        let a = try XCTUnwrap(anyAirway)
        for p in a.fixes {
            XCTAssertFalse(p.coord.lat == 0 && p.coord.lon == 0,
                           "\(a.ident) yielded the null island for \(p.fix)")
        }
    }

    func testASegmentRunsBetweenTheTwoNamedFixesInclusive() throws {
        let a = try XCTUnwrap(anyAirway)
        let from = a.fixes[0].fix, to = a.fixes[2].fix
        let seg = Airways.segment(of: a.ident, from: from, to: to)
        XCTAssertEqual(seg.first?.fix, from)
        XCTAssertEqual(seg.last?.fix, to)
        XCTAssertEqual(seg.count, 3)
    }

    func testASegmentFiledBackwardsComesBackReversed() throws {
        let a = try XCTUnwrap(anyAirway)
        let fwd = Airways.segment(of: a.ident, from: a.fixes[0].fix, to: a.fixes[2].fix)
        let rev = Airways.segment(of: a.ident, from: a.fixes[2].fix, to: a.fixes[0].fix)
        XCTAssertEqual(fwd.map(\.fix), rev.map(\.fix).reversed(),
                       "an airway filed in the other direction must walk the other way")
    }

    func testAFixNotOnTheAirwayYieldsNothing() throws {
        // Refuse rather than expand partially — a path the data does not support is worse than the
        // straight line it replaces.
        let a = try XCTUnwrap(anyAirway)
        XCTAssertTrue(Airways.segment(of: a.ident, from: a.fixes[0].fix, to: "ZZZZZ").isEmpty)
        XCTAssertTrue(Airways.segment(of: a.ident, from: "ZZZZZ", to: a.fixes[0].fix).isEmpty)
    }

    func testTheSameFixOnBothEndsYieldsNothing() throws {
        let a = try XCTUnwrap(anyAirway)
        XCTAssertTrue(Airways.segment(of: a.ident, from: a.fixes[0].fix, to: a.fixes[0].fix).isEmpty)
    }

    func testAFiledAirwayPutsItsIntermediateFixesOnTheRoute() throws {
        let a = try XCTUnwrap(anyAirway)
        let from = a.fixes[0].fix, to = a.fixes[3].fix
        let legs = [RouteLeg(ident: from, kind: RouteLeg.classify(from)),
                    RouteLeg(ident: a.ident, kind: .airway),
                    RouteLeg(ident: to, kind: RouteLeg.classify(to))]
        let idents = RouteResolver.resolve(legs).points.map(\.ident)
        let middle = a.fixes[1...2].map(\.fix)
        for m in middle {
            XCTAssertTrue(idents.contains(m), "\(m) is on \(a.ident) and must be on the drawn route")
        }
        XCTAssertFalse(idents.contains(a.ident), "the airway DESIGNATOR is not a point on the route")
    }

    func testAnUnbracketedAirwayIsStillSkipped() {
        // A route that names an airway with nothing before it cannot be expanded; the old behaviour
        // (skip it) is correct there and must not become a guess.
        let idents = RouteResolver.resolve([RouteLeg(ident: "V1", kind: .airway)]).points.map(\.ident)
        XCTAssertTrue(idents.isEmpty)
    }

    func testTheExpandedPathIsAtLeastAsLongAsTheChord() throws {
        // The whole point: the published route is never shorter than the straight line it replaced.
        let a = try XCTUnwrap(anyAirway)
        let seg = Airways.segment(of: a.ident, from: a.fixes[0].fix, to: a.fixes[3].fix)
        try XCTSkipIf(seg.count < 3)
        var walked = 0.0
        for i in 1..<seg.count { walked += Geo.nmBetween(seg[i - 1].coord, seg[i].coord) }
        let chord = Geo.nmBetween(seg[0].coord, seg[seg.count - 1].coord)
        XCTAssertGreaterThanOrEqual(walked, chord - 0.01)
    }
}
