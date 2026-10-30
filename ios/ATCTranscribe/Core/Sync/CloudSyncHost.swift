import Foundation
import Combine

/// Owns the app's live `SyncCoordinator`, so `ATCTranscribeApp` stays three lines.
///
/// Exists because the coordinator needs the two stores, and a `@StateObject` cannot be initialised
/// from another `@StateObject` — so it is built once the view tree is up, from `.task`, and kept here.
///
/// Every entry point is a no-op when `Features.cloudSync` is off, which is the default build. Nothing
/// instantiates `CKContainer` in that case: asking for a container the binary is not entitled to reach
/// is a runtime failure, and the gate is what guarantees we never ask.
@MainActor final class CloudSyncHost: ObservableObject {

    /// Shown by a settings row when sync is failing. Failure is ordinary — no iCloud account, iCloud
    /// Drive switched off, no signal — and must never be surfaced as an app error.
    @Published private(set) var lastError: String?

    private var coordinator: SyncCoordinator?
    private var started = false

    /// Build the coordinator and do a first pass. Idempotent: a second call is ignored, so a scene
    /// that re-appears does not end up with two coordinators pushing the same records.
    func start(logbook: Logbook, notes: NotesStore) async {
        guard Features.cloudSync, !started else { return }
        started = true
        #if canImport(CloudKit)
        coordinator = SyncCoordinator(ledger: .shared,
                                      transport: CloudKitTransport(),
                                      adapters: [logbook.syncAdapter, notes.syncAdapter])
        await syncNow()
        #endif
    }

    /// A pass on foreground, or from a pull-to-refresh. Quiet by design.
    func syncNow() async {
        guard let coordinator else { return }
        await coordinator.syncQuietly()
        lastError = coordinator.lastError
    }
}
