import Foundation

/// What a fetch came back with.
struct CloudSyncChanges: Equatable, Sendable {
    /// Changed records, live and tombstoned.
    ///
    /// This is a **delta**, not the cloud's whole library — with a change token the server sends only
    /// what moved since that token. `SyncMerge` rule 1 is what makes that safe to hand straight to the
    /// merge: the key set is the union, so a local record the delta does not mention is left alone
    /// rather than read as deleted. A merge written against "remote is the full truth" would wipe the
    /// library on the second sync of every device.
    var records: [SyncRecord] = []
    /// Opaque server cursor to hand back on the next fetch. `nil` means "start from the beginning".
    var token: Data?
}

/// The seam between the merge and CloudKit.
///
/// Exists so `SyncCoordinator` — which decides what to keep, what to delete and what to upload — can
/// be tested without a container, an iCloud account or a network. The same reason
/// `ModelDownloadManager` takes a `ModelDownloading`: the state machine has to be testable without the
/// thing it drives.
protocol CloudSyncTransport: Sendable {
    func fetchChanges(since token: Data?) async throws -> CloudSyncChanges
    func push(_ records: [SyncRecord]) async throws
}

/// An in-process stand-in for the real container.
///
/// Used by the tests, and by a build with the cloud-sync gate off, where it means the coordinator runs
/// its whole merge honestly against an empty cloud and changes nothing — the same arrangement as
/// `Features.transcription`, where the engine and its tests survive the gate that hides the UI.
actor InMemoryCloudTransport: CloudSyncTransport {
    private var stored: [String: SyncRecord] = [:]
    private var bumps = 0
    private var pushedRecords = 0
    /// Armed one call at a time, so a test can let the fetch succeed and fail only the push that
    /// follows it — the order the coordinator's "apply before push" guarantee is actually about.
    private var fetchError: Error?
    private var pushError: Error?

    init(seed: [SyncRecord] = []) {
        for r in seed { stored[r.key] = r }
    }

    func failOnFetch(_ error: Error) { fetchError = error }
    func failOnPush(_ error: Error) { pushError = error }

    /// Everything held, ignoring the token — a delta is a superset-safe input to the merge, so a
    /// transport that always returns everything is a valid (if chatty) implementation.
    func fetchChanges(since token: Data?) async throws -> CloudSyncChanges {
        if let e = fetchError { fetchError = nil; throw e }
        bumps += 1
        return CloudSyncChanges(records: stored.values.sorted { $0.key < $1.key },
                                token: Data("\(bumps)".utf8))
    }

    func push(_ records: [SyncRecord]) async throws {
        if let e = pushError { pushError = nil; throw e }
        pushedRecords += records.count
        for r in records { stored[r.key] = r }
    }

    /// Test inspection.
    func contents() -> [SyncRecord] { stored.values.sorted { $0.key < $1.key } }

    /// How many records have been uploaded in total. A converged pair of devices must stop adding to
    /// this — see `StoreSyncTests.testAConvergedPairStopsTalking`.
    func uploadCount() -> Int { pushedRecords }
}
