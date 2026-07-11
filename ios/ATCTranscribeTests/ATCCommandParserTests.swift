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

    // MARK: multi-aircraft positional binding (Addressee) — the review's HIGH finding

    private let callsignStarts: Set<String> = ["american", "delta", "united", "november", "cessna"]
    private func addr(_ ownTokens: String) -> ATCCommandParser.Addressee {
        ATCCommandParser.Addressee(ownshipTokens: ownTokens.split(separator: " ").map(String.init),
                                   callsignStarts: callsignStarts)
    }

    func testMultiAircraftClearanceForOtherAircraftAbstains() {
        // ownship American 123; the direct-to belongs to American 456 in the SAME transmission → no fire.
        let cmd = ATCCommandParser.parse("american 1 2 3 turn left heading 2 7 0 american 4 5 6 cleared direct bosox",
                                         knownFixes: bosFixes, addressee: addr("american 1 2 3"))
        XCTAssertNil(cmd, "a clearance to the other aircraft must not fire an ownship suggestion")
    }

    func testMultiAircraftClearanceForOwnshipFires() {
        // ownship American 123 is the SECOND aircraft addressed; the direct-to is ours → fires.
        let cmd = ATCCommandParser.parse("american 4 5 6 turn left heading 2 7 0 american 1 2 3 cleared direct bosox",
                                         knownFixes: bosFixes, addressee: addr("american 1 2 3"))
        XCTAssertEqual(cmd, ATCCommand(kind: .directTo, target: "BOSOX", qualifier: ""))
    }

    func testSingleAircraftUnaffectedByAddressee() {
        let cmd = ATCCommandParser.parse("american 1 2 3 cleared direct crltn",
                                         knownFixes: bosFixes, addressee: addr("american 1 2 3"))
        XCTAssertEqual(cmd, ATCCommand(kind: .directTo, target: "CRLTN", qualifier: ""))
    }

    func testMultiAircraftOwnshipNotNamedAbstains() {
        let cmd = ATCCommandParser.parse("delta 8 9 0 turn left united 1 2 cleared direct bosox",
                                         knownFixes: bosFixes, addressee: addr("american 1 2 3"))
        XCTAssertNil(cmd, "two other aircraft, ownship absent → abstain")
    }

    func testOwnshipPrefixDoesNotMatchLongerCallsign() {
        // ownship American 123 must NOT match American 1234's segment.
        let cmd = ATCCommandParser.parse("american 4 5 6 turn left american 1 2 3 4 cleared direct bosox",
                                         knownFixes: bosFixes, addressee: addr("american 1 2 3"))
        XCTAssertNil(cmd, "'american 1 2 3' must not prefix-match 'american 1 2 3 4'")
    }

    func testBoundaryCountAndSegmentHelpers() {
        let toks = "american 1 2 3 turn left american 4 5 6 cleared direct bosox".split(separator: " ").map(String.init)
        XCTAssertEqual(ATCCommandParser.boundaryCount(toks, starts: callsignStarts), 2)
        XCTAssertEqual(ATCCommandParser.subsequenceIndex(toks, ["american", "4", "5", "6"]), 6)
        XCTAssertNil(ATCCommandParser.subsequenceIndex(toks, ["delta", "9"]))
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

    // MARK: Phase 6 — direct-to airport + SID/STAR (grounded, conservative) + broadened approach

    func testDirectToAirportGrounded() {
        let cmd = ATCCommandParser.parse("american 1 2 3 cleared direct kpvd",
                                         grounding: .init(airports: ["KPVD"]))
        XCTAssertEqual(cmd, ATCCommand(kind: .directTo, target: "KPVD", qualifier: "airport"))
    }

    func testDirectToAirportAbstainsWhenNotGrounded() {
        XCTAssertNil(ATCCommandParser.parse("cleared direct kxyz", grounding: .init(airports: ["KPVD"])),
                     "an un-filed airport is not a grounded direct-to target")
    }

    func testSIDLoadFromClimbVia() {
        let cmd = ATCCommandParser.parse("american 1 2 3 climb via the blazzer 6 departure",
                                         grounding: .init(sids: ["BLZZR6"]))
        XCTAssertEqual(cmd, ATCCommand(kind: .loadSID, target: "BLZZR6", qualifier: ""))
    }

    func testSTARLoadFromDescendVia() {
        let cmd = ATCCommandParser.parse("descend via the robuc 3 arrival", grounding: .init(stars: ["ROBUC3"]))
        XCTAssertEqual(cmd, ATCCommand(kind: .loadStar, target: "ROBUC3", qualifier: ""))
    }

    func testProcedureAbstainsOnExpect() {
        XCTAssertNil(ATCCommandParser.parse("expect the blazzer 6 departure", grounding: .init(sids: ["BLZZR6"])),
                     "'expect' is anticipatory → abstain")
    }

    func testProcedureAbstainsOnVersionMismatch() {
        XCTAssertNil(ATCCommandParser.parse("climb via the blazzer 7 departure", grounding: .init(sids: ["BLZZR6"])),
                     "version 7 ≠ ident version 6")
    }

    func testProcedureAbstainsOnGarbledBase() {
        XCTAssertNil(ATCCommandParser.parse("climb via the zzzzz 6 departure", grounding: .init(sids: ["BLZZR6"])),
                     "base consonants don't match the ident")
    }

    func testProcedureAbstainsWhenAmbiguous() {
        // two DISTINCT idents both matching base+version → abstain (a wrong SID load is a real error).
        XCTAssertNil(ATCCommandParser.parse("climb via the blazzer 6 departure",
                                            grounding: .init(sids: ["BLZZR6", "BLZZER6"])))
    }

    func testConsonantSkeletonAndIdentSplit() {
        XCTAssertEqual(ATCCommandParser.consonantSkeleton("Blazzer"), "BLZZR")
        XCTAssertEqual(ATCCommandParser.consonantSkeleton("BLZZR"), "BLZZR")
        let split = ATCCommandParser.identBaseVersion("OOSHN5")
        XCTAssertEqual(split.base, "OOSHN")
        XCTAssertEqual(split.version, "5")
    }

    func testBroadenedApproachTypes() {
        XCTAssertEqual(ATCCommandParser.parse("cleared vor runway 2 2", grounding: .init())?.qualifier, "VOR")
        XCTAssertEqual(ATCCommandParser.parse("cleared rnp runway 3 3 left", grounding: .init())?.qualifier, "RNP")
    }

    func testSuggestionTitlesForNewKinds() {
        XCTAssertEqual(EFBSuggestion.title(for: ATCCommand(kind: .loadSID, target: "BLZZR6", qualifier: "")),
                       "Load BLZZR6 departure")
        XCTAssertEqual(EFBSuggestion.title(for: ATCCommand(kind: .loadStar, target: "ROBUC3", qualifier: "")),
                       "Load ROBUC3 arrival")
    }

    // MARK: Phase 6 review fixes — retraction / trailing-negation / ambiguity / first-letter disambiguation

    func testProcedureAbstainsOnRetraction() {
        // controller self-corrects mid-transmission: the FIRST-named procedure is the RETRACTED one.
        XCTAssertNil(ATCCommandParser.parse("descend via the blazzer 6 arrival disregard descend via the camron 4 arrival",
                                            grounding: .init(stars: ["BLZZR6", "CAMRN4"])),
                     "a 'disregard' anywhere → the whole transmission is unreliable → abstain")
        XCTAssertNil(ATCCommandParser.parse("climb via the blazzer 6 departure correction fly runway heading",
                                            grounding: .init(sids: ["BLZZR6"])),
                     "'correction' retracts the named departure → abstain")
    }

    func testProcedureAbstainsOnNegationAfterName() {
        // the negation follows the procedure NAME — the pre-fix parser only looked at the prefix.
        XCTAssertNil(ATCCommandParser.parse("american 1 2 3 climb and maintain 5 0 0 0 the blazzer 6 departure is no longer in use",
                                            grounding: .init(sids: ["BLZZR6"])),
                     "'is no longer in use' after the name → abstain")
        XCTAssertNil(ATCCommandParser.parse("fly heading 2 7 0 the blazzer 6 departure is not authorized",
                                            grounding: .init(sids: ["BLZZR6"])),
                     "'is not authorized' after the name → abstain")
    }

    func testProcedureStillFiresWithSoftTrailingClause() {
        // a SOFT anticipatory word after the keyword ("when able direct …") must NOT suppress a valid load.
        XCTAssertEqual(ATCCommandParser.parse("climb via the blazzer 6 departure when able direct bosox",
                                              grounding: .init(fixes: ["BOSOX"], sids: ["BLZZR6"])),
                       ATCCommand(kind: .loadSID, target: "BLZZR6", qualifier: ""))
    }

    func testProcedureAbstainsWhenTwoDistinctProceduresNamed() {
        // two different, both-grounded procedures in one transmission (no retraction word) → ambiguous.
        XCTAssertNil(ATCCommandParser.parse("descend via the blazzer 6 arrival then the camron 4 arrival",
                                            grounding: .init(stars: ["BLZZR6", "CAMRN4"])),
                     "two distinct named procedures → abstain rather than guess which")
    }

    func testProcedureFiresValidWhenALaterProcedureIsNegated() {
        // the first procedure is validly cleared; a LATER one is declared unavailable → still load the first.
        XCTAssertEqual(ATCCommandParser.parse("climb via the blazzer 6 departure the camron 4 departure is not in use",
                                              grounding: .init(sids: ["BLZZR6", "CAMRN4"])),
                       ATCCommand(kind: .loadSID, target: "BLZZR6", qualifier: ""),
                       "a negated later procedure must not block the validly-cleared earlier one")
    }

    func testProcedureFirstLetterDisambiguatesVowelInitialTwins() {
        // "aspen" and "espen" share a consonant skeleton (SPN); the first-letter check must keep them apart.
        XCTAssertNil(ATCCommandParser.parse("climb via the aspen 2 departure", grounding: .init(sids: ["ESPEN2"])),
                     "'aspen' must not load the ESPEN departure")
        XCTAssertEqual(ATCCommandParser.parse("climb via the espen 2 departure", grounding: .init(sids: ["ESPEN2"])),
                       ATCCommand(kind: .loadSID, target: "ESPEN2", qualifier: ""),
                       "the correctly-spoken name still loads")
    }

    func testDirectToFourLetterTokenPrefersGroundedFix() {
        // a 4-letter token is BOTH fix- and airport-shaped; when grounded as a FIX it emits a plain direct-to.
        XCTAssertEqual(ATCCommandParser.parse("cleared direct kpvd", grounding: .init(fixes: ["KPVD"])),
                       ATCCommand(kind: .directTo, target: "KPVD", qualifier: ""),
                       "grounded as a fix → fix direct-to (qualifier empty), airport branch not reached")
    }
}
