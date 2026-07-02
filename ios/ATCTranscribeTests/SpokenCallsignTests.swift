import XCTest
@testable import ATCTranscribe

/// BB1: expanding an ADS-B callsign/registration CODE into the spoken ATC form used to bias the
/// Whisper decoder prompt.
final class SpokenCallsignTests: XCTestCase {
    private let kb = ATCKnowledgeBase(
        airlineTelephony: ["JBU": "JetBlue", "AAL": "American", "DAL": "Delta", "SWA": "Southwest"],
        spokenNamesByAirport: [:], spokenBaseByAirport: [:],
        phrasesByType: [:], spellingByType: [:],
        phonetic: ["N": "November", "A": "Alpha", "B": "Bravo"], digits: [:])

    private func spoken(_ code: String) -> String { ATCContext.spokenCallsign(code, knowledge: kb) }

    func testAirlineCallsignUsesTelephonyPlusSpokenDigits() {
        XCTAssertEqual(spoken("JBU1234"), "jetblue one two three four")
        XCTAssertEqual(spoken("AAL2490"), "american two four nine zero")
        XCTAssertEqual(spoken("SWA1310"), "southwest one three one zero")
    }

    func testTailNumberSpelledPhonetically() {
        XCTAssertEqual(spoken("N123AB"), "november one two three alpha bravo")
    }

    func testUnknownAirlineIsSpelledOut() {
        // No telephony for "XYZ" → spell every character (phonetic where known, else the bare letter).
        XCTAssertEqual(spoken("XYZ12"), "x y z one two")
    }

    func testShortAndEmptyCodes() {
        XCTAssertEqual(spoken(""), "")
        XCTAssertEqual(spoken("N1"), "november one")   // too short for the airline branch → spelled
        XCTAssertEqual(spoken("  DAL 89 "), "delta eight nine")   // punctuation/space stripped
    }
}
