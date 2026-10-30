import XCTest
@testable import ATCTranscribe

/// One sync pass end to end, with a fake cloud and a fake store.
///
/// The coordinator is the piece that turns the merge's answer into writes and uploads, so what is
/// asserted here is the wiring: that applied records reach the right store, that tombstones become
/// deletions, that a failed push does not undo a successful apply, and that a pilot with no iCloud
/// account sees nothing at all.
@MainActor
final class SyncCoordinatorTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private var dir: URL!

    /// Stands in for `Logbook` / `NotesStore`: holds records by id and records what it was told.
    private final class FakeStore {
        var held: [String: SyncRecord] = [:]
        var applyCalls = 0

        func adapter(_ kind: SyncRecord.Kind) -> SyncCoordinator.StoreAdapter {
            SyncCoordinator.StoreAdapter(
                kind: kind,
                localRecords: { [unowned self] in held.values.filter { !$0.deleted } },
                apply: { [unowned self] records in
                    applyCalls += 1
                    for r in records {
                        if r.deleted { held[r.id] = nil } else { held[r.id] = r }
                    }
                })
        }
    }

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("coord-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func rec(_ id: String, _ kind: SyncRecord.Kind = .flight,
                     at offset: TimeInterval = 0, _ body: String = "x") -> SyncRecord {
        SyncRecord(id: id, kind: kind, modifiedAt: t0.addingTimeInterval(offset), payload: Data(body.utf8))
    }

    private func coordinator(_ transport: CloudSyncTransport,
                             _ adapters: [SyncCoordinator.StoreAdapter]) -> SyncCoordinator {
        SyncCoordinator(ledger: SyncLedger(directory: dir), transport: transport,
                        adapters: adapters, directory: dir)
    }

    // MARK: The happy paths

    func testLocalRecordsTheCloudLacksAreUploaded() async throws {
        let store = FakeStore()
        store.held = ["a": rec("a"), "b": rec("b")]
        let cloud = InMemoryCloudTransport()

        try await coordinator(cloud, [store.adapter(.flight)]).sync()

        let uploaded = await cloud.contents().map(\.id).sorted()
        XCTAssertEqual(uploaded, ["a", "b"])
        XCTAssertEqual(store.held.count, 2, "an upload must not change the local store")
    }

    func testRemoteRecordsAreWrittenIntoTheStore() async throws {
        let store = FakeStore()
        let cloud = InMemoryCloudTransport(seed: [rec("fromCloud", at: 60, "payload")])

        try await coordinator(cloud, [store.adapter(.flight)]).sync()

        XCTAssertEqual(store.held["fromCloud"]?.payload, Data("payload".utf8))
    }

    /// A tombstone arriving from the cloud has to reach the store as a DELETION, not as a record with
    /// an empty payload — a store that upserts tombstones shows the pilot blank rows.
    func testARemoteTombstoneDeletesLocally() async throws {
        let store = FakeStore()
        store.held = ["doomed": rec("doomed", at: 0)]
        let cloud = InMemoryCloudTransport(seed: [.tombstone(id: "doomed", kind: .flight,
                                                             at: t0.addingTimeInterval(60))])

        try await coordinator(cloud, [store.adapter(.flight)]).sync()

        XCTAssertNil(store.held["doomed"], "the deletion must propagate to this device")
    }

    /// And the opposite: the cloud not mentioning a record leaves it alone. Same rule as
    /// `SyncMergeTests.testARecordMissingFromTheCloudIsPushedAndNeverDeleted`, asserted through the
    /// wiring, because this is the layer that actually calls `delete`.
    func testAnEmptyCloudDoesNotEmptyTheStore() async throws {
        let store = FakeStore()
        store.held = ["a": rec("a"), "b": rec("b"), "c": rec("c")]
        let cloud = InMemoryCloudTransport()

        try await coordinator(cloud, [store.adapter(.flight)]).sync()

        XCTAssertEqual(store.held.count, 3, "a first sync against an empty cloud must keep every flight")
        XCTAssertEqual(store.applyCalls, 0, "with nothing to apply, the store must not be touched at all")
    }

    // MARK: Kind isolation

    func testEachStoreOnlySeesItsOwnKind() async throws {
        let flights = FakeStore(), notes = FakeStore()
        let cloud = InMemoryCloudTransport(seed: [rec("f", .flight, at: 60, "a flight"),
                                                 rec("n", .note, at: 60, "a note")])

        try await coordinator(cloud, [flights.adapter(.flight), notes.adapter(.note)]).sync()

        XCTAssertEqual(flights.held.keys.sorted(), ["f"], "the logbook must not be handed a note")
        XCTAssertEqual(notes.held.keys.sorted(), ["n"], "the note library must not be handed a flight")
    }

    // MARK: Failure

    /// Remote changes are applied before the push, so a push failure costs a retry and nothing else.
    func testAFailedPushKeepsTheChangesAlreadyApplied() async {
        struct Boom: Error {}
        let store = FakeStore()
        store.held = ["mine": rec("mine", at: 0)]
        let cloud = InMemoryCloudTransport(seed: [rec("theirs", at: 60, "adopted")])
        let coord = coordinator(cloud, [store.adapter(.flight)])

        // The seeded fetch succeeds; the push that follows does not.
        await cloud.failOnPush(Boom())
        do {
            try await coord.sync()
            XCTFail("the push was supposed to fail")
        } catch {
            XCTAssertEqual(store.held["theirs"]?.payload, Data("adopted".utf8),
                           "the record the cloud knew about stays applied — the failure was the upload")
            XCTAssertNotNil(store.held["mine"], "and nothing local was lost")
        }
    }

    /// No iCloud account, no signal, iCloud Drive off: all ordinary, none of it an app error.
    func testSyncQuietlySwallowsTheErrorIntoLastError() async {
        struct NoAccount: Error {}
        let store = FakeStore()
        let cloud = InMemoryCloudTransport()
        await cloud.failOnFetch(NoAccount())
        let coord = coordinator(cloud, [store.adapter(.flight)])

        await coord.syncQuietly()

        XCTAssertNotNil(coord.lastError, "the failure is recorded for a settings row")
        XCTAssertTrue(store.held.isEmpty, "and nothing was invented locally")
    }

    func testASuccessfulPassClearsAStaleError() async throws {
        struct Boom: Error {}
        let store = FakeStore()
        let cloud = InMemoryCloudTransport()
        let coord = coordinator(cloud, [store.adapter(.flight)])

        await cloud.failOnFetch(Boom())
        await coord.syncQuietly()
        XCTAssertNotNil(coord.lastError)

        try await coord.sync()
        XCTAssertNil(coord.lastError, "a later good pass must not leave a stale failure on screen")
    }
}
