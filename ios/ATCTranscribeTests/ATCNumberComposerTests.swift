import XCTest
@testable import ATCTranscribe

/// The spoken-number magnitude composer. Input is the pipeline's normalized single-digit token stream
/// plus the surviving magnitude words (hundred/thousand/flight/level/point).
final class ATCNumberComposerTests: XCTestCase {

    private func toks(_ s: String) -> [String] { s.split(separator: " ").map(String.init) }

    // MARK: altitude

    func testAltitudeThousand() {
        let r = ATCNumberComposer.composeAltitude(toks("8 thousand"), from: 0)
        XCTAssertEqual(r?.text, "8000"); XCTAssertEqual(r?.value, 8000)
    }

    func testAltitudeThousandAndHundred() {
        let r = ATCNumberComposer.composeAltitude(toks("8 thousand 5 hundred"), from: 0)
        XCTAssertEqual(r?.value, 8500)
    }

    func testAltitudeElevenThousand() {
        XCTAssertEqual(ATCNumberComposer.composeAltitude(toks("1 1 thousand"), from: 0)?.value, 11000)
    }

    func testAltitudeHundred() {
        XCTAssertEqual(ATCNumberComposer.composeAltitude(toks("5 hundred"), from: 0)?.value, 500)
    }

    func testAltitudeFlightLevel() {
        let r = ATCNumberComposer.composeAltitude(toks("flight level 1 8 0"), from: 0)
        XCTAssertEqual(r?.text, "FL180"); XCTAssertEqual(r?.value, 18000)
    }

    func testAltitudeBareDigits() {
        XCTAssertEqual(ATCNumberComposer.composeAltitude(toks("3 0 0 0"), from: 0)?.value, 3000)
    }

    func testAltitudeRejectsOutOfRange() {
        XCTAssertNil(ATCNumberComposer.composeAltitude(toks("9 9 thousand"), from: 0), "99000 > 60000")
    }

    // MARK: heading / speed / squawk / frequency

    func testHeadingKeepsLeadingZero() {
        let r = ATCNumberComposer.composeHeading(toks("0 9 0"), from: 0)
        XCTAssertEqual(r?.text, "090"); XCTAssertEqual(r?.value, 90)
    }

    func testHeadingRejectsOver360() {
        XCTAssertNil(ATCNumberComposer.composeHeading(toks("4 0 0"), from: 0))
    }

    func testHeading360IsValid() {
        XCTAssertEqual(ATCNumberComposer.composeHeading(toks("3 6 0"), from: 0)?.value, 360)
    }

    func testSpeedInBand() {
        XCTAssertEqual(ATCNumberComposer.composeSpeed(toks("2 5 0"), from: 0)?.value, 250)
    }

    func testSpeedRejectsTooSlow() {
        XCTAssertNil(ATCNumberComposer.composeSpeed(toks("3 0"), from: 0), "30 kt < 40 floor")
    }

    func testSquawkFourOctalDigits() {
        let r = ATCNumberComposer.composeSquawk(toks("1 2 0 0"), from: 0)
        XCTAssertEqual(r?.text, "1200"); XCTAssertEqual(r?.value, 1200)
    }

    func testSquawkRejectsNonOctal() {
        XCTAssertNil(ATCNumberComposer.composeSquawk(toks("1 2 8 0"), from: 0), "8 is not a transponder digit")
    }

    func testSquawkRejectsWrongLength() {
        XCTAssertNil(ATCNumberComposer.composeSquawk(toks("1 2 3"), from: 0))
    }

    func testFrequencyWithPoint() {
        let r = ATCNumberComposer.composeFrequency(toks("1 2 4 point 5"), from: 0)
        XCTAssertEqual(r?.text, "124.5"); XCTAssertEqual(r?.mhz ?? 0, 124.5, accuracy: 0.001)
    }

    func testFrequencyPointless() {
        XCTAssertEqual(ATCNumberComposer.composeFrequency(toks("1 1 9 5"), from: 0)?.text, "119.5")
    }

    func testFrequencyRejectsOutOfBand() {
        XCTAssertNil(ATCNumberComposer.composeFrequency(toks("2 4 4 point 0"), from: 0), "244 MHz is not VHF COM")
    }
}
