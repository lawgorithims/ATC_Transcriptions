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
    private static let maxConcurrent = 4

    init() { refreshCacheStats() }

    var isRunning: Bool { job.running }

    func refreshCacheStats() {
        cachedBytes = PlateStore.cachedBytes()
        cachedCount = PlateStore.cachedCount()
    }

    /// Download all plates for `airports` (deduped). `label` names the job for the UI. No-op while a
    /// job is already running.
    func download(airports: [String], label: String) {
        assert(!label.isEmpty, "download: empty label")
        guard !isRunning else { return }
        let idents = Array(Set(airports.map { $0.trimmingCharacters(in: .whitespaces).uppercased() }))
            .filter { !$0.isEmpty }
        let pending = idents.flatMap { Procedures.forAirport($0) }.filter { !PlateStore.isCached($0) }
        guard !pending.isEmpty else {
            job = Job(label: "\(label) — already downloaded", done: 0, total: 0, running: false)
            return
        }
        job = Job(label: label, done: 0, total: pending.count, running: true)
        task = Task { [weak self] in await self?.run(pending) }
    }

    func cancel() {
        task?.cancel(); task = nil
        job.running = false
        refreshCacheStats()
    }

    func clearCache() {
        guard !isRunning else { return }
        PlateStore.clearAll()
        refreshCacheStats()
        job = Job(label: "Cache cleared", done: 0, total: 0, running: false)
    }

    /// Run the pending plates through a bounded-concurrency task group (keep-N-in-flight), updating
    /// progress on the main actor as each completes.
    private func run(_ plates: [AirportProcedure]) async {
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
                job.done = done
                if done % 8 == 0 { refreshCacheStats() }
                if Task.isCancelled { break }
                addNext()
            }
        }
        job.running = false
        refreshCacheStats()
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
