import XCTest
@testable import ATCTranscribe

/// EFBSuggestion titles for the new kinds, the value validator, and the confidence assessor.
final class ATCInstructionSupportTests: XCTestCase {

    private func ins(_ kind: ATCInstructionKind, target: String, value: Int? = nil, unit: String = "",
                     modifier: String = "", raw: String = "", conf: ATCConfidence = .high) -> ATCInstruction {
        ATCInstruction(kind: kind, target: target, value: value, unit: unit, modifier: modifier,
                       rawTranscript: raw, confidence: conf, addressedToOwnship: true)
    }

    // MARK: titles

    func testTitlesForNewKinds() {
        XCTAssertEqual(EFBSuggestion.title(for: ins(.altitude, target: "8000", value: 8000, modifier: "descend")),
                       "Descend to 8000 ft")
        XCTAssertEqual(EFBSuggestion.title(for: ins(.altitude, target: "5000", value: 5000, modifier: "climb")),
                       "Climb to 5000 ft")
        XCTAssertEqual(EFBSuggestion.title(for: ins(.altitude, target: "FL180", value: 18000, modifier: "maintain")),
                       "Maintain FL180")
        XCTAssertEqual(EFBSuggestion.title(for: ins(.heading, target: "090", value: 90, modifier: "left")),
                       "Turn left heading 090")
        XCTAssertEqual(EFBSuggestion.title(for: ins(.heading, target: "270", value: 270)), "Fly heading 270")
        XCTAssertEqual(EFBSuggestion.title(for: ins(.speed, target: "250", value: 250)), "Maintain 250 kt")
        XCTAssertEqual(EFBSuggestion.title(for: ins(.squawk, target: "4231", value: 4231)), "Squawk 4231")
        XCTAssertEqual(EFBSuggestion.title(for: ins(.frequencyChange, target: "124.5", modifier: "tower")),
                       "Contact Tower 124.5")
    }

    func testMakeGuards() {
        XCTAssertNotNil(EFBSuggestion.make(id: "r1", instruction: ins(.squawk, target: "1200"), source: "x"))
        XCTAssertNil(EFBSuggestion.make(id: "", instruction: ins(.squawk, target: "1200"), source: "x"))
        XCTAssertNil(EFBSuggestion.make(id: "r1", instruction: ins(.altitude, target: ""), source: "x"))
    }

    func testLegacyCommandBridge() {
        let route = ins(.directTo, target: "BOSOX")
        XCTAssertEqual(route.legacyCommand, ATCCommand(kind: .directTo, target: "BOSOX", qualifier: ""))
        XCTAssertNil(ins(.altitude, target: "8000", value: 8000).legacyCommand, "numeric kinds have no legacy command")
    }

    // MARK: validator

    func testValidatorAcceptsMagnitudeLicensedAltitude() {
        XCTAssertTrue(ATCValueValidator.validate(ins(.altitude, target: "8000", value: 8000,
                                                     raw: "descend and maintain 8 thousand")))
    }

    func testValidatorRejectsInventedHeadingDigits() {
        // target 270 but the audio only names 090 (no magnitude word licenses it) → reject.
        XCTAssertFalse(ATCValueValidator.validate(ins(.heading, target: "270", value: 270,
                                                      raw: "turn left heading 0 9 0")))
    }

    func testValidatorRejectsBadHeadingModifier() {
        XCTAssertFalse(ATCValueValidator.validate(ins(.heading, target: "090", value: 90, modifier: "up",
                                                      raw: "heading 0 9 0")))
    }

    func testValidatorRangeGates() {
        XCTAssertFalse(ATCValueValidator.validate(ins(.altitude, target: "70000", value: 70000, raw: "7 0 thousand")))
        XCTAssertFalse(ATCValueValidator.validate(ins(.speed, target: "500", value: 500, raw: "5 0 0")))
        XCTAssertFalse(ATCValueValidator.validate(ins(.squawk, target: "1290", raw: "1 2 9 0")), "9 not octal")
    }

    func testValidatorAcceptsFrequency() {
        XCTAssertTrue(ATCValueValidator.validate(ins(.frequencyChange, target: "124.5",
                                                     raw: "contact tower 1 2 4 point 5")))
    }

    // MARK: confidence

    func testConfidenceHighWithVerifiedCallsign() {
        let snap = SnapGrounding(callsign: CallsignSnap.Result(verdict: "verified_exact",
                                                              original: "american 1 2 3", snapped: "american 1 2 3"))
        XCTAssertEqual(ATCInstructionConfidence.assess(kind: .altitude, snap: snap, asr: .unknown), .high)
    }

    func testConfidenceCappedBySnappedCallsign() {
        let snap = SnapGrounding(callsign: CallsignSnap.Result(verdict: "snapped",
                                                              original: "american 1 2 3", snapped: "american 1 2 4"))
        XCTAssertEqual(ATCInstructionConfidence.assess(kind: .altitude, snap: snap, asr: .unknown), .medium)
    }

    func testConfidenceLowWithUnsureASR() {
        let asr = ASRConfidence(avgLogprob: -1.2, compressionRatio: 1.0)
        XCTAssertEqual(ATCInstructionConfidence.assess(kind: .altitude, snap: nil, asr: asr), .low)
    }
}
