import XCTest
@testable import ATCTranscribe

/// Item 2/3: matching a departure or arrival PLATE to its coded procedure.
///
/// The measurement that motivated every case here is in `TerminalChartMatch`: a plain substring match
/// found 0 of 6,015 bundled terminal charts, because the chart spells the revision and the ident digits
/// it.
final class TerminalChartMatchTests: XCTestCase {

    /// ⚠️ THE WHOLE BUG, in one assertion. This is what the shipped code did.
    func testTheChartSpellsTheRevisionAndTheIdentDigitsIt() {
        XCTAssertFalse("LUCIT THREE (RNAV)".contains("LUCIT3"), "the substring match this replaces")
        XCTAssertEqual(TerminalChartMatch.match(plateName: "LUCIT THREE (RNAV)",
                                                idents: ["LUCIT3"]), "LUCIT3")
    }

    func testTheIdentSplitsIntoBaseAndRevision() {
        let s = TerminalChartMatch.split(ident: "LUCIT3")
        XCTAssertEqual(s?.base, "LUCIT")
        XCTAssertEqual(s?.revision, 3)
        XCTAssertEqual(TerminalChartMatch.split(ident: "MINES1")?.revision, 1)
        XCTAssertNil(TerminalChartMatch.split(ident: "NODIGIT"))
    }

    /// Continuation sheets and qualifiers ride along in the title and must not defeat the match.
    func testQualifiersAndContinuationSheetsStillMatch() {
        for title in ["LUCIT THREE (RNAV)", "LUCIT THREE (RNAV), CONT.1",
                      "LUCIT THREE (OBSTACLE) (RNAV)"] {
            XCTAssertEqual(TerminalChartMatch.match(plateName: title, idents: ["LUCIT3", "PANGG7"]),
                           "LUCIT3", title)
        }
    }

    /// The revision is what separates two charts of the same procedure, so it must not be ignored.
    func testADifferentRevisionIsADifferentChart() {
        XCTAssertNil(TerminalChartMatch.match(plateName: "LUCIT THREE (RNAV)", idents: ["LUCIT4"]))
    }

    /// The ident often CONTRACTS the charted name. Accepted only when the revision agrees and exactly
    /// one candidate qualifies — measured to add 290 charts with 0 ambiguity.
    func testAContractedIdentMatchesOnTheRevision() {
        XCTAssertEqual(TerminalChartMatch.match(plateName: "GARLAND SIX",
                                                idents: ["BOTCH2", "GARL6", "JPOOL8", "KING5"]), "GARL6")
        XCTAssertEqual(TerminalChartMatch.match(plateName: "PRINCETON ONE", idents: ["PRINC1"]), "PRINC1")
    }

    /// ⚠️ AMBIGUITY RETURNS NOTHING. Drawing a different departure than the one on the screen is worse
    /// than drawing none, and the Vector button is hidden when this is nil.
    func testAnAmbiguousTitleMatchesNothing() {
        XCTAssertNil(TerminalChartMatch.match(plateName: "GARLAND SIX", idents: ["GARL6", "GARLA6"]))
    }

    /// The 11% the rule deliberately cannot reach: the title names a place the ident contracts to a
    /// navaid. No guess is made.
    func testANavaidContractionIsRefusedRatherThanGuessed() {
        XCTAssertNil(TerminalChartMatch.match(plateName: "MELBOURNE THREE",
                                              idents: ["CLMNT3", "CPTAN4", "MLB3", "STOOP4"]))
        XCTAssertNil(TerminalChartMatch.match(plateName: "WILKES-BARRE FIVE", idents: ["LVZ5"]))
    }

    func testThePlateRevisionIsRead() {
        XCTAssertEqual(TerminalChartMatch.revision(inPlate: "JOE POOL EIGHT"), 8)
        XCTAssertNil(TerminalChartMatch.revision(inPlate: "NO NUMBER HERE"))
    }
}
