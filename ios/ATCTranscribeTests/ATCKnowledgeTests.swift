import XCTest
@testable import ATCTranscribe

/// Covers the RAG corpus + retriever: frequency-type mapping, phrase/spoken-name lookup, and
/// the lexical retrieval that feeds the LLM (callsign retrieval, enriched vocab, language flag).
final class ATCKnowledgeTests: XCTestCase {

    private func kb() -> ATCKnowledgeBase {
        ATCKnowledgeBase(
            airlineTelephony: ["DAL": "Delta", "SKW": "SkyWest", "AAL": "American", "ACA": "Air Canada"],
            spokenNamesByAirport: ["KJFK": ["Kennedy", "New York"]],
            spokenBaseByAirport: ["KORD": "Chicago"],
            phrasesByType: ["tower": ["cleared to land", "line up and wait"], "unknown": ["contact tower"]],
            spellingByType: ["tower": ["niner", "fife", "squawk"], "unknown": ["niner"]],
            phonetic: ["A": "alpha"], digits: ["9": "niner"])
    }

    private func config() -> AirportConfig {
        let json = """
        {"airport_code":"KJFK","runways":["4L","22R","13L"],"fixes":["CANUK","LENDY"],
         "taxiways":["A","B"],"streams":{"kennedy_tower":{"label":"Kennedy Tower"}}}
        """
        return try! AirportConfig.decode(Data(json.utf8))
    }

    // MARK: knowledge base

    func testFrequencyTypeMapping() {
        XCTAssertEqual(frequencyType(forFeedKey: "lone_star_approach_17c_final"), "approach")
        XCTAssertEqual(frequencyType(forFeedKey: "tower_east"), "tower")
        XCTAssertEqual(frequencyType(forFeedKey: "ground_west"), "ground")
        XCTAssertEqual(frequencyType(forFeedKey: "clearance_delivery"), "clearance")
        XCTAssertEqual(frequencyType(forFeedKey: nil), "unknown")
    }

    func testPhrasesFallBackToUnknown() {
        XCTAssertEqual(kb().phrases(forType: "center"), ["contact tower"])  // undefined -> unknown set
        XCTAssertEqual(kb().phrases(forType: "tower").first, "cleared to land")
    }

    func testSpokenNames() {
        XCTAssertEqual(kb().spokenNames(forAirport: "kjfk"), ["Kennedy", "New York"])
        XCTAssertEqual(kb().spokenNames(forAirport: "KORD"), ["Chicago"])  // falls back to base
        XCTAssertTrue(kb().spokenNames(forAirport: "KXXX").isEmpty)
    }

    // MARK: retriever

    func testRetrievalIncludesRunwaysAndCallsign() {
        let r = ATCKnowledgeRetriever(kb: kb(), config: config(), feedKey: "kennedy_tower")
        let ctx = r.retrieve(transcript: "delta eight ninety cleared to land runway four left", history: [])
        XCTAssertTrue(ctx.block.contains("Runways"))
        XCTAssertTrue(ctx.block.contains("4L"))
        XCTAssertTrue(ctx.block.contains("Delta"))   // the "delta" token retrieves the Delta callsign
        XCTAssertTrue(ctx.block.contains("Kennedy")) // facility name for KJFK
        XCTAssertFalse(ctx.languageSuspect)
    }

    func testEnrichedVocabAddsTaxiwaysAndSingleWordCallsigns() {
        let v = ATCKnowledgeRetriever(kb: kb(), config: config(), feedKey: "kennedy_tower").enrichedVocab()
        XCTAssertTrue(v.contains("4L"))
        XCTAssertTrue(v.contains("A"))            // taxiway
        XCTAssertTrue(v.contains("Delta"))        // single-word telephony
        XCTAssertFalse(v.contains("Air Canada"))  // multi-word excluded (per-token matcher)
    }

    func testLanguageSuspectFlagsNonEnglish() {
        let r = ATCKnowledgeRetriever(kb: kb(), config: nil, feedKey: nil)
        XCTAssertTrue(r.retrieve(transcript: "привет вышка добрый экипаж", history: []).languageSuspect)
        XCTAssertFalse(r.retrieve(transcript: "cleared to land runway four left", history: []).languageSuspect)
    }
}
