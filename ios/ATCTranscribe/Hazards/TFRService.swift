import Foundation

/// TFR feed status surfaced to the UI (mirrors `EONETStatus`).
enum TFRStatus: Sendable, Equatable {
    case idle
    case ok
    case error(String)
}

/// Network seam so the service's lifecycle is unit-testable without hitting the FAA (a fake in tests,
/// `LiveTFRFetcher` in the app).
protocol TFRFetching: Sendable {
    func fetchActive() async throws -> [TFR]
}

/// Live fetch: the `exportTfrList` JSON + each active NOTAM's AIXM detail (bounded concurrency), parsed
/// by `TFRParser`. A detail that fails to fetch/parse is dropped, not fatal.
struct LiveTFRFetcher: TFRFetching {
    private static let listURL = URL(string: "https://tfr.faa.gov/tfrapi/exportTfrList")!
    private static let maxConcurrent = 6

    func fetchActive() async throws -> [TFR] {
        var req = URLRequest(url: Self.listURL, timeoutInterval: 30)
        req.setValue("CommSight/1.0", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let stubs = TFRParser.list(data)
        guard !stubs.isEmpty else { return [] }

        return await withTaskGroup(of: TFR?.self) { group in
            var it = stubs.makeIterator()
            func addNext() { if let s = it.next() { group.addTask { await Self.detail(s) } } }
            for _ in 0..<min(Self.maxConcurrent, stubs.count) { addNext() }
            var out: [TFR] = []
            for await r in group {
                if let r { out.append(r) }
                addNext()
            }
            return out
        }
    }

    private static func detail(_ s: TFRParser.Stub) async -> TFR? {
        guard let u = URL(string: "https://tfr.faa.gov/download/detail_\(TFRParser.detailFile(s.id)).xml")
        else { return nil }
        var req = URLRequest(url: u, timeoutInterval: 25)
        req.setValue("CommSight/1.0", forHTTPHeaderField: "User-Agent")
        guard let (d, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let xml = String(data: d, encoding: .utf8) else { return nil }
        return TFRParser.detail(xml, stub: s)
    }
}

/// Polls the FAA TFR feed while the layer is on, publishes a bounded snapshot + the instant it was
/// fetched (staleness is DISPLAYED, not hidden — TFRs are awareness context, confirm officially), and
/// mirrors it to a disk cache so a relaunch / offline start shows the last set. Edge-triggered
/// `sync(enabled:)` + exponential backoff, mirroring `EONETService`.
actor TFRService {
    struct Config: Sendable {
        var refreshInterval: TimeInterval = 30 * 60
        var backoffBase: TimeInterval = 5 * 60
        var snapshotMaxAge: TimeInterval = 12 * 3600
        var maxTFRs = 400
        var cacheDirectory: URL? = nil
    }
    static let attribution = "TFR data: FAA (tfr.faa.gov). Not an official briefing."

    private let config: Config
    private let fetcher: TFRFetching
    private let onUpdate: @Sendable ([TFR], Date) -> Void
    private let onStatus: (@Sendable (TFRStatus) -> Void)?

    private var pollTask: Task<Void, Never>?
    private var failureStreak = 0
    private var didLoadCache = false

    init(config: Config = Config(),
         fetcher: TFRFetching = LiveTFRFetcher(),
         onUpdate: @escaping @Sendable ([TFR], Date) -> Void,
         onStatus: (@Sendable (TFRStatus) -> Void)? = nil) {
        self.config = config; self.fetcher = fetcher; self.onUpdate = onUpdate; self.onStatus = onStatus
    }

    /// Single edge-triggered entry point — redundant calls are no-ops (no start/stop race).
    func sync(enabled: Bool) { enabled ? start() : stop() }

    private func start() {
        guard pollTask == nil else { return }
        loadCacheOnce()
        pollTask = Task { [weak self] in await self?.loop() }
    }
    private func stop() {
        pollTask?.cancel(); pollTask = nil
        onStatus?(.idle)
    }

    private func loop() async {
        while !Task.isCancelled {
            do {
                let tfrs = Array(try await fetcher.fetchActive().prefix(config.maxTFRs))
                guard !Task.isCancelled else { return }
                let now = Date()
                failureStreak = 0
                onUpdate(tfrs, now); onStatus?(.ok)
                saveCache(tfrs, at: now)
                try? await Task.sleep(nanoseconds: UInt64(config.refreshInterval * 1e9))
            } catch {
                guard !Task.isCancelled else { return }
                failureStreak += 1
                onStatus?(.error(error.localizedDescription))
                let backoff = min(config.backoffBase * pow(2, Double(failureStreak - 1)), 30 * 60)
                try? await Task.sleep(nanoseconds: UInt64(backoff * 1e9))
            }
        }
    }

    // MARK: disk cache

    private struct Snapshot: Codable { let tfrs: [TFR]; let at: Date }

    private var cacheURL: URL? {
        let base = config.cacheDirectory
            ?? (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                             appropriateFor: nil, create: true))
        return base?.appendingPathComponent("tfr_snapshot.json")
    }
    private func loadCacheOnce() {
        guard !didLoadCache else { return }
        didLoadCache = true
        guard let url = cacheURL, let d = try? Data(contentsOf: url),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: d),
              Date().timeIntervalSince(snap.at) < config.snapshotMaxAge, !snap.tfrs.isEmpty else { return }
        onUpdate(snap.tfrs, snap.at)      // show the last known set immediately (offline / cold start)
    }
    private func saveCache(_ tfrs: [TFR], at: Date) {
        guard let url = cacheURL, let d = try? JSONEncoder().encode(Snapshot(tfrs: tfrs, at: at)) else { return }
        try? d.write(to: url, options: .atomic)
    }
}
