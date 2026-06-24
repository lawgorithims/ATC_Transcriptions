import XCTest
@testable import ATCTranscribe

/// WER parity with `server/engine.py:_word_error_rate` (values computed there). Pure
/// logic, so it runs in the Simulator suite. The same checks also run natively in
/// `ATCKitProbe` before the on-ANE proof-of-life.
final class WERTests: XCTestCase {
    func testMatchesPython() {
        XCTAssertEqual(WER.rate(reference: "one six right cleared to land Rex Sixty One Thirty Four",
                                hypothesis: "one six right cleared to land direct sixty one thirty four"),
                       0.0909090909, accuracy: 1e-6)                                                  // 1 of 11
        XCTAssertEqual(WER.rate(reference: "the tower cleared for takeoff",
                                hypothesis: "tower cleared for takeoff"), 0.0, accuracy: 0)            // article dropped
        XCTAssertEqual(WER.rate(reference: "thank you QNH is one zero two three",
                                hypothesis: "thank you qnh is one zero two three"), 0.0, accuracy: 0)  // case-insensitive
        XCTAssertEqual(WER.rate(reference: "roger", hypothesis: ""), 1.0, accuracy: 0)
        XCTAssertEqual(WER.rate(reference: "", hypothesis: "something"), 1.0, accuracy: 0)
        XCTAssertEqual(WER.rate(reference: "hotel echo xray", hypothesis: "hotel echo x-ray"), 0.0, accuracy: 0) // hyphen
    }
}
