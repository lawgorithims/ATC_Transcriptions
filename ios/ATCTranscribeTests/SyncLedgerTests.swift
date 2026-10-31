import XCTest
@testable import ATCTranscribe

/// The ledger: the sync clock, and the only place a tombstone exists.
@MainActor
final class SyncLedgerTests: XCTestCase {

    private var dir: URL!
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledger-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func ledger() -> SyncLedger { SyncLedger(directory: dir) }

    func testTouchRecordsALiveClock() {
        let l = ledger()
        l.touch(.flight, "a", at: t0)
        XCTAssertEqual(l.entry(.flight, "a"), SyncLedger.Entry(modifiedAt: t0, deleted: false))
    }

    /// A record with no ledger entry takes its clock from its own content, never from `Date()`.
    ///
    /// This is the existing-pilot case: a logbook that predates this feature has no ledger beside it.
    /// A wall-clock fallback would make whichever device synced second look like the newer writer and
    /// overwrite the other's copy; a content-derived clock is the same number everywhere, so the two
    /// sides agree and converge.
    func testAnUnknownRecordFallsBackToItsContentClock() {
        let flightEnded = t0.addingTimeInterval(-9999)
        XCTAssertEqual(ledger().clock(.flight, "never-seen", fallback: flightEnded), flightEnded)
    }

    func testTouchOverridesTheFallback() {
        let l = ledger()
        l.touch(.flight, "a", at: t0)
        XCTAssertEqual(l.clock(.flight, "a", fallback: t0.addingTimeInterval(-500)), t0,
                       "once the app has recorded an edit, the content clock is stale")
    }

    // MARK: Tombstones

    func testMarkDeletedKeepsTheIdWithADeletionClock() {
        let l = ledger()
        l.touch(.flight, "a", at: t0)
        l.markDeleted(.flight, "a", at: t0.addingTimeInterval(60))

        XCTAssertEqual(l.entry(.flight, "a")?.deleted, true,
                       "forgetting the id is what resurrects the record on the next sync")
        XCTAssertEqual(l.tombstones(.flight).map(\.id), ["a"])
        XCTAssertEqual(l.tombstones(.flight).first?.modifiedAt, t0.addingTimeInterval(60))
    }

    /// The key is `kind/id`, so reading an id back out means dropping exactly the right prefix.
    /// `"flight"` and `"note"` are different lengths, which is how off-by-one arithmetic here would
    /// show up as notes whose ids are silently truncated.
    func testTombstoneIdsSurviveTheRoundTripForEveryKind() {
        let l = ledger()
        for kind in SyncRecord.Kind.allCases {
            l.markDeleted(kind, "id-for-\(kind.rawValue)", at: t0)
        }
        for kind in SyncRecord.Kind.allCases {
            XCTAssertEqual(l.tombstones(kind).map(\.id), ["id-for-\(kind.rawValue)"],
                           "\(kind.rawValue) tombstone ids must come back whole")
        }
    }

    func testTombstonesAreScopedToTheirKind() {
        let l = ledger()
        l.markDeleted(.flight, "a", at: t0)
        l.markDeleted(.note, "b", at: t0)
        XCTAssertEqual(l.tombstones(.flight).map(\.id), ["a"])
        XCTAssertEqual(l.tombstones(.note).map(\.id), ["b"])
    }

    func testTouchClearsAnEarlierTombstone() {
        let l = ledger()
        l.markDeleted(.flight, "a", at: t0)
        l.touch(.flight, "a", at: t0.addingTimeInterval(60))
        XCTAssertTrue(l.tombstones(.flight).isEmpty, "an undelete is a write, not a second deletion")
    }

    // MARK: Adoption

    func testAdoptStopsAppliedRemoteRecordsFromBeingPushedBack() {
        let l = ledger()
        let remote = SyncRecord(id: "a", kind: .flight, modifiedAt: t0, payload: Data("x".utf8))
        l.adopt([remote])
        XCTAssertEqual(l.clock(.flight, "a", fallback: .distantPast), t0,
                       "without adoption the next merge reads this as locally-newer and re-uploads it")
    }

    func testAdoptingATombstoneRecordsTheDeletion() {
        let l = ledger()
        l.adopt([.tombstone(id: "a", kind: .note, at: t0)])
        XCTAssertEqual(l.tombstones(.note).map(\.id), ["a"])
    }

    // MARK: Pruning and persistence

    func testPruneDropsTombstonesPastTheWindowAndKeepsLiveEntries() {
        let l = ledger()
        l.touch(.flight, "live", at: t0)
        l.markDeleted(.flight, "stale", at: t0)
        l.markDeleted(.flight, "fresh", at: t0)

        // `stale` and `fresh` share a clock, so prune at a `now` that puts both past the window and
        // then at one that keeps both — the boundary itself is what the window means.
        l.prune(now: t0.addingTimeInterval(SyncLedger.tombstoneWindow - 1))
        XCTAssertEqual(l.tombstones(.flight).count, 2, "inside the window, nothing is dropped")

        l.prune(now: t0.addingTimeInterval(SyncLedger.tombstoneWindow + 1))
        XCTAssertTrue(l.tombstones(.flight).isEmpty, "past the window, tombstones go")
        XCTAssertEqual(l.entry(.flight, "live")?.deleted, false, "a live entry is never pruned")
    }

    func testTheLedgerSurvivesARelaunch() {
        do {
            let l = ledger()
            l.touch(.flight, "a", at: t0)
            l.markDeleted(.note, "b", at: t0)
        }
        let reopened = ledger()
        XCTAssertEqual(reopened.entry(.flight, "a")?.modifiedAt, t0)
        XCTAssertEqual(reopened.tombstones(.note).map(\.id), ["b"],
                       "a tombstone that does not survive a relaunch resurrects its record")
    }
}
