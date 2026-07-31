import XCTest
@testable import ATCTranscribe

/// Changing HOW an active approach is joined, and what each published transition commits you to.
///
/// The centre of gravity here is the course reversal, because it is the one thing the choice actually
/// decides: 6,243 approaches publish one and 4,106 of those publish it on only SOME of their
/// transitions. Getting it wrong in the reassuring direction — saying "no course reversal" about a
/// procedure that prints one — is the failure these tests exist to prevent.
final class ApproachEntryOptionsTests: XCTestCase {

    private func leg(_ seq: Int, _ fix: String, _ type: String, role: String = " ",
                     turn: String = "", course: Double? = nil, coord: Coord? = Coord(lat: 42, lon: -71)) -> CIFPLeg {
        CIFPLeg(seq: seq, fix: fix, coord: coord, legType: type, course: course, altitude: "",
                wpDesc: "   \(role)", turnDirection: turn)
    }

    // MARK: - the two codings of a course reversal

    func testHoldInLieuIsRead() {
        let r = ApproachActivation.reversal(legs: [leg(10, "GOSHI", "IF", role: "A"),
                                                   leg(20, "WINNI", "HF")])
        XCTAssertEqual(r, .holdInLieu(fix: "WINNI"))
        XCTAssertEqual(r.isRequired, true)
    }

    func testProcedureTurnIsRead() {
        // The 848-approach case. `HoldingPattern` models HF/HM/HA only, so before this the app had no
        // representation of a PI at all and would have reported these as having no course reversal.
        let r = ApproachActivation.reversal(legs: [leg(10, "BET", "IF"),
                                                   leg(20, "KAYSE", "TF"),
                                                   leg(30, "KAYSE", "PI", role: "A", turn: "R", course: 327.5)])
        XCTAssertEqual(r, .procedureTurn(fix: "KAYSE", turn: "R", courseMag: 327.5))
        XCTAssertEqual(r.isRequired, true)
        XCTAssertEqual(r.summary, "right procedure turn at KAYSE")
    }

    func testLeftProcedureTurnIsNamedLeft() {
        let r = ApproachActivation.reversal(legs: [leg(10, "ABC", "PI", turn: "L", course: 90)])
        XCTAssertEqual(r.summary, "left procedure turn at ABC")
    }

    func testProcedureTurnWithNoCodedTurnDirectionDoesNotInventOne() {
        // The app has been bitten before by assuming standard-right. If the source publishes no turn,
        // the phrase must not pick a side.
        let r = ApproachActivation.reversal(legs: [leg(10, "ABC", "PI", turn: "", course: 90)])
        XCTAssertEqual(r.summary, "procedure turn at ABC")
    }

    func testATransitionWithNeitherCodingReportsNone() {
        let r = ApproachActivation.reversal(legs: [leg(10, "GOSHI", "IF", role: "A"),
                                                   leg(20, "WINNI", "TF", role: "B")])
        XCTAssertEqual(r, .none)
        XCTAssertEqual(r.summary, "no course reversal")
    }

    func testAnUnreadableTransitionIsUnknownAndSaysNothing() {
        // THE safety property. `.unknown` must never render, because the only honest alternative to
        // "there is a reversal" is silence — not a reassurance the data does not support.
        let r = ApproachActivation.reversal(legs: [])
        XCTAssertEqual(r, .unknown)
        XCTAssertNil(r.summary, "an unreadable transition must render nothing at all")
        XCTAssertNil(r.isRequired, "unknown must not collapse to false")
    }

    func testOptionForATransitionWithNoLegsIsUnknownNotNone() {
        let opt = ApproachActivation.option(entry: .transition("GOSHI"), legs: [])
        XCTAssertEqual(opt.reversal, .unknown)
        XCTAssertNil(opt.initialFix)
    }

    func testVectorsHasNoReversalAsAFactNotAnInference() {
        // Vectors joins the final approach course: there is no transition row to read, and no reversal
        // is a property of the join itself.
        let opt = ApproachActivation.option(entry: .vectors, legs: [])
        XCTAssertEqual(opt.reversal, .none)
        XCTAssertNil(opt.initialFix)
        XCTAssertEqual(opt.legCount, 0)
    }

    // MARK: - which fix the approach actually starts at

    func testInitialFixPrefersTheMarkedIAFOverTheFirstLeg() {
        // KCEV I18 via RID, exactly as coded: the row OPENS at SHB with no role, and the FAA marks the
        // initial approach fix on SQ two legs later.
        let legs = [leg(10, "SHB", "IF"), leg(20, "SQ", "TF"), leg(30, "SQ", "PI", role: "A", turn: "R")]
        XCTAssertEqual(ApproachActivation.initialFix(legs: legs), "SQ")
    }

    func testInitialFixFallsBackToPositionWhenNothingIsMarked() {
        let legs = [leg(10, "SHB", "IF"), leg(20, "SQ", "TF")]
        XCTAssertEqual(ApproachActivation.initialFix(legs: legs), "SHB")
    }

    func testInitialFixSkipsRunwayPseudoFixes() {
        let legs = [leg(10, "RW04R", "IF", role: "A"), leg(20, "CRLTN", "TF", role: "A")]
        XCTAssertEqual(ApproachActivation.initialFix(legs: legs), "CRLTN",
                       "a runway threshold is a leg endpoint, not a fix anyone is cleared to")
    }

    func testInitialFixSkipsLegsWithNoCoordinate() {
        let legs = [leg(10, "VECTR", "CF", role: "A", coord: nil), leg(20, "CRLTN", "TF", role: "A")]
        XCTAssertEqual(ApproachActivation.initialFix(legs: legs), "CRLTN")
    }

    // MARK: - against the shipped cycle

    func testEntryOptionsAlwaysOffersVectors() throws {
        try XCTSkipUnless(CIFP.available, "cifp.sqlite not present")
        let opts = CIFP.entryOptions(airport: "KBOS", ident: "I04R")
        XCTAssertTrue(opts.contains { $0.entry == .vectors },
                      "ATC can always vector to final, so VECTORS is never absent")
    }

    func testPABEProcedureTurnIsReadFromTheRealDatabase() throws {
        try XCTSkipUnless(CIFP.available, "cifp.sqlite not present")
        let opts = CIFP.entryOptions(airport: "PABE", ident: "I19RZ")
        guard let bet = opts.first(where: { $0.label == "BET" }) else {
            return XCTFail("PABE I19R-Z publishes a BET transition")
        }
        XCTAssertEqual(bet.reversal, .procedureTurn(fix: "KAYSE", turn: "R", courseMag: 327.5),
                       "the published procedure turn must be read, not reported as absent")
        XCTAssertEqual(bet.initialFix, "KAYSE")
    }

    func testKCEVInitialFixIsTheMarkedOneNotTheFirstLeg() throws {
        try XCTSkipUnless(CIFP.available, "cifp.sqlite not present")
        let opts = CIFP.entryOptions(airport: "KCEV", ident: "I18")
        guard let rid = opts.first(where: { $0.label == "RID" }) else {
            return XCTFail("KCEV I18 publishes a RID transition")
        }
        XCTAssertEqual(rid.initialFix, "SQ", "the row opens at SHB; the marked IAF is SQ")
    }

    func testNoTransitionInTheWholeCycleIsReportedAsUnknownWhenItHasLegs() throws {
        try XCTSkipUnless(CIFP.available, "cifp.sqlite not present")
        // A spot check across a spread of fields: every published transition should read as something
        // definite, because they all have coded legs. `.unknown` here would mean the reader is broken.
        for (apt, ident) in [("KBOS", "I04R"), ("KDEN", "I16R"), ("PABE", "I19RZ"), ("KCEV", "I18")] {
            for opt in CIFP.entryOptions(airport: apt, ident: ident) where opt.entry != .vectors {
                XCTAssertNotEqual(opt.reversal, .unknown, "\(apt) \(ident) via \(opt.label) read as unknown")
            }
        }
    }

    func testEveryOptionIsUniquelyIdentified() throws {
        try XCTSkipUnless(CIFP.available, "cifp.sqlite not present")
        // The chooser is a ForEach over these; a duplicate id would silently drop a way onto the approach.
        let opts = CIFP.entryOptions(airport: "PAOM", ident: "I28Z")   // the most transitions in the country
        XCTAssertEqual(Set(opts.map(\.id)).count, opts.count)
    }
}
