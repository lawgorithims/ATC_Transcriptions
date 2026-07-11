import XCTest
@testable import ATCTranscribe

/// Ownship addressing: the EFB automation must fire ONLY when ATC is addressing the iPad pilot's own
/// aircraft — recognizing the standard shorthands of the filed tail — and NEVER on another aircraft or a
/// mere mention. These pin both the positive (recall) and, most importantly, the negative (safety) cases.
final class OwnshipIdentityTests: XCTestCase {

    // The user's example: a Piper Seneca, N8925T. Body "8925T", country "November", type cues piper/seneca.
    private let seneca = OwnshipIdentity(callsign: "N8925T", aircraftType: "Piper Seneca")

    private func addressed(_ s: String, _ id: OwnshipIdentity? = nil) -> Bool {
        (id ?? seneca).isAddressed(inNormalized: s)
    }

    // MARK: recall — the forms ATC actually uses ADDRESS ownship

    func testFullCallsignForms() {
        XCTAssertTrue(addressed("november 8 9 2 5 tango cleared to land runway 4"))
        XCTAssertTrue(addressed("n8925t cleared to land"))                 // collapsed alnum, at start
        XCTAssertFalse(addressed("descend and maintain 3 thousand n8925t"),
                       "callsign at the very end (no instruction after) is not matched — a trailing callsign "
                       + "could be another aircraft's; controllers lead with the addressed callsign")
    }

    func testBodyDropTheNForms() {
        XCTAssertTrue(addressed("8 9 2 5 tango descend and maintain 3 thousand"))   // body spoken, start
        XCTAssertTrue(addressed("8925t contact tower 1 1 9 point 1"))              // body alnum, start
    }

    func testCuedSuffixForms() {
        XCTAssertTrue(addressed("seneca 2 5 tango cleared for takeoff"))    // type cue + last-three
        XCTAssertTrue(addressed("piper 2 5 tango squawk 1 2 0 0"))          // the other type word
        XCTAssertTrue(addressed("seneca 9 2 5 tango cross runway 4"))       // 4-char type-cued suffix
    }

    func testAddressedWhenFollowedByInstructionNotAtStart() {
        XCTAssertTrue(addressed("and november 8 9 2 5 tango descend via the blazzer 6 arrival"))
    }

    // MARK: safety — mentions & other aircraft must NOT be addressed

    func testBareSuffixWithoutCueDoesNotFire() {
        // Product-owner policy: a bare short suffix with no type/country cue is too ambiguous → abstain.
        XCTAssertFalse(addressed("2 5 tango cleared to land"))
        XCTAssertFalse(addressed("25t cleared to land"))
    }

    func testWrongAircraftTypeCueDoesNotFire() {
        // A Cessna's "25T" must not match a Piper Seneca's identity even though the suffix overlaps.
        XCTAssertFalse(addressed("cessna 2 5 tango cleared to land"))
    }

    func testDifferentTailSharingTheSuffixDoesNotFire() {
        // N125T shares the "25T" suffix but is a different aircraft — the cued digits differ, so no match.
        XCTAssertFalse(addressed("november 1 2 5 tango cleared to land"))
        XCTAssertFalse(addressed("n125t cleared to land"))
    }

    func testTheSenecaMentionToAnotherAircraftDoesNotFire() {
        // The canonical case: our plane's TYPE is mentioned in a traffic advisory to Jetblue — not addressed.
        XCTAssertFalse(addressed("jetblue 1 2 3 4 hold short runway 4 left seneca exiting the runway at alpha"))
    }

    func testAnotherAircraftAddressedDoesNotFire() {
        XCTAssertFalse(addressed("american 1 2 3 4 cleared direct bosox"))
        XCTAssertFalse(addressed("delta 8 9 0 turn left heading 2 7 0"))
    }

    func testEmptyOrNoOwnshipIsSafe() {
        let none = OwnshipIdentity(callsign: "", aircraftType: "Piper Seneca")
        XCTAssertFalse(none.isValid)
        XCTAssertFalse(none.isAddressed(inNormalized: "november 8 9 2 5 tango cleared to land"))
    }

    // MARK: airline ownship still works (no suffix abbreviation)

    func testAirlineOwnshipMatchesFullFormOnly() {
        let jb = OwnshipIdentity(callsign: "JBU1234", aircraftType: "Airbus A320",
                                 spokenCallsign: ["jetblue", "1", "2", "3", "4"])
        XCTAssertFalse(jb.isGATail)
        XCTAssertTrue(jb.isAddressed(inNormalized: "jetblue 1 2 3 4 cleared to land"))
        XCTAssertTrue(jb.isAddressed(inNormalized: "jbu1234 cleared to land"))
        XCTAssertFalse(jb.isAddressed(inNormalized: "jetblue 5 6 7 8 cleared to land"), "different flight #")
        XCTAssertFalse(jb.isAddressed(inNormalized: "2 3 4 cleared to land"), "no airline suffix abbreviation")
    }

    // MARK: end-to-end through the parser (addressee positional binding + abbreviation)

    func testAbbreviatedOwnshipDrivesTheParser() {
        let cmd = ATCCommandParser.parse("seneca 2 5 tango cleared direct bosox",
                                         grounding: .init(fixes: ["BOSOX"]),
                                         addressee: seneca.addressee(airlineStarts: []))
        XCTAssertEqual(cmd, ATCCommand(kind: .directTo, target: "BOSOX", qualifier: ""))
    }

    func testMultiAircraftBindsClearanceToOwnshipByAbbreviation() {
        // Jetblue gets BOSOX; our Seneca (addressed by "seneca 2 5 tango") gets GABBS — bind to ours.
        let starts: Set<String> = ["jetblue", "american", "delta", "united"]
        let cmd = ATCCommandParser.parse(
            "jetblue 1 2 3 4 cleared direct bosox seneca 2 5 tango cleared direct gabbs",
            grounding: .init(fixes: ["BOSOX", "GABBS"]),
            addressee: seneca.addressee(airlineStarts: starts))
        XCTAssertEqual(cmd, ATCCommand(kind: .directTo, target: "GABBS", qualifier: ""))
    }

    func testMultiAircraftClearanceToTheOtherAircraftAbstainsForOwnship() {
        // Jetblue is cleared direct; our Seneca is only told to hold short (no EFB action) → no BOSOX for us.
        let starts: Set<String> = ["jetblue", "american", "delta", "united"]
        let cmd = ATCCommandParser.parse(
            "jetblue 1 2 3 4 cleared direct bosox seneca 2 5 tango hold short runway 4",
            grounding: .init(fixes: ["BOSOX"]),
            addressee: seneca.addressee(airlineStarts: starts))
        XCTAssertNil(cmd, "the direct-to belongs to Jetblue, not ownship")
    }

    // MARK: red-team fixes — false-fires the adversarial review found

    func testCountryCuedSuffixIsRejectedAsAmbiguous() {
        // "November 2 5 Tango" is byte-identical to N25T's FULL callsign (a DIFFERENT aircraft), so a
        // country-cued suffix must NOT fire — unlike a type cue, which no aircraft is registered under.
        XCTAssertFalse(addressed("november 2 5 tango turn left heading 2 7 0"))
        XCTAssertFalse(addressed("november 9 2 5 tango cross runway 4"))
    }

    func testOwnshipAcknowledgedThenAnotherAircraftClearedDoesNotFire() {
        // Ownship gets only "roger"; the actionable clearance belongs to a Pilatus (a type the app does
        // not know) later in the SAME transmission. Must not leak BOSOX to ownship.
        XCTAssertFalse(addressed("november 8 9 2 5 tango roger pilatus 3 4 tango whiskey cleared direct bosox"))
        let cmd = ATCCommandParser.parse(
            "november 8 9 2 5 tango roger pilatus 3 4 tango whiskey cleared direct bosox",
            grounding: .init(fixes: ["BOSOX"]), addressee: seneca.addressee(airlineStarts: []))
        XCTAssertNil(cmd, "the direct-to belongs to the Pilatus, not ownship")
    }

    func testTrafficReferenceFollowTheSenecaDoesNotFire() {
        // "follow the Seneca 25T, cleared ILS" — our tail is the TRAFFIC to follow; the ILS is the
        // Cessna's (number two behind us). Must not fire.
        XCTAssertFalse(addressed("cessna 3 4 lima number two follow the seneca 2 5 tango cleared ils runway 4 left"))
    }

    func testUnknownFirstAircraftThenOwnshipClearedBindsToOwnship() {
        // A Pilatus (unknown type → its start word isn't known) is cleared first; ownship is cleared
        // second. The clause must bind to OWNSHIP's segment (GABBS), never the Pilatus's BOSOX.
        let cmd = ATCCommandParser.parse(
            "pilatus 3 4 tango whiskey cleared direct bosox seneca 2 5 tango cleared direct gabbs",
            grounding: .init(fixes: ["BOSOX", "GABBS"]),
            addressee: seneca.addressee(airlineStarts: []))
        XCTAssertEqual(cmd, ATCCommand(kind: .directTo, target: "GABBS", qualifier: ""))
    }

    func testInstructionMustFollowOwnshipCallsign() {
        // Ownship named but NOT followed by an instruction (a plain read-back-style mention) → no fire.
        XCTAssertFalse(addressed("traffic is a seneca 2 5 tango"))
        XCTAssertTrue(addressed("seneca 2 5 tango roger climb and maintain 5 thousand"),
                      "a single 'roger' filler before the instruction still counts as addressed")
    }

    // MARK: re-verify round-2 fixes — second-aircraft-clearance leaks

    func testMentionCueBehindADescriptorStillDoesNotFire() {
        // "follow the SLOWER Seneca 25T, cleared visual" — a descriptor between the cue and our callsign
        // must not defeat the mention check (the clearance is for whoever is told to follow us).
        XCTAssertFalse(addressed("follow the slower seneca 2 5 tango cleared visual runway 4 left"))
        XCTAssertFalse(addressed("traffic a fast moving seneca 2 5 tango cleared ils runway 4 left"))
        // A LONG descriptor chain (>5 words) between the cue and our callsign must still be caught.
        XCTAssertFalse(addressed("follow the slow moving small blue seneca 2 5 tango cleared visual runway 4 left"))
    }

    func testSecondAircraftWithNoDigitBeforeItsClearanceDoesNotLeak() {
        // Ownship gets "ident"; an unknown-type aircraft with a digit-less abbreviated callsign
        // ("pilatus tango whiskey") is then cleared. efbClauseOpens requires ownship's OWN adjacent
        // instruction to be a clearance verb, so the following aircraft's approach can't bind to ownship.
        let addr = seneca.addressee(airlineStarts: [])
        XCTAssertNil(ATCCommandParser.parse("seneca 2 5 tango ident pilatus tango whiskey cleared visual runway 4 left",
                                            grounding: .init(), addressee: addr),
                     "the visual approach belongs to the Pilatus, not ownship")
        XCTAssertNil(ATCCommandParser.parse("seneca 2 5 tango ident pilatus cleared direct bosox",
                                            grounding: .init(fixes: ["BOSOX"]), addressee: addr),
                     "ownship's own instruction was 'ident', not a clearance")
    }

    func testOwnshipGetsNonClearanceInstructionThenAnotherAircraftClearedDoesNotFire() {
        // Ownship gets a real instruction ("ident"), but the actionable clearance is a Pilatus's. Ownship
        // IS addressed, yet the EFB must abstain — the clearance verb isn't ownship's own instruction.
        let addr = seneca.addressee(airlineStarts: [])
        XCTAssertTrue(addressed("seneca 2 5 tango ident pilatus 3 4 tango cleared direct bosox"),
                      "ownship is addressed (told to ident)")
        XCTAssertNil(ATCCommandParser.parse("seneca 2 5 tango ident pilatus 3 4 tango cleared direct bosox",
                                            grounding: .init(fixes: ["BOSOX"]), addressee: addr),
                     "the direct-to belongs to the Pilatus, not ownship")
    }

    func testOwnshipTurnThenDigitAbbreviatedAircraftClearedDoesNotFire() {
        let addr = seneca.addressee(airlineStarts: [])
        XCTAssertNil(ATCCommandParser.parse("november 8 9 2 5 tango turn 3 4 tango whiskey cleared direct bosox",
                                            grounding: .init(fixes: ["BOSOX"]), addressee: addr),
                     "ownship was told to turn; the direct-to belongs to 34TW")
    }

    func testOwnshipNonActionableClearanceThenAnotherAircraftDirectDoesNotFire() {
        // Ownship's own instruction opens with "cleared" but is "cleared to land" (not EFB-actionable);
        // an unknown Pilatus is then "cleared direct BOSOX". Ownship's clause ends at the SECOND opener,
        // so the Pilatus's direct-to never leaks.
        let addr = seneca.addressee(airlineStarts: [])
        XCTAssertNil(ATCCommandParser.parse("seneca 2 5 tango cleared to land and pilatus cleared direct bosox",
                                            grounding: .init(fixes: ["BOSOX"]), addressee: addr),
                     "the direct-to belongs to the Pilatus, not ownship")
    }

    func testOwnshipsOwnClearanceStillFiresThroughAGreeting() {
        // A benign non-numeric greeting between callsign and the clearance verb is skipped by the parser
        // (but note the gate still requires the instruction adjacent, so this specifically exercises parse).
        let addr = seneca.addressee(airlineStarts: [])
        XCTAssertEqual(ATCCommandParser.parse("seneca 2 5 tango cleared direct bosox",
                                              grounding: .init(fixes: ["BOSOX"]), addressee: addr),
                       ATCCommand(kind: .directTo, target: "BOSOX", qualifier: ""))
    }
}
