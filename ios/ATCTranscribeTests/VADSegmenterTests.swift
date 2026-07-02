import XCTest
@testable import ATCTranscribe

/// Encodes the segmentation behavior of `atc_stream.VADSegmenter` (energy path).
/// The same cases are cross-checked against the Python reference in
/// `ios/Tools/parity_check.py`. A "frame" is 30 ms = 480 samples at 16 kHz.
final class VADSegmenterTests: XCTestCase {

    // Pin an explicit config so these segmentation-LOGIC cases don't move when the app's DEFAULTS are
    // tuned for latency. The cases below encode silence 700 ms (= 23 frames) and maxSegment 12 s (= 400
    // frames); keep testing that logic regardless of the shipped defaults.
    private func seg() -> VADSegmenter {
        VADSegmenter(config: VADConfig(silenceDurationMs: 700, maxSegmentS: 12.0), now: { 0 })
    }

    /// Lock the shipped defaults that control live latency (so a change is deliberate). Lowered to
    /// split fast back-to-back transmissions and bound the worst-case delay — see VADConfig.
    func testDefaultsAreTunedForLowLatency() {
        XCTAssertEqual(VADConfig().silenceDurationMs, 400)
        XCTAssertEqual(VADConfig().maxSegmentS, 8.0, accuracy: 1e-9)
    }

    /// `n` frames of constant amplitude `amp` (RMS == amp for a constant signal,
    /// so amp 0.5 reads as speech, 0.0 as silence, vs the 0.008 energy threshold).
    private func frames(_ n: Int, _ amp: Float) -> [Float] {
        [Float](repeating: amp, count: n * VADSegmenter.frameSamples)
    }

    func testSpeechThenSilenceEmitsOneSegment() {
        // 17 speech frames (>= 16 min) then 23 silence frames (>= silence threshold).
        let out = seg().feed(frames(17, 0.5) + frames(23, 0.0))
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].streamStartS, 0.0, accuracy: 1e-9)
        XCTAssertEqual(out[0].streamEndS, 1.2, accuracy: 1e-9)         // 40 frames * 30 ms
        XCTAssertEqual(out[0].audio.count, 40 * VADSegmenter.frameSamples)
    }

    func testShortSpeechIsDropped() {
        // 5 speech frames (< 16 min) -> finalize drops it.
        XCTAssertTrue(seg().feed(frames(5, 0.5) + frames(23, 0.0)).isEmpty)
    }

    func testMaxSegmentCapEmits() {
        // 400 frames * 480 = 192000 samples = 12 s -> capped + emitted.
        XCTAssertEqual(seg().feed(frames(400, 0.5)).count, 1)
    }

    func testSilenceOnlyEmitsNothing() {
        XCTAssertTrue(seg().feed(frames(50, 0.0)).isEmpty)
    }

    // A live mic (unlike a bursty radio) delivers CONTINUOUS above-threshold room ambient that never
    // drops to true silence. The auto noise floor must LEARN that ambient and gate it out — instead of
    // reading every frame as speech and looping on the max-segment cap forever (the stuck-"transcribing"
    // mic bug). 20 s of steady 0.02 ambient (> the 0.008 absolute floor) must emit NOTHING.
    func testContinuousAmbientBootstrapsFloorAndGatesIt() {
        let s = VADSegmenter(config: VADConfig(), now: { 0 })
        XCTAssertTrue(s.feed(frames(666, 0.02)).isEmpty,
                      "steady above-threshold ambient must gate off once the floor bootstraps, not emit cap-noise")
    }

    // The same continuous ambient with two louder speech bursts: ambient gated, and each burst (well
    // above ambient × noiseMargin) finalizes on the ambient between them — so a real transmission over
    // mic room-tone still yields one segment per burst, not one never-ending blob.
    func testContinuousAmbientWithBurstsSegmentsEachBurst() {
        let s = VADSegmenter(config: VADConfig(), now: { 0 })   // default: 400 ms silence, 8 s cap
        let pcm = frames(60, 0.02) + frames(20, 0.30) + frames(40, 0.02) + frames(20, 0.30) + frames(40, 0.02)
        let out = s.feed(pcm)
        XCTAssertEqual(out.count, 2, "each burst over continuous ambient must finalize as its own segment")
        for seg in out {
            XCTAssertLessThan(seg.audio.count, 8 * VADSegmenter.sampleRate,
                              "a burst must finalize on the ambient gap, not grow to the 8 s cap")
        }
    }

    // A sustained near-constant QUIET transmission must NOT self-gate partway through. The auto floor
    // must never train UP on frames it just classified as speech — otherwise a steady 0.05 call would
    // raise its own gate above itself after ~1.5 s and drop the rest of the transmission (a regression
    // the shared gate would have inflicted on radio/replay too). The emitted segment must span the tone.
    func testSustainedQuietTransmissionDoesNotSelfGate() {
        let s = VADSegmenter(config: VADConfig(), now: { 0 })
        let out = s.feed(frames(23, 0.0) + frames(200, 0.05) + frames(23, 0.0))
        XCTAssertEqual(out.count, 1)
        XCTAssertGreaterThanOrEqual(out[0].audio.count, 200 * VADSegmenter.frameSamples,
                                    "a steady quiet transmission must not self-gate partway through")
    }

    // A normal-volume transmission that OPENS the stream with no leading silence must still segment: the
    // first frame is judged at the absolute threshold BEFORE the seed, and 0.2 clears the clamped gate.
    // (Guards the seed from gating a stream that opens mid-transmission — for normal signal levels.)
    func testTransmissionOpeningStreamStillEmits() {
        let s = VADSegmenter(config: VADConfig(), now: { 0 })
        XCTAssertEqual(s.feed(frames(20, 0.2) + frames(23, 0.0)).count, 1)
    }

    // A genuinely LOUD steady signal (0.5) is a real transmission, not ambient — the clamp keeps the
    // learned floor in the ambient range so it still reads as speech and caps (guards the fix from
    // over-gating loud continuous audio). Mirrors testMaxSegmentCapEmits under the shipped default cap.
    func testLoudContinuousSignalStillReadsAsSpeech() {
        let s = VADSegmenter(config: VADConfig(), now: { 0 })   // 8 s cap = 267 frames
        XCTAssertEqual(s.feed(frames(300, 0.5)).count, 1, "loud continuous audio must not be learned as ambient")
    }

    // Manual squelch at max raises the gate (0.10 RMS) so a moderate 0.03 signal is squelched —
    // no segment opens, so the transcriber never wakes on a low-level/noisy channel.
    func testManualSquelchSuppressesBelowThreshold() {
        let s = VADSegmenter(config: VADConfig(squelchAuto: false, squelchLevel: 1.0), now: { 0 })
        XCTAssertTrue(s.feed(frames(30, 0.03) + frames(23, 0.0)).isEmpty)
    }

    // Manual squelch wide open passes the same 0.03 signal through as one segment.
    func testManualSquelchOpenPassesSignal() {
        let s = VADSegmenter(config: VADConfig(squelchAuto: false, squelchLevel: 0.0), now: { 0 })
        XCTAssertEqual(s.feed(frames(20, 0.03) + frames(23, 0.0)).count, 1)
    }
}
