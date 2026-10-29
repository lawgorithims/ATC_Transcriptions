import Foundation
import Combine

/// The app's view of what the pilot has paid for.
///
/// # Why this is a singleton AND an `ObservableObject`
///
/// Both halves are needed, for reasons already demonstrated elsewhere in this codebase:
///
/// - **Singleton**, because the most important enforcement sites are not in the view tree.
///   `ChartLibrary.shared`, `NavDataLibrary.shared`, `LZPackLibrary.shared` and
///   `DownloadPolicy.shared` cannot read an `@EnvironmentObject`. `DownloadPolicy` is a singleton
///   for precisely this reason, and its doc comment records what the alternative produced: *"three
///   behaviours for one question, none of them visible to the pilot."*
/// - **`ObservableObject`**, so the ~40 view sites re-render when an entitlement changes.
///
/// # Why NOT on `AppModel`
///
/// `UI/AppModel.swift` is 5,374 lines with 163 `@Published` properties and ARCHITECTURE §5 calls it
/// the god-object. Two concrete reasons beyond size: §5's `WidgetStore` note records that *"nested
/// `ObservableObject`s don't republish their parent"*, so hanging this off `AppModel` would fail to
/// republish; and `AppModel` publishes several times a second during a live session, which would
/// drag every paywall view into that storm for no reason. `UI/DownloadsView.swift` already shows
/// the house pattern — `@ObservedObject var library = ChartLibrary.shared` beside
/// `@ObservedObject var policy = DownloadPolicy.shared`.
///
/// The published value is a flattened `EntitlementGate` **value**, not a nested object, so a view
/// reads one `Bool` and compares cheaply.
@MainActor
final class EntitlementStore: ObservableObject {
    static let shared = EntitlementStore()

    /// The current gate. Every read site goes through this.
    ///
    /// Initialised to `.free` and then resolved, rather than being optional: there is no "we don't
    /// know yet" state a view has to special-case, and the unwritten state is the unentitled one
    /// (the polarity rule documented on `Entitlements`).
    @Published private(set) var gate: EntitlementGate = .free

    private init() {
        InstallIdentity.recordFirstLaunchIfNeeded()
        gate = Self.resolve()
    }

    /// Convenience passthrough so a call site can read `EntitlementStore.shared.can(.ifrLowCharts)`
    /// without reaching through `gate` — mainly for the non-view singletons.
    func can(_ capability: Capability) -> Bool { gate.can(capability) }

    /// Recompute the gate. Called at launch, on `scenePhase == .active`, and (from M3) whenever
    /// StoreKit reports a transaction change or the server issues a new record.
    func refresh() {
        gate = Self.resolve()
    }

    // MARK: Resolution

    private static func resolve() -> EntitlementGate {
        #if DEBUG
        if let forced = debugOverride() { return forced }
        #endif

        // ───────────────────────────────────────────────────────────────────────────────────────
        // M1: EVERYTHING IS GRANTED. This build has no purchase path, no backend and no cache, so
        // the only honest behaviour is to change nothing for anyone — the entitlement layer ships
        // invisibly so its plumbing, its call sites and its tests can be proven under real use
        // before money is involved.
        //
        // M3 replaces this with: read the signed record from `EntitlementCache`, cross-check
        // StoreKit's `Transaction.currentEntitlements`, and take the higher of the two. When that
        // lands, THIS is the line that must become the legacy-cohort grant for
        // `InstallIdentity.isPrePaywallInstall` and `.free` for everyone else — and
        // `InstallIdentity.paywallFirstBuild` must be set in the same change.
        // ───────────────────────────────────────────────────────────────────────────────────────
        return EntitlementGate(tier: .proPerformance, currency: .verified(asOf: Date()))
    }

    #if DEBUG
    /// `--entitlement <none|flightbag|pro|performance>` for UI tests and manual checks.
    ///
    /// ⚠️ `#if DEBUG` ONLY. In a release build this would be a free unlock for anyone who can
    /// attach a debugger or install a configuration profile. The `#if` is the whole guarantee —
    /// a DEBUG-built test target cannot assert the absence of a symbol in a RELEASE build, so
    /// there is deliberately no test here to lean on. Keep the `#if DEBUG` wrapper when editing.
    ///
    /// Parsed from `CommandLine.arguments`, never through UserDefaults — `DownloadPolicy` documents
    /// why: a `-key value` launch argument lands in UserDefaults' ARGUMENT domain, which outranks
    /// every other domain, is read-only, and makes any non-numeric value read back as `false`.
    static func debugOverride() -> EntitlementGate? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--entitlement"), i + 1 < args.count else { return nil }
        switch args[i + 1].lowercased() {
        case "none":        return .free
        case "flightbag":  return EntitlementGate(tier: .flightBag, currency: .verified(asOf: Date()))
        case "pro":        return EntitlementGate(tier: .pro, currency: .verified(asOf: Date()))
        case "performance": return EntitlementGate(tier: .proPerformance, currency: .verified(asOf: Date()))
        case "lapsed":     return EntitlementGate(tier: .pro, currency: .lapsed(since: Date()))
        case "offline":    return EntitlementGate(tier: .pro, currency: .unverified(lastVerified: Date()))
        default:
            assertionFailure("--entitlement: unknown value '\(args[i + 1])'")
            return nil
        }
    }
    #endif
}
