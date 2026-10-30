import Foundation

/// The per-record sync clock, and the only home for tombstones.
///
/// # Why the clock is not a field on `LoggedFlight` / `Note`
///
/// Two reasons, and the second is the one that settles it:
///
/// 1. `LoggedFlight` has no `updatedAt` and adding one changes its memberwise init, its `Equatable`
///    conformance and the shape of `flights.json` — a migration, for a field the app itself never reads.
/// 2. **A tombstone has no record to hold a field.** The whole point of a tombstone is that it outlives
///    the thing it describes, so the deletion clock has to live outside the model whatever we do with
///    the edit clock. Splitting them across two homes would mean two sources of truth for "when did
///    this record last change", which is exactly the question the merge asks.
///
/// # Records that predate the ledger
///
/// Every pilot already using the app has a logbook with no ledger beside it. Those records get their
/// clock from their own content — a flight's `endedAt`, a note's `updatedAt` — via the `fallback`
/// argument, never from `Date()`. That matters: a wall-clock fallback would make whichever device
/// synced second look like the newer writer and clobber the other's copy, while a content-derived
/// clock is **the same number on every device**, so the first sync of an existing library converges
/// instead of picking a winner.
@MainActor final class SyncLedger {

    /// The app's ledger, in `Documents/Sync`. One instance for both stores: the keys are `kind/id`, so
    /// the logbook and the note library cannot collide, and a single file means one prune and one
    /// place to look when a record will not stay deleted.
    static let shared = SyncLedger()

    struct Entry: Codable, Equatable {
        var modifiedAt: Date
        var deleted: Bool
    }

    /// How long a tombstone is kept. See `SyncMerge.pruning` — this is a correctness parameter.
    ///
    /// 180 days, because the device this has to survive is an iPad that lives in a flight bag between
    /// trips. A pilot who flies in April and again in September must not find the flights they deleted
    /// in April restored from the iPhone that never got the news.
    static let tombstoneWindow: TimeInterval = 180 * 24 * 60 * 60

    private var entries: [String: Entry] = [:]
    private let fileURL: URL

    init(directory: URL? = nil) {
        let dir = directory ?? Self.defaultDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("ledger.json")
        load()
    }

    // MARK: Reads

    func entry(_ kind: SyncRecord.Kind, _ id: String) -> Entry? { entries["\(kind.rawValue)/\(id)"] }

    /// The clock for a live local record: its ledger entry if it has one, else `fallback` (see the
    /// note above on records that predate the ledger).
    func clock(_ kind: SyncRecord.Kind, _ id: String, fallback: Date) -> Date {
        entry(kind, id)?.modifiedAt ?? fallback
    }

    /// Every surviving tombstone, as records the merge can compare directly.
    func tombstones(_ kind: SyncRecord.Kind) -> [SyncRecord] {
        entries.compactMap { key, entry in
            guard entry.deleted, key.hasPrefix("\(kind.rawValue)/") else { return nil }
            return SyncRecord.tombstone(id: String(key.dropFirst(kind.rawValue.count + 1)),
                                        kind: kind, at: entry.modifiedAt)
        }
        .sorted { $0.id < $1.id }
    }

    // MARK: Writes

    /// A local edit or insert. Clears any tombstone for the id — an undelete is a legitimate write and
    /// has to beat the deletion it supersedes, which it does by carrying a later clock.
    func touch(_ kind: SyncRecord.Kind, _ id: String, at: Date = Date()) {
        entries["\(kind.rawValue)/\(id)"] = Entry(modifiedAt: at, deleted: false)
        persist()
    }

    /// A local delete. Keeps the id with a deletion clock rather than forgetting it, because
    /// forgetting is what resurrects the record on the next sync.
    func markDeleted(_ kind: SyncRecord.Kind, _ id: String, at: Date = Date()) {
        entries["\(kind.rawValue)/\(id)"] = Entry(modifiedAt: at, deleted: true)
        persist()
    }

    /// Record the clocks of remote records the stores have just applied, so the next merge does not
    /// see them as locally-newer and push them straight back.
    func adopt(_ records: [SyncRecord]) {
        for r in records {
            entries[r.key] = Entry(modifiedAt: r.modifiedAt, deleted: r.deleted)
        }
        persist()
    }

    /// Drop tombstones past the window. Live entries are never pruned.
    func prune(now: Date = Date()) {
        let before = entries.count
        entries = entries.filter { _, e in
            !e.deleted || now.timeIntervalSince(e.modifiedAt) < Self.tombstoneWindow
        }
        if entries.count != before { persist() }
    }

    // MARK: Storage

    private func load() {
        guard let d = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: d) else { return }
        entries = decoded
    }

    private func persist() {
        guard let d = try? JSONEncoder().encode(entries) else { return }
        try? d.write(to: fileURL, options: .atomic)
    }

    /// `Documents/Sync`, beside `Documents/Logbook` and `Documents/Notes` — and in the iCloud device
    /// backup with them, which is deliberate. A restored device that gets the stores without their
    /// clocks would re-push its whole library as newly-modified.
    private static var defaultDir: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return docs.appendingPathComponent("Sync", isDirectory: true)
    }
}
