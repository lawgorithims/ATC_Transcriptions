import XCTest
@testable import ATCTranscribe

/// The per-line 🟢🟡🔴 confidence bucketing.
final class LineConfidenceTests: XCTestCase {

    private func rec(callsign: String? = nil, key: String? = nil, gate: Double,
                     state: RefinementState = .none) -> TranscriptRecord {
        var r = TranscriptRecord(text: "x", streamStartS: 0, streamEndS: 0, audioDurationMs: 0,
            captureToTextMs: 0, transcribeMs: 0, realTimeFactor: 0, prompt: "", corrected: "",
            corrections: [], timestamp: "")
        r.callsign = callsign
        r.callsignKey = key
        r.gateConfidence = gate
        r.refinementState = state
        return r
    }

    func testHighWhenAttributedAndClean() {
        XCTAssertEqual(LineConfidence.of(rec(callsign: "AAL1", key: "AAL1", gate: 0.9)), .high)
    }

    func testMediumWhenHeardButUnverified() {
        XCTAssertEqual(LineConfidence.of(rec(callsign: "AAL1", key: nil, gate: 0.9)), .medium)
    }

    func testLowWhenNoCallsignAndGateFlagged() {
        XCTAssertEqual(LineConfidence.of(rec(callsign: nil, key: nil, gate: 0.3)), .low)
    }

    func testPendingIsMediumNotGreen() {
        XCTAssertEqual(LineConfidence.of(rec(callsign: "AAL1", key: "AAL1", gate: 0.9, state: .pending)), .medium)
    }

    func testAttributedButLowGateIsMedium() {
        XCTAssertEqual(LineConfidence.of(rec(callsign: "AAL1", key: "AAL1", gate: 0.5)), .medium)
    }
}
