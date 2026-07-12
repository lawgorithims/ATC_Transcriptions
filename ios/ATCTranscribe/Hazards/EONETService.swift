import Foundation

/// EONET feed status surfaced to the UI.
enum EONETStatus: Sendable, Equatable {
    case idle              // layer off / not polling
    case ok                // last poll succeeded
    case error(String)     // last poll failed (a cached snapshot may still be shown)
}

/// Abstraction over the network fetch so the service's lifecycle logic is unit-testable without a
/// network (mirrors `AircraftFetching`; tests inject a fake, the app uses `LiveEONETFetcher`).
protocol EONETFetching: Sendable {
    func fetch(category: EONETCategory, limit: Int) async throws -> [EONETEvent]
}

/// Polls NASA EONET's open-events feed (the four aviation-relevant categories) while hazard
/// awareness is wanted, publishes a bounded merged snapshot, and mirrors it to a small disk cache
/// so a relaunch — or an offline start — shows the last known events immediately. Hazards are
/// awareness context, not safety-of-flight-fresh data, so staleness is DISPLAYED (via the published
/// snapshot instant) rather than events being dropped. Lifecycle mirrors `ADSBService`: one
/// edge-triggered `sync(enabled:)`, exponential backoff on failures, and a partial-category failure
/// keeps the other categories' results.
actor EONETService {
    struct Config: Sendable {
        var refreshInterval: TimeInterval = 30 * 60     // EONET updates every few hours — be polite
        var backoffBase: TimeInterval = 5 * 60          // failure backoff 5 → 10 → 20 → 30 min (capped)
        var perCategoryLimit = 100                      // 4 × 100 = hard event ceiling (rule 2)
        var snapshotMaxAge: TimeInterval = 24 * 3600    // an older disk snapshot is ignored
        var cacheDirectory: URL? = nil                  // test override; nil → Application Support/EONET
    }

    static let attribution = "Hazard data: NASA EONET"

    private let config: Config
    private let fetcher: EONETFetching
    /// Publishes the merged snapshot + the instant it was FETCHED (`.distantPast` when unknown);
    /// the UI derives its staleness note from that instant.
    private let onUpdate: @Sendable ([EONETEvent], Date) -> Void
    private let onStatus: (@Sendable (EONETStatus) -> Void)?

    private var pollTask: Task<Void, Never>?
    private var byCategory: [String: [EONETEvent]] = [:]
    private var lastSuccessAt: Date?
    private var failureStreak = 0
    private var didLoadCache = false

    init(config: Config = Config(),
         fetcher: EONETFetching = LiveEONETFetcher(),
         onUpdate: @escaping @Sendable ([EONETEvent], Date) -> Void,
         onStatus: (@Sendable (EONETStatus) -> Void)? = nil) {
        self.config = config
        self.fetcher = fetcher
        self.onUpdate = onUpdate
        self.onStatus = onStatus
    }

    /// The single edge-triggered entry point (see `ADSBService.sync`): redundant calls are no-ops,
    /// so there is no start/stop ordering race. Call it from every transition (toggle, scene phase,
    /// plan change, thermal).
    func sync(enabled: Bool) {
        if enabled {
            if pollTask == nil { pollTask = Task { [weak self] in await self?.runLoop() } }
        } else {
            stop()
        }
    }

    /// Stop polling. Unlike ADS-B contacts, the published events are NOT cleared — the map keeps
    /// the last snapshot (its age is displayed) and the disk cache survives for the next start.
    private func stop() {
        pollTask?.cancel()
        pollTask = nil
        failureStreak = 0
        onStatus?(.idle)
    }

    private func runLoop() async {
        loadCachedSnapshotOnce()          // offline-first: last snapshot shows before any network
        while !Task.isCancelled {
            await pollOnce()
            let delay = failureStreak == 0
                ? config.refreshInterval
                : min(config.backoffBase * pow(2.0, Double(failureStreak - 1)), config.refreshInterval)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    private func pollOnce() async {
        var fetched: [String: [EONETEvent]] = [:]
        var lastError = "feed error"
        for cat in EONETCategory.allCases {                       // bounded: 4 categories (rule 2)
            if Task.isCancelled { return }
            do {
                let list = try await fetcher.fetch(category: cat, limit: config.perCategoryLimit)
                fetched[cat.rawValue] = Array(list.prefix(config.perCategoryLimit))
            } catch is CancellationError {
                return
            } catch {
                lastError = Self.describe(error)
            }
        }
        assert(fetched.count <= EONETCategory.allCases.count, "at most one result per category")
        guard !fetched.isEmpty else {
            // Every category failed: keep the previous snapshot published (its age is displayed)
            // and back off — never clear on failure, never spin.
            failureStreak += 1
            onStatus?(.error(lastError))
            return
        }
        for (key, list) in fetched { byCategory[key] = list }     // partial success keeps the rest
        failureStreak = 0
        lastSuccessAt = Date()
        onStatus?(.ok)
        publish()
        saveSnapshot()
    }

    /// Merge the per-category results in a stable order and publish. The total is bounded by
    /// `categories × perCategoryLimit` (rule 2).
    private func publish() {
        var all: [EONETEvent] = []
        all.reserveCapacity(EONETCategory.allCases.count * config.perCategoryLimit)
        for cat in EONETCategory.allCases {
            all.append(contentsOf: (byCategory[cat.rawValue] ?? []).prefix(config.perCategoryLimit))
        }
        assert(all.count <= EONETCategory.allCases.count * config.perCategoryLimit, "merged snapshot bounded")
        onUpdate(all, lastSuccessAt ?? .distantPast)
    }

    // MARK: Disk snapshot (offline-first)

    private struct Snapshot: Codable {
        static let currentVersion = 1
        let version: Int
        let savedAt: Date
        let events: [EONETEvent]
    }

    private var cacheFile: URL? {
        let dir = config.cacheDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("EONET", isDirectory: true)
        return dir?.appendingPathComponent("events.json")
    }

    /// Publish the cached snapshot (if fresh) BEFORE the first network poll so a relaunch or an
    /// offline start shows hazards immediately. One-shot per service instance; fail-soft — any
    /// read/decode problem just means no cached publish.
    private func loadCachedSnapshotOnce() {
        guard !didLoadCache else { return }
        didLoadCache = true
        let cap = EONETCategory.allCases.count * config.perCategoryLimit
        guard let file = cacheFile,
              let data = try? Data(contentsOf: file), data.count <= EONETEvent.maxResponseBytes,
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data),
              snap.version == Snapshot.currentVersion,
              Date().timeIntervalSince(snap.savedAt) <= config.snapshotMaxAge else { return }
        var byCat: [String: [EONETEvent]] = [:]
        for ev in snap.events.prefix(cap) { byCat[ev.category.rawValue, default: []].append(ev) }
        assert(byCat.count <= EONETCategory.allCases.count, "cache holds only known categories")
        byCategory = byCat
        lastSuccessAt = snap.savedAt      // the staleness anchor for the cached data
        publish()
    }

    private func saveSnapshot() {
        guard let file = cacheFile, let savedAt = lastSuccessAt else { return }
        var all: [EONETEvent] = []
        for cat in EONETCategory.allCases { all.append(contentsOf: byCategory[cat.rawValue] ?? []) }
        assert(all.count <= EONETCategory.allCases.count * config.perCategoryLimit, "snapshot bounded")
        let snap = Snapshot(version: Snapshot.currentVersion, savedAt: savedAt, events: all)
        guard let data = try? JSONEncoder().encode(snap) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)               // fail-soft: the cache is best-effort
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case is URLError: return "offline"
        default: return "feed error"
        }
    }
}

// MARK: - Live network fetcher

/// The production `EONETFetching`: one GET per category on an ephemeral, no-cache session,
/// decoded via the tolerant `EONETEvent.decode`.
struct LiveEONETFetcher: EONETFetching {
    var session: URLSession = .eonet

    func fetch(category: EONETCategory, limit: Int) async throws -> [EONETEvent] {
        assert(limit > 0 && limit <= 1000, "sane per-category limit")
        assert(!category.rawValue.isEmpty, "category id must be non-empty")
        var comps = URLComponents(string: "https://eonet.gsfc.nasa.gov/api/v3/events")
        comps?.queryItems = [URLQueryItem(name: "status", value: "open"),
                             URLQueryItem(name: "category", value: category.rawValue),
                             URLQueryItem(name: "limit", value: String(limit))]
        guard let url = comps?.url else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.setValue("CommSight/1.0 (on-device ATC transcription)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse {
            guard (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        }
        // A 200 whose body isn't a valid EONET envelope (maintenance/HTML/rate-limit page) decodes
        // to nil — throw so the service counts it as a failed category and KEEPS the cached snapshot,
        // instead of overwriting good hazards with a spurious empty result. A real `{"events":[]}`
        // decodes to [] and is returned normally.
        guard let events = EONETEvent.decode(data, category: category) else {
            throw URLError(.cannotParseResponse)
        }
        return events
    }
}

extension URLSession {
    /// Ephemeral, no-cache session for EONET polling — an offline device fails in ≤15 s and falls
    /// back to the disk snapshot instead of spinning (mirrors `URLSession.adsb`).
    static let eonet: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        c.timeoutIntervalForRequest = 15
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()
}
