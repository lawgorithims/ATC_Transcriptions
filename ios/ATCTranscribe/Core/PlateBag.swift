import Foundation

/// Bulk plate downloader for the Flight Bag — fetches every published plate for a set of airports (a
/// filed route, the current airport, or a region bundle) into `PlateStore`, with progress + cancel.
/// One job at a time; bounded concurrency; plates already cached are skipped. `@MainActor` so its
/// `@Published` progress drives the UI directly.
@MainActor
final class PlateBag: ObservableObject {
    struct Job: Equatable { var label: String; var done: Int; var total: Int; var running: Bool }
    @Published private(set) var job = Job(label: "", done: 0, total: 0, running: false)
    @Published private(set) var cachedBytes: Int64 = 0
    @Published private(set) var cachedCount: Int = 0

    private var task: Task<Void, Never>?
    private var generation = 0          // bumped on every start/cancel so a stale run's tail writes are ignored
    private static let maxConcurrent = 4

    init() { refreshCacheStats() }

    var isRunning: Bool { job.running }

    func refreshCacheStats() {
        cachedBytes = PlateStore.cachedBytes()
        cachedCount = PlateStore.cachedCount()
    }

    /// Download all plates for `airports` (deduped). `label` names the job for the UI. No-op while a
    /// job is already running. The pending list (flatMap + fileExists over up to thousands of plates for
    /// a region bundle) is computed OFF the main actor so the UI never freezes on confirm (C6).
    func download(airports: [String], label: String) {
        assert(!label.isEmpty, "download: empty label")
        guard !isRunning else { return }
        let idents = Array(Set(airports.map { $0.trimmingCharacters(in: .whitespaces).uppercased() }))
            .filter { !$0.isEmpty }
        guard !idents.isEmpty else { return }
        generation &+= 1
        let gen = generation
        job = Job(label: label, done: 0, total: 0, running: true)   // total filled in after the off-main scan
        task = Task { [weak self] in
            let pending = await Self.pendingPlates(idents)           // nonisolated → runs off the main actor
            await self?.beginRun(pending, gen: gen)
        }
    }

    func cancel() {
        task?.cancel(); task = nil
        generation &+= 1            // invalidate the cancelled run's in-flight progress writes (C9)
        job.running = false
        refreshCacheStats()
    }

    func clearCache() {
        guard !isRunning else { return }
        PlateStore.clearAll()
        refreshCacheStats()
        job = Job(label: "Cache cleared", done: 0, total: 0, running: false)
    }

    /// Off the main actor: the plates for `idents` not already on disk. `Procedures.forAirport` (load-once
    /// bundled data) and `PlateStore.isCached` (FileManager) are both thread-safe, so this is safe here.
    nonisolated private static func pendingPlates(_ idents: [String]) async -> [AirportProcedure] {
        assert(idents.count < 100_000, "pendingPlates: runaway ident list")
        var out: [AirportProcedure] = []
        for icao in idents.prefix(20_000) {
            for p in Procedures.forAirport(icao) where !PlateStore.isCached(p) { out.append(p) }
        }
        return out
    }

    /// Back on the main actor after the scan: publish the total and run, unless a newer job superseded us.
    private func beginRun(_ pending: [AirportProcedure], gen: Int) async {
        guard gen == generation else { return }        // cancelled / superseded while scanning
        guard !pending.isEmpty else {
            job = Job(label: "\(job.label) — already downloaded", done: 0, total: 0, running: false)
            return
        }
        job.total = pending.count
        await run(pending, gen: gen)
    }

    /// Run the pending plates through a bounded-concurrency task group (keep-N-in-flight), updating
    /// progress on the main actor as each completes. All state writes are gated on `gen == generation`
    /// so a cancelled/superseded run's draining tail never clobbers a newer job (C9).
    private func run(_ plates: [AirportProcedure], gen: Int) async {
        assert(!plates.isEmpty, "run: no plates")
        var index = 0, done = 0
        await withTaskGroup(of: Void.self) { group in
            func addNext() {
                guard index < plates.count, !Task.isCancelled else { return }
                let p = plates[index]; index += 1
                group.addTask { _ = await PlateStore.ensureOnDisk(p) }
            }
            for _ in 0..<min(Self.maxConcurrent, plates.count) { addNext() }
            for await _ in group {
                assert(done <= plates.count, "run: overran plate count")
                done += 1
                if gen == generation {                 // only the current job may write progress
                    job.done = done
                    if done % 8 == 0 { refreshCacheStats() }
                }
                if Task.isCancelled { break }
                addNext()
            }
        }
        if gen == generation { job.running = false; refreshCacheStats() }
    }

    /// Airports referenced by a filed plan: departure / destination / alternate, plus route legs that
    /// look like airport idents that actually publish plates. Deduped.
    static func routeAirports(_ plan: FlightPlan?) -> [String] {
        guard let plan else { return [] }
        var out: [String] = []
        for s in [plan.departure, plan.destination, plan.alternate] {
            let t = s.trimmingCharacters(in: .whitespaces).uppercased()
            if !t.isEmpty, !Procedures.forAirport(t).isEmpty { out.append(t) }
        }
        for leg in plan.route.prefix(64) {
            let t = leg.trimmingCharacters(in: .whitespaces).uppercased()
            if t.count >= 3, t.count <= 4, t.allSatisfy({ $0.isLetter }), !Procedures.forAirport(t).isEmpty {
                out.append(t)
            }
        }
        return Array(Set(out))
    }
}
