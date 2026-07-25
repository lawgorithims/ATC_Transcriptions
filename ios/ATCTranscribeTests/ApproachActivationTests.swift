import XCTest
@testable import ATCTranscribe

/// The derivations behind "activate approach". The shipped cifp.sqlite has no IAF/FAF/missed FLAGS —
/// `Tools/build_cifp.py` drops ARINC's route-type and waypoint-description columns — so the entry
/// options and the missed-approach boundary are inferred from the record structure. These tests pin
/// that inference, including against the real KBOS ILS RWY 04R record.
final class ApproachActivationTests: XCTestCase {

    // MARK: entries

    func testVectorsIsAlwaysOfferedEvenWithNoPublishedTransitions() {
        // 322 approaches in the DB publish no transition at all; ATC can still vector to final.
        let e = ApproachActivation.entries(transitions: [])
        XCTAssertEqual(e, [.vectors])
    }

    func testTransitionsAreDedupedUppercasedSortedAndVectorsComesLast() {
        let e = ApproachActivation.entries(transitions: ["youuk", "BBOGG", "  brunl ", "BBOGG", ""])
        XCTAssertEqual(e, [.transition("BBOGG"), .transition("BRUNL"), .transition("YOUUK"), .vectors],
                       "entries must be normalized, deduped, alphabetical, with VECTORS last")
    }

    func testEntryExposesTheIAFFixOnlyForATransition() {
        XCTAssertEqual(ApproachActivation.Entry.transition("BBOGG").iafFix, "BBOGG")
        XCTAssertNil(ApproachActivation.Entry.vectors.iafFix, "vectors has no fix to fly direct to")
    }

    // MARK: missed-approach segmentation

    /// The real KBOS ILS RWY 04R approach-proper record (procedure_id 11554 in the shipped DB).
    /// Published missed approach: "climb to 3000 direct WAXEN and hold".
    func testKBOSIls04RSplitsAtTheRunwayThreshold() {
        let legs = [(seq: 10, fix: "WINNI", legType: "IF"),
                    (seq: 11, fix: "NABBO", legType: "CF"),
                    (seq: 20, fix: "MILTT", legType: "CF"),
                    (seq: 30, fix: "RW04R", legType: "CF"),
                    (seq: 40, fix: "WAXEN", legType: "CF"),
                    (seq: 50, fix: "WAXEN", legType: "HM")]
        let s = ApproachActivation.splitMissed(legs)
        XCTAssertEqual(s.approach, [10, 11, 20, 30], "everything through the runway threshold is the approach")
        XCTAssertEqual(s.missed, [40, 50], "everything after the threshold is the missed approach")
    }

    func testFallsBackToTheTrailingHoldWhenThereIsNoRunwayThreshold() {
        // ~11% of approach records carry no RW* pseudo-fix; the missed is then the climb + the hold.
        let legs = [(seq: 10, fix: "ABCDE", legType: "IF"),
                    (seq: 20, fix: "FGHIJ", legType: "TF"),
                    (seq: 30, fix: "KLMNO", legType: "CA"),
                    (seq: 40, fix: "KLMNO", legType: "HM")]
        let s = ApproachActivation.splitMissed(legs)
        XCTAssertEqual(s.approach, [10, 20])
        XCTAssertEqual(s.missed, [30, 40], "the climb feeding the hold belongs to the missed approach")
    }

    func testNoMissedSegmentIsReportedRatherThanInvented() {
        // 0.3% of approaches have neither boundary. The app must say so and defer to the plate text,
        // never fabricate a go-around path.
        let legs = [(seq: 10, fix: "ABCDE", legType: "IF"), (seq: 20, fix: "FGHIJ", legType: "TF")]
        let s = ApproachActivation.splitMissed(legs)
        XCTAssertEqual(s.approach, [10, 20])
        XCTAssertTrue(s.missed.isEmpty)
    }

    func testEmptyLegsAreHandled() {
        let s = ApproachActivation.splitMissed([])
        XCTAssertTrue(s.approach.isEmpty); XCTAssertTrue(s.missed.isEmpty)
    }

    func testTheRunwayThresholdItselfStaysWithTheApproach() {
        let legs = [(seq: 10, fix: "RW22L", legType: "CF"), (seq: 20, fix: "HOLDX", legType: "HM")]
        let s = ApproachActivation.splitMissed(legs)
        XCTAssertEqual(s.approach, [10], "the threshold is the last point of the approach, not the missed")
        XCTAssertEqual(s.missed, [20])
    }

    // MARK: published missed-approach marker (authoritative)

    /// The FAA publishes the missed-approach point in the waypoint-description code; every one of the
    /// 10,243 coded approaches in cycle 2607 carries exactly one. Reading it replaced a structural
    /// heuristic that DISAGREED on 7 of 94 sampled approaches — this is the real KBOS LOC RWY 27.
    func testPublishedMapMarkerBeatsTheStructuralHeuristic() {
        // LONER(IF) -> RIPIT(FAF) -> OQDEK(MAP, 461ft) -> climb 3000 direct BOSOX -> hold BOSOX.
        let legs = [(seq: 10, fix: "LONER", legType: "IF"),
                    (seq: 20, fix: "RIPIT", legType: "CF"),
                    (seq: 30, fix: "OQDEK", legType: "CF"),
                    (seq: 40, fix: "BOSOX", legType: "CF"),
                    (seq: 50, fix: "BOSOX", legType: "HM")]
        let roles: [LegRole] = [.intermediateFix, .finalApproachFix, .missedApproachPoint, .none, .none]
        let marked = ApproachActivation.splitMissed(legs, roles: roles)
        XCTAssertEqual(marked.approach, [10, 20, 30], "the approach runs through the missed-approach point")
        XCTAssertEqual(marked.missed, [40, 50], "the missed is the climb to BOSOX and its hold")

        // The heuristic gets this one wrong — it has no RW* fix to anchor on and walks the CF legs back
        // through the whole approach. Pinned so the regression is visible if anyone re-fronts it.
        let guessed = ApproachActivation.splitMissed(legs)
        XCTAssertNotEqual(guessed.missed, marked.missed,
                          "this fixture exists precisely because the structural fallback mis-splits it")
    }

    /// A missed approach whose legs have NO fix (a climb-to-altitude) — previously undeliverable,
    /// because the old builder dropped every fix-less leg. Real shape: KBOS RNAV RWY 32.
    func testMissedApproachContainingAFixlessClimbLeg() {
        let legs = [(seq: 10, fix: "YAARD", legType: "IF"),
                    (seq: 30, fix: "PAARK", legType: "TF"),
                    (seq: 40, fix: "",      legType: "CA"),      // climb to altitude — no fix
                    (seq: 50, fix: "WINDZ", legType: "DF"),
                    (seq: 60, fix: "TELLE", legType: "TF"),
                    (seq: 70, fix: "TELLE", legType: "HM")]
        let roles: [LegRole] = [.intermediateFix, .missedApproachPoint, .none, .none, .none, .none]
        let s = ApproachActivation.splitMissed(legs, roles: roles)
        XCTAssertEqual(s.approach, [10, 30])
        XCTAssertEqual(s.missed, [40, 50, 60, 70], "the fix-less climb leg belongs to the missed approach")
    }

    /// A record with no published marker must still yield a missed approach, via the fallback.
    func testUnmarkedRecordFallsBackToTheStructuralSplit() {
        let legs = [(seq: 10, fix: "ABCDE", legType: "IF"),
                    (seq: 20, fix: "RW04R", legType: "CF"),
                    (seq: 30, fix: "HOLDX", legType: "HM")]
        let s = ApproachActivation.splitMissed(legs, roles: [.none, .none, .none])
        XCTAssertEqual(s.approach, [10, 20], "falls back to the runway-threshold boundary")
        XCTAssertEqual(s.missed, [30])
    }

    func testLegRoleDecodesTheWaypointDescriptionCode() {
        XCTAssertEqual(LegRole(wpDesc: "E  A"), .initialApproachFix)
        XCTAssertEqual(LegRole(wpDesc: "E  F"), .finalApproachFix)
        XCTAssertEqual(LegRole(wpDesc: "EY M"), .missedApproachPoint)
        XCTAssertEqual(LegRole(wpDesc: "E  I"), .intermediateFix)
        XCTAssertEqual(LegRole(wpDesc: "EE  "), .none)
        XCTAssertEqual(LegRole(wpDesc: ""), .none, "a short/absent code is not a defect")
    }

    // MARK: plate → coded approach matching

    /// One plate legitimately maps to two coded approaches; the type token is what separates them.
    func testIlsOrLocPlateRanksBothIlsAndLocalizerForThatRunway() {
        let candidates = [(ident: "I04R", name: "ILS RWY 04R", runway: "04R"),
                          (ident: "L04R", name: "LOC RWY 04R", runway: "04R"),
                          (ident: "I27",  name: "ILS RWY 27",  runway: "27")]
        let m = ApproachActivation.matchPlate(plateName: "ILS OR LOC RWY 04R", runway: "04R",
                                              candidates: candidates)
        XCTAssertEqual(m.count, 2, "only the 04R approaches are plausible")
        XCTAssertEqual(Set(m.map(\.ident)), ["I04R", "L04R"])
        XCTAssertEqual(m.first?.runway, "04R")
    }

    func testRunwayFiltersOutOtherApproaches() {
        let candidates = [(ident: "I04R", name: "ILS RWY 04R", runway: "04R"),
                          (ident: "I27",  name: "ILS RWY 27",  runway: "27")]
        let m = ApproachActivation.matchPlate(plateName: "ILS RWY 27", runway: "27", candidates: candidates)
        XCTAssertEqual(m.map(\.ident), ["I27"])
    }

    func testRnavPlatePrefersTheGpsCodedApproach() {
        let candidates = [(ident: "R04L", name: "RNAV (GPS) RWY 04L", runway: "04L"),
                          (ident: "I04L", name: "ILS RWY 04L", runway: "04L")]
        let m = ApproachActivation.matchPlate(plateName: "RNAV (GPS) RWY 04L", runway: "04L",
                                              candidates: candidates)
        XCTAssertEqual(m.first?.ident, "R04L", "the RNAV/GPS plate must rank its own coded approach first")
    }

    func testAPlateWithNoRunwayStillReturnsCandidates() {
        // e.g. "VOR-A" circling approaches carry no runway in the title.
        let candidates = [(ident: "VORA", name: "VOR-A", runway: ""),
                          (ident: "I04R", name: "ILS RWY 04R", runway: "04R")]
        let m = ApproachActivation.matchPlate(plateName: "VOR-A", runway: nil, candidates: candidates)
        XCTAssertEqual(m.first?.ident, "VORA", "the VOR plate must rank the VOR approach first")
    }

    func testNoCandidatesYieldsNoMatchRatherThanACrash() {
        XCTAssertTrue(ApproachActivation.matchPlate(plateName: "ILS RWY 04R", runway: "04R",
                                                    candidates: []).isEmpty)
    }
}

/// The route amendments behind activating an approach. These pin a sequence a pilot actually hit at
/// KTCS: activate the RNAV via DUCAS, re-activate via TCS, then go missed.
final class ApproachRouteAmendmentTests: XCTestCase {

    private let here = Coord(lat: 33.23, lon: -107.27)   // near KTCS

    /// Activating with NO flight plan must produce a usable DIRECT-TO, not a lone orphan waypoint.
    func testActivatingWithNoFlightPlanGivesADirectTo() {
        var plan = FlightPlan()
        plan.joinApproach(at: "DUCAS", airport: "KTCS", from: here)
        XCTAssertEqual(plan.route, ["DUCAS"], "must fly direct to the chosen IAF")
        XCTAssertEqual(plan.destination, "KTCS", "and still end at the field, not at the IAF")
        XCTAssertFalse(plan.departure.isEmpty, "direct-to must anchor at present position")
    }

    /// THE reported bug: re-activating stacked the old IAF in front of the new one, so the strip read
    /// "DUCAS then LAYEN" instead of a direct TCS.
    func testReactivatingReplacesTheIAFInsteadOfAccumulating() {
        var plan = FlightPlan()
        plan.joinApproach(at: "DUCAS", airport: "KTCS", from: here)
        plan.joinApproach(at: "TCS", airport: "KTCS", from: here)
        XCTAssertEqual(plan.route, ["TCS"], "the previous IAF must be replaced, not prepended")
        XCTAssertFalse(plan.route.contains("DUCAS"))
    }

    /// VECTORS leaves the filed route alone — ATC is turning you onto final.
    func testVectorsLeavesTheFiledRouteIntact() {
        var plan = FlightPlan()
        plan.departure = "KABQ"; plan.route = ["SANTI", "CHILI"]; plan.destination = "KTCS"
        plan.joinApproach(at: nil, airport: "KTCS", from: here)
        XCTAssertEqual(plan.route, ["SANTI", "CHILI"], "vectors must not rewrite the enroute route")
        XCTAssertEqual(plan.destination, "KTCS")
    }

    func testVectorsFillsAMissingDestination() {
        var plan = FlightPlan()
        plan.joinApproach(at: nil, airport: "KTCS", from: here)
        XCTAssertEqual(plan.destination, "KTCS")
    }

    /// THE other reported bug: after going missed the plan still routed through DUCAS — the abandoned
    /// approach was still loaded, so its transition kept drawing.
    func testMissedApproachDropsTheAbandonedApproachAndItsLeftovers() {
        var plan = FlightPlan()
        plan.joinApproach(at: "DUCAS", airport: "KTCS", from: here)
        plan.loadProcedure(LoadedProcedure(airport: "KTCS", kind: "IAP", ident: "RNV-A",
                                           name: "RNAV-A", runway: "", transition: "DUCAS",
                                           fixes: ["DUCAS", "HEMAT", "LAYEN"]))
        XCTAssertNotNil(plan.approachProcedure)

        // KTCS RNV-A's coded missed is a climb direct LAYEN, then hold at LAYEN.
        plan.flyMissedApproach(fixes: ["LAYEN"], from: here)
        XCTAssertEqual(plan.destination, "LAYEN", "the missed ends at its published hold")
        XCTAssertTrue(plan.route.isEmpty, "a single-fix missed is a plain direct-to")
        XCTAssertFalse(plan.route.contains("DUCAS"), "the abandoned approach's fix must be gone")
        XCTAssertNil(plan.approachProcedure, "going missed unloads the approach being abandoned")
    }

    /// A multi-fix missed flies the whole sequence and still ends at the hold.
    func testMultiFixMissedFliesTheWholeSequence() {
        var plan = FlightPlan()
        plan.flyMissedApproach(fixes: ["WAXEN", "BOSOX", "HOLDX"], from: here)
        XCTAssertEqual(plan.route, ["WAXEN", "BOSOX"])
        XCTAssertEqual(plan.destination, "HOLDX")
    }

    /// With no coded missed the plan must be left untouched — never invent a go-around.
    func testNoCodedMissedLeavesThePlanAlone() {
        var plan = FlightPlan()
        plan.departure = "KABQ"; plan.route = ["SANTI"]; plan.destination = "KTCS"
        plan.flyMissedApproach(fixes: [], from: here)
        XCTAssertEqual(plan.route, ["SANTI"])
        XCTAssertEqual(plan.destination, "KTCS")
    }
}
