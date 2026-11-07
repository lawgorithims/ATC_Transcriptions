import Foundation

/// Live-feed status surfaced to the UI.
enum ADSBStatus: Sendable, Equatable {
    case idle              // streaming off / no center
    case ok                // last poll succeeded
    case error(String)     // last poll failed (offline / 429 / http / decode)
}

/// What the online-traffic layer is doing, in terms the pilot can act on. Drives the map pill — see
/// `AppModel.trafficFeed`, which is where the ordering rationale lives.
enum TrafficFeedState: Equatable {
    case off                       // the layer is switched off
    case stratux                   // the Stratux link owns traffic; its own widget reports status
    case paused(String)            // running would be pointless right now (standby / background)
    case waitingForCenter          // no fix, no typed airport, no settled camera → nothing to poll around
    case loading                   // polling, no snapshot yet
    case idleUnexpected            // enabled + centered + no error, yet the poller never reported in
    case failed(String)            // last poll failed
    case liveEmpty                 // fetched fine, genuinely no aircraft in range
    case liveWithAircraft          // aircraft are drawn — the planes are their own evidence

    /// The pill's text, or nil when the map should say nothing (the aircraft speak for themselves).
    var pillText: String? {
        switch self {
        case .off, .stratux, .liveWithAircraft: return nil
        case .paused(let why):    return why
        case .waitingForCenter:   return "Traffic is waiting for a GPS fix…"
        case .loading:            return "Loading traffic…"
        case .idleUnexpected:     return "Traffic feed idle — toggle the layer to retry"
        case .failed:             return "Traffic unavailable — check connection"
        case .liveEmpty:          return "Traffic live — no aircraft nearby"
        }
    }
    /// SF Symbol for the pill.
    var pillIcon: String {
        switch self {
        case .waitingForCenter:            return "location.slash"
        case .failed:                      return "wifi.exclamationmark"
        case .paused, .idleUnexpected:     return "pause.circle"
        default:                           return "airplane"
        }
    }
    /// Only a genuine in-flight fetch spins — a paused or idle feed must not imply progress.
    var pillSpins: Bool { self == .loading }
}

enum ADSBFeedError: Error, Equatable {
    case rateLimited, http(Int), badURL
    /// The provider answered, and refused this client — 401/403. A DIFFERENT problem from a server
    /// fault or a dead network, and the only one the pilot can do nothing about: retrying forever is
    /// pointless and the app has to say so rather than looking merely unlucky. See `LiveAircraftFetcher`
    /// for how this fault actually reached a cockpit.
    case refusedByProvider
}

/// Abstraction over the actual network fetch so the service's freshness/lifecycle logic is
/// unit-testable without a network (tests inject a fake; the app uses `LiveAircraftFetcher`).
/// Returns the contacts plus the server clock (for a device-vs-server skew sanity check).
protocol AircraftFetching: Sendable {
    func fetch(center: Coord, radiusNm: Int) async throws -> (aircraft: [Aircraft], serverNow: Date?)
}

/// Polls adsb.lol for aircraft within a radius of a center point while streaming is on and a
/// session is active, prunes contacts against a **server-anchored** clock, and publishes the pruned
/// snapshot. The injected corrector block carries an absolute expiry (see `AppModel.injectTraffic`)
/// that is re-checked at read time, so a stalled/failed/backgrounded poller can never leak stale
/// aircraft into a prompt — this actor only ever publishes the freshest contacts it actually has.
actor ADSBService {
    struct Config: Sendable {
        var radiusNm = 30
        var pollInterval: TimeInterval = 5      // be polite (~1 req/s limit); 1 req / 5 s
        var contactWindow: TimeInterval = 30    // drop a contact whose last-heard is older than this
        var clockSkewBound: TimeInterval = 60   // device-vs-server divergence beyond this → distrust
        var maxAircraft = 60
    }

    static let attribution = "Aircraft data: adsb.lol"

    private let config: Config
    private let fetcher: AircraftFetching
    /// Publishes the pruned contacts + the instant of the LAST SUCCESSFUL fetch (drives the block
    /// expiry). `.distantPast` when there is no trusted snapshot, so any injected block is expired.
    private let onUpdate: @Sendable ([Aircraft], Date) -> Void
    private let onStatus: (@Sendable (ADSBStatus) -> Void)?

    private var center: Coord?
    private var pollTask: Task<Void, Never>?
    private var contacts: [String: Aircraft] = [:]
    private var lastSuccessAt: Date?
    private var failureStreak = 0

    init(config: Config = Config(),
         fetcher: AircraftFetching = LiveAircraftFetcher(),
         onUpdate: @escaping @Sendable ([Aircraft], Date) -> Void,
         onStatus: (@Sendable (ADSBStatus) -> Void)? = nil) {
        self.config = config
        self.fetcher = fetcher
        self.onUpdate = onUpdate
        self.onStatus = onStatus
    }

    /// The single edge-triggered entry point. The actor decides start/stop/recenter from its own
    /// state, so redundant calls are no-ops and there is no start/stop ordering race. Call it from
    /// every transition (session start/stop, standby, airport change, toggle, scene phase).
    func sync(center newCenter: Coord?, enabled: Bool) {
        // A moved center (airport change) must forget the old facility's contacts immediately.
        if newCenter != center {
            center = newCenter
            contacts = [:]
            lastSuccessAt = nil
            failureStreak = 0
            onUpdate([], .distantPast)
        }
        if enabled, center != nil {
            if pollTask == nil { pollTask = Task { [weak self] in await self?.runLoop() } }
        } else {
            stop()
        }
    }

    private func stop() {
        pollTask?.cancel()
        pollTask = nil
        contacts = [:]
        lastSuccessAt = nil
        failureStreak = 0
        onUpdate([], .distantPast)        // clear UI + corrector immediately
        onStatus?(.idle)
    }

    private func runLoop() async {
        while !Task.isCancelled {
            await pollOnce()
            // Back off on consecutive failures (429 / outage) so we don't hammer the feed or drain
            // the battery; reset to the base cadence on the next success.
            let delay = min(config.pollInterval * pow(2.0, Double(failureStreak)), 60)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    private func pollOnce() async {
        guard let polledCenter = center else { return }
        do {
            let (list, serverNow) = try await fetcher.fetch(center: polledCenter, radiusNm: config.radiusNm)
            // Discard if cancelled or the center moved (airport change) while this poll was in flight,
            // so old-facility aircraft never enter `contacts`.
            if Task.isCancelled || center != polledCenter { return }
            let fetchedAt = list.first?.fetchedAt ?? Date()
            // Distrust a snapshot whose device clock diverges wildly from the server's (mis-set
            // clock, or a stamp made before a long background suspension): publish empty, keep nothing.
            if let serverNow, abs(fetchedAt.timeIntervalSince(serverNow)) > config.clockSkewBound {
                contacts = [:]; lastSuccessAt = nil; failureStreak += 1
                onStatus?(.error("clock skew"))
                pruneAndPublish(now: Date())
                return
            }
            // Upsert only contacts that are already fresh by the server-anchored window.
            for ac in list where !ac.isStale(window: config.contactWindow, now: fetchedAt) {
                contacts[ac.hex] = ac
            }
            lastSuccessAt = fetchedAt
            failureStreak = 0
            onStatus?(.ok)
        } catch is CancellationError {
            return
        } catch {
            failureStreak += 1
            onStatus?(.error(Self.describe(error)))   // keep existing contacts; they age out below
        }
        pruneAndPublish(now: Date())
    }

    /// Drop contacts older than `contactWindow` (server-anchored) and publish the survivors, sorted
    /// nearest-first and capped. Runs after EVERY poll (success, empty, or failure), so a failed
    /// poll can never freeze old data — contacts age out, and the published snapshot instant stays
    /// pinned to the last SUCCESSFUL fetch so the corrector block expires on schedule.
    private func pruneAndPublish(now: Date) {
        contacts = contacts.filter { !$0.value.isStale(window: config.contactWindow, now: now) }
        let sorted = contacts.values.sorted {
            ($0.distanceNm ?? .greatestFiniteMagnitude) < ($1.distanceNm ?? .greatestFiniteMagnitude)
        }
        onUpdate(Array(sorted.prefix(config.maxAircraft)), lastSuccessAt ?? .distantPast)
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case ADSBFeedError.rateLimited: return "rate limited"
        // Says what it is, because the pilot's next move differs: everything else here is worth
        // waiting out, and this one never resolves on its own.
        case ADSBFeedError.refusedByProvider: return "feed refused this app"
        case ADSBFeedError.http(let c): return "http \(c)"
        case is URLError: return "offline"
        default: return "feed error"
        }
    }
}

// MARK: - Live network fetcher

/// The production `AircraftFetching`: a GET to adsb.lol `/v2/point` on an ephemeral, no-cache
/// `URLSession`, decoded via `Aircraft.decode`. HTTPS so ATS is satisfied.
///
/// ⚠️ THE PROVIDER CHANGED BECAUSE THE OLD ONE STOPPED ANSWERING, AND IT FAILED SILENTLY FOR LONG
/// ENOUGH TO BE REPORTED AS "ADS-B never works". This was `api.airplanes.live/v2/point`, which now
/// returns **403** with a body asking you to email them for access — they closed the open endpoint.
/// Nothing in the client was wrong; the feed had simply gone away underneath it, and a layer that is
/// switched on and shows an empty sky is indistinguishable from a quiet one.
///
/// adsb.lol serves the SAME `/v2/point/{lat}/{lon}/{radius}` shape and the same `{ "now", "ac": [] }`
/// body — both are readsb/tar1090 derived — so `Aircraft.decode` needed no change at all. It is a
/// free community network and asks for attribution, which is in `attribution` and in the
/// acknowledgements list; if that is ever traded for a paid or keyed provider, both must move too.
///
/// If this reports `refusedByProvider` again, the feed has not broken — it has been withdrawn, and
/// the fix is a provider decision rather than a code change. `opendata.adsb.fi` was verified working
/// at the same time as a second option, though it uses a different URL shape and an `aircraft` key.
struct LiveAircraftFetcher: AircraftFetching {
    var session: URLSession = .adsb

    func fetch(center: Coord, radiusNm: Int) async throws -> (aircraft: [Aircraft], serverNow: Date?) {
        let lat = String(format: "%.4f", center.lat)
        let lon = String(format: "%.4f", center.lon)
        guard let url = URL(string: "https://api.adsb.lol/v2/point/\(lat)/\(lon)/\(radiusNm)") else {
            throw ADSBFeedError.badURL
        }
        var req = URLRequest(url: url)
        req.setValue("Obelisk/1.0 (on-device ATC transcription)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: req)
        let fetchedAt = Date()   // bytes have arrived — anchor freshness here
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 429 { throw ADSBFeedError.rateLimited }
            // 401/403 is the provider shutting the door, not a glitch — name it so the pill can say
            // something true and the next person does not spend a day reading the decoder.
            if http.statusCode == 401 || http.statusCode == 403 { throw ADSBFeedError.refusedByProvider }
            guard (200..<300).contains(http.statusCode) else { throw ADSBFeedError.http(http.statusCode) }
        }
        return try Aircraft.decode(data, fetchedAt: fetchedAt)
    }
}

extension URLSession {
    /// Ephemeral, no-cache session for ADS-B polling — never serve a cached (stale) snapshot, and
    /// fail fast rather than queue when offline. Delegate-less, so no invalidation is needed.
    static let adsb: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        c.timeoutIntervalForRequest = 8
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()
}
