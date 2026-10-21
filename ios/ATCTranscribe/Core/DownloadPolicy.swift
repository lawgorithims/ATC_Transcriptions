import Foundation
import Combine
import Network

/// The pilot's two standing answers to "when may this app use the network for bulk data", and the
/// one place that decides whether a given download is allowed right now.
///
/// WHY ONE OBJECT. Before this, every bulk path made its own call: `ChartLibrary.prefetch` and
/// `updateInstalledPacks` consulted `NetPath.isExpensive()`, `startBulkDownload` asked the UI to
/// confirm, and `NavDataLibrary` asked nothing at all and would happily pull 22 MB of databases over
/// a cockpit hotspot. Three behaviours for one question, none of them visible to the pilot and none
/// of them changeable. Both settings below are now read by every download path in the app.
///
/// WHY THE DEFAULTS ARE ON, AND WHY THAT IS NOT `UserDefaults.bool`. `bool(forKey:)` returns `false`
/// for a key that was never written, so reading a default-ON setting through it ships the feature OFF
/// for every install — the same polarity trap `Features.transcription` documents. `defaultsTrue`
/// distinguishes "unset" from "set to false" by looking for the object first.
@MainActor
final class DownloadPolicy: ObservableObject {
    static let shared = DownloadPolicy()

    private enum Key {
        static let wifiOnly = "atc.download.wifiOnly"
        static let precacheNext = "atc.download.precacheNextCycle"
    }

    /// Download bulk data only on Wi-Fi (or wired). ON by default: the alternative is an EFB that can
    /// spend a few gigabytes of a pilot's cellular allowance without being asked.
    @Published var wifiOnly: Bool {
        didSet { UserDefaults.standard.set(wifiOnly, forKey: Key.wifiOnly) }
    }

    /// Download the next FAA cycle ahead of its effective date, so the roll is invisible. ON by
    /// default: the packs a pilot already chose are the ones they will still want in 28 days, and the
    /// alternative is discovering on cycle-roll day — possibly at the airport, possibly with no
    /// signal — that the kit needs a multi-gigabyte re-download.
    @Published var precacheNextCycle: Bool {
        didSet { UserDefaults.standard.set(precacheNextCycle, forKey: Key.precacheNext) }
    }

    init() {
        // `--reset-download-settings` clears both keys so a UI test can meet the FRESH defaults.
        // Matching `--reset-widgets`, which exists for the same reason. Passing the keys as plain
        // launch arguments does not work and fails misleadingly: `-atc.download.wifiOnly <value>`
        // lands in UserDefaults' ARGUMENT domain, which outranks everything, is read-only, and makes
        // any non-numeric value read back as `false` — so an attempt to clear a default-ON setting
        // sets it off instead, and the test fails blaming the feature.
        if CommandLine.arguments.contains("--reset-download-settings") {
            UserDefaults.standard.removeObject(forKey: Key.wifiOnly)
            UserDefaults.standard.removeObject(forKey: Key.precacheNext)
        }
        wifiOnly = Self.defaultsTrue(Key.wifiOnly)
        precacheNextCycle = Self.defaultsTrue(Key.precacheNext)
    }

    /// An unwritten key means ON. See the class note — `bool(forKey:)` alone cannot tell "never set"
    /// from "deliberately off", and guessing wrong silently disables the feature.
    private static func defaultsTrue(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) == nil ? true : UserDefaults.standard.bool(forKey: key)
    }

    // MARK: Verdict

    /// Why a download is being attempted. The two differ in exactly one way: background work also
    /// declines a CONSTRAINED path (iOS Low Data Mode) even when `wifiOnly` is off, because Low Data
    /// Mode is the pilot asking for restraint in general. A download the pilot just tapped is not
    /// background work and is never refused for that reason alone.
    enum Intent: Equatable { case userInitiated, background }

    enum Verdict: Equatable {
        case allowed
        /// `wifiOnly` is on and this path is cellular, a hotspot, or metered.
        case needsWiFi
        /// Low Data Mode, declined for background bulk only.
        case lowDataMode
        case offline

        var isAllowed: Bool { self == .allowed }

        /// What to tell the pilot. Never "failed" — none of these are failures.
        var explanation: String? {
            switch self {
            case .allowed:     return nil
            case .needsWiFi:   return "Waiting for Wi-Fi — downloads are set to Wi-Fi only."
            case .lowDataMode: return "Paused while Low Data Mode is on."
            case .offline:     return "No network connection."
            }
        }
    }

    /// A snapshot of the current network path. Separated from the decision so the decision is pure
    /// and testable — `NWPathMonitor` cannot be driven from a unit test.
    struct PathState: Equatable, Sendable {
        var satisfied: Bool
        /// Wi-Fi or wired Ethernet. NOT "not cellular": a path can be neither.
        var wifi: Bool
        var expensive: Bool
        var constrained: Bool

        static let unsatisfied = PathState(satisfied: false, wifi: false, expensive: false, constrained: false)
    }

    /// The whole rule, as a pure function.
    ///
    /// ⚠️ EXPENSIVE WI-FI IS NOT WI-FI. An iPad joined to an iPhone's Personal Hotspot reports the
    /// `.wifi` interface **and** `isExpensive == true`, because the bytes land on the phone's cellular
    /// plan. Accepting it as Wi-Fi would spend the exact allowance this setting exists to protect, in
    /// the exact situation — a cockpit — where the hotspot is most likely to be the only link.
    nonisolated static func decide(path: PathState, wifiOnly: Bool, intent: Intent) -> Verdict {
        guard path.satisfied else { return .offline }
        if wifiOnly, !path.wifi || path.expensive || path.constrained { return .needsWiFi }
        if intent == .background, path.constrained { return .lowDataMode }
        return .allowed
    }

    /// Probe the live path and decide. One-shot: reads the first update, then tears the monitor down.
    func verdict(_ intent: Intent) async -> Verdict {
        Self.decide(path: await Self.currentPath(), wifiOnly: wifiOnly, intent: intent)
    }

    /// One-shot network-path snapshot.
    nonisolated static func currentPath() async -> PathState {
        await withCheckedContinuation { (cont: CheckedContinuation<PathState, Never>) in
            let monitor = NWPathMonitor()
            let once = OnceBox(cont)
            monitor.pathUpdateHandler = { path in
                once.fire(PathState(
                    satisfied: path.status == .satisfied,
                    wifi: path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet),
                    expensive: path.isExpensive,
                    constrained: path.isConstrained))
                monitor.cancel()
            }
            monitor.start(queue: DispatchQueue(label: "download.policy.path"))
        }
    }

    /// Resumes a continuation at most once — `NWPathMonitor` reports more than one update.
    private final class OnceBox: @unchecked Sendable {
        private var cont: CheckedContinuation<PathState, Never>?
        private let lock = NSLock()
        init(_ c: CheckedContinuation<PathState, Never>) { cont = c }
        func fire(_ value: PathState) {
            lock.lock(); defer { lock.unlock() }
            cont?.resume(returning: value); cont = nil
        }
    }
}
