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
}
