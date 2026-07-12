import XCTest
@testable import ATCTranscribe

/// `FlightPlan` — the Electronic Flight Bag model: ForeFlight paste parsing, the LLM context
/// block, staleness, and UserDefaults persistence.
final class FlightPlanTests: XCTestCase {

    override func tearDown() {
        FlightPlan.clear()   // don't leak the saved plan into other tests / the running app
        super.tearDown()
    }

    // MARK: ForeFlight paste parsing

    func testParsePlainRoute() {
        let r = FlightPlan.parseRoute("KDFW DCT BLECO Q105 LFK KAUS")
        XCTAssertEqual(r.departure, "KDFW")
        XCTAssertEqual(r.destination, "KAUS")
        XCTAssertEqual(r.route, ["BLECO", "Q105", "LFK"])   // DCT filler dropped
    }

    func testParseDottedForeFlightRoute() {
        let r = FlightPlan.parseRoute("kdfw./.BLECO.Q105.LFK..kaus")
        XCTAssertEqual(r.departure, "KDFW")
        XCTAssertEqual(r.destination, "KAUS")
        XCTAssertEqual(r.route, ["BLECO", "Q105", "LFK"])
    }

    func testParseSingleAirport() {
        let r = FlightPlan.parseRoute("KDFW")
        XCTAssertEqual(r.departure, "KDFW")
        XCTAssertNil(r.destination)
        XCTAssertTrue(r.route.isEmpty)
    }

    func testParseEmpty() {
        let r = FlightPlan.parseRoute("   ")
        XCTAssertNil(r.departure)
        XCTAssertNil(r.destination)
        XCTAssertTrue(r.route.isEmpty)
    }

    func testParsePreservesUserWaypointTokens() {
        // A map-dropped waypoint is stored as "lat,lon" — the dotted-route separators (, .) must
        // not shred it, or any flight-plan-strip edit silently destroys the waypoint.
        let r = FlightPlan.parseRoute("KMSP 42.100,-71.300 KORD")
        XCTAssertEqual(r.departure, "KMSP")
        XCTAssertEqual(r.destination, "KORD")
        XCTAssertEqual(r.route, ["42.100,-71.300"], "the lat,lon token must survive verbatim")
        // …while a dotted ForeFlight route still splits normally.
        let dotted = FlightPlan.parseRoute("KDFW./.BLECO.Q105..KAUS")
        XCTAssertEqual(dotted.route, ["BLECO", "Q105"])
    }

    func testReconcileDropsOrphanedProcedures() {
        var plan = FlightPlan()
        plan.departure = "KMSP"; plan.destination = "KORD"
        plan.departureProcedure = LoadedProcedure(airport: "KMSP", kind: "SID", ident: "S1", name: "S",
                                                  runway: "", transition: "", fixes: ["A"])
        plan.arrivalProcedure = LoadedProcedure(airport: "KORD", kind: "STAR", ident: "T1", name: "T",
                                                runway: "", transition: "", fixes: ["B"])
        plan.reconcileProceduresWithEndpoints()
        XCTAssertNotNil(plan.departureProcedure, "matching SID survives")
        XCTAssertNotNil(plan.arrivalProcedure, "matching STAR survives")
        plan.departure = "KSTP"; plan.destination = "KMDW"   // pilot re-typed the route
        plan.reconcileProceduresWithEndpoints()
        XCTAssertNil(plan.departureProcedure, "SID at KMSP is stale for a KSTP departure")
        XCTAssertNil(plan.arrivalProcedure, "STAR at KORD is stale for a KMDW arrival")
    }

    // MARK: context block

    func testContextBlockOmitsEmptyFields() {
        var plan = FlightPlan()
        plan.callsign = "N345AB"
        XCTAssertEqual(plan.contextBlock, "Own flight: callsign N345AB.")
    }

    func testContextBlockFull() {
        var plan = FlightPlan()
        plan.callsign = "N345AB"
        plan.aircraftType = "Cessna 172"
        plan.departure = "KDFW"
        plan.destination = "KAUS"
        plan.alternate = "KSAT"
        plan.route = ["BLECO", "Q105", "LFK"]
        XCTAssertEqual(plan.contextBlock,
            "Own flight: callsign N345AB, Cessna 172, KDFW to KAUS, alternate KSAT. Route: BLECO Q105 LFK.")
    }

    func testEmptyPlanHasNoContextOrVocab() {
        let plan = FlightPlan()
        XCTAssertTrue(plan.isEmpty)
        XCTAssertEqual(plan.contextBlock, "")
        XCTAssertTrue(plan.vocabTerms.isEmpty)
    }

    func testVocabTermsIncludeCallsignAirportsAndRoute() {
        var plan = FlightPlan()
        plan.callsign = "N345AB"
        plan.departure = "KDFW"
        plan.destination = "KAUS"
        plan.route = ["BLECO", "LFK"]
        XCTAssertTrue(plan.vocabTerms.contains("N345AB"))
        XCTAssertTrue(plan.vocabTerms.contains("KDFW"))
        XCTAssertTrue(plan.vocabTerms.contains("BLECO"))
    }

    // MARK: route classification (for the colour-coded route bar)

    func testRouteLegClassification() {
        XCTAssertEqual(RouteLeg.classify("KDFW"), .airport)   // 4-letter ICAO
        XCTAssertEqual(RouteLeg.classify("BLECO"), .waypoint) // 5-letter RNAV/GPS fix
        XCTAssertEqual(RouteLeg.classify("LFK"), .vor)        // 3-letter navaid
        XCTAssertEqual(RouteLeg.classify("Q105"), .airway)
        XCTAssertEqual(RouteLeg.classify("J42"), .airway)
        XCTAssertEqual(RouteLeg.classify("UL607"), .airway)
        XCTAssertEqual(RouteLeg.classify("V16"), .airway)
        XCTAssertEqual(RouteLeg.classify("DCT"), .other)
        XCTAssertEqual(RouteLeg.classify("DARTZ4"), .other)   // SID/STAR procedure — not a fix/airway
    }

    func testFullRouteOrdersAndTagsEndpoints() {
        var plan = FlightPlan()
        plan.departure = "KDFW"
        plan.destination = "KAUS"
        plan.route = ["BLECO", "Q105", "LFK"]
        let legs = plan.fullRoute
        XCTAssertEqual(legs.map(\.ident), ["KDFW", "BLECO", "Q105", "LFK", "KAUS"])
        XCTAssertEqual(legs.first?.kind, .airport)   // departure forced to airport
        XCTAssertEqual(legs.last?.kind, .airport)    // destination forced to airport
        XCTAssertEqual(legs[2].kind, .airway)        // Q105
    }

    // MARK: staleness

    func testStaleAfterSevenDays() {
        var plan = FlightPlan()
        plan.callsign = "N1"
        plan.savedAt = Date(timeIntervalSinceNow: -8 * 24 * 3600)
        XCTAssertTrue(plan.isStale)
        XCTAssertGreaterThanOrEqual(plan.ageDays, 7)
    }

    func testFreshPlanNotStale() {
        var plan = FlightPlan()
        plan.callsign = "N1"
        plan.savedAt = Date()
        XCTAssertFalse(plan.isStale)
    }

    // MARK: persistence

    func testSaveLoadRoundTrip() {
        var plan = FlightPlan()
        plan.callsign = "N345AB"
        plan.departure = "KDFW"
        plan.destination = "KAUS"
        plan.route = ["BLECO", "Q105"]
        plan.save()

        let loaded = FlightPlan.load()
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.callsign, "N345AB")
        XCTAssertEqual(loaded?.departure, "KDFW")
        XCTAssertEqual(loaded?.route, ["BLECO", "Q105"])
    }

    /// A pre-altitude persisted plan (no `cruiseAltitudeFt` key) must still decode — the field is
    /// optional Codable, mirroring the procedure slots.
    func testOldPlanWithoutAltitudeStillDecodes() throws {
        let old = #"{"aircraftType":"","callsign":"N345AB","departure":"KDFW","destination":"KAUS","alternate":"","route":["BLECO"],"savedAt":700000000}"#
        let plan = try JSONDecoder().decode(FlightPlan.self, from: Data(old.utf8))
        XCTAssertNil(plan.cruiseAltitudeFt)
        XCTAssertEqual(plan.callsign, "N345AB")
    }

    func testAltitudeRoundTripsAndCountsAsContent() {
        var plan = FlightPlan()
        plan.cruiseAltitudeFt = 16_000
        XCTAssertFalse(plan.isEmpty, "an altitude alone is content — must not be dropped by editPlan")
        plan.save()
        XCTAssertEqual(FlightPlan.load()?.cruiseAltitudeFt, 16_000)
        XCTAssertTrue(plan.contextBlock.contains("cruising 16000 feet"),
                      "altitude grounds the corrector's context block")
    }

    func testSavingEmptyPlanClearsStorage() {
        var plan = FlightPlan()
        plan.callsign = "N1"
        plan.save()
        XCTAssertNotNil(FlightPlan.load())

        FlightPlan().save()   // empty → clears
        XCTAssertNil(FlightPlan.load())
    }
}
