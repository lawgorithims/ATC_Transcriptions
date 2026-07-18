import XCTest
@testable import ATCTranscribe

/// Pure coverage for the interactive map: shared geodesy, tap-ranking, airspace containment, and the
/// flight-plan editing helpers (add / insert-in-order / Direct-To / remove / endpoints) with their
/// endpoint + airway mapping edges. No MapKit / bundle needed except the skipped NavMeta smoke test.
final class MapInteractionTests: XCTestCase {

    // MARK: Geo

    func testDistanceAndBearing() {
        let bos = Coord(lat: 42.3629, lon: -71.0064)     // ~KBOS
        let jfk = Coord(lat: 40.6398, lon: -73.7789)     // ~KJFK
        XCTAssertEqual(Geo.nmBetween(bos, jfk), 158, accuracy: 8, "BOS→JFK ≈ 158 nm")
        XCTAssertEqual(Geo.nmBetween(bos, bos), 0, accuracy: 0.001)
        XCTAssertTrue((215...245).contains(Geo.bearing(bos, jfk)), "BOS→JFK is roughly SW")
    }

    // MARK: MapProbe ranking

    private func obj(_ kind: MapObjectKind, _ ident: String) -> IdentifiedObject {
        IdentifiedObject(kind: kind, ident: ident, coord: Coord(lat: 0, lon: 0), onRoute: false)
    }

    func testRankOrdersPointsByDistanceAirspaceLastAndDropsFar() {
        let cands: [(object: IdentifiedObject, distance: Double)] = [
            (obj(.airspace, "CLASS B"), 2),      // area feature — sorts after points despite being closest
            (obj(.vor, "BOS"), 10),
            (obj(.airport, "KBOS"), 5),
            (obj(.fix, "FARFX"), 99),            // outside the 24 pt radius → dropped
        ]
        XCTAssertEqual(MapProbe.rank(cands, within: 24).map(\.ident), ["KBOS", "BOS", "CLASS B"])
    }

    func testRankEmptyWhenAllOutsideRadius() {
        XCTAssertTrue(MapProbe.rank([(obj(.airport, "X"), 40)], within: 24).isEmpty)
    }

    // MARK: Airspace containment (ray casting)

    func testAirspaceContainsCoord() {
        let ring = [Coord(lat: 0, lon: 0), Coord(lat: 0, lon: 2), Coord(lat: 2, lon: 2), Coord(lat: 2, lon: 0)]
        let a = Airspace(id: 1, cls: "B", name: "TEST", floorFt: 0, ceilingFt: 10000,
                         bb: BBox(minLat: 0, minLon: 0, maxLat: 2, maxLon: 2), rings: [ring])
        XCTAssertTrue(a.containsCoord(Coord(lat: 1, lon: 1)))
        XCTAssertFalse(a.containsCoord(Coord(lat: 3, lon: 3)))
    }

    // MARK: FlightPlan editing

    private func leg(_ ident: String, _ kind: RouteKind, _ lat: Double, _ lon: Double) -> ResolvedLeg {
        ResolvedLeg(ident: ident, kind: kind, coord: Coord(lat: lat, lon: lon))
    }

    func testAddWaypointAppendsUppercased() {
        var p = FlightPlan(departure: "KBOS", destination: "KJFK", route: ["PVD"])
        p.addWaypoint(" hfd ")
        XCTAssertEqual(p.route, ["PVD", "HFD"])
    }

    func testInsertInOrderBetweenEndpoints() {
        var p = FlightPlan(departure: "KBOS", destination: "KJFK")
        let resolved = [leg("KBOS", .airport, 42.36, -71.0), leg("KJFK", .airport, 40.64, -73.78)]
        p.insertWaypointInOrder("HFD", at: Coord(lat: 41.7, lon: -72.65), resolved: resolved)
        XCTAssertEqual(p.route, ["HFD"], "single gap between departure and destination")
    }

    func testInsertInOrderPicksNearestMiddleGap() {
        var p = FlightPlan(departure: "KBOS", destination: "KDFW", route: ["ALB", "BUF"])
        let resolved = [leg("KBOS", .airport, 42.36, -71.0), leg("ALB", .vor, 42.75, -73.8),
                        leg("BUF", .vor, 42.93, -78.6), leg("KDFW", .airport, 32.90, -97.04)]
        p.insertWaypointInOrder("SYR", at: Coord(lat: 43.0, lon: -76.1), resolved: resolved)   // between ALB & BUF
        XCTAssertEqual(p.route, ["ALB", "SYR", "BUF"])
    }

    func testDirectToSetsDestinationAndClearsMiddle() {
        var p = FlightPlan(departure: "KBOS", destination: "KJFK", route: ["PVD", "HFD"])
        p.directTo("alb")                                   // no fix → keep the filed departure (only sensible anchor)
        XCTAssertEqual(p.departure, "KBOS")
        XCTAssertEqual(p.destination, "ALB")
        XCTAssertTrue(p.route.isEmpty)
    }

    /// Direct-to WITH a present-position fix re-anchors the origin to that GPS point (as a lat,lon user-point),
    /// so the drawn course runs from where the aircraft IS — not the filed departure (the build-63 report).
    func testDirectToFromPresentPositionReanchorsOrigin() {
        var p = FlightPlan(departure: "KBOS", destination: "KJFK", route: ["PVD", "HFD"])
        let here = Coord(lat: 41.50, lon: -72.10)
        p.directTo("alb", from: here)
        XCTAssertEqual(p.departure, UserPoint.token(here), "origin must become the present-position user-point")
        XCTAssertEqual(UserPoint.parse(p.departure), here, "the stored origin must round-trip to the GPS fix")
        XCTAssertNotEqual(p.departure, "KBOS", "must NOT anchor on the filed departure when a fix exists")
        XCTAssertEqual(p.destination, "ALB")
        XCTAssertTrue(p.route.isEmpty)
    }

    func testRemoveWaypointAndEndpoints() {
        var p = FlightPlan(departure: "KBOS", destination: "KJFK", route: ["PVD", "HFD"])
        p.removeWaypoint("hfd");  XCTAssertEqual(p.route, ["PVD"])
        p.removeWaypoint("KJFK"); XCTAssertEqual(p.destination, "")
        p.removeWaypoint("KBOS"); XCTAssertEqual(p.departure, "")
    }

    func testSetEndpointsAndContains() {
        var p = FlightPlan(route: ["PVD"])
        p.setDeparture("kbos"); p.setDestination("kjfk")
        XCTAssertEqual(p.departure, "KBOS")
        XCTAssertEqual(p.destination, "KJFK")
        XCTAssertTrue(p.contains("pvd"))
        XCTAssertTrue(p.contains("KBOS"))
        XCTAssertFalse(p.contains("ZZZ"))
    }

    // MARK: NavMeta (only when the bundle resource is present in the test host)

    func testNavMetaDecodesWhenBundled() throws {
        try XCTSkipUnless(NavMeta.navaidCount > 0, "navaid_meta.json not in this test bundle")
        XCTAssertEqual(NavMeta.navaid("BOS")?.type, "VORTAC")
        XCTAssertNotNil(NavMeta.navaid("BOS")?.frequencyText)
        XCTAssertNotNil(NavMeta.airport("KJFK")?.name)
    }

    // MARK: User waypoints (dropped lat/lon points)

    func testUserPointParseFormatRoundTrip() {
        XCTAssertEqual(UserPoint.parse("42.100,-71.300"), Coord(lat: 42.1, lon: -71.3))
        XCTAssertNil(UserPoint.parse("KBOS"))            // real idents never parse
        XCTAssertNil(UserPoint.parse("Q105"))
        XCTAssertNil(UserPoint.parse("91.0,0.0"))        // lat out of range
        XCTAssertTrue(UserPoint.isUserPoint("42.1,-71.3"))
        XCTAssertFalse(UserPoint.isUserPoint("BOS"))
        XCTAssertEqual(UserPoint.parse(UserPoint.token(Coord(lat: 42.12345, lon: -71.98765))),
                       Coord(lat: 42.123, lon: -71.988))
    }

    func testRouteResolverResolvesUserPoint() {
        let plan = FlightPlan(departure: "KBOS", destination: "KJFK", route: ["42.100,-71.300"])
        let (points, unresolved) = RouteResolver.resolve(plan.fullRoute)
        XCTAssertTrue(unresolved.isEmpty, "a lat/lon token resolves, never 'unresolved'")
        XCTAssertEqual(points.map(\.ident), ["KBOS", "42.100,-71.300", "KJFK"])
        XCTAssertEqual(points[1].coord, Coord(lat: 42.1, lon: -71.3))
    }

    // MARK: Procedures (bundled FAA d-TPP index)

    func testProceduresDecodeForKnownAirport() throws {
        try XCTSkipIf(Procedures.airportCount == 0, "procedures.json not bundled in the test host")
        let bos = Procedures.forAirport("kbos")   // case-insensitive
        XCTAssertFalse(bos.isEmpty, "KBOS should have published procedures")
        XCTAssertTrue(bos.contains { $0.category == .approach }, "KBOS should have approaches")
        XCTAssertTrue(bos.contains { $0.category == .departure }, "KBOS should have departures")
        if let p = bos.first(where: { !$0.pdf.isEmpty }) {
            XCTAssertEqual(p.plateURL?.absoluteString,
                           "https://aeronav.faa.gov/d-tpp/\(Procedures.cycle)/\(p.pdf)")
        }
        XCTAssertTrue(Procedures.forAirport("ZZZZ").isEmpty, "an unknown airport has no procedures")
    }

    // MARK: Coded procedures (bundled FAA CIFP → cifp.sqlite)

    func testCIFPProceduresAndLegsForKnownAirport() throws {
        try XCTSkipIf(CIFP.procedureCount == 0, "cifp.sqlite not bundled in the test host")
        let procs = CIFP.procedures(airport: "kbos")
        XCTAssertFalse(procs.isEmpty, "KBOS should have coded procedures")
        let approaches = procs.filter { $0.kind == "IAP" }
        XCTAssertFalse(approaches.isEmpty, "KBOS should have approaches")

        let legs = CIFP.legs(procedureID: approaches[0].id)
        XCTAssertFalse(legs.isEmpty, "an approach should have legs")
        XCTAssertEqual(legs.map(\.seq), legs.map(\.seq).sorted(), "legs are returned in sequence order")
        XCTAssertTrue(legs.contains { $0.coord != nil }, "at least some legs resolve to a coordinate")

        // Boston Logan ILS 04R ≈ 110.30 MHz / ~035° — sanity-check the decode.
        let ils = CIFP.ils(airport: "KBOS")
        XCTAssertFalse(ils.isEmpty, "KBOS should have ILS records")
        XCTAssertTrue(ils.allSatisfy { ($0.freqMHz ?? 111) >= 108 && ($0.freqMHz ?? 111) <= 112 }, "localizer freqs in band")
        XCTAssertTrue(CIFP.procedures(airport: "ZZZZ").isEmpty, "an unknown airport has no procedures")
    }

    // MARK: Search (needs the bundled nav resources)

    func testSearchByIdentAndNameWhenBundled() throws {
        try XCTSkipUnless(NavDatabase.count > 0 && NavMeta.airportCount > 0, "nav resources not in this test bundle")
        XCTAssertTrue(MapSearch.results("").isEmpty)
        let byIdent = MapSearch.results("KBOS")
        XCTAssertEqual(byIdent.first?.ident, "KBOS", "exact ident sorts first")
        XCTAssertEqual(byIdent.first?.kind, .airport)
        XCTAssertTrue(MapSearch.results("Logan").contains { $0.ident == "KBOS" }, "name search finds Boston Logan")
    }

    // MARK: Phase 5 — loaded procedures (SID / STAR / approach)

    private func loaded(_ kind: String, _ ident: String, fixes: [String], transition: String = "") -> LoadedProcedure {
        LoadedProcedure(airport: "KBOS", kind: kind, ident: ident, name: "\(ident) proc",
                        runway: "33L", transition: transition, fixes: fixes)
    }

    func testLoadAndClearProcedureSlotsByKind() {
        var p = FlightPlan(departure: "KBOS", destination: "KPVD")
        p.loadProcedure(loaded("SID", "LOGN5", fixes: ["LOGN"]))
        p.loadProcedure(loaded("STAR", "ROBUC3", fixes: ["ROBUC"]))
        p.loadProcedure(loaded("IAP", "H33LX", fixes: ["BBOGG", "CRLTN"], transition: "BBOGG"))
        XCTAssertEqual(p.departureProcedure?.ident, "LOGN5")
        XCTAssertEqual(p.arrivalProcedure?.ident, "ROBUC3")
        XCTAssertEqual(p.approachProcedure?.ident, "H33LX")
        XCTAssertEqual(p.loadedProcedures.count, 3)
        p.clearProcedure(kind: "IAP")
        XCTAssertNil(p.approachProcedure)
        XCTAssertEqual(p.loadedProcedures.count, 2)
        p.clearProcedure(kind: "")
        XCTAssertTrue(p.loadedProcedures.isEmpty, "clearing all removes every slot")
    }

    func testProcedureOnlyPlanIsNotEmpty() {
        var p = FlightPlan()
        XCTAssertTrue(p.isEmpty)
        p.loadProcedure(loaded("IAP", "H33LX", fixes: ["BBOGG"]))
        XCTAssertFalse(p.isEmpty, "a loaded procedure makes the plan non-empty (so it persists)")
    }

    func testGroundingContextNamesProcedureButKeepsFixesOutOfSnapVocab() {
        var p = FlightPlan(callsign: "N345AB", departure: "KBOS", destination: "KPVD")
        p.loadProcedure(loaded("IAP", "H33LX", fixes: ["BBOGG", "CRLTN"], transition: "BBOGG"))
        // The LLM context block names the loaded approach + its transition …
        XCTAssertTrue(p.contextBlock.contains("Approach H33LX proc via BBOGG"), p.contextBlock)
        // … but the deterministic snap-vocab does NOT gain the procedure fixes (Phase-3 FP guard).
        XCTAssertFalse(p.vocabTerms.contains("BBOGG"), "procedure fixes must not enter the snap-vocab")
        XCTAssertFalse(p.vocabTerms.contains("CRLTN"))
        XCTAssertTrue(p.vocabTerms.contains("N345AB"), "the filed callsign is still in the snap-vocab")
    }

    func testContextBlockProcedureOnlyHasNoDanglingOwnFlight() {
        var p = FlightPlan()
        p.loadProcedure(loaded("IAP", "H33LX", fixes: ["BBOGG"]))
        let block = p.contextBlock
        XCTAssertFalse(block.contains("Own flight"), "no callsign/airports → no 'Own flight:' fragment: \(block)")
        XCTAssertTrue(block.contains("Approach H33LX proc"), block)
        XCTAssertFalse(block.hasPrefix(" "), "no leading space")
    }

    func testOldPlanJSONDecodesWithoutProcedureKeys() throws {
        let json = #"{"aircraftType":"","callsign":"N1","departure":"KBOS","destination":"KPVD","alternate":"","route":["PVD"],"savedAt":0}"#
        let p = try JSONDecoder().decode(FlightPlan.self, from: Data(json.utf8))
        XCTAssertNil(p.approachProcedure, "a pre-Phase-5 plan decodes with nil procedure slots")
        XCTAssertEqual(p.destination, "KPVD")
    }

    func testCIFPReFindsProcedureLegsByStableKeys() throws {
        try XCTSkipIf(CIFP.procedureCount == 0, "cifp.sqlite not bundled")
        let iap = try XCTUnwrap(CIFP.procedures(airport: "KBOS").first { $0.kind == "IAP" })
        let byKey = CIFP.legs(airport: "KBOS", ident: iap.ident, transition: iap.transition)
        let byRowid = CIFP.legs(procedureID: iap.id)
        XCTAssertEqual(byKey.map(\.fix), byRowid.map(\.fix), "re-find by keys == find by rowid")
        XCTAssertTrue(CIFP.legs(airport: "KBOS", ident: "ZZZZZ", transition: "").isEmpty)
    }

    func testProcedureRouteExpandsWithApproachLegs() throws {
        try XCTSkipIf(CIFP.procedureCount == 0, "cifp.sqlite not bundled")
        let iap = try XCTUnwrap(CIFP.procedures(airport: "KBOS").first { $0.kind == "IAP" && !$0.runway.isEmpty })
        let fixes = Array(Set(CIFP.legs(procedureID: iap.id).map(\.fix).filter { !$0.isEmpty && !$0.hasPrefix("RW") }))
        var p = FlightPlan(departure: "KBOS", destination: "KPVD", route: ["PVD"])
        p.loadProcedure(LoadedProcedure(airport: "KBOS", kind: "IAP", ident: iap.ident, name: iap.name,
                                        runway: iap.runway, transition: iap.transition, fixes: fixes))
        let route = ProcedureRoute.resolve(p)
        XCTAssertGreaterThan(route.count, 2, "endpoints + approach legs")
        XCTAssertLessThanOrEqual(route.count, ProcedureRoute.maxLegs)
        XCTAssertTrue(route.contains { fixes.contains($0.ident) }, "the coded approach fixes are in the drawn route")
        // consecutive-duplicate collapse holds
        for i in 1..<route.count { XCTAssertNotEqual(route[i].ident, route[i - 1].ident) }
    }
}
