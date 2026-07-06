import XCTest
@testable import ATCTranscribe

/// The LLM-layer augmentation (PR #5 Deliverable 3): snap verdicts must ground the prompt,
/// arm the validator's runway veto, and fire the confidence gate.
final class SnapGroundingTests: XCTestCase {

    private let kdfwRunways = ["13L", "13R", "17C", "17L", "17R", "18L", "18R",
                               "31L", "31R", "35C", "35L", "35R", "36L", "36R"]

    // MARK: validator runway veto

    private func makeValidator(grounded: [String]?) -> CorrectionValidator {
        // every word of the veto tests' `to` strings is allowed, so the anti-hallucination
        // check can never be the reason an edit drops — the veto is the only variable
        var v = CorrectionValidator(
            allowed: ["runway", "cleared", "land", "gate", "hold", "short", "of",
                      "22", "17", "center"],
            phonetic: [:])
        if let grounded { v.groundedRunways = CorrectionValidator.runwayKeys(designators: grounded) }
        return v
    }

    // NOTE: veto edits preserve digits AND direction words (the flip guard runs first), so
    // the only introducible runway key is "the word runway appearing before existing digits"
    // ("gate 22" → "runway 22") — the veto is the only variable in these tests.

    func testVetoRejectsUnknownRunway() {
        let v = makeValidator(grounded: kdfwRunways)
        // introduces designator 22 (bare); KDFW has no runway 22 of any suffix.
        let out = v.validate(raw: "hold position at gate 22",
                             edits: [CorrectionEdit(from: "gate 22", to: "runway 22",
                                                    reason: "t", backend: "llm")],
                             backend: "llm")
        XCTAssertFalse(out.changed, "edit introducing runway 22 at KDFW must be vetoed")
    }

    func testVetoAllowsRealRunwayAndRephrasing() {
        let v = makeValidator(grounded: kdfwRunways)
        // introduces designator 17C, which exists at KDFW — the veto must not fire.
        let out = v.validate(raw: "hold short of 17 center",
                             edits: [CorrectionEdit(from: "short of 17 center",
                                                    to: "short of runway 17 center",
                                                    reason: "t", backend: "llm")],
                             backend: "llm")
        XCTAssertTrue(out.changed, "verified-runway rewording must pass the veto")
    }

    func testVetoDisabledWithoutGrounding() {
        let v = makeValidator(grounded: nil)
        let out = v.validate(raw: "hold position at gate 22",
                             edits: [CorrectionEdit(from: "gate 22", to: "runway 22",
                                                    reason: "t", backend: "llm")],
                             backend: "llm")
        XCTAssertTrue(out.changed, "no grounding → veto must not fire")
    }

    func testDirectionFlipRejectedLikeADigitChange() {
        // "turn left"→"turn right" passes the near-miss ratio and per-word vocab checks —
        // only the semantic-flip guard can stop it (found by the offline LLM benchmark).
        let v = makeValidator(grounded: nil)
        let out = v.validate(raw: "turn left heading two seven zero",
                             edits: [CorrectionEdit(from: "turn left", to: "turn right",
                                                    reason: "t", backend: "llm")],
                             backend: "llm")
        XCTAssertFalse(out.changed, "left→right must be blocked like a digit change")
    }

    func testRunwayKeyParsing() {
        XCTAssertEqual(CorrectionValidator.runwayKeys(in: "cleared runway one seven right then runway 4"),
                       ["17|R", "4|"])
        XCTAssertEqual(CorrectionValidator.runwayKeys(designators: ["02C", "22", "35L"]),
                       ["2|C", "22|", "35|L"])
    }

    // MARK: gate signal

    func testGateFiresOnSnapReasons() {
        let gate = ConfidenceGate()
        let retrieved = RetrievedContext(block: "", vocab: [], languageSuspect: false)
        let decision = gate.assess(text: "delta two two heavy going around",
                                   retrieved: retrieved, asr: nil, inlineEdits: [],
                                   snapReasons: ["unverified callsign"])
        XCTAssertTrue(decision.shouldRefine)
        XCTAssertTrue(decision.reason.contains("unverified callsign"))
    }

    func testGateUnchangedWithoutSnapReasons() {
        let gate = ConfidenceGate()
        let retrieved = RetrievedContext(block: "", vocab: [], languageSuspect: false)
        let decision = gate.assess(text: "wind two seven zero at one five",
                                   retrieved: retrieved, asr: nil, inlineEdits: [])
        XCTAssertFalse(decision.shouldRefine)
    }

    // MARK: prompt grounding block

    func testPromptBlockRendersVerdicts() {
        let grounding = SnapGrounding(
            callsign: .init(verdict: "snapped", original: "delta 2 3 3", snapped: "delta 2 3 2", applied: true),
            slots: [.init(slot: "runway", verdict: "unverified", original: "22")],
            airportIdent: "KDFW",
            airportRunways: kdfwRunways)
        let block = grounding.promptBlock
        XCTAssertTrue(block.contains("do NOT alter"))
        XCTAssertTrue(block.contains("delta 2 3 2"))
        XCTAssertTrue(block.contains("NOT verified at KDFW"))
        XCTAssertTrue(block.contains("runway 22"))
        XCTAssertTrue(block.contains("Runways at KDFW"))
        XCTAssertEqual(grounding.gateReasons, ["unverified runway"])
        XCTAssertTrue(grounding.callsignAttributable)
    }

    func testUnverifiedCallsignNotAttributable() {
        let grounding = SnapGrounding(
            callsign: .init(verdict: "unverified", original: "delta 2 7 7"),
            slots: [], airportIdent: nil, airportRunways: [])
        XCTAssertFalse(grounding.callsignAttributable)
        XCTAssertEqual(grounding.gateReasons, ["unverified callsign"])
        XCTAssertTrue(grounding.correctionEdits.isEmpty)
    }
}
