import XCTest
@testable import ATCTranscribe

/// Live route ETAs from present position at the current ground speed — next-waypoint sequencing + timing.
final class RouteETAsTests: XCTestCase {

    // A due-east 3-waypoint route at ~42°N: A(−72) → B(−71) → C(−70). 1° lon ≈ 44.6 NM here.
    private let route: [(ident: String, coord: Coord)] = [
        ("KA", Coord(lat: 42, lon: -72)),
        ("KB", Coord(lat: 42, lon: -71)),
        ("KC", Coord(lat: 42, lon: -70)),
    ]

    func testNextWaypointIsAheadOnFirstLeg() {
        // Just east of A, on the A→B leg → next waypoint is B.
        let e = RouteETAs.compute(route: route, present: Coord(lat: 42, lon: -71.8), groundSpeedKt: 120)
        XCTAssertEqual(e?.nextIdent, "KB")
        XCTAssertEqual(e?.destIdent, "KC")
    }

    func testNextWaypointAdvancesOnSecondLeg() {
        // Past B, on the B→C leg → next waypoint is C (the destination).
        let e = RouteETAs.compute(route: route, present: Coord(lat: 42, lon: -70.5), groundSpeedKt: 120)
        XCTAssertEqual(e?.nextIdent, "KC")
    }

    func testToDestIsNotLessThanToNext() {
        let e = RouteETAs.compute(route: route, present: Coord(lat: 42, lon: -71.9), groundSpeedKt: 100)!
        XCTAssertNotNil(e.toNextMin); XCTAssertNotNil(e.toDestMin)
        XCTAssertGreaterThanOrEqual(e.toDestMin!, e.toNextMin!)   // destination is at or beyond the next wpt
    }

    func testETEShrinksWithHigherGroundSpeed() {
        let slow = RouteETAs.compute(route: route, present: Coord(lat: 42, lon: -71.9), groundSpeedKt: 60)!
        let fast = RouteETAs.compute(route: route, present: Coord(lat: 42, lon: -71.9), groundSpeedKt: 240)!
        XCTAssertGreaterThan(slow.toDestMin!, fast.toDestMin!)
    }

    func testNilWhenParkedOrNoData() {
        XCTAssertNil(RouteETAs.compute(route: route, present: Coord(lat: 42, lon: -71.9), groundSpeedKt: 2))  // taxi
        XCTAssertNil(RouteETAs.compute(route: route, present: Coord(lat: 42, lon: -71.9), groundSpeedKt: nil))
        XCTAssertNil(RouteETAs.compute(route: [route[0]], present: Coord(lat: 42, lon: -72), groundSpeedKt: 120)) // 1 wpt
        XCTAssertNil(RouteETAs.compute(route: route, present: nil, groundSpeedKt: 120))
    }

    func testETAClockIsInTheFuture() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let e = RouteETAs.compute(route: route, present: Coord(lat: 42, lon: -71.9), groundSpeedKt: 100)!
        XCTAssertNotEqual(e.destETAText(now: now), "—")          // a real clock time, not the nil dash
    }

    func testETETextIsADurationNotAClock() {
        // ~89 NM to destination at 100 kt ≈ 53 min → "<60 min" duration form, never a clock (no ":" for <60).
        let near = RouteETAs.compute(route: route, present: Coord(lat: 42, lon: -71.9), groundSpeedKt: 100)!
        XCTAssertTrue(near.destETEText().hasSuffix(" min"), "sub-hour ETE should read like '53 min', got \(near.destETEText())")
        XCTAssertNotEqual(near.nextETEText(), "—")
        // Slow ground speed over the full route pushes past an hour → "h:mm" form.
        let slow = RouteETAs.compute(route: route, present: Coord(lat: 42, lon: -71.99), groundSpeedKt: 40)!
        XCTAssertTrue(slow.destETEText().contains(":"), "multi-hour ETE should read like '2:14', got \(slow.destETEText())")
    }
}
