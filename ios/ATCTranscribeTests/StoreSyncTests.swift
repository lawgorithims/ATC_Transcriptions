import XCTest
@testable import ATCTranscribe

/// Sync through the real stores, with two independent "devices" and one fake cloud between them.
///
/// `SyncMergeTests` proves the rules on synthetic records; this proves the adapters actually encode,
/// decode, upsert and delete the things a pilot cares about — a flight with a breadcrumb trail, and a
/// note with its ink.
@MainActor
final class StoreSyncTests: XCTestCase {

    private var roots: [URL] = []

    override func tearDown() {
        for r in roots { try? FileManager.default.removeItem(at: r) }
        roots = []
        super.tearDown()
    }

    /// A store pair in its own directory with its own ledger — one simulated device.
    private func device() -> (logbook: Logbook, notes: NotesStore) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dev-\(UUID().uuidString)", isDirectory: true)
        roots.append(root)
        let ledger = SyncLedger(directory: root.appendingPathComponent("Sync"))
        return (Logbook(directory: root.appendingPathComponent("Logbook"), ledger: ledger),
                NotesStore(directory: root.appendingPathComponent("Notes"), ledger: ledger))
    }

    private func coordinator(_ transport: CloudSyncTransport,
                             _ adapters: [SyncCoordinator.StoreAdapter],
                             _ ledger: SyncLedger) -> SyncCoordinator {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("coord-\(UUID().uuidString)", isDirectory: true)
        roots.append(dir)
        return SyncCoordinator(ledger: ledger, transport: transport, adapters: adapters, directory: dir)
    }

    private func flight(start: Date, notes: String = "") -> LoggedFlight {
        let trail = (0..<3).map { i in
            Breadcrumb(t: start.addingTimeInterval(Double(i) * 60), lat: 42 + Double(i) * 0.1,
                       lon: -71 - Double(i) * 0.1, altFt: 3000, speedKt: 120, track: 90)
        }
        return LoggedFlight(id: UUID(), startedAt: start, endedAt: start.addingTimeInterval(3600),
                            durationSec: 3600, distanceNM: 100, maxSpeedKt: 140, avgSpeedKt: 110,
                            maxAltFtMSL: 8500, stops: [], aircraftCallsign: "N8925T",
                            aircraftType: "Seneca", notes: notes, breadcrumb: trail)
    }

    // MARK: The logbook

    /// A flight recorded on the iPad appears on the phone, breadcrumb trail and all.
    func testAFlightCrossesFromOneDeviceToTheOther() async throws {
        let a = device(), b = device()
        let cloud = InMemoryCloudTransport()
        let f = flight(start: Date(timeIntervalSince1970: 1_700_000_000), notes: "bumpy over the ridge")
        a.logbook.add(f)

        try await coordinator(cloud, [a.logbook.syncAdapter], a.logbook.ledger).sync()
        try await coordinator(cloud, [b.logbook.syncAdapter], b.logbook.ledger).sync()

        XCTAssertEqual(b.logbook.flights.count, 1)
        XCTAssertEqual(b.logbook.flights.first, f,
                       "the whole value must survive the round trip, breadcrumb included")
    }

    /// Deleting on one device deletes on the other — the tombstone's whole job.
    func testADeletionCrossesToTheOtherDevice() async throws {
        let a = device(), b = device()
        let cloud = InMemoryCloudTransport()
        let f = flight(start: Date(timeIntervalSince1970: 1_700_000_000))
        a.logbook.add(f)

        try await coordinator(cloud, [a.logbook.syncAdapter], a.logbook.ledger).sync()
        try await coordinator(cloud, [b.logbook.syncAdapter], b.logbook.ledger).sync()
        XCTAssertEqual(b.logbook.flights.count, 1, "precondition: both devices have it")

        a.logbook.delete(f.id)
        try await coordinator(cloud, [a.logbook.syncAdapter], a.logbook.ledger).sync()
        try await coordinator(cloud, [b.logbook.syncAdapter], b.logbook.ledger).sync()

        XCTAssertTrue(b.logbook.flights.isEmpty, "the deletion must reach the second device")
    }

    /// ⚠️ THE REGRESSION THIS WHOLE DESIGN EXISTS TO PREVENT.
    ///
    /// Installing on a second device must not empty the first one. The second device syncs against a
    /// cloud that has nothing of its own, and if its empty library is read as authority, the first
    /// device's logbook is deleted everywhere on the next pass.
    func testASecondEmptyDeviceDoesNotWipeTheFirst() async throws {
        let a = device(), b = device()
        let cloud = InMemoryCloudTransport()
        for i in 0..<3 {
            a.logbook.add(flight(start: Date(timeIntervalSince1970: 1_700_000_000 + Double(i) * 86_400)))
        }

        // The brand-new device syncs FIRST, with nothing in it.
        try await coordinator(cloud, [b.logbook.syncAdapter], b.logbook.ledger).sync()
        try await coordinator(cloud, [a.logbook.syncAdapter], a.logbook.ledger).sync()
        try await coordinator(cloud, [b.logbook.syncAdapter], b.logbook.ledger).sync()

        XCTAssertEqual(a.logbook.flights.count, 3, "the established logbook must be untouched")
        XCTAssertEqual(b.logbook.flights.count, 3, "and the new device must receive it")
    }

    /// An edit on one side wins over an older copy on the other.
    func testTheLaterEditOfAFlightWins() async throws {
        let a = device(), b = device()
        let cloud = InMemoryCloudTransport()
        let f = flight(start: Date(timeIntervalSince1970: 1_700_000_000), notes: "first")
        a.logbook.add(f)
        try await coordinator(cloud, [a.logbook.syncAdapter], a.logbook.ledger).sync()
        try await coordinator(cloud, [b.logbook.syncAdapter], b.logbook.ledger).sync()

        var edited = b.logbook.flights[0]
        edited.notes = "corrected on the phone"
        b.logbook.update(edited)

        try await coordinator(cloud, [b.logbook.syncAdapter], b.logbook.ledger).sync()
        try await coordinator(cloud, [a.logbook.syncAdapter], a.logbook.ledger).sync()

        XCTAssertEqual(a.logbook.flights.first?.notes, "corrected on the phone")
    }

    /// A logbook that predates this feature has records but no clocks. Two devices restored from the
    /// same backup must then produce IDENTICAL sync records, so the first sync is a no-op instead of
    /// one of them being declared the newer writer and overwriting the other.
    ///
    /// This is why `clock(_:_:fallback:)` takes the flight's own `endedAt` and never `Date()`.
    func testTwoDevicesWithAPreExistingLibraryAndNoClocksAgree() throws {
        let f = flight(start: Date(timeIntervalSince1970: 1_700_000_000))
        let encoded = try JSONEncoder().encode([f])

        /// A logbook whose flights.json was put there by an older build, with an empty ledger beside it.
        func legacyDevice() throws -> Logbook {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("legacy-\(UUID().uuidString)", isDirectory: true)
            roots.append(root)
            let dir = root.appendingPathComponent("Logbook")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try encoded.write(to: dir.appendingPathComponent("flights.json"))
            return Logbook(directory: dir, ledger: SyncLedger(directory: root.appendingPathComponent("Sync")))
        }

        let one = try legacyDevice(), two = try legacyDevice()
        XCTAssertEqual(one.flights, [f], "precondition: the old file loaded")
        XCTAssertEqual(one.syncRecords(), two.syncRecords(),
                       "with no ledger entry both devices must clock the flight from its own endedAt. "
                       + "A Date() fallback here makes the second device look newer and silently "
                       + "overwrite the first device's copy of every flight it already had.")

        let out = SyncMerge.merge(local: one.syncRecords(), remote: two.syncRecords())
        XCTAssertTrue(out.toPush.isEmpty && out.toApply.isEmpty,
                      "identical libraries must generate no work at all")
    }

    // MARK: Notes

    /// A note's ink has to travel with it. An index row on its own is a tile that opens blank.
    func testANoteCrossesWithItsDrawing() async throws {
        let a = device(), b = device()
        let cloud = InMemoryCloudTransport()
        let ink = Data("pretend this is a PKDrawing".utf8)
        let id = NotesStore.newID()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertTrue(a.notes.save(id: id, title: "Approach brief", drawing: ink,
                                   thumbnail: Data("png".utf8), createdAt: now, now: now))

        try await coordinator(cloud, [a.notes.syncAdapter], a.notes.ledger).sync()
        try await coordinator(cloud, [b.notes.syncAdapter], b.notes.ledger).sync()

        XCTAssertEqual(b.notes.notes.map(\.title), ["Approach brief"])
        XCTAssertEqual(b.notes.drawingData(id), ink, "the ink must arrive, not just the index row")
    }

    func testADeletedNoteTakesItsFilesWithItOnTheOtherDevice() async throws {
        let a = device(), b = device()
        let cloud = InMemoryCloudTransport()
        let id = NotesStore.newID()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        _ = a.notes.save(id: id, title: "scratch", drawing: Data("ink".utf8),
                         thumbnail: nil, createdAt: now, now: now)

        try await coordinator(cloud, [a.notes.syncAdapter], a.notes.ledger).sync()
        try await coordinator(cloud, [b.notes.syncAdapter], b.notes.ledger).sync()
        XCTAssertNotNil(b.notes.drawingData(id), "precondition: the ink is on the second device")

        a.notes.delete(a.notes.notes[0])
        try await coordinator(cloud, [a.notes.syncAdapter], a.notes.ledger).sync()
        try await coordinator(cloud, [b.notes.syncAdapter], b.notes.ledger).sync()

        XCTAssertTrue(b.notes.notes.isEmpty, "the row is gone")
        XCTAssertNil(b.notes.drawingData(id), "and so is the ink — a deletion must not leave orphans")
    }

    // MARK: No churn

    /// ⚠️ THE REGRESSION TEST FOR THE ENCODER BUG, at the level where it was visible.
    ///
    /// Once two devices agree, further passes must upload NOTHING. With a plain `JSONEncoder()` the
    /// payload bytes for one flight differed between encodes, so every pass found a difference that
    /// was not there, broke the tie by byte order and re-uploaded the whole library — on both devices,
    /// forever, against the pilot's own iCloud quota.
    ///
    /// Nothing else in the suite notices: both devices still converge on the right data, and every
    /// round-trip test passes. Only the upload count gives it away.
    func testAConvergedPairStopsTalking() async throws {
        let a = device(), b = device()
        let cloud = InMemoryCloudTransport()
        for i in 0..<4 {
            a.logbook.add(flight(start: Date(timeIntervalSince1970: 1_700_000_000 + Double(i) * 86_400)))
        }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        _ = a.notes.save(id: NotesStore.newID(), title: "brief", drawing: Data(repeating: 3, count: 256),
                         thumbnail: nil, createdAt: now, now: now)

        func pass(_ d: (logbook: Logbook, notes: NotesStore)) async throws {
            try await coordinator(cloud, [d.logbook.syncAdapter, d.notes.syncAdapter],
                                  d.logbook.ledger).sync()
        }

        try await pass(a)
        try await pass(b)
        try await pass(a)
        let settled = await cloud.uploadCount()
        XCTAssertGreaterThan(settled, 0, "precondition: something was uploaded to begin with")

        // Three more passes with nothing changed on either device.
        for _ in 0..<3 { try await pass(a); try await pass(b) }

        let afterIdlePasses = await cloud.uploadCount()
        XCTAssertEqual(afterIdlePasses, settled,
                       "a settled pair of devices must upload nothing further. If this grows, two "
                       + "encodings of one value are being compared as different records and every "
                       + "sync re-uploads the library.")
        XCTAssertEqual(a.logbook.flights.count, 4)
        XCTAssertEqual(b.logbook.flights.count, 4)
        XCTAssertEqual(b.notes.notes.count, 1)
    }

    // MARK: Both kinds through one coordinator

    /// The real wiring: one pass, both stores, records routed by kind.
    func testOnePassCarriesFlightsAndNotesWithoutCrossingThem() async throws {
        let a = device(), b = device()
        let cloud = InMemoryCloudTransport()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        a.logbook.add(flight(start: now))
        _ = a.notes.save(id: NotesStore.newID(), title: "n", drawing: Data("ink".utf8),
                         thumbnail: nil, createdAt: now, now: now)

        try await coordinator(cloud, [a.logbook.syncAdapter, a.notes.syncAdapter],
                              a.logbook.ledger).sync()
        try await coordinator(cloud, [b.logbook.syncAdapter, b.notes.syncAdapter],
                              b.logbook.ledger).sync()

        XCTAssertEqual(b.logbook.flights.count, 1)
        XCTAssertEqual(b.notes.notes.count, 1)
    }
}
