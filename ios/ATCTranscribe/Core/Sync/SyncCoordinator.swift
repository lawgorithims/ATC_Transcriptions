import Foundation
import Combine

/// Runs one sync pass: gather, fetch, merge, apply, push.
///
/// Holds no knowledge of CloudKit (that is `CloudSyncTransport`) and none of `LoggedFlight` or `Note`
/// (that is `StoreAdapter`), so the whole orchestration is testable with two closures and a dictionary.
///
/// # Order of operations, and why
///
/// Remote changes are applied to the stores **before** anything is pushed. If the push then fails, the
/// device has correctly adopted what the cloud knew and will retry the upload on the next pass — the
/// worst case is a delay. The other order risks the opposite: a successful push followed by a failed
/// apply leaves the cloud holding records this device has decided it owns but has not written down.
@MainActor final class SyncCoordinator: ObservableObject {

    /// How one store takes part. Deliberately closures rather than a protocol the stores conform to:
    /// `NotesStore` keeps its drawings in files beside its index and `Logbook` keeps one JSON array, so
    /// there is no shared shape to name — only a shared pair of questions.
    struct StoreAdapter {
        let kind: SyncRecord.Kind
        /// Everything this store contributes to a pass: its live records with clocks resolved through
        /// the ledger, PLUS its tombstones. Self-contained on purpose — the coordinator holds no view
        /// of what a given store has deleted, so the store is the only thing that can answer.
        let localRecords: @MainActor () -> [SyncRecord]
        /// Write winners in. Tombstones in this list are deletions; everything else is an upsert.
        let apply: @MainActor ([SyncRecord]) -> Void
    }

    /// Held only for `prune()` — tombstone retention is pass-level housekeeping, not a per-store
    /// concern. Record clocks are adopted by the stores themselves.
    private let ledger: SyncLedger
    private let transport: CloudSyncTransport
    private let adapters: [StoreAdapter]
    private let tokenURL: URL

    /// Last error, for a settings row to show. Sync failing is normal (no account, no signal) and must
    /// never be presented as an app error.
    @Published private(set) var lastError: String?

    init(ledger: SyncLedger,
         transport: CloudSyncTransport,
         adapters: [StoreAdapter],
         directory: URL? = nil) {
        assert(Set(adapters.map(\.kind)).count == adapters.count,
               "SyncCoordinator: two adapters for one kind would each apply the other's records")
        self.ledger = ledger
        self.transport = transport
        self.adapters = adapters
        let dir = directory ?? Self.defaultDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tokenURL = dir.appendingPathComponent("token.bin")
    }

    /// One pass. Throws only what the transport throws; a merge cannot fail.
    func sync() async throws {
        var local: [SyncRecord] = []
        for a in adapters { local += a.localRecords() }

        let changes = try await transport.fetchChanges(since: savedToken())
        let outcome = SyncMerge.merge(local: local, remote: changes.records)

        // Apply first (see the note above), one adapter at a time so a record of one kind can never be
        // handed to the store that owns the other.
        for a in adapters {
            let mine = outcome.toApply.filter { $0.kind == a.kind }
            if !mine.isEmpty { a.apply(mine) }
        }
        // Adopting the applied clocks is the STORE's job, inside its own `applySynced` — it is the only
        // thing that knows which ledger it writes to. Doing it again from here would write to whichever
        // ledger this coordinator happens to hold, which is the same object today and a silent
        // mis-attribution the day it is not.

        if !outcome.toPush.isEmpty {
            try await transport.push(outcome.toPush)
        }
        save(token: changes.token)
        ledger.prune()
        lastError = nil
    }

    /// `sync()` with the error swallowed into `lastError`, for call sites that fire and forget — a
    /// launch, a foreground, a pull-to-refresh. A pilot with no iCloud account must see nothing.
    func syncQuietly() async {
        do { try await sync() } catch { lastError = error.localizedDescription }
    }

    // MARK: Token

    private func savedToken() -> Data? { try? Data(contentsOf: tokenURL) }

    private func save(token: Data?) {
        guard let token else { try? FileManager.default.removeItem(at: tokenURL); return }
        try? token.write(to: tokenURL, options: .atomic)
    }

    private static var defaultDir: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return docs.appendingPathComponent("Sync", isDirectory: true)
    }
}
