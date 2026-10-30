import Foundation

/// The merge. A pure function of (local records, remote records) → what to keep, push and apply.
///
/// # Why this is pure, and why it is the only thing here with exhaustive tests
///
/// Every way a sync engine destroys a pilot's logbook passes through this function. CloudKit's own
/// failure modes are recoverable — a push that fails retries, a fetch that fails refetches — but a
/// merge that decides "the cloud does not have this flight, so delete it" is not recoverable, because
/// the next push propagates the deletion to every other device. So the transport is injectable, the
/// scheduling lives elsewhere, and this file has no dependencies beyond `Foundation`.
///
/// # The rules, in the order they are applied
///
/// 1. **The key set is the UNION of both sides, never the intersection.** A record present only
///    locally is pushed; a record present only remotely is applied. **Absence is never deletion.**
///    This is the whole rule. A deletion is a tombstone — a record that says so — and nothing else
///    counts, because "not in the set I just fetched" is indistinguishable from a partial fetch, a
///    fresh iCloud account, a zone that was reset, or a device that has simply never pushed.
/// 2. **Later `modifiedAt` wins.** Last-writer-wins, where a tombstone's clock is its deletion time,
///    so a delete beats an older edit and a newer edit *undeletes* (which is the correct read of
///    "I edited this flight after you deleted it").
/// 3. **On an exact clock tie, the live record beats the tombstone.** Preserving data is the right bias
///    for a logbook; the pilot can always delete again, and cannot un-lose a flight.
/// 4. **Still tied, both live, payloads differ → the payload that sorts later wins.** Arbitrary on
///    purpose: the rule's only job is that every device picks the SAME side without talking to any
///    other, so the devices converge. "Prefer local" looks kinder and diverges forever.
enum SyncMerge {

    /// What the caller must do after a merge.
    struct Outcome: Equatable {
        /// The merged truth, keyed by `SyncRecord.key`. Includes surviving tombstones.
        var resolved: [String: SyncRecord] = [:]
        /// Local versions that won, and so have to go up.
        var toPush: [SyncRecord] = []
        /// Remote versions that won, and so have to be written into the stores. Includes tombstones,
        /// which the stores turn into deletions.
        var toApply: [SyncRecord] = []
    }

    static func merge(local: [SyncRecord], remote: [SyncRecord]) -> Outcome {
        var localByKey: [String: SyncRecord] = [:]
        for r in local { localByKey[r.key] = r }
        var remoteByKey: [String: SyncRecord] = [:]
        for r in remote { remoteByKey[r.key] = r }

        var out = Outcome()
        // RULE 1: the union. Sorted so `toPush` / `toApply` are deterministic, which is what makes
        // this testable and makes two runs over the same input produce the same CloudKit batch.
        for key in Set(localByKey.keys).union(remoteByKey.keys).sorted() {
            switch (localByKey[key], remoteByKey[key]) {
            case let (.some(mine), .none):
                out.resolved[key] = mine
                out.toPush.append(mine)
            case let (.none, .some(theirs)):
                out.resolved[key] = theirs
                out.toApply.append(theirs)
            case let (.some(mine), .some(theirs)):
                if mine == theirs {
                    out.resolved[key] = mine          // already agreed; no traffic either way
                } else if winner(mine, theirs) == .local {
                    out.resolved[key] = mine
                    out.toPush.append(mine)
                } else {
                    out.resolved[key] = theirs
                    out.toApply.append(theirs)
                }
            case (.none, .none):
                continue                              // unreachable: the key came from one of the two
            }
        }
        return out
    }

    private enum Side { case local, remote }

    /// Rules 2–4, in order.
    private static func winner(_ mine: SyncRecord, _ theirs: SyncRecord) -> Side {
        if mine.modifiedAt != theirs.modifiedAt {
            return mine.modifiedAt > theirs.modifiedAt ? .local : .remote      // 2
        }
        if mine.deleted != theirs.deleted {
            return mine.deleted ? .remote : .local                             // 3 — live beats tombstone
        }
        // 4 — same clock, same deleted-ness, different bytes. Deterministic, not clever.
        let a = mine.payload ?? Data(), b = theirs.payload ?? Data()
        return a.lexicographicallyPrecedes(b) ? .remote : .local
    }

    // MARK: Tombstone retention

    /// Drop tombstones older than `window`, keeping every live record.
    ///
    /// ⚠️ THE WINDOW IS A CORRECTNESS PARAMETER, not housekeeping. A tombstone is the only evidence
    /// that a record was deleted; prune it while a device that still holds that record is offline, and
    /// when that device next syncs, rule 1 reads its copy as a record the cloud has never seen and
    /// pushes it back. The deleted flight returns, on every device.
    ///
    /// `SyncLedger.tombstoneWindow` is deliberately long for that reason. An iPad that lives in a
    /// flight bag between trips is offline for weeks as a matter of course.
    static func pruning(_ records: [SyncRecord], olderThan window: TimeInterval, now: Date) -> [SyncRecord] {
        assert(window > 0, "pruning: a non-positive window deletes every tombstone immediately")
        return records.filter { !$0.deleted || now.timeIntervalSince($0.modifiedAt) < window }
    }
}
