import XCTest
@testable import ATCTranscribe

/// Phase-4 ATC command interpreter. The parser is deterministic + pure, so these pin every clearance
/// shape it acts on, the ownship gate, and — most importantly — the NEGATIVE / safety cases where it
/// must abstain (non-fix direct-to, un-grounded fix, non-clearance chatter, no ownship).
final class ATCCommandParserTests: XCTestCase {

    private let bosFixes: Set<String> = ["BOSOX", "CRLTN", "REVER", "MILIS"]

    // MARK: ownship gate

    func testOwnshipMatchesSpokenOrKeyForm() {
        XCTAssertTrue(ATCCommandParser.addressesOwnship(subject: "American 1234", subjectKey: "AAL1234", own: "American 1234"))
        XCTAssertTrue(ATCCommandParser.addressesOwnship(subject: "American 1234", subjectKey: "AAL1234", own: "aal 1234"))
        XCTAssertTrue(ATCCommandParser.addressesOwnship(subject: "November 3 4 5 alpha bravo", subjectKey: "N345AB", own: "N345AB"))
    }

    func testOwnshipRejectsOtherAircraftAndEmptyOwn() {
        XCTAssertFalse(ATCCommandParser.addressesOwnship(subject: "Delta 890", subjectKey: "DAL890", own: "American 1234"))
        XCTAssertFalse(ATCCommandParser.addressesOwnship(subject: "American 1234", subjectKey: "AAL1234", own: ""),
                       "no ownship set → never act (safety default)")
        XCTAssertFalse(ATCCommandParser.addressesOwnship(subject: nil, subjectKey: nil, own: "AAL1234"),
                       "transmission names no aircraft → no match")
    }

    // MARK: direct-to

    func testParsesGroundedDirectTo() {
        let cmd = ATCCommandParser.parse("american 1 2 3 4 cleared direct bosox", knownFixes: bosFixes)
        XCTAssertEqual(cmd, ATCCommand(kind: .directTo, target: "BOSOX", qualifier: ""))
    }

    func testDirectToAbstainsWhenFixNotGrounded() {
        // the token after "direct" is not one of the airport's real fixes → abstain (never route to it).
        XCTAssertNil(ATCCommandParser.parse("cleared direct zzzzz", knownFixes: bosFixes))
        XCTAssertNil(ATCCommandParser.parse("cleared direct bosox", knownFixes: []),
                     "no grounding set → no direct-to")
    }

    func testDirectToAbstainsWithoutAFix() {
        XCTAssertNil(ATCCommandParser.parse("cleared direct", knownFixes: bosFixes))
        XCTAssertNil(ATCCommandParser.parse("proceed direct the airport", knownFixes: bosFixes),
                     "'the' is not fix-shaped / not grounded")
    }

    // MARK: cleared approach

    func testParsesClearedApproachWithRunway() {
        XCTAssertEqual(ATCCommandParser.parse("cleared ils runway 4 right", knownFixes: bosFixes),
                       ATCCommand(kind: .clearedApproach, target: "04R", qualifier: "ILS"))
        XCTAssertEqual(ATCCommandParser.parse("cleared rnav runway 3 3 left", knownFixes: bosFixes),
                       ATCCommand(kind: .clearedApproach, target: "33L", qualifier: "RNAV"))
        XCTAssertEqual(ATCCommandParser.parse("november 5 cleared visual runway 2 2", knownFixes: []),
                       ATCCommand(kind: .clearedApproach, target: "22", qualifier: "visual"))
    }

    func testApproachNeedsClearedAnchor() {
        // a plain mention of an approach without a "cleared" anchor must not fire.
        XCTAssertNil(ATCCommandParser.parse("expect the ils runway 4 right", knownFixes: bosFixes))
    }

    func testApproachRejectsImpossibleRunway() {
        XCTAssertNil(ATCCommandParser.parse("cleared ils runway 4 1", knownFixes: bosFixes), "41 is not a runway")
    }

    // MARK: false-fire guards found by the adversarial review (anticipation / denial / negation)

    func testDirectToAbstainsOnAnticipatoryOrDenied() {
        // "expect direct" is a FUTURE routing, "unable/no longer direct" are denials — none are clearances.
        XCTAssertNil(ATCCommandParser.parse("expect direct bosox after the fix", knownFixes: bosFixes))
        XCTAssertNil(ATCCommandParser.parse("unable direct bosox", knownFixes: bosFixes))
        XCTAssertNil(ATCCommandParser.parse("no longer direct bosox", knownFixes: bosFixes))
        // a terse "N345 direct BOSOX" with no clearance verb also abstains — a miss is safer than a
        // false direct-to.
        XCTAssertNil(ATCCommandParser.parse("november 3 4 5 direct bosox", knownFixes: bosFixes))
    }

    func testDirectToStillFiresOnAProceedClearance() {
        XCTAssertEqual(ATCCommandParser.parse("proceed direct crltn", knownFixes: bosFixes),
                       ATCCommand(kind: .directTo, target: "CRLTN", qualifier: ""))
    }

    func testApproachAbstainsWhenNegatedOrMerelyExpected() {
        XCTAssertNil(ATCCommandParser.parse("not cleared for the ils runway 4", knownFixes: bosFixes))
        XCTAssertNil(ATCCommandParser.parse("cleared as filed maintain 3 0 0 0 expect the ils runway 4", knownFixes: bosFixes),
                     "a stale earlier 'cleared' must not anchor a later 'expect the ils'")
        XCTAssertNil(ATCCommandParser.parse("cleared to land runway 4", knownFixes: bosFixes))
        XCTAssertNil(ATCCommandParser.parse("cleared for takeoff runway 4", knownFixes: bosFixes))
    }

    func testApproachFiresThroughForTheFiller() {
        XCTAssertEqual(ATCCommandParser.parse("cleared for the ils runway 4 left", knownFixes: bosFixes),
                       ATCCommand(kind: .clearedApproach, target: "04L", qualifier: "ILS"))
    }

    // MARK: non-clearance chatter must never produce a command

    func testNonActionableTransmissionsAbstain() {
        XCTAssertNil(ATCCommandParser.parse("descend and maintain 3 thousand", knownFixes: bosFixes))
        XCTAssertNil(ATCCommandParser.parse("turn left heading 2 7 0", knownFixes: bosFixes))
        XCTAssertNil(ATCCommandParser.parse("contact tower 1 1 9 point 5", knownFixes: bosFixes))
        XCTAssertNil(ATCCommandParser.parse("", knownFixes: bosFixes))
        XCTAssertNil(ATCCommandParser.parse("wind 2 7 0 at 1 0", knownFixes: bosFixes))
    }

    // MARK: EFBSuggestion model

    func testSuggestionTitleAndMake() {
        let direct = ATCCommand(kind: .directTo, target: "BOSOX", qualifier: "")
        XCTAssertEqual(EFBSuggestion.title(for: direct), "Fly direct BOSOX")
        let appr = ATCCommand(kind: .clearedApproach, target: "04R", qualifier: "ILS")
        XCTAssertEqual(EFBSuggestion.title(for: appr), "Load ILS runway 04R")

        XCTAssertNotNil(EFBSuggestion.make(id: "r1", command: direct, source: "cleared direct bosox"))
        XCTAssertNil(EFBSuggestion.make(id: "", command: direct, source: "x"), "empty id → nil")
        XCTAssertNil(EFBSuggestion.make(id: "r1", command: ATCCommand(kind: .directTo, target: "", qualifier: ""), source: "x"),
                     "empty target → nil")
    }
}
