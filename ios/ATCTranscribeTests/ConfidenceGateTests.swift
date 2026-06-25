import XCTest
@testable import ATCTranscribe

/// The confidence gate decides whether a transmission is worth the background LLM. It should skip
/// clean/confident ones and run the LLM only when a real suspicion signal fires (any of: low ASR
/// confidence, a lexical near-miss to a known term, non-English, residual repetition).
final class ConfidenceGateTests: XCTestCase {

    private func gate(_ s: GateSensitivity = .conservative) -> ConfidenceGate {
        ConfidenceGate(sensitivity: s)
    }
    private func ctx(vocab: [String] = ["Delta", "13L", "CANUK"], lang: Bool = false) -> RetrievedContext {
        RetrievedContext(block: "", vocab: vocab, languageSuspect: lang)
    }
    private let confident = ASRConfidence(avgLogprob: -0.2, compressionRatio: 1.4)

    func testCleanConfidentSkips() {
        let d = gate().assess(text: "delta eight ninety contact ground",
                              retrieved: ctx(), asr: confident, inlineEdits: [])
        XCTAssertFalse(d.shouldRefine)
        XCTAssertEqual(d.reason, "high confidence")
    }

    func testNearMissCallsignRefines() {
        // "delto" ~ "Delta" (ratio 0.8, in the uncertain band) → ambiguous mishear → run LLM.
        let d = gate().assess(text: "delto eight ninety contact ground",
                              retrieved: ctx(), asr: confident, inlineEdits: [])
        XCTAssertTrue(d.shouldRefine)
        XCTAssertTrue(d.reason.contains("mishear"))
    }

    func testStrongMatchIsNotNearMiss() {
        // A token that strongly matches (≥0.84) would already be auto-fixed by the deterministic
        // tier, so it is NOT a gate signal.
        let d = gate().assess(text: "delt eight ninety contact ground",
                              retrieved: ctx(), asr: confident, inlineEdits: [])
        XCTAssertFalse(d.shouldRefine)
    }

    func testLowASRConfidenceRefines() {
        let d = gate().assess(text: "delta eight ninety contact ground",
                              retrieved: ctx(), asr: ASRConfidence(avgLogprob: -1.5, compressionRatio: 1.4),
                              inlineEdits: [])
        XCTAssertTrue(d.shouldRefine)
        XCTAssertTrue(d.reason.contains("ASR"))
    }

    func testHighCompressionRefines() {
        let d = gate().assess(text: "delta eight ninety contact ground",
                              retrieved: ctx(), asr: ASRConfidence(avgLogprob: -0.2, compressionRatio: 2.1),
                              inlineEdits: [])
        XCTAssertTrue(d.shouldRefine)
    }

    func testLanguageSuspectRefines() {
        let d = gate().assess(text: "delta eight ninety contact ground",
                              retrieved: ctx(lang: true), asr: confident, inlineEdits: [])
        XCTAssertTrue(d.shouldRefine)
        XCTAssertTrue(d.reason.contains("non-English"))
    }

    func testResidualRepetitionRefines() {
        let edit = CorrectionEdit(from: "runway runway", to: "runway", reason: "repeat", backend: "deterministic")
        let d = gate().assess(text: "delta runway runway one three",
                              retrieved: ctx(), asr: confident, inlineEdits: [edit])
        XCTAssertTrue(d.shouldRefine)
        XCTAssertTrue(d.reason.contains("repetition"))
    }

    func testSensitivityScalesASRThreshold() {
        // A middling avgLogprob: conservative treats it as suspicious, aggressive trusts it.
        let asr = ASRConfidence(avgLogprob: -0.9, compressionRatio: 1.4)
        let c = gate(.conservative).assess(text: "delta eight ninety contact ground", retrieved: ctx(), asr: asr, inlineEdits: [])
        let a = gate(.aggressive).assess(text: "delta eight ninety contact ground", retrieved: ctx(), asr: asr, inlineEdits: [])
        XCTAssertTrue(c.shouldRefine)
        XCTAssertFalse(a.shouldRefine)
    }

    func testShortReadbackIgnoresNoisyASR() {
        // 1-word readbacks don't trigger on a noisy avgLogprob (too little for the LLM anyway).
        let d = gate().assess(text: "roger", retrieved: ctx(),
                              asr: ASRConfidence(avgLogprob: -1.5, compressionRatio: 1.4), inlineEdits: [])
        XCTAssertFalse(d.shouldRefine)
    }
}
