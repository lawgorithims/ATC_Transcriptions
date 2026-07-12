import XCTest
@testable import ATCTranscribe

/// Encodes the behavior of `atc_context.py`: empty when there's nothing, rolling
/// 3-deep history, and the static prefix / vocab built from an airport config.
final class ATCContextTests: XCTestCase {

    func testEmptyContextIsEmptyPrompt() {
        XCTAssertEqual(ATCContext().buildPrompt(), "")
    }

    func testHistoryRollsAtThree() {
        let ctx = ATCContext()
        ctx.update("one"); ctx.update("two"); ctx.update("three"); ctx.update("four")
        XCTAssertEqual(ctx.recentHistory, ["two", "three", "four"])
        XCTAssertEqual(ctx.buildPrompt(), "Recent transmissions: two three four")
    }

    func testBlankUpdatesIgnored() {
        let ctx = ATCContext()
        ctx.update("   "); ctx.update("")
        XCTAssertEqual(ctx.recentHistory, [])
    }

    /// Phase 3: the route's plate priming biases the decode prompt and informs the LLM block, but is
    /// deliberately NOT added to the corrector's snap-vocab (C1 — a large OCR-derived route-wide fix set
    /// in the allow-set would let the LLM rewrite a correctly-heard word onto a fabricated chart fix).
    func testPlatePrimingBiasesDecodeAndInformsLLMButNotSnapVocab() {
        let ctx = ATCContext()
        ctx.setPlatePriming(promptLine: "Chart fixes: WAXEN, IRSEW.",
                            block: "Charts for KBOS: frequencies 118.25; fixes WAXEN, IRSEW.")
        XCTAssertTrue(ctx.buildPrompt().contains("Chart fixes: WAXEN, IRSEW."), "decode bias includes chart fixes")
        let k = ctx.retrieveKnowledge(for: "cleared direct waxen")
        XCTAssertTrue(k.block.contains("Charts for KBOS"), "LLM block carries the chart priming")
        XCTAssertFalse(k.vocab.contains("WAXEN"), "chart fixes must NOT enter the validator snap-vocab (C1)")

        ctx.setPlatePriming(promptLine: "", block: "")
        XCTAssertEqual(ctx.buildPrompt(), "", "cleared priming leaves an empty prompt")
        XCTAssertFalse(ctx.retrieveKnowledge(for: "x").block.contains("Charts for KBOS"))
    }

    func testStaticPrefixAndVocabFromConfig() throws {
        // Inline config avoids unit-test bundle-resource lookup; exercises the same
        // decode + prefix path the app uses with airport_configs/*.json.
        let json = """
        {
          "airport_code": "KDFW",
          "airport_name": "Dallas/Fort Worth International Airport",
          "tracon": "Lone Star Approach / Departure (D10)",
          "runways": ["17C", "35C"],
          "fixes": ["AKUNA", "BLECO"],
          "streams": {
            "f": { "label": "Lone Star Approach (17/35C Final)", "frequency_mhz": "127.075" }
          }
        }
        """
        let cfg = try AirportConfig.decode(Data(json.utf8))
        // Inject an empty knowledge base so the enriched vocab is exactly the local config terms
        // (with the real KB it would also include airline callsigns / facility names).
        let ctx = ATCContext(config: cfg, feedKey: "f", knowledge: .empty)

        let prompt = ctx.buildPrompt()
        XCTAssertTrue(prompt.contains("Air traffic control radio transcript from Lone Star Approach (17/35C Final)."))
        XCTAssertTrue(prompt.contains("Airport: Dallas/Fort Worth International Airport."))
        XCTAssertTrue(prompt.contains("Facility: Lone Star Approach / Departure (D10)."))
        XCTAssertTrue(prompt.contains("Frequency: 127.075 MHz."))
        XCTAssertTrue(prompt.contains("Runways: 17C, 35C."))
        XCTAssertTrue(prompt.contains("Fixes: AKUNA, BLECO."))
        XCTAssertEqual(ctx.vocab(), ["17C", "35C", "AKUNA", "BLECO"])
    }

    func testHistoryAppendsAfterStaticPrefix() throws {
        let json = #"{"airport_name":"Test","streams":{"f":{"label":"Test Feed"}}}"#
        let cfg = try AirportConfig.decode(Data(json.utf8))
        let ctx = ATCContext(config: cfg, feedKey: "f")
        ctx.update("cleared to land")
        let prompt = ctx.buildPrompt()
        XCTAssertTrue(prompt.hasPrefix("Air traffic control radio transcript from Test Feed."))
        XCTAssertTrue(prompt.hasSuffix("Recent transmissions: cleared to land"))
    }
}
