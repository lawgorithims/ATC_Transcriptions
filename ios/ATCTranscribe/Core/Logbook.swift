import Foundation

/// The flight logbook: every saved flight, newest first, as one JSON file under Documents/Logbook. Mirrors
/// NotesStore's on-disk pattern, but takes an injectable directory so it's unit-testable (NotesStore
/// hardcodes Documents and can't be tested — deliberately NOT copied).
@MainActor final class Logbook: ObservableObject {
    @Published private(set) var flights: [LoggedFlight] = []

    static let maxFlights = 500
    private let dir: URL
    private var fileURL: URL { dir.appendingPathComponent("flights.json") }

    /// The sync clock for each flight, and the only home for a deleted flight's tombstone.
    /// See `Logbook+Sync.swift`.
    let ledger: SyncLedger

    /// A caller that hands over a scratch `directory` gets a scratch `ledger` beside it unless it says
    /// otherwise, so a test can never write sync clocks into the real container or leak them into the
    /// next test. The app passes neither and gets Documents plus the shared ledger.
    init(directory: URL? = nil, ledger: SyncLedger? = nil) {
        let resolved = directory ?? Logbook.defaultDir
        dir = resolved
        self.ledger = ledger ?? (directory == nil ? .shared : SyncLedger(directory: resolved))
        try? FileManager.default.createDirectory(at: resolved, withIntermediateDirectories: true)
        load()
    }

    /// Insert a finished flight (clamps its detail breadcrumb + caps the list). Idempotent-safe on id.
    func add(_ flight: LoggedFlight) {
        assert(flight.endedAt >= flight.startedAt, "add: end before start")
        assert(!flights.contains { $0.id == flight.id }, "add: duplicate flight id")
        var f = flight
        if f.breadcrumb.count > LoggedFlight.maxBreadcrumb {
            f = f.withBreadcrumb(Array(f.breadcrumb.prefix(LoggedFlight.maxBreadcrumb)))
        }
        flights.insert(f, at: 0)
        if flights.count > Self.maxFlights { flights = Array(flights.prefix(Self.maxFlights)) }
        assert(flights.count <= Self.maxFlights, "add: list over cap")
        ledger.touch(.flight, f.id.uuidString)
        persist()
    }

    func delete(_ id: UUID) {
        flights.removeAll { $0.id == id }
        // A tombstone, not a forgetting: an id this app simply stops mentioning is indistinguishable
        // from one it has never seen, and the next sync would fetch the flight back from the cloud.
        ledger.markDeleted(.flight, id.uuidString)
        persist()
    }

    /// Replace a flight (edited aircraft / notes), keeping newest-first order.
    func update(_ flight: LoggedFlight) {
        guard let i = flights.firstIndex(where: { $0.id == flight.id }) else { return }
        flights[i] = flight
        flights.sort { $0.startedAt > $1.startedAt }
        ledger.touch(.flight, flight.id.uuidString)
        persist()
    }

    // MARK: Sync

    /// This store's side of a sync pass: every live flight, plus the ledger's tombstones.
    ///
    /// A flight with no ledger entry — i.e. every flight in a logbook that predates this feature —
    /// takes its clock from `endedAt`. That is immutable, meaningful, and **identical on every
    /// device**, which is what makes the first sync of an existing library converge instead of
    /// letting whichever iPad synced second overwrite the other.
    func syncRecords() -> [SyncRecord] {
        let live: [SyncRecord] = flights.compactMap { f in
            guard let payload = try? SyncCoding.encoder.encode(f) else { return nil }
            return SyncRecord(id: f.id.uuidString, kind: .flight,
                              modifiedAt: ledger.clock(.flight, f.id.uuidString, fallback: f.endedAt),
                              payload: payload)
        }
        return live + ledger.tombstones(.flight)
    }

    /// Write merged records in. Tombstones are deletions; everything else is an upsert by id.
    ///
    /// ⚠️ `Self.maxFlights` is NOT applied here, and that is deliberate. The cap bounds what this app
    /// *creates* (500 × ~100 KB of breadcrumb). Applying it to merged records would drop the oldest
    /// flights the cloud holds, and then — because a flight absent from the store is "remote only" on
    /// the next pass — fetch and drop them again on every sync, forever. Two devices that each filled
    /// the cap with different flights can therefore exceed it once merged.
    func applySynced(_ records: [SyncRecord]) {
        // `uniquingKeysWith`, not `uniqueKeysWithValues`: the latter traps on a duplicate id, and this
        // dictionary is built from a decoded file. A corrupt flights.json must degrade, not crash.
        var byID = Dictionary(flights.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for r in records {
            guard let uuid = UUID(uuidString: r.id) else {
                assertionFailure("applySynced: non-UUID flight id \(r.id)")
                continue
            }
            if r.deleted {
                byID[uuid] = nil
            } else if let payload = r.payload,
                      let f = try? SyncCoding.decoder.decode(LoggedFlight.self, from: payload) {
                byID[uuid] = f
            }
        }
        flights = byID.values.sorted { $0.startedAt > $1.startedAt }
        // Adopt the clocks the merge settled on, or the next pass reads these same records as
        // locally-newer and pushes them straight back up.
        ledger.adopt(records)
        persist()
    }

    /// How the coordinator talks to this store.
    var syncAdapter: SyncCoordinator.StoreAdapter {
        SyncCoordinator.StoreAdapter(kind: .flight,
                                     localRecords: { [weak self] in self?.syncRecords() ?? [] },
                                     apply: { [weak self] in self?.applySynced($0) })
    }

    // MARK: persistence

    private func load() {
        guard let d = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([LoggedFlight].self, from: d) else { return }
        flights = Array(list.sorted { $0.startedAt > $1.startedAt }.prefix(Self.maxFlights))
    }
    private func persist() {
        guard let d = try? JSONEncoder().encode(flights) else { return }
        try? d.write(to: fileURL, options: .atomic)
    }

    private static var defaultDir: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return docs.appendingPathComponent("Logbook")
    }
}

extension LoggedFlight {
    /// Copy with a replaced breadcrumb (used to clamp the stored detail trail).
    func withBreadcrumb(_ crumbs: [Breadcrumb]) -> LoggedFlight {
        LoggedFlight(id: id, startedAt: startedAt, endedAt: endedAt, durationSec: durationSec,
                     distanceNM: distanceNM, maxSpeedKt: maxSpeedKt, avgSpeedKt: avgSpeedKt,
                     maxAltFtMSL: maxAltFtMSL, stops: stops, aircraftCallsign: aircraftCallsign,
                     aircraftType: aircraftType, notes: notes, breadcrumb: crumbs)
    }
}
