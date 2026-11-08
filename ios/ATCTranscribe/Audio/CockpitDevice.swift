import Foundation

/// A cockpit audio appliance on the aircraft's local Wi-Fi.
///
/// Both supported devices speak the *same* wire protocol — the `commsight-cockpit-audio`
/// sidecar: `GET /audio.raw` yields raw 16 kHz mono S16LE PCM, `GET /health` yields JSON
/// status. `StratuxAudioSource` already consumes that stream and is not in fact
/// Stratux-specific; only its name is. So supporting a second appliance is a matter of
/// knowing *where* to look, not of new streaming code.
///
/// They differ only in defaults:
///
/// | | Stratux | Obelisk |
/// |---|---|---|
/// | Address | 192.168.10.1 | 192.168.4.1 |
/// | Also provides | ADS-B traffic, GPS | battery telemetry, MP3 for browsers |
///
/// The Obelisk deliberately advertises no default gateway, so an iPad keeps using cellular
/// for weather and charts while using its Wi-Fi only for audio.
enum CockpitDeviceKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case stratux
    case obelisk

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .stratux: return "Stratux receiver"
        case .obelisk: return "Obelisk"
        }
    }

    /// Address the appliance serves on when running as its own access point.
    var defaultHost: String {
        switch self {
        case .stratux: return "192.168.10.1"
        case .obelisk: return "192.168.4.1"
        }
    }

    /// Both run the same sidecar, hence the same port. Kept per-kind so they can diverge
    /// without touching call sites.
    var defaultAudioPort: Int { 8090 }

    /// SSID the appliance broadcasts — shown in UI to tell the pilot what to join.
    var expectedSSID: String {
        switch self {
        case .stratux: return "stratux"
        case .obelisk: return "Obelisk"
        }
    }

    /// Only the Stratux supplies ADS-B traffic and a GPS fix. The Obelisk is audio-only, so
    /// selecting it must NOT enable the traffic/GPS link — that would leave the app polling
    /// an endpoint that does not exist and reporting a receiver that is not there.
    var providesTrafficAndGPS: Bool { self == .stratux }

    /// Only the Obelisk carries a battery (PiSugar) and reports its charge.
    var providesBatteryTelemetry: Bool { self == .obelisk }
}

// MARK: - Health

/// Decoded `/health` from the cockpit-audio sidecar.
///
/// Every field is optional on purpose. The two appliances run different sidecar versions,
/// and a decoder that fails because one key is absent would report a perfectly healthy
/// device as unreachable — the worst possible failure for a discovery probe. Absence is
/// information, not an error.
struct CockpitHealth: Decodable, Sendable, Equatable {
    var service: String?
    var version: String?
    var ok: Bool?
    var rate: Int?
    var channels: Int?
    var format: String?
    var resolvedDevice: String?
    var devicePresent: Bool?
    var captureDevices: [String]?
    var streaming: Bool?

    /// Obelisk-only additions; absent on a Stratux sidecar.
    var platform: String?
    var battery: BatteryTelemetry?
    var filter: FilterStatus?

    enum CodingKeys: String, CodingKey {
        case service, version, ok, rate, channels, format, streaming, platform, battery, filter
        case resolvedDevice = "resolved_device"
        case devicePresent = "device_present"
        case captureDevices = "capture_devices"
    }

    /// True when the sidecar can actually deliver audio: the process answered, it found a
    /// capture device, and that device is present. `ok` alone is not enough — a sidecar with
    /// no adapter plugged in answers happily and then serves silence.
    var canStream: Bool { (ok ?? false) && (devicePresent ?? false) }

    /// The audio format the pipeline requires. A sidecar misconfigured to 44.1 kHz stereo
    /// would stream bytes that decode into noise at 2.7× speed, so this is worth asserting
    /// rather than discovering by ear.
    var formatMatchesPipeline: Bool {
        (rate ?? 16000) == 16000 && (channels ?? 1) == 1 && (format ?? "S16_LE") == "S16_LE"
    }
}

/// PiSugar 3 battery state, reported by the Obelisk's telemetry.
struct BatteryTelemetry: Decodable, Sendable, Equatable {
    var percent: Double?
    var voltage: Double?
    var current: Double?
    var charging: Bool?
    var temperatureC: Double?
    /// Minutes of runtime left, when the device can estimate it.
    var minutesRemaining: Int?

    enum CodingKeys: String, CodingKey {
        case percent, voltage, current, charging
        case temperatureC = "temperature_c"
        case minutesRemaining = "minutes_remaining"
    }

    /// Clamped to 0...100. The PiSugar's fuel gauge can report slightly out-of-range values
    /// while charging, and a progress bar fed 103% renders wrong.
    var clampedPercent: Double? {
        guard let percent else { return nil }
        return Swift.min(100, Swift.max(0, percent))
    }

    /// Worth warning the pilot about: under 20% and not on charge.
    var isLow: Bool { (clampedPercent ?? 100) < 20 && !(charging ?? false) }
}

/// Whether the Obelisk's noise filter is engaged, and what Obelisk is being fed.
///
/// The distinction matters for transcription accuracy: noise reduction tuned to help a human
/// listener can chew up consonants and *hurt* ASR. This reports the truth so the two can be
/// compared rather than guessed at.
struct FilterStatus: Decodable, Sendable, Equatable {
    var enabled: Bool?
    var preset: String?
    /// "filtered" or "raw" — which of the two the sidecar is serving on /audio.raw.
    var commsightSource: String?

    enum CodingKeys: String, CodingKey {
        case enabled, preset
        case commsightSource = "commsight_source"
    }

    var servingFiltered: Bool { (commsightSource ?? "raw") == "filtered" }
}

// MARK: - Discovery

/// The result of probing one address.
struct CockpitDeviceStatus: Sendable, Equatable, Identifiable {
    let kind: CockpitDeviceKind
    let host: String
    let port: Int
    let health: CockpitHealth?
    let reachable: Bool
    /// Round-trip time of the probe, useful for showing which of two devices is closer/faster.
    let latency: TimeInterval?

    var id: String { "\(kind.rawValue)@\(host):\(port)" }

    /// Ready to be selected as the live audio source.
    var isUsable: Bool { reachable && (health?.canStream ?? false) }

    /// One line for the UI — deliberately concrete about *why* something is unusable, because
    /// "not found" sends people to reboot routers when the real fault is an unplugged adapter.
    var summary: String {
        guard reachable else { return "Not found at \(host)" }
        guard let health else { return "Responded, but the reply could not be read" }
        if !(health.devicePresent ?? false) { return "Connected — but no audio adapter plugged in" }
        if !health.formatMatchesPipeline {
            return "Connected — wrong audio format (\(health.rate ?? 0) Hz, needs 16000)"
        }
        if health.streaming == true { return "Connected — already streaming to a client" }
        return "Ready"
    }
}

/// Probes cockpit-audio appliances over HTTP.
///
/// Discovery is a bounded, parallel probe of the two known addresses rather than mDNS/Bonjour.
/// That is a deliberate choice: the appliance networks advertise no gateway and often no
/// multicast DNS responder, and there are exactly two candidate addresses. Two HTTP GETs with
/// a short timeout are simpler, faster and far more debuggable than a browse.
enum CockpitDeviceProbe {
    /// Hard ceiling on a probe. The appliance is one Wi-Fi hop away on a quiet local network;
    /// if it has not answered in this long it is not there. Short enough that probing both
    /// candidates stays responsive in the UI.
    static let timeout: TimeInterval = 2.5

    /// Probe a single address. Never throws — an unreachable device is a normal outcome of
    /// discovery, not an error, and callers uniformly want a status rather than a `catch`.
    static func probe(kind: CockpitDeviceKind,
                      host: String? = nil,
                      port: Int? = nil,
                      session: URLSession = .shared) async -> CockpitDeviceStatus {
        let h = (host ?? kind.defaultHost).trimmingCharacters(in: .whitespaces)
        let p = port ?? kind.defaultAudioPort
        assert(!h.isEmpty, "probe host must not be empty")
        assert(p > 0 && p < 65536, "probe port out of range: \(p)")

        let unreachable = CockpitDeviceStatus(kind: kind, host: h, port: p,
                                              health: nil, reachable: false, latency: nil)
        guard let url = URL(string: "http://\(h):\(p)/health") else { return unreachable }

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpMethod = "GET"

        let started = Date()
        do {
            let (data, response) = try await session.data(for: request)
            let elapsed = Date().timeIntervalSince(started)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return CockpitDeviceStatus(kind: kind, host: h, port: p,
                                           health: nil, reachable: true, latency: elapsed)
            }
            let health = try? JSONDecoder().decode(CockpitHealth.self, from: data)
            return CockpitDeviceStatus(kind: kind, host: h, port: p,
                                       health: health, reachable: true, latency: elapsed)
        } catch {
            return unreachable
        }
    }

    /// Probe every known appliance concurrently and return them usable-first.
    ///
    /// Both are probed even once one answers: a cockpit can legitimately have a Stratux for
    /// traffic and an Obelisk for audio on separate networks, and silently preferring whichever
    /// replied first would make the choice non-deterministic between runs.
    static func discover(overrides: [CockpitDeviceKind: (host: String, port: Int)] = [:],
                         session: URLSession = .shared) async -> [CockpitDeviceStatus] {
        let kinds = CockpitDeviceKind.allCases
        assert(kinds.count <= 8, "discovery fans out one task per kind; keep the set small")

        var results: [CockpitDeviceStatus] = []
        results.reserveCapacity(kinds.count)

        await withTaskGroup(of: CockpitDeviceStatus.self) { group in
            for kind in kinds {
                let override = overrides[kind]
                group.addTask {
                    await probe(kind: kind, host: override?.host, port: override?.port,
                                session: session)
                }
            }
            for await status in group { results.append(status) }
        }

        // Usable first, then merely reachable, then by latency. Stable and explainable.
        results.sort { a, b in
            if a.isUsable != b.isUsable { return a.isUsable }
            if a.reachable != b.reachable { return a.reachable }
            return (a.latency ?? .greatestFiniteMagnitude) < (b.latency ?? .greatestFiniteMagnitude)
        }
        return results
    }

    /// Fetch just the battery, for periodic refresh once a device is already selected.
    /// Returns nil for a Stratux (no battery) or any device that does not report one.
    static func battery(kind: CockpitDeviceKind,
                        host: String? = nil,
                        port: Int? = nil,
                        session: URLSession = .shared) async -> BatteryTelemetry? {
        guard kind.providesBatteryTelemetry else { return nil }
        return await probe(kind: kind, host: host, port: port, session: session).health?.battery
    }
}
