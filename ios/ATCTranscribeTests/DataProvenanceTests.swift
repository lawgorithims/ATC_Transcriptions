import XCTest
@testable import ATCTranscribe

/// Data currency: aeronautical data expires, and an expired chart looks exactly as authoritative as a
/// current one. These pin the arithmetic behind the badge that says otherwise.
final class DataProvenanceTests: XCTestCase {

    private func d(_ iso: String) -> Date { DataProvenance.date(iso)! }

    private func prov(effective: String, expires: String) -> DataProvenance {
        DataProvenance(source: "test", cycle: "2607",
                       effective: d(effective), expires: d(expires), ingestedAt: nil)
    }

    func testCurrentWhileInsideTheCycle() {
        let p = prov(effective: "2026-07-09", expires: "2026-08-06")
        XCTAssertEqual(p.currency(asOf: d("2026-07-20")), .current)
    }

    func testExpiredOnTheExpiryDayItself() {
        // The expiry date is the first day the data is NOT valid — not the last day it is. The cycle
        // hands over at 0901Z on that date (see DataProvenance.cycleBoundary), so the check is against
        // that instant rather than the day after.
        let p = prov(effective: "2026-07-09", expires: "2026-08-06")
        XCTAssertTrue(p.currency(asOf: d("2026-08-06").addingTimeInterval(10 * 3600)).isExpired,
                      "data must be expired ON its expiry date, not the day after")
        XCTAssertFalse(p.currency(asOf: d("2026-08-05").addingTimeInterval(23 * 3600)).isExpired,
                       "and must not expire a day early")
    }

    func testWarnsInTheFinalWeek() {
        let p = prov(effective: "2026-07-09", expires: "2026-08-06")
        XCTAssertEqual(p.currency(asOf: d("2026-08-01")), .expiringSoon(days: 5))
        XCTAssertEqual(p.currency(asOf: d("2026-07-29")), .current,
                       "8 days out is outside the final-week warning and is simply current")
        XCTAssertEqual(p.currency(asOf: d("2026-07-30")), .expiringSoon(days: 7),
                       "the warning starts exactly 7 days out")
    }

    /// A dataset with no expiry must NOT read as reassuringly current.
    func testMissingExpiryIsUnknownNotCurrent() {
        let p = DataProvenance(source: "s", cycle: "", effective: nil, expires: nil, ingestedAt: nil)
        XCTAssertEqual(p.currency(asOf: d("2026-07-20")), .unknown)
        XCTAssertNotEqual(p.currency(asOf: d("2026-07-20")), .current)
        XCTAssertEqual(DataCurrency.unknown.label, "Undated")
    }

    /// A screen fusing several datasets is only as current as its stalest input.
    func testWorstOfSeveralDatasetsWins() {
        XCTAssertEqual(DataCurrency.worst([.current, .current]), .current)
        XCTAssertEqual(DataCurrency.worst([.current, .unknown]), .unknown)
        XCTAssertEqual(DataCurrency.worst([.current, .expiringSoon(days: 3)]), .expiringSoon(days: 3))
        XCTAssertTrue(DataCurrency.worst([.current, .unknown, .expiringSoon(days: 3),
                                          .expired(since: Date())]).isExpired,
                      "one expired source must dominate the combined badge")
        XCTAssertEqual(DataCurrency.worst([]), .unknown)
    }

    func testMalformedDatesAreRejectedRatherThanGuessed() {
        XCTAssertNil(DataProvenance.date(""))
        XCTAssertNil(DataProvenance.date("not-a-date"))
        XCTAssertNil(DataProvenance.date("2026-07"))
        XCTAssertNotNil(DataProvenance.date("2026-07-09T14:00:00Z"), "ISO date-time still parses")
    }

    func testMetaDictionaryRoundTrip() {
        let p = DataProvenance(meta: ["source": "FAA CIFP", "cycle": "2607",
                                      "effective": "2026-07-09", "expires": "2026-08-06",
                                      "ingested_at": "2026-07-25T14:20:50+00:00"])
        XCTAssertEqual(p.cycle, "2607")
        XCTAssertEqual(p.source, "FAA CIFP")
        XCTAssertNotNil(p.effective); XCTAssertNotNil(p.expires); XCTAssertNotNil(p.ingestedAt)
        XCTAssertTrue(p.summary.contains("2607"))
    }

    /// The shipped CIFP must actually carry its provenance — this is the constraint, not a nicety.
    func testShippedCIFPCarriesProvenance() {
        let p = CIFP.provenance
        XCTAssertFalse(p.cycle.isEmpty, "the bundled CIFP must record which cycle it is")
        XCTAssertNotNil(p.expires, "the bundled CIFP must record when it stops being valid")
        XCTAssertFalse(p.source.isEmpty)
    }

    /// The chart catalog publishes only a cycle date; expiry is the 56-day FAA raster cycle.
    func testChartCatalogExpiryIsDerivedFromItsCycle() {
        guard let eff = ChartCatalog.cycleDate("05-14-2026") else { return XCTFail("cycle unparsed") }
        let p = DataProvenance(source: "charts", cycle: "05-14-2026", effective: eff,
                               expires: eff.addingTimeInterval(56 * 24 * 3600), ingestedAt: nil)
        XCTAssertEqual(DataProvenance.iso(p.expires!), "2026-07-09",
                       "05-14 + 56 days is the published 07-09 expiry")
        XCTAssertTrue(p.currency(asOf: d("2026-07-25")).isExpired,
                      "the catalog the app downloads from today IS expired")
    }

    /// FAA cycles hand over at 0901Z, not at midnight. Measuring from UTC midnight turned the badge red
    /// nine hours early — and disagreed with the chart banner, which already anchors to 0901Z.
    func testTheCycleRollsOverAt0901ZNotAtMidnight() {
        let p = DataProvenance(source: "FAA CIFP", cycle: "2607", effective: d("2026-07-09"),
                               expires: d("2026-08-06"), ingestedAt: nil)
        XCTAssertFalse(p.currency(asOf: d("2026-08-06").addingTimeInterval(2 * 3600)).isExpired,
                       "0200Z on the boundary date is still legally current")
        XCTAssertTrue(p.currency(asOf: d("2026-08-06").addingTimeInterval(9 * 3600 + 120)).isExpired,
                      "past 0901Z the cycle has handed over")
    }

    /// The shipped CIFP is what the approach legs come from, so its currency is the one the Activate
    /// sheet's badge reports. It must be a real cycle with a real expiry, not an inferred one.
    func testShippedCIFPCycleAndExpiryAgree() {
        let p = CIFP.provenance
        XCTAssertEqual(p.cycle, "2607")
        XCTAssertEqual(p.effective.map(DataProvenance.iso), "2026-07-09")
        XCTAssertEqual(p.expires.map(DataProvenance.iso), "2026-08-06",
                       "28 days after the effective date — the next cycle's start")
    }
}
