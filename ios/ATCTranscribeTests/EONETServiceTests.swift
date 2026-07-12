import XCTest
@testable import ATCTranscribe

/// EONET polling-service lifecycle driven by a fake fetcher: enabled polls / disabled doesn't,
/// partial-category failure keeps the other categories, an all-category failure never clears the
/// published snapshot, and the disk cache round-trips (fresh publishes before any fetch, stale is
/// ignored).
final class EONETServiceTests: XCTestCase {

    private var cacheDir: URL!

    override func setUpWithError() throws {
        cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("eonet-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: cacheDir)
    }

    private func config(refresh: TimeInterval = 0.05) -> EONETService.Config {
        EONETService.Config(refreshInterval: refresh, backoffBase: 0.01, cacheDirectory: cacheDir)
    }

    private static func fire(_ id: String = "F1") -> EONETEvent {
        EONETEvent(id: id, title: "Fire \(id)", category: .wildfires, updatedAt: Date(),
                   point: Coord(lat: 40, lon: -120), polygon: [], track: [])
    }

    func testEnabledPollsAndPublishes() async {
        let box = HazardBox()
        let fetcher = FakeEONETFetcher { cat, _ in cat == .wildfires ? [Self.fire()] : [] }
        let svc = EONETService(config: config(), fetcher: fetcher, onUpdate: { box.add($0, $1) })
        await svc.sync(enabled: true)
        try? await Task.sleep(nanoseconds: 150_000_000)
        await svc.sync(enabled: false)
        XCTAssertTrue(box.all().contains { $0.events.map(\.id) == ["F1"] },
                      "got \(box.all().map { $0.events.map(\.id) })")
        XCTAssertTrue(box.all().allSatisfy { $0.at != .distantPast || $0.events.isEmpty })
    }

    func testDisabledNeverPolls() async {
        let box = HazardBox()
        let fetcher = FakeEONETFetcher { _, _ in [Self.fire()] }
        let svc = EONETService(config: config(), fetcher: fetcher, onUpdate: { box.add($0, $1) })
        await svc.sync(enabled: false)
        try? await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(fetcher.calls(), 0)
        XCTAssertTrue(box.all().isEmpty)
    }

    func testPartialFailureKeepsOtherCategories() async {
        let box = HazardBox()
        let fetcher = FakeEONETFetcher { cat, _ in
            guard cat == .wildfires else { throw URLError(.timedOut) }
            return [Self.fire()]
        }
        let svc = EONETService(config: config(), fetcher: fetcher, onUpdate: { box.add($0, $1) })
        await svc.sync(enabled: true)
        try? await Task.sleep(nanoseconds: 120_000_000)
        await svc.sync(enabled: false)
        XCTAssertTrue(box.all().contains { $0.events.map(\.id) == ["F1"] },
                      "a partial success must still publish the categories that worked")
    }

    func testAllFailKeepsPriorSnapshot() async {
        let box = HazardBox()
        let statuses = StatusBox()
        let fetcher = FakeEONETFetcher { cat, round in
            guard round == 0 else { throw URLError(.notConnectedToInternet) }
            return cat == .wildfires ? [Self.fire()] : []
        }
        let svc = EONETService(config: config(refresh: 0.03), fetcher: fetcher,
                               onUpdate: { box.add($0, $1) }, onStatus: { statuses.add($0) })
        await svc.sync(enabled: true)
        try? await Task.sleep(nanoseconds: 200_000_000)            // round 0 ok + several failed rounds
        await svc.sync(enabled: false)
        let snaps = box.all()
        XCTAssertFalse(snaps.isEmpty)
        // No later publish ever wiped the good snapshot — failures don't publish at all.
        XCTAssertTrue(snaps.allSatisfy { $0.events.map(\.id) == ["F1"] },
                      "got \(snaps.map { $0.events.map(\.id) })")
        XCTAssertTrue(statuses.all().contains(.error("offline")))
    }

    func testDiskCachePublishesBeforeAnyFetch() async {
        // Instance A fetches once and mirrors the snapshot to disk.
        let boxA = HazardBox()
        let svcA = EONETService(config: config(),
                                fetcher: FakeEONETFetcher { cat, _ in cat == .wildfires ? [Self.fire()] : [] },
                                onUpdate: { boxA.add($0, $1) })
        await svcA.sync(enabled: true)
        try? await Task.sleep(nanoseconds: 120_000_000)
        await svcA.sync(enabled: false)
        XCTAssertTrue(boxA.all().contains { !$0.events.isEmpty }, "precondition: A must have fetched")

        // Instance B's network is dead — the cached snapshot must still publish, with its saved
        // instant (not .distantPast) so the UI can show the age.
        let boxB = HazardBox()
        let svcB = EONETService(config: config(),
                                fetcher: FakeEONETFetcher { _, _ in throw URLError(.notConnectedToInternet) },
                                onUpdate: { boxB.add($0, $1) })
        await svcB.sync(enabled: true)
        try? await Task.sleep(nanoseconds: 120_000_000)
        await svcB.sync(enabled: false)
        let first = boxB.all().first
        XCTAssertEqual(first?.events.map(\.id), ["F1"])
        XCTAssertNotEqual(first?.at, .distantPast)
    }

    func testStaleDiskCacheIsIgnored() async throws {
        // Handcraft a >24 h-old snapshot (JSONEncoder's default Date coding is seconds since the
        // reference date, so the file can be written directly).
        let old = Date().addingTimeInterval(-48 * 3600).timeIntervalSinceReferenceDate
        let json = """
        {"version":1,"savedAt":\(old),"events":[
          {"id":"OLD","title":"Old Fire","category":"wildfires","updatedAt":\(old),
           "point":{"lat":40.0,"lon":-120.0},"polygon":[],"track":[]}]}
        """
        try Data(json.utf8).write(to: cacheDir.appendingPathComponent("events.json"))

        let box = HazardBox()
        let svc = EONETService(config: config(),
                               fetcher: FakeEONETFetcher { _, _ in throw URLError(.notConnectedToInternet) },
                               onUpdate: { box.add($0, $1) })
        await svc.sync(enabled: true)
        try? await Task.sleep(nanoseconds: 100_000_000)
        await svc.sync(enabled: false)
        XCTAssertTrue(box.all().allSatisfy { $0.events.isEmpty },
                      "a stale cache must never surface events: \(box.all().map { $0.events.map(\.id) })")
    }
}

// MARK: - Test doubles

private final class FakeEONETFetcher: EONETFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var callCount = 0
    private let handler: @Sendable (EONETCategory, Int) throws -> [EONETEvent]

    /// `handler(category, round)` — `round` advances once per full sweep of the four categories.
    init(_ handler: @escaping @Sendable (EONETCategory, Int) throws -> [EONETEvent]) {
        self.handler = handler
    }

    func fetch(category: EONETCategory, limit: Int) async throws -> [EONETEvent] {
        try handler(category, nextRound())
    }

    /// Synchronous so the NSLock never crosses an await (async-context lock warning).
    private func nextRound() -> Int {
        lock.lock(); defer { lock.unlock() }
        let round = callCount / EONETCategory.allCases.count
        callCount += 1
        return round
    }

    func calls() -> Int { lock.lock(); defer { lock.unlock() }; return callCount }
}

private final class HazardBox: @unchecked Sendable {
    private let lock = NSLock()
    private var snaps: [(events: [EONETEvent], at: Date)] = []
    func add(_ e: [EONETEvent], _ at: Date) { lock.lock(); snaps.append((e, at)); lock.unlock() }
    func all() -> [(events: [EONETEvent], at: Date)] { lock.lock(); defer { lock.unlock() }; return snaps }
}

private final class StatusBox: @unchecked Sendable {
    private let lock = NSLock()
    private var statuses: [EONETStatus] = []
    func add(_ s: EONETStatus) { lock.lock(); statuses.append(s); lock.unlock() }
    func all() -> [EONETStatus] { lock.lock(); defer { lock.unlock() }; return statuses }
}
