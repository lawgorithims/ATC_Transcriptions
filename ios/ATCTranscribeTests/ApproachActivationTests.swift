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
        XCTAssertEqual(LegRole(wpDesc: "EE  "), .none)
        XCTAssertEqual(LegRole(wpDesc: ""), .none, "a short/absent code is not a defect")
    }

    /// `I` and `B` are the pair it is easiest to transpose, and the coded data settles it: at KBOS
    /// H33LX the fix CRLTN is `B` on the last leg of every transition and `I` on the first leg of the
    /// approach proper — the intermediate fix seen from either side of the join.
    func testFinalApproachCourseFixAndIntermediateFixAreNotTransposed() {
        XCTAssertEqual(LegRole(wpDesc: "E  I"), .finalApproachCourseFix)
        XCTAssertEqual(LegRole(wpDesc: "EE B"), .intermediateFix)
        XCTAssertNotEqual(LegRole(wpDesc: "E  I"), .intermediateFix)
    }

    // MARK: runway pseudo-fixes vs real navaids

    /// `RW` + two digits is a runway threshold; `RW` as a bare prefix is three real navaids. Testing the
    /// prefix deleted RWF (Redwood Falls VOR), RWO (Kodiak) and the waypoint RWLND from routes, from the
    /// map's fix layer and from the spoken-fix vocabulary — and blanked KOVL VOR-A's whole coded missed
    /// approach, which is flown to RWF.
    func testRunwayPseudoFixTestMatchesShapeNotPrefix() {
        for threshold in ["RW04", "RW33L", "RW09C", "RW27R", "rw04"] {
            XCTAssertTrue(CIFP.isRunwayPseudoFix(threshold), "\(threshold) is a runway threshold")
        }
        for navaid in ["RWF", "RWO", "RWLND", "RW", "RWABC", "R04"] {
            XCTAssertFalse(CIFP.isRunwayPseudoFix(navaid), "\(navaid) is not a runway threshold")
        }
    }

    // MARK: the missed sequence as flown

    /// The hold's inbound `DF` and its `HM` leg name the same fix — one hold, not two waypoints.
    func testConsecutiveRepeatsCollapseSoTheHoldIsNamedOnce() {
        XCTAssertEqual(ApproachActivation.missedSequence(["", "WAXEN", "WAXEN"]), ["WAXEN"])
    }

    /// PADK I23-Y: the published missed is ADK, COMAT, ADK, hold at ADK. Removing every repeat left
    /// COMAT last, so the go-around ended somewhere the plate never sends it.
    func testAMissedThatReturnsToAnEarlierFixStillEndsAtItsPublishedHold() {
        let seq = ApproachActivation.missedSequence(["ADK", "COMAT", "ADK", "ADK"])
        XCTAssertEqual(seq, ["ADK", "COMAT", "ADK"])
        XCTAssertEqual(seq.last, "ADK", "the published hold must be the last fix flown")
    }

    /// KBAM S04 — the same shape, two fixes deep.
    func testMissedRevisitingAFixTwiceKeepsThePublishedHoldLast() {
        XCTAssertEqual(ApproachActivation.missedSequence(["RITYO", "BAM", "FESUD", "BAM", "BAM"]),
                       ["RITYO", "BAM", "FESUD", "BAM"])
    }

    /// KOVL VOR-A's missed is a fix-less climb then RWF, the Redwood Falls VOR. The old `RW` prefix test
    /// ate it and reported the approach as having no coded missed at all.
    func testARealNavaidStartingWithRWSurvivesTheMissedSequence() {
        XCTAssertEqual(ApproachActivation.missedSequence(["", "RWF", "RWF"]), ["RWF"])
    }

    func testRunwayThresholdsAreStillDroppedFromTheMissedSequence() {
        XCTAssertEqual(ApproachActivation.missedSequence(["RW33L", "WAXEN"]), ["WAXEN"])
    }

    func testAnEntirelyFixlessMissedYieldsNothingRatherThanAnInventedPath() {
        XCTAssertTrue(ApproachActivation.missedSequence(["", "", ""]).isEmpty)
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

    /// A candidate sharing no approach-type token with the plate is not a match, it is the only thing
    /// left at that airport. Returning it looked exactly like a confident single match, and the sheet
    /// hides its approach chooser at a count of one — so 12N's "VOR-A" plate silently armed R03, an
    /// RNAV approach to a runway the plate never names.
    func testALoneUnrelatedCandidateIsNotOfferedAsAMatch() {
        let m = ApproachActivation.matchPlate(plateName: "VOR-A", runway: nil,
                                              candidates: [(ident: "R03", name: "RNAV (GPS) RWY 03", runway: "03")])
        XCTAssertTrue(m.isEmpty, "a zero-score lone candidate must not present as a confident match")
    }

    /// When several unrelated candidates tie at zero they are still offered — the chooser stays visible,
    /// so the pilot picks rather than the app guessing.
    func testSeveralUnscoredCandidatesAreStillOfferedForTheChooser() {
        let m = ApproachActivation.matchPlate(plateName: "VOR-A", runway: nil,
                                              candidates: [(ident: "R03", name: "RNAV (GPS) RWY 03", runway: "03"),
                                                           (ident: "R21", name: "RNAV (GPS) RWY 21", runway: "21")])
        XCTAssertEqual(m.count, 2, "an ambiguous set is a choice to present, not a match to make")
    }

    /// A scoring candidate must suppress the noise entirely, so the chooser is not padded with
    /// approaches the plate has nothing to do with.
    func testScoringCandidatesSuppressTheUnscoredOnes() {
        let m = ApproachActivation.matchPlate(plateName: "ILS RWY 04R", runway: nil,
                                              candidates: [(ident: "I04R", name: "ILS RWY 04R", runway: "04R"),
                                                           (ident: "R21", name: "RNAV (GPS) RWY 21", runway: "21")])
        XCTAssertEqual(m.map(\.ident), ["I04R"])
    }

    /// A circling plate and the straight-in of the same type score identically on type tokens alone, so
    /// the circling approach lost the ident tiebreak and ranked second in its own chooser. KCGE codes
    /// R34 and RNV-A; the "RNAV (GPS)-A" plate is the circling one.
    func testACirclingPlateRanksItsOwnCirclingApproachFirst() {
        let candidates = [(ident: "R34",   name: "RNAV (GPS) RWY 34", runway: "34"),
                          (ident: "RNV-A", name: "RNAV (GPS)-A",      runway: "")]
        let m = ApproachActivation.matchPlate(plateName: "RNAV (GPS)-A", runway: nil, candidates: candidates)
        XCTAssertEqual(m.first?.ident, "RNV-A")
        XCTAssertEqual(m.count, 2, "the straight-in stays available, just not first")
    }

    /// Two circling approaches at the same field are told apart only by their letter.
    func testCirclingApproachesAreSeparatedByTheirLetter() {
        let candidates = [(ident: "RNV-A", name: "RNAV (GPS)-A", runway: ""),
                          (ident: "RNV-B", name: "RNAV (GPS)-B", runway: "")]
        XCTAssertEqual(ApproachActivation.matchPlate(plateName: "RNAV (GPS)-B", runway: nil,
                                                     candidates: candidates).first?.ident, "RNV-B")
    }

    func testCirclingLetterIsNotReadOffAStraightInTitle() {
        XCTAssertNil(ApproachActivation.circlingLetter("RNAV (GPS) Y RWY 12"),
                     "the Y distinguishes duplicate straight-ins; it is not a circling letter")
        XCTAssertNil(ApproachActivation.circlingLetter("ILS OR LOC RWY 04R"))
        XCTAssertEqual(ApproachActivation.circlingLetter("VOR/DME-B"), "B")
        XCTAssertEqual(ApproachActivation.circlingLetter("RNAV (GPS)-A"), "A")
    }

    /// The RNP-AR-vs-GPS distinction the approach-type table now gets right: an "RNAV (GPS)" plate must
    /// not rank an RNP AR approach — those require specific operator and aircrew authorization.
    func testRnavGpsPlateDoesNotRankTheRnpApproachFirst() {
        let candidates = [(ident: "H22LY", name: "RNAV (RNP) Y RWY 22L", runway: "22L"),
                          (ident: "R22LZ", name: "RNAV (GPS) Z RWY 22L", runway: "22L")]
        let m = ApproachActivation.matchPlate(plateName: "RNAV (GPS) Z RWY 22L", runway: "22L",
                                              candidates: candidates)
        XCTAssertEqual(m.first?.ident, "R22LZ", "the GPS plate must rank the GPS approach, not the RNP AR one")
    }

    /// The mirror case, which the deleted "+1 charted RNAV (GPS)" bonus used to get backwards: an RNP AR
    /// plate ranked the ordinary GPS approach first on 408 plates nationwide.
    func testRnpPlateRanksTheRnpApproachFirst() {
        let candidates = [(ident: "H22LX", name: "RNAV (RNP) X RWY 22L", runway: "22L"),
                          (ident: "R22LZ", name: "RNAV (GPS) Z RWY 22L", runway: "22L")]
        let m = ApproachActivation.matchPlate(plateName: "RNAV (RNP) X RWY 22L", runway: "22L",
                                              candidates: candidates)
        XCTAssertEqual(m.first?.ident, "H22LX")
    }

    /// Y and Z to the same runway are different procedures with different missed approaches.
    func testTheMultipleIndicatorPicksTheRightProcedure() {
        let candidates = [(ident: "R19RY", name: "RNAV (GPS) Y RWY 19R", runway: "19R"),
                          (ident: "R19RZ", name: "RNAV (GPS) Z RWY 19R", runway: "19R")]
        XCTAssertEqual(ApproachActivation.matchPlate(plateName: "RNAV (GPS) Z RWY 19R", runway: "19R",
                                                     candidates: candidates).first?.ident, "R19RZ")
        XCTAssertEqual(ApproachActivation.matchPlate(plateName: "RNAV (GPS) Y RWY 19R", runway: "19R",
                                                     candidates: candidates).first?.ident, "R19RY")
    }

    /// When the plate's own letter is not coded at all, offering a DIFFERENT lettered procedure as the
    /// lone confident match let the sheet arm it with no chooser — KLGA's "RNAV (GPS) Y RWY 13" plate
    /// silently armed the Z procedure. A letter disagreement disqualifies.
    func testAWrongLetteredApproachIsNeverTheLoneMatch() {
        let candidates = [(ident: "R13-Z", name: "RNAV (GPS) Z RWY 13", runway: "13")]
        XCTAssertTrue(ApproachActivation.matchPlate(plateName: "RNAV (GPS) Y RWY 13", runway: "13",
                                                    candidates: candidates).isEmpty)
    }

    /// But an unlettered candidate is NOT a disagreement — "ILS Z OR LOC RWY 17" really does cover the
    /// unlettered localizer, and the plate letter is not always adjacent to RWY.
    func testAnUnletteredCandidateStillMatchesALetteredPlate() {
        let candidates = [(ident: "I17-Z", name: "ILS Z RWY 17", runway: "17"),
                          (ident: "L17",   name: "LOC RWY 17",   runway: "17")]
        let m = ApproachActivation.matchPlate(plateName: "ILS Z OR LOC RWY 17", runway: "17",
                                              candidates: candidates)
        XCTAssertEqual(m.map(\.ident), ["I17-Z", "L17"])
    }

    /// The letter bonus must only RANK candidates that already agree on type — never qualify one. It was
    /// worth +3, which on its own cleared the confidence bar, so KROA's "LDA Z RWY 06" plate came back as
    /// a single candidate (the RNP AR H06-Z, letter Z) and the sheet armed it with no chooser shown.
    func testAMatchingLetterCannotQualifyAWrongTypeApproach() {
        let candidates = [(ident: "H06-Z", name: "RNAV (RNP) Z RWY 06", runway: "06"),
                          (ident: "R06-Y", name: "RNAV (GPS) Y RWY 06", runway: "06"),
                          (ident: "X06-Y", name: "LDA Y RWY 06",        runway: "06")]
        let m = ApproachActivation.matchPlate(plateName: "LDA Z RWY 06", runway: "06", candidates: candidates)
        XCTAssertNotEqual(m.count, 1, "a lone wrong-type candidate would be armed with no chooser")
        XCTAssertNotEqual(m.first?.ident, "H06-Z", "an RNP AR approach must not top an LDA plate")
    }

    /// ATC says "cleared for the RNAV approach" — never "GPS", never "RNP" — so an unqualified RNAV
    /// clearance must load the ordinary approach, not the AR one that needs special authorization. The
    /// ident tiebreak sorts H before R, so without this the AR procedure won at 374 airport/runways.
    func testASpokenRnavClearanceLoadsTheGpsApproachNotTheRnpAr() {
        let candidates = [(ident: "H10-Z", name: "RNAV (RNP) Z RWY 10", runway: "10"),
                          (ident: "R10-Y", name: "RNAV (GPS) Y RWY 10", runway: "10")]
        // Exactly what loadApproachForRunway passes: the parser's qualifier, with an empty rawTranscript.
        let m = ApproachActivation.matchPlate(plateName: "RNAV ", runway: nil, candidates: candidates)
        XCTAssertEqual(m.first?.ident, "R10-Y")
    }

    /// But a plate that really does say RNP still gets it.
    func testAnExplicitRnpPlateStillRanksTheRnpApproach() {
        let candidates = [(ident: "H10-Z", name: "RNAV (RNP) Z RWY 10", runway: "10"),
                          (ident: "R10-Z", name: "RNAV (GPS) Z RWY 10", runway: "10")]
        XCTAssertEqual(ApproachActivation.matchPlate(plateName: "RNAV (RNP) Z RWY 10", runway: "10",
                                                     candidates: candidates).first?.ident, "H10-Z")
    }

    func testMultipleIndicatorReadsOnlyStandaloneLetters() {
        XCTAssertEqual(ApproachActivation.multipleIndicator("RNAV (GPS) Z RWY 22"), "Z")
        XCTAssertEqual(ApproachActivation.multipleIndicator("ILS Y OR LOC Y RWY 04"), "Y")
        XCTAssertEqual(ApproachActivation.multipleIndicator("VOR Z OR TACAN RWY 20"), "Z")
        XCTAssertNil(ApproachActivation.multipleIndicator("RNAV (GPS) RWY 22R"),
                     "the trailing R is a runway side, not a multiple indicator")
        XCTAssertNil(ApproachActivation.multipleIndicator("ILS RWY 20R (SA CAT I)"))
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

    /// Diverting: activating an approach with vectors must repoint the plan at the field that approach
    /// belongs to. Only filling an EMPTY destination left the plan aimed at the original one, which the
    /// next route edit read as a mismatch and used to silently drop the approach.
    func testVectorsAtADiversionAirportRepointsTheDestination() {
        var plan = FlightPlan()
        plan.departure = "KAUS"; plan.destination = "KDFW"
        plan.joinApproach(at: nil, airport: "KACT", from: here)
        XCTAssertEqual(plan.destination, "KACT", "the plan must end at the airport being approached")
        XCTAssertEqual(plan.departure, "KAUS", "vectors must not disturb the rest of the plan")
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

    // MARK: ⚠️ the plate's OWN runway — measured at 4,705 of 9,535 charts wrong before this

    private func cands(_ xs: [(String, String, String)]) -> [(ident: String, name: String, runway: String)] {
        xs.map { (ident: $0.0, name: $0.1, runway: $0.2) }
    }

    /// The defect, in one case: nothing scored the runway, so same-type approaches tied and the
    /// `ident <` tiebreak picked the RECIPROCAL. Measured over every bundled straight-in chart with a
    /// coded approach: 4,705 of 9,535 (49.3%) resolved to a different runway. Now 0.
    func testThePlatesOwnRunwayDecidesTheMatch() {
        let c = cands([("R08", "RNAV (GPS) RWY 08", "08"), ("R26", "RNAV (GPS) RWY 26", "26")])
        let r = ApproachActivation.matchPlate(plateName: "RNAV (GPS) RWY 26", runway: nil, candidates: c)
        XCTAssertEqual(r.first?.ident, "R26", "the plate names 26; 08 is the reciprocal, not the approach")
        XCTAssertEqual(r.count, 1, "the other runway must not even be offered")
    }

    /// ⚠️ THE PADDING IS DIFFERENT ON THE TWO SIDES. CIFP codes "RW04R"/"04", plate titles print
    /// "RWY 04R", and some print "RWY 4" — a raw string compare fails to match rather than matching
    /// wrongly, which is equally useless.
    func testRunwayPaddingDoesNotDefeatTheMatch() {
        XCTAssertEqual(ApproachActivation.normalizedRunway("RW04R"), "4R")
        XCTAssertEqual(ApproachActivation.normalizedRunway("04"), "4")
        XCTAssertEqual(ApproachActivation.normalizedRunway("4"), "4")
        XCTAssertEqual(ApproachActivation.plateRunway("ILS OR LOC RWY 04R"), "4R")
        XCTAssertEqual(ApproachActivation.plateRunway("VOR RWY 4"), "4")
        let c = cands([("I04R", "ILS RWY 04R", "RW04R")])
        XCTAssertEqual(ApproachActivation.matchPlate(plateName: "ILS OR LOC RWY 4R",
                                                     runway: nil, candidates: c).first?.ident, "I04R")
    }

    /// A parallel pair is the case that actually reaches a pilot: 04L and 04R are different approaches
    /// with different minima and different Baro-VNAV limits. Reproduced on the iPad before the fix —
    /// KBOS's 04R plate rendered 04L's −14 °C limit.
    func testParallelRunwaysAreNotInterchangeable() {
        let c = cands([("R04L", "RNAV (GPS) RWY 04L", "04L"), ("R04R", "RNAV (GPS) RWY 04R", "04R")])
        XCTAssertEqual(ApproachActivation.matchPlate(plateName: "RNAV (GPS) RWY 04R",
                                                     runway: nil, candidates: c).first?.ident, "R04R")
        XCTAssertEqual(ApproachActivation.matchPlate(plateName: "RNAV (GPS) RWY 04L",
                                                     runway: nil, candidates: c).first?.ident, "R04L")
    }

    /// A CIRCLING plate names a letter, not a runway, and must keep matching every candidate — the new
    /// filter must not silently disqualify the approaches it is meant to rank.
    func testACirclingPlateStillMatches() {
        XCTAssertNil(ApproachActivation.plateRunway("VOR-A"))
        let c = cands([("V-A", "VOR-A", ""), ("R08", "RNAV (GPS) RWY 08", "08")])
        XCTAssertEqual(ApproachActivation.matchPlate(plateName: "VOR-A", runway: nil,
                                                     candidates: c).first?.ident, "V-A")
    }

    /// When the caller's runway and the plate's disagree, the plate is not that approach's plate.
    /// Nothing is the right answer; a "confident" wrong one is what shipped.
    func testCallerAndPlateDisagreementYieldsNothing() {
        let c = cands([("R22", "RNAV (GPS) RWY 22", "22")])
        XCTAssertTrue(ApproachActivation.matchPlate(plateName: "RNAV (GPS) RWY 04",
                                                    runway: "22", candidates: c).isEmpty)
    }
}
