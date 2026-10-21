import XCTest
@testable import ATCTranscribe

/// Decoding the `next` block that makes pre-caching possible — and, more importantly, what happens
/// when it is malformed.
final class ChartCatalogStagedTests: XCTestCase {

    private func decode(_ json: String) throws -> ChartCatalog {
        try JSONDecoder().decode(ChartCatalog.self, from: Data(json.utf8))
    }

    private let liveOnly = """
    {"cycle":"09-03-2026",
     "sectional":[{"id":"Denver_SEC","bounds":[-109,39,-100,45],"bytes":10,"path":"c/09-03-2026/sectional/Denver_SEC.mbtiles"}],
     "ifrLow":[],"ifrHigh":[]}
    """

    func testAManifestWithNoStagedCycleStillDecodes() throws {
        let cat = try decode(liveOnly)
        XCTAssertEqual(cat.cycle, "09-03-2026")
        XCTAssertNil(cat.next, "no staged cycle is the ordinary state for half of every cycle")
    }

    func testTheStagedBlockDecodesWithItsOwnCycleAndDate() throws {
        let cat = try decode("""
        {"cycle":"09-03-2026","sectional":[],"ifrLow":[],"ifrHigh":[],
         "next":{"cycle":"10-29-2026","effective":"2026-10-29",
                 "sectional":[{"id":"Denver_SEC","bounds":[-109,39,-100,45],"bytes":20,
                               "path":"c/10-29-2026/sectional/Denver_SEC.mbtiles"}],
                 "ifrLow":[],"ifrHigh":[]}}
        """)
        XCTAssertEqual(cat.cycle, "09-03-2026", "the LIVE cycle is unchanged by staging")
        XCTAssertEqual(cat.next?.cycle, "10-29-2026")
        XCTAssertEqual(cat.next?.entries.count, 1)
        XCTAssertEqual(cat.next?.entries.first?.path,
                       "c/10-29-2026/sectional/Denver_SEC.mbtiles",
                       "a staged pack must live at its own path, not over the live cycle's bytes")
    }

    /// ⚠️ A BROKEN `next` MUST NOT BLANK THE MAP.
    ///
    /// With the synthesized initialiser, a `next` block that is present but unreadable throws out of
    /// the whole decode. `ChartLibrary.warm()` treats that as "no catalog", and a nil catalog means
    /// `ChartStore` draws no charts at all — while every pack sits on disk. A convenience feature
    /// would then be able to take the primary function of the app down, remotely, via a manifest the
    /// device does not control.
    func testAMalformedStagedBlockIsDroppedAndTheLiveCatalogSurvives() throws {
        let cat = try decode("""
        {"cycle":"09-03-2026",
         "sectional":[{"id":"Denver_SEC","bounds":[-109,39,-100,45],"bytes":10,"path":"a.mbtiles"}],
         "ifrLow":[],"ifrHigh":[],
         "next":{"cycle":"10-29-2026","sectional":"this should be an array"}}
        """)
        XCTAssertEqual(cat.cycle, "09-03-2026")
        XCTAssertEqual(cat.sectional.count, 1, "the live charts must still be there")
        XCTAssertNil(cat.next, "the unreadable staged block is simply ignored")
    }

    func testAStagedBlockMissingItsEffectiveDateIsIgnoredRatherThanGuessed() throws {
        // The date is required: the client's refusal to activate early is the only thing stopping a
        // pre-cached chart being flown before it is legal, and deriving the date from the cycle string
        // would make the publisher's claim unfalsifiable.
        let cat = try decode("""
        {"cycle":"09-03-2026","sectional":[],"ifrLow":[],"ifrHigh":[],
         "next":{"cycle":"10-29-2026","sectional":[],"ifrLow":[],"ifrHigh":[]}}
        """)
        XCTAssertNil(cat.next)
    }

    // MARK: The 0901Z boundary

    func testIsInForceUsesTheFAACutoverNotLocalMidnight() throws {
        let cat = try decode("""
        {"cycle":"09-03-2026","sectional":[],"ifrLow":[],"ifrHigh":[],
         "next":{"cycle":"10-29-2026","effective":"2026-10-29",
                 "sectional":[],"ifrLow":[],"ifrHigh":[]}}
        """)
        let staged = try XCTUnwrap(cat.next)
        let eff = try XCTUnwrap(staged.effectiveDate)

        XCTAssertFalse(staged.isInForce(asOf: eff.addingTimeInterval(-1)),
                       "the day before is not in force")
        XCTAssertFalse(staged.isInForce(asOf: eff.addingTimeInterval(9 * 3600)),
                       "0900Z on the effective date is one minute early")
        XCTAssertTrue(staged.isInForce(asOf: eff.addingTimeInterval(9 * 3600 + 61)),
                      "0901Z is the cutover")
    }

    /// An undateable staged block reports NOT in force, forever. That is the safe direction: it means
    /// the pre-cache ignores it, rather than treating an unparseable date as permission.
    func testAnUnparseableEffectiveDateIsNeverInForce() throws {
        let cat = try decode("""
        {"cycle":"09-03-2026","sectional":[],"ifrLow":[],"ifrHigh":[],
         "next":{"cycle":"10-29-2026","effective":"next Tuesday",
                 "sectional":[],"ifrLow":[],"ifrHigh":[]}}
        """)
        let staged = try XCTUnwrap(cat.next)
        XCTAssertNil(staged.effectiveDate)
        XCTAssertFalse(staged.isInForce(asOf: Date(timeIntervalSince1970: 4_000_000_000)))
    }
}
