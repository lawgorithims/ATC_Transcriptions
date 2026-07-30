import XCTest
@testable import ATCTranscribe

/// Winds-aloft service lifecycle driven by a fake fetcher: the enable edge fetches, a 404 walks back to an
/// older cycle, a transport failure keeps the last good field set, a pan outside the covered box refetches
/// while a small pan does not, and the disk snapshot round-trips.
@MainActor
final class WindAloftServiceTests: XCTestCase {

    private var cacheDir: URL!
    private var grib: Data!

    /// 2026-07-29 15:00Z. Two things depend on this exact value: the newest six-hourly cycle is 12z so
    /// the natural forecast hour is +3, and it equals the fixture's own valid time (06z +9h), so the held
    /// field set is not stale and the staleness path never masks the geometry tests.
    private let clock = Date(timeIntervalSince1970: 1_785_337_200)

    override func setUpWithError() throws {
        cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wind-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "wind_fixture", withExtension: "grib2"))
        grib = try Data(contentsOf: url)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: cacheDir)
    }

    /// Records every URL requested and answers from a script keyed on the call index, so nothing
    /// main-actor-isolated is captured in the `@Sendable` fetch closure.
    private final class FakeFetcher: WindGribFetching, @unchecked Sendable {
        /// How the Nth call behaves.
        enum Answer: Sendable { case grib, notFound, transportError }

        private let lock = NSLock()
        private var urls: [URL] = []
        private let payload: Data
        private let script: [Answer]
        private let fallback: Answer

        init(payload: Data, script: [Answer] = [], fallback: Answer = .grib) {
            self.payload = payload
            self.script = script
            self.fallback = fallback
        }

        func fetch(_ url: URL) async throws -> Data {
            let n = lock.withLock { urls.append(url); return urls.count - 1 }
            switch n < script.count ? script[n] : fallback {
            case .grib:           return payload
            case .notFound:       throw WindFetchError.notFound
            case .transportError: throw WindFetchError.badResponse
            }
        }

        var requested: [URL] { lock.withLock { urls } }
    }

    /// A clock the test can move. Lock-protected because the service reads it from its fetch task.
    private final class MovableClock: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Date
        init(_ d: Date) { stored = d }
        var value: Date {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    private func service(_ fetcher: WindGribFetching) -> WindAloftService {
        WindAloftService(fetcher: fetcher, now: { [clock] in clock }, cacheDirectory: cacheDir)
    }

    /// Let the service's detached decode and its main-actor hop finish. The decode is real work on a real
    /// payload, so this polls rather than sleeping a fixed interval.
    private func settle(_ svc: WindAloftService, until: @escaping (WindAloftService) -> Bool) async {
        for _ in 0..<80 {                                  // bounded: ≤ 4 s
            if until(svc) { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    // MARK: lifecycle

    func testEnableEdgeFetchesAndPublishes() async {
        let fetcher = FakeFetcher(payload: grib)
        let svc = service(fetcher)
        XCTAssertNil(svc.fieldSet)
        svc.setEnabled(true)
        await settle(svc) { $0.fieldSet != nil }
        XCTAssertNotNil(svc.fieldSet, "the enable edge must fetch")
        XCTAssertEqual(svc.fieldSet?.field(.mb850)?.ni, 281)
        XCTAssertFalse(svc.failed)
        XCTAssertEqual(fetcher.requested.count, 1)
        svc.setEnabled(false)
        XCTAssertNotNil(svc.fieldSet, "disabling keeps the data so re-enabling is instant")
    }

    func testDisabledDoesNotFetch() async {
        let fetcher = FakeFetcher(payload: grib)
        let svc = service(fetcher)
        svc.viewportChanged(RadarRegion(centerLat: 35, centerLon: -95, latSpan: 6, lonSpan: 10))
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(fetcher.requested.isEmpty, "a viewport change with the layer off must not fetch")
        XCTAssertNil(svc.fieldSet)
    }

    /// The newest cycle is often not published yet. A 404 must walk back a cycle rather than fail.
    func testNotFoundWalksBackToAnOlderCycle() async {
        let fetcher = FakeFetcher(payload: grib, script: [.notFound, .notFound])
        let svc = service(fetcher)
        svc.setEnabled(true)
        await settle(svc) { $0.fieldSet != nil }
        XCTAssertNotNil(svc.fieldSet)
        XCTAssertEqual(fetcher.requested.count, 3, "two misses then a hit")
        // Newest first: 12z+3h, then 06z+9h, then 00z+15h.
        XCTAssertTrue(fetcher.requested[0].absoluteString.contains("gfs.t12z"))
        XCTAssertTrue(fetcher.requested[0].absoluteString.contains(".f003"))
        XCTAssertTrue(fetcher.requested[1].absoluteString.contains("gfs.t06z"))
        XCTAssertTrue(fetcher.requested[1].absoluteString.contains(".f009"))
        XCTAssertTrue(fetcher.requested[2].absoluteString.contains("gfs.t00z"))
        XCTAssertTrue(fetcher.requested[2].absoluteString.contains(".f015"))
    }

    func testWalkIsBoundedAndReportsFailureWithNothingToShow() async {
        let fetcher = FakeFetcher(payload: grib, fallback: .notFound)
        let svc = service(fetcher)
        svc.setEnabled(true)
        await settle(svc) { $0.failed }
        XCTAssertTrue(svc.failed)
        XCTAssertNil(svc.fieldSet)
        XCTAssertEqual(fetcher.requested.count, WindFetchPlan.maxCycleAttempts,
                       "the cycle walk must be bounded")
        XCTAssertFalse(svc.fetching)
    }

    /// A transport failure (not a 404) stops the walk immediately — a network outage must not burn five
    /// requests — and never clears data already on screen.
    func testTransportFailureStopsTheWalkAndKeepsTheLastGoodData() async {
        let fetcher = FakeFetcher(payload: grib, script: [.grib], fallback: .transportError)
        let svc = service(fetcher)
        svc.setEnabled(true)
        await settle(svc) { $0.fieldSet != nil }
        let first = svc.fieldSet
        XCTAssertNotNil(first)

        // Pan far away so the held box no longer covers the view, forcing a fresh attempt.
        svc.viewportChanged(RadarRegion(centerLat: -20, centerLon: 30, latSpan: 6, lonSpan: 10))
        await settle(svc) { $0.fetching == false && $0.fieldSet != nil }
        XCTAssertNotNil(svc.fieldSet, "a failed refetch must keep the last good field set")
        XCTAssertFalse(svc.failed, "there is still something to show, so this is not a hard failure")
        XCTAssertEqual(fetcher.requested.count, 2, "a transport error aborts the cycle walk")
    }

    /// The forecast hour must advance with the wall clock: a field set valid two hours ago is refetched
    /// even though the map has not moved. Without this the overlay silently freezes on a long leg.
    func testStaleValidTimeRefetchesWithoutAMapMove() async {
        let fetcher = FakeFetcher(payload: grib)
        let fakeClock = MovableClock(clock)
        let svc = WindAloftService(fetcher: fetcher, now: { fakeClock.value }, cacheDirectory: cacheDir)
        svc.viewportChanged(RadarRegion(centerLat: 35, centerLon: -95, latSpan: 5, lonSpan: 8))
        svc.setEnabled(true)
        await settle(svc) { $0.fieldSet != nil }
        XCTAssertEqual(fetcher.requested.count, 1)

        // Same view, but the clock has moved past the tolerance.
        fakeClock.value = clock.addingTimeInterval(WindAloftService.refetchAge + 600)
        svc.viewportChanged(RadarRegion(centerLat: 35, centerLon: -95, latSpan: 5, lonSpan: 8))
        await settle(svc) { _ in fetcher.requested.count > 1 }
        XCTAssertEqual(fetcher.requested.count, 2, "a drifted valid time must refetch")
    }

    // MARK: viewport-driven refetch

    func testSmallPanInsideTheCoveredBoxDoesNotRefetch() async {
        let fetcher = FakeFetcher(payload: grib)
        let svc = service(fetcher)
        // The fixture covers 20…55 N, −130…−60 E. Start centred inside it.
        svc.viewportChanged(RadarRegion(centerLat: 35, centerLon: -95, latSpan: 5, lonSpan: 8))
        svc.setEnabled(true)
        await settle(svc) { $0.fieldSet != nil }
        XCTAssertEqual(fetcher.requested.count, 1)

        svc.viewportChanged(RadarRegion(centerLat: 35.4, centerLon: -95.5, latSpan: 5, lonSpan: 8))
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(fetcher.requested.count, 1, "a pan still inside the covered box must not refetch")
    }

    func testPanOutsideTheCoveredBoxRefetches() async {
        let fetcher = FakeFetcher(payload: grib)
        let svc = service(fetcher)
        svc.viewportChanged(RadarRegion(centerLat: 35, centerLon: -95, latSpan: 5, lonSpan: 8))
        svc.setEnabled(true)
        await settle(svc) { $0.fieldSet != nil }
        XCTAssertEqual(fetcher.requested.count, 1)

        svc.viewportChanged(RadarRegion(centerLat: 50, centerLon: 10, latSpan: 5, lonSpan: 8))
        await settle(svc) { _ in fetcher.requested.count > 1 }
        XCTAssertEqual(fetcher.requested.count, 2, "leaving the covered box must refetch")
    }

    // MARK: disk snapshot

    func testSnapshotRoundTripsSoAColdStartShowsSomething() async {
        let fetcher = FakeFetcher(payload: grib)
        let first = service(fetcher)
        first.setEnabled(true)
        await settle(first) { $0.fieldSet != nil }
        XCTAssertNotNil(first.fieldSet)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheDir.appendingPathComponent("snapshot.grib2").path))

        // A fresh service with a fetcher that always fails still shows the snapshot.
        let offline = FakeFetcher(payload: grib, fallback: .transportError)
        let second = service(offline)
        second.setEnabled(true)
        await settle(second) { $0.fieldSet != nil }
        XCTAssertNotNil(second.fieldSet, "a cold offline start must restore the snapshot")
        XCTAssertEqual(second.fieldSet?.field(.mb850)?.ni, 281)
    }

    // MARK: pure geometry + URL building

    func testCandidatesAreNewestFirstAndBounded() {
        let list = WindFetchPlan.candidates(now: clock)
        XCTAssertEqual(list.count, WindFetchPlan.maxCycleAttempts)
        XCTAssertEqual(list[0].forecastHour, 3, "15:00Z against the 12z cycle is +3h")
        XCTAssertEqual(list[1].forecastHour, 9)
        XCTAssertEqual(list[2].forecastHour, 15)
        for i in 1..<list.count {
            XCTAssertLessThan(list[i].cycle, list[i - 1].cycle, "cycles must walk backwards")
            XCTAssertEqual(list[i - 1].cycle.timeIntervalSince(list[i].cycle), 6 * 3600, accuracy: 1)
        }
        for c in list {
            XCTAssertGreaterThanOrEqual(c.forecastHour, 0)
            XCTAssertLessThanOrEqual(c.forecastHour, WindFetchPlan.maxForecastHour)
        }
    }

    func testFilterURLShape() throws {
        let box = WindBBox(minLat: 27, minLon: -105, maxLat: 42, maxLon: -85)
        let url = try XCTUnwrap(WindFetchPlan.filterURL(cycle: clock.addingTimeInterval(-3 * 3600),
                                                           forecastHour: 3, bbox: box))
        let s = url.absoluteString
        XCTAssertTrue(s.hasPrefix("https://nomads.ncep.noaa.gov/cgi-bin/filter_gfs_0p25_1hr.pl?"))
        XCTAssertTrue(s.contains("dir=%2Fgfs.20260729%2F12%2Fatmos"), s)
        XCTAssertTrue(s.contains("file=gfs.t12z.pgrb2.0p25.f003"), s)
        XCTAssertTrue(s.contains("var_UGRD=on"))
        XCTAssertTrue(s.contains("var_VGRD=on"))
        XCTAssertTrue(s.contains("leftlon=-105.00"))
        XCTAssertTrue(s.contains("rightlon=-85.00"))
        XCTAssertTrue(s.contains("bottomlat=27.00"))
        XCTAssertTrue(s.contains("toplat=42.00"))
        for level in WindLevel.allCases {
            XCTAssertTrue(s.contains("\(level.gribLevParam)=on"), "missing \(level.gribLevParam)")
        }
        XCTAssertNil(WindFetchPlan.filterURL(cycle: clock, forecastHour: 999, bbox: box))
    }

    func testFetchBoxPadsTheViewAndSnapsToTheGrid() {
        let (fetch, visible) = WindFetchPlan.fetchBBox(
            for: RadarRegion(centerLat: 35.13, centerLon: -95.07, latSpan: 4, lonSpan: 6))
        XCTAssertTrue(fetch.contains(visible), "the download must cover the screen")
        XCTAssertGreaterThanOrEqual(fetch.latSpan, 15, "a minimum pad avoids refetching on every drag")
        XCTAssertGreaterThanOrEqual(fetch.lonSpan, 20)
        XCTAssertLessThanOrEqual(fetch.latSpan, 40.5, "and a ceiling keeps the request cheap")
        XCTAssertLessThanOrEqual(fetch.lonSpan, 60.5)
        for v in [fetch.minLat, fetch.maxLat, fetch.minLon, fetch.maxLon] {
            XCTAssertEqual((v / WindFetchPlan.gridStep).rounded(), v / WindFetchPlan.gridStep,
                           accuracy: 1e-9, "\(v) is not on the 0.25° grid")
        }
    }

    /// Longitude is clamped, never wrapped: the filter cannot express a box crossing the antimeridian.
    func testBoxNearTheAntimeridianStaysInRange() {
        for lon in [179.0, -179.0, 180.0, -180.0] {
            let (fetch, _) = WindFetchPlan.fetchBBox(
                for: RadarRegion(centerLat: 20, centerLon: lon, latSpan: 5, lonSpan: 8))
            XCTAssertGreaterThanOrEqual(fetch.minLon, -180, "lon \(lon)")
            XCTAssertLessThanOrEqual(fetch.maxLon, 180, "lon \(lon)")
            XCTAssertGreaterThan(fetch.lonSpan, 0, "lon \(lon)")
        }
        let (polar, _) = WindFetchPlan.fetchBBox(
            for: RadarRegion(centerLat: 89, centerLon: 0, latSpan: 5, lonSpan: 8))
        XCTAssertLessThanOrEqual(polar.maxLat, 90)
        XCTAssertGreaterThanOrEqual(polar.minLat, -90)
    }

    func testGribMagicGuardRejectsAnHtmlErrorPage() {
        XCTAssertFalse(WindFetchPlan.looksLikeGrib(Data("<!DOCTYPE html><html><head><title>404".utf8)))
        XCTAssertFalse(WindFetchPlan.looksLikeGrib(Data()))
        XCTAssertTrue(WindFetchPlan.looksLikeGrib(grib))
    }

    func testWindReadoutAtACoordinate() async {
        let fetcher = FakeFetcher(payload: grib)
        let svc = service(fetcher)
        svc.setEnabled(true)
        await settle(svc) { $0.fieldSet != nil }
        let w = svc.wind(at: 32.8968, lon: -97.0380, level: .mb850)
        XCTAssertEqual(Double(try! XCTUnwrap(w).kt), 6.657, accuracy: 0.02)
        XCTAssertEqual(Double(try! XCTUnwrap(w).fromDeg), 175.06, accuracy: 0.1)
        XCTAssertNil(svc.wind(at: 0, lon: 0, level: .mb850), "outside the grid")
        XCTAssertNil(svc.wind(at: 32.9, lon: -97, level: .mb200), "level not in the fixture")
    }
}
