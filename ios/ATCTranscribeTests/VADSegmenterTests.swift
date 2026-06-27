import XCTest
@testable import ATCTranscribe

/// Encodes the segmentation behavior of `atc_stream.VADSegmenter` (energy path).
/// The same cases are cross-checked against the Python reference in
/// `ios/Tools/parity_check.py`. A "frame" is 30 ms = 480 samples at 16 kHz.
final class VADSegmenterTests: XCTestCase {

    private func seg() -> VADSegmenter { VADSegmenter(now: { 0 }) }

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

    // Manual squelch at max raises the gate (0.05 RMS) so a moderate 0.03 signal is squelched —
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
