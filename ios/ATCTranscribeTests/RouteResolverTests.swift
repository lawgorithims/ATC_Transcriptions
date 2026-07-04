import XCTest
@testable import ATCTranscribe

/// Route → map-point resolution: airports resolve in order, airway designators are skipped (not
/// counted as "unresolved"), unknown fixes are collected. Airport assertions use the curated
/// `AirportCoordinates` (bundled), so they're deterministic regardless of the big nav DB; a lenient
/// case exercises `NavDatabase` only when its resource is present in the test host.
final class RouteResolverTests: XCTestCase {

    func testResolvesAirportsInOrder() {
        let plan = FlightPlan(departure: "KBOS", destination: "KDFW")
        let (points, unresolved) = RouteResolver.resolve(plan.fullRoute)
        XCTAssertEqual(points.map(\.ident), ["KBOS", "KDFW"], "departure + destination airports resolve in order")
        XCTAssertEqual(points.first?.kind, .airport)
        XCTAssertTrue(unresolved.isEmpty)
    }

    func testAirwayIsSkippedNotUnresolved() {
        // Q105 classifies as an airway (a path, not a point) → skipped; ZZZZZ is a fake fix → unresolved.
        let plan = FlightPlan(departure: "KBOS", destination: "KDFW", route: ["Q105", "ZZZZZ"])
        let (points, unresolved) = RouteResolver.resolve(plan.fullRoute)
        XCTAssertEqual(points.map(\.ident), ["KBOS", "KDFW"], "airway + unknown fix aren't plotted")
        XCTAssertFalse(unresolved.contains("Q105"), "an airway is skipped, never reported unresolved")
        XCTAssertTrue(unresolved.contains("ZZZZZ"), "an unknown fix is reported unresolved")
    }

    func testEmptyPlanResolvesToNothing() {
        let (points, unresolved) = RouteResolver.resolve(FlightPlan().fullRoute)
        XCTAssertTrue(points.isEmpty)
        XCTAssertTrue(unresolved.isEmpty)
    }

    func testNavDatabaseResolvesAKnownFixWhenBundled() throws {
        try XCTSkipUnless(NavDatabase.count > 0, "nav_coords.json not in this bundle")
        XCTAssertNotNil(NavDatabase.resolve("ROBUC", near: nil), "a known NASR enroute fix should resolve")
        XCTAssertNotNil(NavDatabase.resolve("BOS", near: Coord(lat: 42.36, lon: -71.0)), "the BOS VOR should resolve")
    }
}
