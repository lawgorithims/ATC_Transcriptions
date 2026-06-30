import Foundation

/// Health of the Stratux link, surfaced to the UI.
enum StratuxStatus: Sendable, Equatable {
    case idle               // not connected
    case connecting
    case connected          // traffic WebSocket open
    case error(String)      // last connect/receive failed
}

/// Talks to a Stratux receiver (github.com/stratux/stratux) over its Wi-Fi: subscribes to the
/// `/traffic` WebSocket for live ADS-B targets and polls `/getSituation` for ownship GPS. It
/// publishes the SAME normalized `[Aircraft]` + freshness instant the airplanes.live `ADSBService`
/// does, so the corrector / traffic-page pipeline downstream is identical — the only difference is
/// the source (on-board receiver vs internet, works in flight with no cell/Wi-Fi internet).
///
/// Freshness: each target carries Stratux's `Age` (seconds since its last fix) anchored to the
/// instant the message arrived, so the same server-anchored prune as airplanes.live drops a target
/// that stops being heard — even if the WebSocket itself goes quiet (a periodic prune republishes).
actor StratuxService {
    struct Config: Sendable {
        var trafficWindow: TimeInterval = 60    // drop a target not heard for this long
        var refresh: TimeInterval = 2           // prune + poll GPS on this cadence
        var maxAircraft = 60
    }

    static let attribution = "Traffic & GPS: Stratux receiver"

    private let config: Config
    /// Pruned contacts + the publish instant (drives the corrector block's read-site expiry).
    private let onTraffic: @Sendable ([Aircraft], Date) -> Void
    private let onGPS: @Sendable (StratuxGPS?) -> Void
    private let onStatus: @Sendable (StratuxStatus) -> Void

    private var host: String?
    private var enabled = false
    private var trafficTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var contacts: [String: Aircraft] = [:]
    private let session: URLSession

    init(config: Config = Config(),
         onTraffic: @escaping @Sendable ([Aircraft], Date) -> Void,
         onGPS: @escaping @Sendable (StratuxGPS?) -> Void,
         onStatus: @escaping @Sendable (StratuxStatus) -> Void) {
        self.config = config
        self.onTraffic = onTraffic
        self.onGPS = onGPS
        self.onStatus = onStatus
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 8
        cfg.waitsForConnectivity = false
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: cfg)
    }

    /// The single edge-triggered entry point (mirrors `ADSBService.sync`). Redundant calls are no-ops;
    /// a changed host forgets the old receiver's contacts immediately.
    func sync(host newHost: String?, enabled: Bool) {
        let h = newHost?.trimmingCharacters(in: .whitespaces).nilWhenEmpty
        if h != host {
            // The host changed → tear the live tasks down so the spawn block below restarts them
            // against the NEW host. They capture the host at spawn time and never re-read it, so a
            // mid-session address edit (or switching receivers) would otherwise keep streaming from
            // the OLD box with a misleadingly "connected" status.
            host = h
            trafficTask?.cancel(); trafficTask = nil
            refreshTask?.cancel(); refreshTask = nil
            contacts = [:]
            onTraffic([], .distantPast)
            onGPS(nil)
        }
        self.enabled = enabled
        if enabled, let h = host {
            if trafficTask == nil { trafficTask = Task { [weak self] in await self?.runTraffic(host: h) } }
            if refreshTask == nil { refreshTask = Task { [weak self] in await self?.runRefresh(host: h) } }
        } else {
            stop()
        }
    }

    private func stop() {
        trafficTask?.cancel(); trafficTask = nil
        refreshTask?.cancel(); refreshTask = nil
        contacts = [:]
        onTraffic([], .distantPast)        // clear UI + corrector immediately
        onGPS(nil)
        onStatus(.idle)
    }

    // MARK: traffic WebSocket

    private func runTraffic(host: String) async {
        var backoff = 1.0
        while !Task.isCancelled {
            guard let url = URL(string: "ws://\(host)/traffic") else {
                // Malformed host → surface it and retry rather than leaving a dead, non-nil task that
                // blocks any respawn. A host change cancels this task (see sync); the backoff caps churn.
                onStatus(.error("bad address"))
                try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                backoff = min(backoff * 2, 15)
                continue
            }
            onStatus(.connecting)
            let ws = session.webSocketTask(with: url)
            ws.resume()
            var announced = false
            do {
                while !Task.isCancelled {
                    let message = try await ws.receive()
                    if !announced { onStatus(.connected); announced = true }   // announce on the connect transition only
                    backoff = 1.0
                    ingest(message)
                }
            } catch {
                if !Task.isCancelled { onStatus(.error(Self.describe(error))) }
            }
            ws.cancel(with: .goingAway, reason: nil)
            if Task.isCancelled { break }
            try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
            backoff = min(backoff * 2, 15)
        }
    }

    /// Decode one `/traffic` message (Stratux pushes a single `TrafficInfo` JSON per message) and
    /// upsert it; targets with no usable position/identity are ignored.
    private func ingest(_ message: URLSessionWebSocketTask.Message) {
        let data: Data?
        switch message {
        case .string(let s): data = s.data(using: .utf8)
        case .data(let d):   data = d
        @unknown default:    data = nil
        }
        guard let data, let traf = try? JSONDecoder().decode(StratuxTraffic.self, from: data),
              let ac = traf.aircraft(receivedAt: Date()) else { return }
        contacts[ac.hex] = ac
        publishTraffic(now: Date())
    }

    // MARK: GPS poll + periodic prune

    private func runRefresh(host: String) async {
        while !Task.isCancelled {
            await pollGPS(host: host)
            publishTraffic(now: Date())     // age out stale targets even while the WS is quiet
            try? await Task.sleep(nanoseconds: UInt64(config.refresh * 1_000_000_000))
        }
    }

    private func pollGPS(host: String) async {
        guard let url = URL(string: "http://\(host)/getSituation") else { return }
        do {
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return }
            let situation = try JSONDecoder().decode(StratuxSituation.self, from: data)
            onGPS(situation.gps)
        } catch {
            // A failed GPS poll just leaves the last value; the WS status reflects link health.
        }
    }

    /// Drop contacts older than `trafficWindow` (server-anchored) and publish the survivors, nearest
    /// first and capped. The published instant is `now` (the contacts are live), so the corrector
    /// block's read-site expiry stays anchored to a real, recent observation.
    private func publishTraffic(now: Date) {
        contacts = contacts.filter { !$0.value.isStale(window: config.trafficWindow, now: now) }
        let sorted = contacts.values.sorted {
            ($0.distanceNm ?? .greatestFiniteMagnitude) < ($1.distanceNm ?? .greatestFiniteMagnitude)
        }
        onTraffic(Array(sorted.prefix(config.maxAircraft)), contacts.isEmpty ? .distantPast : now)
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case is URLError where (error as? URLError)?.code == .timedOut: return "timed out"
        case is URLError: return "unreachable"
        default: return "link error"
        }
    }
}

private extension String {
    var nilWhenEmpty: String? { isEmpty ? nil : self }
}
