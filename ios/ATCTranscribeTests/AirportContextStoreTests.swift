import XCTest
@testable import ATCTranscribe

/// The airport-context provider chain: bundled nationwide table, curated-config overlay,
/// designator parsing, and the CSV plumbing of the internet fallback.
final class AirportContextStoreTests: XCTestCase {

    func testBundledTableLoadsAndCoversMajors() {
        XCTAssertGreaterThan(BundledAirportContextSource.count, 10_000,
                             "airport_ctx.json missing or truncated")
        let dfw = BundledAirportContextSource.lookup("KDFW")
        XCTAssertNotNil(dfw)
        XCTAssertTrue(dfw?.runways.contains("17C") == true)
        XCTAssertFalse(dfw?.frequencyValues.isEmpty ?? true)
        // every bundled frequency is airband by construction
        XCTAssertTrue(dfw!.frequencyValues.allSatisfy { (118.0...136.975).contains($0) })
    }

    func testBundledLookupIsCaseAndWhitespaceTolerant() {
        XCTAssertEqual(BundledAirportContextSource.lookup(" kdfw ")?.ident, "KDFW")
        XCTAssertNil(BundledAirportContextSource.lookup("XXXX9"))
    }

    func testCompositePrefersCuratedThenFillsFromBundled() async {
        // KDFW has a curated config (runways + per-feed frequencies) — the chain must answer.
        let store = AirportContextStore(sources: [CuratedAirportContextSource(),
                                                  BundledAirportContextSource()])
        let ctx = await store.airport("KDFW")
        XCTAssertNotNil(ctx)
        XCTAssertTrue(ctx!.runways.contains("35C"))
        XCTAssertFalse(ctx!.frequencies.isEmpty)
        // An airport with no curated config still resolves through the bundled table.
        let bna = await store.airport("KBNA")
        XCTAssertTrue(bna?.runways.contains("31") == true)
    }

    func testParseDesignator() {
        XCTAssertEqual(SlotSnap.parseDesignator("17C").num, "17")
        XCTAssertEqual(SlotSnap.parseDesignator("17C").suffix, "C")
        XCTAssertEqual(SlotSnap.parseDesignator("02L").num, "2")
        XCTAssertEqual(SlotSnap.parseDesignator("22").suffix, "")
        XCTAssertEqual(SlotSnap.parseDesignator("H1").num, "", "helipad designators are ignored")
    }

    func testCSVRowSplitterHandlesQuotedCommas() {
        let row = NetworkAirportContextSource.splitCSVRow(
            #"123,"KDFW","Dallas/Fort Worth, TX",1,"17C""#)
        XCTAssertEqual(row[2], "Dallas/Fort Worth, TX")
        XCTAssertEqual(row[4], "17C")
    }

    // MARK: - Phase 3: CIFP grounding (fixes + ILS freqs → SlotSnap + provider chain)

    private func groundCtx(fixes: [String] = [], nav: [Double] = [],
                           runways: [String] = [], freqs: [String: [Double]] = [:]) -> AirportContextData {
        AirportContextData(ident: "KBOS", runways: runways, frequencies: freqs,
                           fixes: fixes, navFrequencies: nav)
    }

    // fix slot — snapping
    func testFixSlotSnapsMisheardDirectTo() {
        let (text, edits) = SlotSnap.apply("cleared direct bossox", context: groundCtx(fixes: ["BOSOX", "CRLTN"]))
        XCTAssertTrue(text.contains("direct bosox"), "misheard fix snapped to the real one: \(text)")
        XCTAssertTrue(edits.contains { $0.slot == "fix" && $0.verdict == "snapped" && $0.snapped == "bosox" })
    }

    func testFixSlotVerifiesExactFix() {
        let (text, edits) = SlotSnap.apply("hold at crltn", context: groundCtx(fixes: ["CRLTN"]))
        XCTAssertTrue(text.contains("hold at crltn"), "an exact fix is left as-is: \(text)")
        XCTAssertTrue(edits.contains { $0.slot == "fix" && $0.verdict == "verified" })
    }

    // fix slot — the false-positive guards (the whole point of the conservatism)
    func testFixSlotNeverTouchesStopwords() {
        // "hold short" must NEVER snap "short" onto a look-alike fix, even one spelled identically.
        let (text, edits) = SlotSnap.apply("hold short runway 4 right",
                                           context: groundCtx(fixes: ["SHORE", "SHORT"], runways: ["4R"]))
        XCTAssertTrue(text.contains("hold short"), "stopword after an anchor is protected: \(text)")
        XCTAssertFalse(edits.contains { $0.slot == "fix" }, "no fix edit is even recorded for a stopword")
    }

    func testFixSlotAbstainsWhenAmbiguous() {
        // two fixes each edit-1 from the heard token → abstain, leave as heard.
        let (text, edits) = SlotSnap.apply("direct bosix", context: groundCtx(fixes: ["BOSOX", "BOSEX"]))
        XCTAssertTrue(text.contains("direct bosix"), "ambiguous fix is not rewritten: \(text)")
        XCTAssertFalse(edits.contains { $0.slot == "fix" && $0.verdict == "snapped" })
    }

    func testFixSlotIgnoresTokensBelowFloor() {
        // a token that isn't an exact fix and is <5 chars never snaps (would over-trigger on chatter).
        let (text, edits) = SlotSnap.apply("direct funk", context: groundCtx(fixes: ["FUNKY"]))
        XCTAssertTrue(text.contains("direct funk"), "sub-floor token left as heard: \(text)")
        XCTAssertFalse(edits.contains { $0.slot == "fix" && $0.verdict == "snapped" })
    }

    func testNoFixesNoFixEdits() {
        let (_, edits) = SlotSnap.apply("cleared direct bossox", context: groundCtx(fixes: []))
        XCTAssertFalse(edits.contains { $0.slot == "fix" }, "fix slot is inert without fix data")
    }

    // fix slot — false-positive regressions the adversarial review found (verified vs real cifp.sqlite)
    func testFixSlotIgnoresWeakOverCrossAnchors() {
        // "over"/"cross" precede landmarks far more than fixes — they are NOT anchors, so "cross the
        // river" must never become "cross the rivet" (RIVET is a real KDFW fix at edit-1 from "river").
        let c = groundCtx(fixes: ["RIVET", "FIEND", "REVER"])
        XCTAssertTrue(SlotSnap.apply("cross the river", context: c).text.contains("cross the river"))
        XCTAssertTrue(SlotSnap.apply("over the field", context: c).text.contains("over the field"))
        XCTAssertFalse(SlotSnap.apply("cross the river", context: c).edits.contains { $0.slot == "fix" && $0.verdict == "snapped" })
    }

    func testFixSlotProtectsIlsAndLandmarkPhraseology() {
        // even after a real anchor, standard phraseology nouns are stoplisted (outer marker, the river).
        XCTAssertTrue(SlotSnap.apply("hold the outer marker", context: groundCtx(fixes: ["OUTTR"])).text.contains("outer"))
        XCTAssertTrue(SlotSnap.apply("hold the river", context: groundCtx(fixes: ["RIVET"])).text.contains("hold the river"))
    }

    func testFrequencyNeverSnapsAcrossBands() {
        // airband 126.3 heard; its only edit-1 neighbor is a nav/ILS 116.3 — must NOT snap across 118 MHz.
        let (text, edits) = SlotSnap.apply("contact tower one two six point three", context: groundCtx(nav: [116.3]))
        XCTAssertFalse(edits.contains { $0.slot == "frequency" && $0.verdict == "snapped" },
                       "no cross-band comms→ILS rewrite: \(text)")
    }

    // ILS / localizer nav-band frequency
    func testILSFrequencySnapsInNavBand() {
        let (text, edits) = SlotSnap.apply("contact localizer one zero nine point five",
                                           context: groundCtx(nav: [109.30]))
        XCTAssertTrue(edits.contains { $0.slot == "frequency" && $0.verdict == "snapped" },
                      "ILS near-miss snapped: \(text) / \(edits)")
    }

    // CIFP airport-context source + chain
    func testCIFPSourceProvidesFixesAndILS() throws {
        try XCTSkipIf(CIFP.procedureCount == 0, "cifp.sqlite not bundled in the test host")
        let data = CIFPAirportContextSource.lookup("KBOS")
        XCTAssertNotNil(data)
        XCTAssertFalse(data?.fixes.isEmpty ?? true, "KBOS has coded-procedure fixes")
        XCTAssertTrue(data!.navFrequencies.allSatisfy { (108.0...112.0).contains($0) }, "ILS freqs in band")
        XCTAssertNil(CIFPAirportContextSource.lookup("ZZZZ"), "unknown airport → nil")
    }

    func testChainMergesCIFPFixesWithBundledRunways() async throws {
        try XCTSkipIf(CIFP.procedureCount == 0 || BundledAirportContextSource.count == 0, "bundles missing")
        let store = AirportContextStore(sources: [CIFPAirportContextSource(), BundledAirportContextSource()])
        let ctx = await store.airport("KBOS")
        XCTAssertFalse(ctx?.fixes.isEmpty ?? true, "fixes come from CIFP (first in chain)")
        XCTAssertFalse(ctx?.runways.isEmpty ?? true, "runways filled from the bundled table")
    }
}
