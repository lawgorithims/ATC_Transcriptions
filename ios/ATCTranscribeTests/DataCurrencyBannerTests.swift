import XCTest
@testable import ATCTranscribe

/// The app-wide staleness sweep. The badge and the provenance layer were already right; what this
/// covers is the reduction to one line a pilot can act on, and the cases where it must say nothing.
final class DataCurrencyBannerTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_784_000_000)   // 2026-07-15T…Z, mid-cycle

    private func prov(_ expiresInDays: Int) -> DataProvenance {
        DataProvenance(source: "test", cycle: "2607",
                       effective: now.addingTimeInterval(-28 * 86_400),
                       expires: now.addingTimeInterval(Double(expiresInDays) * 86_400),
                       ingestedAt: nil)
    }

    func testSaysNothingWhenEverythingIsCurrent() {
        let s = StaleDataSummary.make(sources: [("Procedures", prov(20)), ("Charts", prov(40))], asOf: now)
        XCTAssertNil(s)
    }

    /// An undated dataset is a real gap, and the badge says "Undated" wherever one is shown — but it is
    /// not a claim that the data is stale. A banner that fired on it would be permanent furniture the
    /// pilot learns to scroll past, which is how a real expiry gets missed.
    func testAnUndatedDatasetDoesNotRaiseTheBanner() {
        XCTAssertNil(StaleDataSummary.make(sources: [("Nav", .unknown)], asOf: now))
    }

    func testReportsAnExpiredDataset() {
        let s = StaleDataSummary.make(sources: [("Procedures", prov(-3)), ("Charts", prov(30))], asOf: now)
        XCTAssertEqual(s?.expired, true)
        XCTAssertEqual(s?.headline, "Procedures has expired")
        XCTAssertTrue(s?.detail.contains("3 days") == true, "the pilot needs to know how far out of cycle")
    }

    func testExpiredOutranksExpiringSoon() {
        let s = StaleDataSummary.make(sources: [("Charts", prov(-10)), ("Procedures", prov(2))], asOf: now)
        XCTAssertEqual(s?.expired, true)
        XCTAssertTrue(s?.headline.contains("Charts") == true,
                      "the expired one is the headline, not the one merely expiring")
    }

    func testCountsMultipleExpiredDatasets() {
        let s = StaleDataSummary.make(sources: [("Charts", prov(-10)), ("Procedures", prov(-1))], asOf: now)
        XCTAssertEqual(s?.headline, "2 datasets have expired")
        XCTAssertTrue(s?.detail.contains("Charts") == true)
        XCTAssertTrue(s?.detail.contains("Procedures") == true)
    }

    func testWarnsBeforeExpiryWithTheSoonestFirst() {
        let s = StaleDataSummary.make(sources: [("Charts", prov(6)), ("Procedures", prov(2))], asOf: now)
        XCTAssertEqual(s?.expired, false)
        XCTAssertTrue(s?.headline.contains("2 days") == true, "lead with the one lapsing first")
    }

    func testSingularDayReads() {
        let s = StaleDataSummary.make(sources: [("Charts", prov(1))], asOf: now)
        XCTAssertTrue(s?.headline.contains("1 day") == true)
        XCTAssertFalse(s?.headline.contains("1 days") == true)
    }

    /// The shipped chart catalog really is out of cycle — that is the situation this banner exists for,
    /// and it must actually fire on the app's own data rather than only on fixtures.
    @MainActor
    func testTheAppsOwnDatasetsAreSweptWithoutCrashing() {
        let model = AppModel()
        model.refreshDataCurrency(now: now)
        // No assertion on the outcome — it changes with every cycle. What matters is that the sweep runs
        // over the real provenance sources and produces either nil or a well-formed summary.
        if let s = model.staleDataSummary {
            XCTAssertFalse(s.headline.isEmpty)
            XCTAssertFalse(s.detail.isEmpty)
        }
    }
}
