import XCTest
@testable import ATCTranscribe

/// Streaming speaker-change segmentation: the segmenter emits a turn the instant the NEXT speaker is
/// confirmed acoustically different, instead of waiting for the 400 ms silence. Verified with synthetic
/// tones (loud-low = "ATC", quiet-high = "aircraft") — real-audio behavior is device-validated. Every
/// ambiguous verdict must bias toward MERGE (fall back to the silence path), never a wrong split.
final class VADSegmenterStreamingTests: XCTestCase {

    private func streaming() -> VADSegmenter {
        VADSegmenter(config: VADConfig(), speakerAware: true, speaker: SpeakerModel(), now: { 0 })
    }
    private func plain() -> VADSegmenter {
        VADSegmenter(config: VADConfig(), speakerAware: false, now: { 0 })
    }
    private func tone(_ n: Int, amp: Float, freq: Float) -> [Float] {
        (0..<n).map { amp * sin(2 * .pi * freq * Float($0) / 16000) }
    }
    private func silence(_ n: Int) -> [Float] { [Float](repeating: 0, count: n) }

    // 30ms frames @16k: silenceFrames=13 (400ms), pttBreakFrames=5 (150ms), onsetConfirm=10 (300ms),
    // minTurnSpeech=16 (500ms). "ATC" = 20 frames loud-low; a sub-400ms PTT gap; "aircraft" = 20 frames.
    private let atc = { (s: VADSegmenterStreamingTests) in s.tone(9600, amp: 0.5, freq: 500) }
    private let aircraft = { (s: VADSegmenterStreamingTests) in s.tone(9600, amp: 0.03, freq: 1500) }
    private var pttGap: [Float] { silence(2880) }   // 6 frames: > pttBreak (5), < silence (13)

    func testStreamingEmitsFirstTurnEarly() {
        // A rapid ATC→aircraft exchange whose gap is < 400ms. Streaming emits the ATC turn the moment
        // the aircraft is confirmed a different speaker — BEFORE the aircraft finishes.
        let audio = atc(self) + pttGap + aircraft(self)
        let out = streaming().feed(audio)
        XCTAssertEqual(out.count, 1, "ATC turn should emit early, mid-aircraft-transmission")
        XCTAssertNotNil(out[0].speaker)
        // The plain VAD merges the sub-400ms-gap exchange into one still-open segment → emits nothing yet.
        XCTAssertEqual(plain().feed(audio).count, 0, "plain VAD would batch the whole exchange")
    }

    func testStreamingSameSpeakerMergesNoSplit() {
        // Same speaker both sides of a >150ms breath — must NOT early-split (merge-back).
        let out = streaming().feed(atc(self) + pttGap + atc(self))
        XCTAssertEqual(out.count, 0, "a same-speaker pause must merge, not early-emit")
    }

    func testStreamingLevelJumpMergesNoSplit() {
        // The SAME voice keying up much louder across a PTT gap (same pitch + brightness, ~+17 dB level)
        // must MERGE, never early-split: loudness alone is not a speaker change. The overall distance
        // clears newSpeakerDist purely on the `level` dim, so only the timbre gate prevents a wrong split.
        let loud = tone(9600, amp: 0.5, freq: 700)
        let quiet = tone(9600, amp: 0.06, freq: 700)   // same 700 Hz, far quieter
        XCTAssertEqual(streaming().feed(loud + pttGap + quiet).count, 0,
                       "a same-voice loudness jump must merge, not split (level ≠ speaker change)")
    }

    func testStreamingDisableMidConfirmMergesAndKeepsAllAudio() {
        // Toggling "Separate speakers" OFF while a next-speaker onset is mid-confirmation must fold
        // turn A + the PTT gap + the buffered onset into ONE merged plain segment — losing none of it.
        let seg = streaming()
        let a = atc(self)                              // 9600: arms turn A
        let onset = tone(4320, amp: 0.5, freq: 1500)    // 9 frames: < onsetConfirm(10) → parks in .confirmingOnset
        XCTAssertEqual(seg.feed(a + pttGap + onset).count, 0, "onset too short to confirm — nothing emitted yet")
        seg.setSpeakerAware(false)                     // flip OFF mid-.confirmingOnset
        let out = seg.flush()                          // plain-path finalize of the folded segment
        XCTAssertEqual(out.count, 1, "the merged transmission must finalize as one segment, not be lost")
        XCTAssertEqual(out[0].audio.count, a.count + pttGap.count + onset.count,
                       "turn A + PTT gap + the mid-confirmation onset must all survive the OFF toggle")
        XCTAssertNil(out[0].speaker, "plain-path finalize leaves speaker nil")
    }

    func testStreamingDisableMidConfirmWithOnsetGapKeepsExactAudio() {
        // Like the OFF-toggle test, but the parked onset contains an INTERIOR silence frame — guards the
        // double-append/reorder of onset-interior silence (which is buffered in onsetFrames only, not
        // mirrored into segmentFrames). Exact length proves each frame folds in once, in order.
        let seg = streaming()
        let a = atc(self)                                                  // 9600: arms turn A
        let onset = tone(1920, amp: 0.5, freq: 1500)                        // 4 speech frames
            + silence(480)                                                 // 1 interior silence frame
            + tone(1440, amp: 0.5, freq: 1500)                              // 3 speech frames (7 speech < onsetConfirm 10)
        XCTAssertEqual(seg.feed(a + pttGap + onset).count, 0, "onset too short to confirm — nothing emitted yet")
        seg.setSpeakerAware(false)
        let out = seg.flush()
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].audio.count, a.count + pttGap.count + onset.count,
                       "an onset with interior silence must fold in exactly once — no duplicated/reordered frame")
    }

    func testStreamingMicroPauseNeverArms() {
        // A <150ms micro-pause never even arms the tentative boundary → identical to plain.
        let micro = silence(1440)   // 3 frames < pttBreakFrames
        XCTAssertEqual(streaming().feed(atc(self) + micro + atc(self)).count, 0)
    }

    func testStreamingFinalTurnEmitsOnSilenceFallback() {
        // A lone/last turn has no next speaker → still emits on the 400ms silence fallback, tagged.
        let out = streaming().feed(atc(self) + silence(6720))   // 14 frames >= silenceFrames
        XCTAssertEqual(out.count, 1)
        XCTAssertNotNil(out[0].speaker)
    }

    func testStreamingFlushDrainsParkedTurn() {
        // Stream ends while a turn is parked awaiting the next speaker's confirmation → flush emits it.
        let seg = streaming()
        let bStart = tone(2400, amp: 0.03, freq: 1500)   // 5 frames: < onsetConfirm, can't confirm
        XCTAssertEqual(seg.feed(atc(self) + pttGap + bStart).count, 0, "onset too short to confirm yet")
        let flushed = seg.flush()
        XCTAssertEqual(flushed.count, 1, "flush must drain the parked turn, not lose it")
        XCTAssertNotNil(flushed[0].speaker)
    }

    func testStreamingCapEmitsAndResets() {
        // A gapless burst past the 8s cap emits at the cap (tagged) and keeps going.
        let out = streaming().feed(tone(140_000, amp: 0.5, freq: 500))   // 8.75s continuous
        XCTAssertGreaterThanOrEqual(out.count, 1)
        XCTAssertNotNil(out[0].speaker)
    }

    func testPlainPathLeavesSpeakerNil() {
        // speakerAware=false: unchanged plain VAD, no speaker tag (the post-hoc diarizer labels).
        let out = plain().feed(atc(self) + silence(6720))
        XCTAssertEqual(out.count, 1)
        XCTAssertNil(out[0].speaker)
    }

    /// M1 remediation, streaming twin: a gapless loud channel latches the runaway-noise notice on
    /// the speaker-aware path too (the `.speaking` cap counts; the onset-merged cap does not).
    func testStreamingGaplessRunawayLatches() {
        let s = streaming()
        _ = s.feed(tone(480_000, amp: 0.5, freq: 500))   // 30 s gapless — ≥3 cap emissions
        XCTAssertTrue(s.consumeRunawayNoise(), "gapless caps on the streaming path must latch")
    }
}
