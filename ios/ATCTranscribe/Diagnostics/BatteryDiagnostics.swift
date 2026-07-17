import Foundation
import UIKit
import MetricKit

/// On-device battery/energy telemetry so we can find out what actually drains the iPad in flight, instead
/// of guessing. Two independent sources:
///
///  1. A lightweight periodic SAMPLER (opt-in): every 60 s while foregrounded it records the battery
///     level, charging state, thermal state, and a tag describing what the app was doing at that moment
///     (transcribing / map layer / Stratux / GPS). Between samples it derives a discharge rate (%/hr),
///     so a session can be replayed to see which activity correlates with the steepest drain. Bounded
///     ring buffer, mirrored to disk so it survives relaunch.
///  2. MetricKit: iOS delivers a daily aggregate payload (cumulative CPU/GPU seconds, display, location,
///     network) at ~near-zero cost — captured whenever it arrives and summarized for the diagnostics view.
///
/// Everything is inert until the user enables collection (Settings → General), so the tool never costs
/// battery unless we're deliberately measuring. Device-only for real numbers (the Simulator has no
/// battery and never delivers MetricKit payloads).
@MainActor final class BatteryDiagnostics: NSObject, ObservableObject {

    struct Sample: Codable, Identifiable, Equatable {
        let at: Date
        let level: Double            // 0…1, or -1 when unavailable (Simulator)
        let charging: Bool
        let thermal: Int             // ProcessInfo.ThermalState.rawValue (0 nominal … 3 critical)
        let activity: String         // what the app was doing at this instant
        var dischargePctPerHour: Double?   // derived vs the previous sample (nil while charging / first)
        var id: Date { at }
    }

    @Published private(set) var samples: [Sample] = []
    @Published private(set) var metricSummary: String?     // latest MetricKit payload, human-readable
    @Published var enabled: Bool = UserDefaults.standard.bool(forKey: BatteryDiagnostics.enabledKey) {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            enabled ? startSampling() : stopSampling()
        }
    }

    /// Injected by the app: a compact one-line description of what's running right now (transcription
    /// state, map layer, Stratux, GPS). Kept as a closure so this stays decoupled from `AppModel`.
    var activityProvider: (() -> String)?

    private static let enabledKey = "atc.batteryDiagnostics"
    private static let maxSamples = 720          // ~12 h at one sample/min — bounded ring
    private var samplerTask: Task<Void, Never>?
    private var foregrounded = true

    override init() {
        super.init()
        loadFromDisk()
        MXMetricManager.shared.add(self)         // MetricKit is free + system-throttled — always subscribe
        if enabled { startSampling() }
    }

    /// Scene phase drives the sampler: no point sampling (or holding a timer) while backgrounded, where
    /// the app is suspended anyway.
    func setForegrounded(_ active: Bool) {
        foregrounded = active
        if enabled { active ? startSampling() : stopSampling() }
    }

    func clear() {
        samples = []
        persist()
    }

    /// A shareable plain-text dump of everything collected (for AirDrop/Messages to a dev machine).
    func exportText() -> String {
        var lines = ["CommSight battery diagnostics", "Samples: \(samples.count)", ""]
        if let m = metricSummary { lines.append("MetricKit (latest daily payload):"); lines.append(m); lines.append("") }
        lines.append("time,level%,charging,thermal,discharge%/hr,activity")
        let df = ISO8601DateFormatter()
        for s in samples.suffix(Self.maxSamples) {                            // bounded (rule 2)
            let lvl = s.level >= 0 ? String(format: "%.0f", s.level * 100) : "n/a"
            let rate = s.dischargePctPerHour.map { String(format: "%.1f", $0) } ?? ""
            lines.append("\(df.string(from: s.at)),\(lvl),\(s.charging),\(s.thermal),\(rate),\(s.activity)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: sampler

    private func startSampling() {
        guard samplerTask == nil, foregrounded else { return }
        UIDevice.current.isBatteryMonitoringEnabled = true
        samplerTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.takeSample()
                try? await Task.sleep(nanoseconds: 60_000_000_000)   // 60 s
            }
        }
    }

    private func stopSampling() {
        samplerTask?.cancel(); samplerTask = nil
    }

    private func takeSample() {
        assert(Self.maxSamples > 0, "sample ring must be positive")
        let device = UIDevice.current
        let level = Double(device.batteryLevel)          // -1 when monitoring off / Simulator
        let charging = device.batteryState == .charging || device.batteryState == .full
        let thermal = ProcessInfo.processInfo.thermalState.rawValue
        let activity = activityProvider?() ?? "—"
        var s = Sample(at: Date(), level: level, charging: charging, thermal: thermal,
                       activity: activity, dischargePctPerHour: nil)
        if let prev = samples.last, !charging, !prev.charging,
           prev.level >= 0, level >= 0, level < prev.level {
            let hours = s.at.timeIntervalSince(prev.at) / 3600
            if hours > 0 { s.dischargePctPerHour = (prev.level - level) * 100 / hours }
        }
        samples.append(s)
        if samples.count > Self.maxSamples { samples.removeFirst(samples.count - Self.maxSamples) }
        persist()
    }

    /// The most recent derived discharge rate (%/hr), for the summary header. nil until two discharging
    /// samples exist.
    var latestDischargeRate: Double? { samples.last(where: { $0.dischargePctPerHour != nil })?.dischargePctPerHour }

    // MARK: persistence

    private var fileURL: URL? {
        (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                      appropriateFor: nil, create: true))?
            .appendingPathComponent("battery_diagnostics.json")
    }
    private func persist() {
        guard let url = fileURL, let d = try? JSONEncoder().encode(samples) else { return }
        try? d.write(to: url, options: .atomic)
    }
    private func loadFromDisk() {
        guard let url = fileURL, let d = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode([Sample].self, from: d) else { return }
        samples = Array(s.suffix(Self.maxSamples))
    }
}

// MARK: - MetricKit

extension BatteryDiagnostics: MXMetricManagerSubscriber {
    nonisolated func didReceive(_ payloads: [MXMetricPayload]) {
        // Summarize off the payloads' key energy-relevant fields; hop to main to publish.
        let text = payloads.suffix(3).map { Self.summarize($0) }.joined(separator: "\n---\n")
        Task { @MainActor in self.metricSummary = text.isEmpty ? nil : text }
    }

    nonisolated private static func summarize(_ p: MXMetricPayload) -> String {
        var lines: [String] = []
        lines.append("Window: \(p.timeStampBegin) → \(p.timeStampEnd)")
        if let cpu = p.cpuMetrics { lines.append("CPU time: \(cpu.cumulativeCPUTime)") }
        if let gpu = p.gpuMetrics { lines.append("GPU time: \(gpu.cumulativeGPUTime)") }
        if let loc = p.locationActivityMetrics {
            lines.append("GPS best-accuracy time: \(loc.cumulativeBestAccuracyTime)")
            lines.append("GPS navigation-accuracy time: \(loc.cumulativeBestAccuracyForNavigationTime)")
        }
        if let net = p.networkTransferMetrics {
            lines.append("WiFi up/down: \(net.cumulativeWifiUpload)/\(net.cumulativeWifiDownload)")
            lines.append("Cell up/down: \(net.cumulativeCellularUpload)/\(net.cumulativeCellularDownload)")
        }
        if let app = p.applicationTimeMetrics {
            lines.append("Foreground time: \(app.cumulativeForegroundTime)")
            lines.append("Background time: \(app.cumulativeBackgroundTime)")
        }
        return lines.joined(separator: "\n")
    }
}
