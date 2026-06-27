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

    func testSavingEmptyPlanClearsStorage() {
        var plan = FlightPlan()
        plan.callsign = "N1"
        plan.save()
        XCTAssertNotNil(FlightPlan.load())

        FlightPlan().save()   // empty → clears
        XCTAssertNil(FlightPlan.load())
    }
}
