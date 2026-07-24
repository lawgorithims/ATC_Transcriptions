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
