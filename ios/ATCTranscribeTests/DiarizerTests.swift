import XCTest
@testable import ATCTranscribe

/// Mechanically verifies the diarizer's split-on-gap + merge-same-speaker logic with synthetic
/// tones. (Real-audio robustness is device-validated; this locks the segmentation math.)
final class DiarizerTests: XCTestCase {

    private func tone(_ n: Int, amp: Float, freq: Float) -> [Float] {
        (0..<n).map { amp * sin(2 * .pi * freq * Float($0) / 16000) }
    }
    private func silence(_ n: Int) -> [Float] { [Float](repeating: 0, count: n) }

    // Two clearly different transmissions (distinct in-band timbres) split by a PTT gap → 2 speakers.
    // Frequencies sit inside the 300–3800 Hz ATC voice band the MFCC front-end analyzes.
    func testSplitsTwoDifferentTransmissions() {
        let pieces = Diarizer().diarize(tone(8000, amp: 0.5, freq: 500)
                                        + silence(3200)
                                        + tone(8000, amp: 0.1, freq: 1500))
        XCTAssertEqual(pieces.count, 2)
        XCTAssertNotEqual(pieces[0].speaker, pieces[1].speaker)
    }

    // One continuous transmission → one piece.
    func testSingleContinuousIsOnePiece() {
        XCTAssertEqual(Diarizer().diarize(tone(16000, amp: 0.4, freq: 700)).count, 1)
    }

    // Same speaker with a short mid-sentence pause → split candidates merge back to one piece.
    func testMidSentencePauseMergesBack() {
        let pieces = Diarizer().diarize(tone(6000, amp: 0.4, freq: 700)
                                        + silence(2400)
                                        + tone(6000, amp: 0.4, freq: 700))
        XCTAssertEqual(pieces.count, 1)
    }
}
