import XCTest
@testable import ATCTranscribe

/// The upgraded correction prompt: uniform world-frame slots, the static-prefix cache
/// invariant that carries the 2-3 s latency budget, and the world-model contracts.
final class PromptWorldFrameTests: XCTestCase {

    private func fullFrame() -> WorldFrame {
        WorldFrame(
            knowledge: "Runways: 22L, 22R\nFacility names: Kennedy",
            grounding: SnapGrounding(
                callsign: .init(verdict: "snapped", original: "delta 2 3 3",
                                snapped: "delta 2 3 2", applied: true),
                slots: [], airportIdent: "KJFK", airportRunways: ["22L", "22R"]),
            expectedReadback: "delta two thirty two descend and maintain one one thousand",
            history: ["prior one", "prior two"],
            transcript: "down two one one thousand delta two thirty two")
    }

    func testSlotOrderIsFixed() {
        let text = fullFrame().rendered()
        let order = ["WORLD:", "Runways: 22L", "Verified against live data",
                     "Expected readback", "Recent transmissions:", "TRANSCRIPT:"]
        var cursor = text.startIndex
        for marker in order {
            guard let r = text.range(of: marker, range: cursor..<text.endIndex) else {
                return XCTFail("missing or out-of-order slot: \(marker)\n\(text)")
            }
            cursor = r.upperBound
        }
    }

    func testEmptySlotsAreOmitted() {
        let minimal = WorldFrame(transcript: "wind two seven zero at one five").rendered()
        XCTAssertFalse(minimal.contains("Expected readback"))
        XCTAssertFalse(minimal.contains("Recent transmissions"))
        XCTAssertFalse(minimal.contains("Verified"))
        XCTAssertTrue(minimal.hasPrefix("WORLD:"))
        XCTAssertTrue(minimal.contains("TRANSCRIPT: wind two seven zero at one five"))
    }

    /// The KV-cache contract: everything before the final user turn must be byte-identical
    /// regardless of the frame content, or the local model re-prefills the whole prompt and
    /// the latency budget is lost.
    func testStaticPrefixIsIdenticalAcrossFrames() {
        let a = ATCCorrectionPrompt.chatMLPrompt(frame: fullFrame())
        let b = ATCCorrectionPrompt.chatMLPrompt(
            frame: WorldFrame(transcript: "totally different"))
        let marker = "<|im_start|>user\nWORLD:"
        let aPrefix = a.range(of: marker, options: .backwards).map { a[..<$0.lowerBound] }
        let bPrefix = b.range(of: marker, options: .backwards).map { b[..<$0.lowerBound] }
        XCTAssertNotNil(aPrefix)
        XCTAssertEqual(aPrefix, bPrefix, "static prefix must not vary with the frame")
    }

    func testSystemInstructionsCarryTheWorldModel() {
        let s = ATCCorrectionPrompt.systemInstructions
        XCTAssertTrue(s.contains("cleared to land"), "command grammar present")
        XCTAssertTrue(s.contains("squawk"), "ontology present")
        XCTAssertTrue(s.contains("READBACK"), "readback structure explained")
        XCTAssertTrue(s.contains("NEVER copy its digits"), "readback digit-safety rule")
        XCTAssertTrue(s.contains("Preserve every digit"), "digit preservation absolute")
        XCTAssertTrue(s.contains(#"{"edits""#), "edits-only JSON contract")
    }

    func testFewShotsCoverTheContracts() {
        let shots = ATCCorrectionPrompt.fewShot
        XCTAssertEqual(shots.count, 5)
        XCTAssertTrue(shots.contains { $0.user.contains("Expected readback") },
                      "a readback exemplar must exist")
        XCTAssertTrue(shots.contains { $0.user.contains("do NOT alter") && $0.assistant.contains(#""edits": []"#) },
                      "a verified no-op exemplar must exist")
        for shot in shots {
            XCTAssertNil(shot.assistant.range(of: #""corrected""#),
                         "few-shots teach edits-only output")
        }
    }

    func testLegacyShimMatchesFrameRendering() {
        let viaShim = ATCCorrectionPrompt.userMessage(
            transcript: "t", retrieved: "K", history: ["h"])
        let viaFrame = ATCCorrectionPrompt.userMessage(
            frame: WorldFrame(knowledge: "K", history: ["h"], transcript: "t"))
        XCTAssertEqual(viaShim, viaFrame)
    }
}
