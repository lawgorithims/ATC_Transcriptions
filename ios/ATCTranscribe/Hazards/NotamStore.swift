import Foundation

/// Per-aerodrome NOTAM snapshots.
///
/// Shaped after `MetarStore` rather than `TFRService`: TFRs are one global feed polled while a layer is
/// on, but NOTAMs are per-ICAO and are only worth pulling for airports the pilot is actually working —
/// the plan's endpoints, the airport they tapped, the airport under the active approach. So: TTL per
/// ident, in-flight de-duplication, and an explicit terminal state per ident.
///
/// THE STATE IS THE POINT. "No NOTAMs", "no API key" and "the fetch failed" all look identical as an
/// empty list, and only one of them means the pilot has nothing to read. `state(for:)` never collapses
/// them, and only `.ok` is permitted to render as "none".
@MainActor
final class NotamStore: ObservableObject {

    @Published private(set) var notams: [String: [Notam]] = [:]
    @Published private(set) var states: [String: NotamFeedState] = [:]
    /// Mirrors the keychain so views can react without touching it on every redraw.
    @Published private(set) var credentialConfigured = NotamCredential.isConfigured

    private var fetchedAt: [String: Date] = [:]
    private var inFlight: Set<String> = []
    private let fetcher: NotamFetching
    private let ttl: TimeInterval

    /// Cap on retained aerodromes (rule 2).
    static let maxCached = 60

    init(fetcher: NotamFetching = LiveNotamFetcher(), ttl: TimeInterval = 15 * 60) {
        self.fetcher = fetcher
        self.ttl = ttl
    }

    static func key(_ ident: String) -> String {
        ident.trimmingCharacters(in: .whitespaces).uppercased()
    }

    func notams(_ ident: String) -> [Notam] { notams[Self.key(ident)] ?? [] }

    /// The feed state for an ident. `.noCredential` outranks everything: without a key nothing was ever
    /// asked, so no other answer would be honest.
    func state(for ident: String) -> NotamFeedState {
        if !credentialConfigured { return .noCredential }
        return states[Self.key(ident)] ?? .loading
    }

    func refreshCredentialState() { credentialConfigured = NotamCredential.isConfigured }

    /// Save a credential and drop every cached state, so idents that were showing `.noCredential`
    /// re-ask rather than sitting on a stale refusal.
    func setCredential(clientID: String, clientSecret: String) {
        NotamCredential.save(clientID: clientID, clientSecret: clientSecret)
        states.removeAll()
        fetchedAt.removeAll()
        refreshCredentialState()
    }

    func clearCredential() {
        NotamCredential.clear()
        notams.removeAll()
        states.removeAll()
        fetchedAt.removeAll()
        refreshCredentialState()
    }

    /// Fetch this aerodrome's NOTAMs if the snapshot is stale and nothing is already in flight.
    func ensure(_ ident: String, now: Date = Date()) {
        let key = Self.key(ident)
        guard !key.isEmpty, key.count <= 8 else { return }
        guard credentialConfigured else { return }
        guard !inFlight.contains(key) else { return }
        if let at = fetchedAt[key], now.timeIntervalSince(at) < ttl { return }
        inFlight.insert(key)
        if states[key] == nil { states[key] = .loading }
        Task { [weak self] in
            guard let self else { return }
            await self.run(key)
        }
    }

    private func run(_ key: String) async {
        do {
            let fetched = try await fetcher.fetch(icao: key)
            inFlight.remove(key)
            if notams.count >= Self.maxCached { notams.removeAll(); fetchedAt.removeAll() }
            notams[key] = fetched
            fetchedAt[key] = Date()
            states[key] = .ok(fetchedAt: Date())
        } catch NotamFetchError.noCredential {
            inFlight.remove(key)
            refreshCredentialState()
            states[key] = .noCredential
        } catch NotamFetchError.unauthorized {
            inFlight.remove(key)
            // The key is present but the FAA rejected it. Say THAT — telling the pilot there is no key
            // would send them to re-enter one that is already there.
            states[key] = .failed("The FAA rejected this API key.")
        } catch {
            inFlight.remove(key)
            // KEEP the last good snapshot. A transport failure must never publish a false empty, which
            // is the same rule the TFR feed follows for the same reason.
            states[key] = .failed(((error as? NotamFetchError).map(Self.describe) ?? error.localizedDescription))
        }
    }

    private static func describe(_ e: NotamFetchError) -> String {
        switch e {
        case .noCredential: return "No API key configured."
        case .unauthorized: return "The FAA rejected this API key."
        case .transport(let why): return why
        }
    }
}
