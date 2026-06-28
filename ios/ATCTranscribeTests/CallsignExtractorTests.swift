import XCTest
@testable import ATCTranscribe

/// `CallsignExtractor` — the canonical callsign per transmission that groups an aircraft's
/// conversation (and cross-references the ADS-B feed).
final class CallsignExtractorTests: XCTestCase {

    private let kb = ATCKnowledgeBase(
        airlineTelephony: ["AAL": "American", "JBU": "JetBlue", "DAL": "Delta", "ACA": "Air Canada",
                           "SWA": "Southwest", "EZY": "Easy"],
        spokenNamesByAirport: [:], spokenBaseByAirport: [:], phrasesByType: [:], spellingByType: [:],
        phonetic: ["A": "alpha", "B": "bravo", "C": "charlie", "M": "mike", "N": "november", "W": "whiskey"],
        digits: [:])

    private func cs(_ text: String) -> CallsignExtractor.Callsign? {
        CallsignExtractor.extract(text, knowledge: kb)
    }

    func testAirlineGroupedNumber() {
        let c = cs("american twelve thirty four cleared to land runway one seven center")
        XCTAssertEqual(c?.display, "American 1234")
        XCTAssertEqual(c?.icaoKey, "AAL1234")
    }

    func testAirlineMidSentence() {
        // Callsign need not lead the transmission.
        XCTAssertEqual(cs("cleared to land delta eight ninety")?.display, "Delta 890")
        XCTAssertEqual(cs("cleared to land delta eight ninety")?.icaoKey, "DAL890")
    }

    func testMultiWordAirline() {
        let c = cs("air canada eight seventy five contact ground")
        XCTAssertEqual(c?.display, "Air Canada 875")
        XCTAssertEqual(c?.icaoKey, "ACA875")
    }

    func testGASpelledTail() {
        let c = cs("november three four five alpha bravo hold short runway one seven center")
        XCTAssertEqual(c?.display, "N345AB")
        XCTAssertEqual(c?.icaoKey, "N345AB")
    }

    func testGALiteralTail() {
        XCTAssertEqual(cs("N9133M cleared for takeoff")?.display, "N9133M")
    }

    func testNoCallsign() {
        XCTAssertNil(cs("cleared to land runway one seven center"))
        XCTAssertNil(cs("contact ground point niner"))
    }

    func testStableAcrossPhrasingForGrouping() {
        // The same aircraft yields the SAME display key in different transmissions, so they group.
        XCTAssertEqual(cs("american twelve thirty four turn left heading one eight zero")?.display,
                       cs("roger american twelve thirty four")?.display)
    }

    func testGreedyDigitFusionSameKeyAcrossPhrasing() {
        // normalizeNumbers may split an ambiguous run ("fifty six six eighteen" -> "56 6 18"); the
        // extractor must re-fuse so a split phrasing and a digit-by-digit one give the SAME key.
        let split = cs("american fifty six six eighteen cleared to land")
        let byDigit = cs("american five six six one eight cleared to land")
        XCTAssertEqual(split?.icaoKey, "AAL56618")
        XCTAssertEqual(split?.icaoKey, byDigit?.icaoKey)
    }

    func testEnglishWordTelephonyDoesNotMisfire() {
        // "Easy" (EZY) is a telephony name AND an ordinary word; a single trailing digit must not
        // synthesize a callsign on an instruction with no aircraft.
        XCTAssertNil(cs("climb easy three thousand"))
    }

    func testTrafficAdvisoryPicksAddressedAircraft() {
        // The addressed aircraft's callsign precedes the instruction word, not the leading traffic.
        let c = cs("traffic delta eight ninety southwest twelve thirty four cleared to land")
        XCTAssertEqual(c?.display, "Southwest 1234")
    }

    func testBareNovemberDoesNotFabricateTail() {
        XCTAssertNil(cs("november five seven contact tower"))          // 2 digits, no letter → reject
        XCTAssertEqual(cs("november one two three contact")?.display, "N123")   // ≥3 digits → accept
    }
}
