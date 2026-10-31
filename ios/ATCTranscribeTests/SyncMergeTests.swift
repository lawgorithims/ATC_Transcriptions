import XCTest
@testable import ATCTranscribe

/// The merge, asserted case by case.
///
/// This is where a sync engine loses a pilot's logbook, so the rules are tested as rules rather than
/// through the stores: `SyncMerge` is a pure function and every branch is reachable with two arrays.
final class SyncMergeTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func rec(_ id: String, _ kind: SyncRecord.Kind = .flight,
                     at offset: TimeInterval = 0, _ body: String = "x") -> SyncRecord {
        SyncRecord(id: id, kind: kind, modifiedAt: t0.addingTimeInterval(offset),
                   payload: Data(body.utf8))
    }
    private func dead(_ id: String, _ kind: SyncRecord.Kind = .flight,
                      at offset: TimeInterval = 0) -> SyncRecord {
        .tombstone(id: id, kind: kind, at: t0.addingTimeInterval(offset))
    }

    // MARK: Rule 1 — the union

    /// ⚠️ THE MOST IMPORTANT TEST IN THIS FILE.
    ///
    /// A record the cloud has never heard of must be PUSHED, not deleted. Every catastrophic sync bug
    /// is a variation on reading "absent from the fetch" as "deleted elsewhere": the fetch is a delta,
    /// so on a healthy second sync it is legitimately empty while the device holds a full library.
    ///
    /// If this fails, the first sync after installing on a second iPad empties the first one.
    func testARecordMissingFromTheCloudIsPushedAndNeverDeleted() {
        let mine = [rec("a"), rec("b"), rec("c")]
        let out = SyncMerge.merge(local: mine, remote: [])

        XCTAssertEqual(out.resolved.count, 3, "nothing may be dropped because the cloud did not mention it")
        XCTAssertEqual(out.toPush.map(\.id), ["a", "b", "c"], "all three are ours to upload")
        XCTAssertTrue(out.toApply.isEmpty, "there is nothing to apply from an empty delta")
        XCTAssertFalse(out.resolved.values.contains { $0.deleted },
                       "an absent remote must never manufacture a tombstone")
    }

    /// And the mirror: a record only the cloud has is adopted, not ignored.
    func testARecordOnlyTheCloudHasIsApplied() {
        let out = SyncMerge.merge(local: [], remote: [rec("a")])
        XCTAssertEqual(out.toApply.map(\.id), ["a"])
        XCTAssertTrue(out.toPush.isEmpty)
        XCTAssertEqual(out.resolved.count, 1)
    }

    func testIdenticalRecordsProduceNoTraffic() {
        let both = [rec("a"), rec("b")]
        let out = SyncMerge.merge(local: both, remote: both)
        XCTAssertTrue(out.toPush.isEmpty, "agreeing sides must not churn CloudKit")
        XCTAssertTrue(out.toApply.isEmpty, "agreeing sides must not rewrite the stores")
        XCTAssertEqual(out.resolved.count, 2)
    }

    // MARK: Rule 2 — last writer wins

    func testTheLaterEditWinsInBothDirections() {
        let older = rec("a", at: 0, "old"), newer = rec("a", at: 60, "new")

        let remoteWins = SyncMerge.merge(local: [older], remote: [newer])
        XCTAssertEqual(remoteWins.toApply.first?.payload, Data("new".utf8))
        XCTAssertTrue(remoteWins.toPush.isEmpty)

        let localWins = SyncMerge.merge(local: [newer], remote: [older])
        XCTAssertEqual(localWins.toPush.first?.payload, Data("new".utf8))
        XCTAssertTrue(localWins.toApply.isEmpty)
    }

    /// A delete beats an edit that came before it.
    func testADeletionBeatsAnOlderEdit() {
        let out = SyncMerge.merge(local: [rec("a", at: 0)], remote: [dead("a", at: 60)])
        XCTAssertEqual(out.toApply.count, 1)
        XCTAssertTrue(out.toApply[0].deleted, "the tombstone must reach the store as a deletion")
        XCTAssertEqual(out.resolved["flight/a"]?.deleted, true)
    }

    /// And an edit after a delete UNDELETES — which is the correct reading of "I edited this flight
    /// on the iPad after deleting it on the phone", and the reason the clock is single.
    func testANewerEditUndeletesARecord() {
        let out = SyncMerge.merge(local: [rec("a", at: 120, "revived")], remote: [dead("a", at: 60)])
        XCTAssertEqual(out.toPush.count, 1)
        XCTAssertFalse(out.toPush[0].deleted)
        XCTAssertEqual(out.resolved["flight/a"]?.payload, Data("revived".utf8))
    }

    // MARK: Rule 3 — a tie favours the data

    func testOnAnExactTieTheLiveRecordBeatsTheTombstone() {
        let live = rec("a", at: 0, "keep me"), gone = dead("a", at: 0)

        for (local, remote) in [(live, gone), (gone, live)] {
            let out = SyncMerge.merge(local: [local], remote: [remote])
            XCTAssertEqual(out.resolved["flight/a"]?.deleted, false,
                           "a pilot can delete a flight again; they cannot un-lose one, so a dead "
                           + "heat must resolve towards the data")
        }
    }

    // MARK: Rule 4 — convergence, not kindness

    /// Same clock, both live, different bytes: both devices must choose the SAME side without talking
    /// to each other, or they ping-pong forever. "Prefer local" is the tempting rule and is the bug.
    func testAnUnresolvableTieIsDecidedTheSameWayFromBothSides() {
        let a = rec("x", at: 0, "aaa"), b = rec("x", at: 0, "bbb")

        let fromA = SyncMerge.merge(local: [a], remote: [b]).resolved["flight/x"]
        let fromB = SyncMerge.merge(local: [b], remote: [a]).resolved["flight/x"]
        XCTAssertEqual(fromA, fromB, "the two devices disagreed, so neither will ever stop pushing")
    }

    // MARK: Kinds

    /// `Note.id` and `LoggedFlight.id` are both UUID strings. Keyed on the bare id, a note would
    /// overwrite a flight.
    func testTheSameIdInTwoKindsDoesNotCollide() {
        let out = SyncMerge.merge(local: [rec("same", .flight, at: 0, "a flight")],
                                  remote: [rec("same", .note, at: 60, "a note")])
        XCTAssertEqual(out.resolved.count, 2, "two kinds, two records")
        XCTAssertEqual(out.resolved["flight/same"]?.payload, Data("a flight".utf8))
        XCTAssertEqual(out.resolved["note/same"]?.payload, Data("a note".utf8))
        XCTAssertTrue(out.toApply.allSatisfy { $0.kind == .note }, "only the note came from the cloud")
    }

    // MARK: Convergence as a property

    /// Merging the result again changes nothing. A merge that is not a fixed point syncs forever.
    func testMergingIsIdempotent() {
        let local = [rec("a", at: 0), rec("b", at: 30), dead("c", at: 10)]
        let remote = [rec("b", at: 90, "newer"), rec("d", at: 5)]

        let once = SyncMerge.merge(local: local, remote: remote)
        let settled = Array(once.resolved.values)
        let twice = SyncMerge.merge(local: settled, remote: settled)

        XCTAssertEqual(twice.resolved, once.resolved)
        XCTAssertTrue(twice.toPush.isEmpty && twice.toApply.isEmpty,
                      "a settled pair of sides must generate no work")
    }

    /// Two devices with divergent libraries reach the same answer from their own point of view.
    func testTwoDevicesConvergeOnTheSameTruth() {
        let iPad = [rec("a", at: 0), rec("shared", at: 30, "ipad"), dead("gone", at: 50)]
        let phone = [rec("b", at: 0), rec("shared", at: 90, "phone")]

        let onIPad = SyncMerge.merge(local: iPad, remote: phone).resolved
        let onPhone = SyncMerge.merge(local: phone, remote: iPad).resolved

        XCTAssertEqual(onIPad, onPhone)
        XCTAssertEqual(onIPad["flight/shared"]?.payload, Data("phone".utf8), "the later edit won")
        XCTAssertEqual(onIPad["flight/a"]?.deleted, false, "the iPad's record survived")
        XCTAssertEqual(onIPad["flight/b"]?.deleted, false, "the phone's record survived")
        XCTAssertEqual(onIPad["flight/gone"]?.deleted, true, "the deletion propagated")
    }

    // MARK: Tombstone retention

    func testPruningDropsOldTombstonesAndKeepsEverythingElse() {
        let window: TimeInterval = 100
        let now = t0.addingTimeInterval(1000)
        let records = [rec("live", at: 0),            // ancient but alive
                       dead("old", at: 0),            // 1000s old — past the window
                       dead("recent", at: 950)]       // 50s old — inside it

        let kept = SyncMerge.pruning(records, olderThan: window, now: now).map(\.id).sorted()
        XCTAssertEqual(kept, ["live", "recent"])
    }

    /// The hazard the window exists for, written as a test so the reason survives.
    func testAPrunedTombstoneResurrectsTheRecord() {
        let now = t0.addingTimeInterval(1000)
        let cloud = SyncMerge.pruning([dead("a", at: 0)], olderThan: 100, now: now)
        XCTAssertTrue(cloud.isEmpty, "precondition: the tombstone has been pruned")

        // A device that was offline the whole time still holds the record.
        let out = SyncMerge.merge(local: [rec("a", at: 0)], remote: cloud)
        XCTAssertEqual(out.toPush.map(\.id), ["a"],
                       "with no tombstone left, rule 1 cannot tell a deleted record from a new one — "
                       + "which is exactly why SyncLedger.tombstoneWindow is 180 days and not a week")
    }

    func testTheShippedWindowIsLongEnoughForAFlightBagIPad() {
        XCTAssertGreaterThanOrEqual(SyncLedger.tombstoneWindow, 90 * 24 * 60 * 60,
                                    "a tombstone has to outlive a season of not flying")
    }
}
