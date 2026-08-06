import XCTest
@testable import ATCTranscribe

/// The pre-decode dead-air gate. These call the production symbol with synthesised audio whose
/// envelope shape mirrors what was measured on the real corpora (gold-137 vs 500 held-out no-speech
/// clips), so they fail if the thresholds or the statistics drift.
final class DeadAirFilterTests: XCTestCase {

    /// Always returns the same line, so the only thing that can make `process` return nil is the gate.
    private actor FixedTranscriber: Transcribing {
        private let line: String
        init(_ line: String) { self.line = line }
        func transcribe(_ audio: [Float], context: String?) async throws -> TranscriptionOutput {
            TranscriptionOutput(text: line, asr: .unknown)
        }
    }

    private let sr = 16_000

    /// Steady noise: constant-amplitude white noise. Envelope is flat -> low range, low CV. This is
    /// what radio dead air looks like and what the gate must reject.
    private func steadyNoise(seconds: Double, amp: Float = 0.05) -> [Float] {
        var rng = SystemRandomNumberGenerator()
        return (0..<Int(Double(sr) * seconds)).map { _ in
            Float.random(in: -amp...amp, using: &rng)
        }
    }

    /// Bursty audio: alternating loud/quiet blocks, like words separated by gaps. Wide envelope
    /// range and high CV — the signature of speech.
    private func burstyAudio(seconds: Double) -> [Float] {
        var rng = SystemRandomNumberGenerator()
        let n = Int(Double(sr) * seconds)
        return (0..<n).map { i in
            let loud = (i / 4000) % 2 == 0            // ~0.25 s alternation
            let amp: Float = loud ? 0.30 : 0.002
            return Float.random(in: -amp...amp, using: &rng)
        }
    }

    func testSteadyNoiseIsRejected() {
        guard case .deadAir = DeadAirFilter.verdict(for: steadyNoise(seconds: 3)) else {
            return XCTFail("steady noise must be classified as dead air — it is the whole point")
        }
    }

    func testBurstySpeechLikeAudioPasses() {
        XCTAssertEqual(DeadAirFilter.verdict(for: burstyAudio(seconds: 3)), .speech)
    }

    /// Bias-toward-passing: anything too short to measure must go to the transcriber, never be dropped.
    func testTooShortAlwaysPasses() {
        XCTAssertEqual(DeadAirFilter.verdict(for: []), .speech)
        // fewer than minFrames (8 x 480 samples) — below the measurable floor
        XCTAssertEqual(DeadAirFilter.verdict(for: steadyNoise(seconds: 0.15)), .speech)
    }

    /// Digital silence is dead air, and must not divide by zero on the way there.
    func testPureSilenceIsDeadAirAndDoesNotCrash() {
        let silence = [Float](repeating: 0, count: sr)
        guard case .deadAir = DeadAirFilter.verdict(for: silence) else {
            return XCTFail("digital silence must be dead air")
        }
    }

    /// A quiet but bursty transmission still passes: loudness is NOT the criterion, burstiness is.
    /// This is the over-suppression guard — a faint real clearance must never be dropped.
    func testQuietButBurstyStillPasses() {
        var rng = SystemRandomNumberGenerator()
        let n = sr * 3
        let quiet: [Float] = (0..<n).map { i in
            let loud = (i / 4000) % 2 == 0
            let amp: Float = loud ? 0.02 : 0.0002      // 15x quieter than `burstyAudio`
            return Float.random(in: -amp...amp, using: &rng)
        }
        XCTAssertEqual(DeadAirFilter.verdict(for: quiet), .speech)
    }

    /// The envelope is framed exactly like VADSegmenter (30 ms / 480 samples) so the two agree about
    /// what a "frame" is; a change here would silently decouple them.
    func testEnvelopeFramingMatchesVAD() {
        XCTAssertEqual(DeadAirFilter.frameSamples, 480)
        let env = DeadAirFilter.envelope([Float](repeating: 0.1, count: 480 * 5 + 100))
        XCTAssertEqual(env.count, 5, "partial trailing frame must be discarded, not padded")
        XCTAssertEqual(env[0], 0.1, accuracy: 1e-5)
    }

    /// The preference must reach a NEWLY BUILT pipeline, not just a running one. A session is rebuilt
    /// on every model swap and feed change, so if the flag were only applied through `setDeadAirFilter`
    /// a user who turned it OFF would get it silently back ON at the next swap. This asserts the
    /// constructor carries it — the failure it guards against leaves no trace at runtime.
    func testPreferenceSurvivesPipelineConstruction() async {
        let audio = steadyNoise(seconds: 3)
        let seg = SpeechSegment(audio: audio, streamStartS: 0,
                                streamEndS: Double(audio.count) / 16_000.0,
                                finalizedWallTime: Date().timeIntervalSince1970)

        let on = LivePipeline(transcriber: FixedTranscriber("delta 2 1 9 heavy"),
                              context: ATCContext(), deadAirFilterEnabled: true)
        let dropped = await on.process(seg)
        XCTAssertNil(dropped, "filter ON must drop steady noise before the decode")

        let off = LivePipeline(transcriber: FixedTranscriber("delta 2 1 9 heavy"),
                               context: ATCContext(), deadAirFilterEnabled: false)
        let kept = await off.process(seg)
        XCTAssertNotNil(kept, "filter OFF must restore the previous behaviour — the segment reaches the transcriber")
    }

    /// Pin the shipped operating point. Measured zero-gold-loss thresholds were 14.36 dB / 0.583;
    /// we ship below them on purpose so a quieter-but-real transmission still survives. If someone
    /// raises these above the measured points, real transmissions start getting dropped.
    func testThresholdsKeepMarginBelowTheMeasuredZeroLossPoint() {
        XCTAssertLessThan(DeadAirFilter.minRangeDB, 14.36,
                          "range threshold must stay below the measured zero-gold-loss point")
        XCTAssertLessThan(DeadAirFilter.minCV, 0.583,
                          "CV threshold must stay below the measured zero-gold-loss point")
        XCTAssertGreaterThan(DeadAirFilter.minRangeDB, 0)
        XCTAssertGreaterThan(DeadAirFilter.minCV, 0)
    }
}
