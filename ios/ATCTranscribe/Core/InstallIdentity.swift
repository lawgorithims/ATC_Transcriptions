import Foundation

/// This install's stable identity, and whether it predates the paywall.
///
/// # Why this ships BEFORE anything is for sale
///
/// Two of the things in the monetization plan cannot be reconstructed after the fact, so they have
/// to exist from the build before the first purchase is possible:
///
/// 1. **`appAccountToken` cannot be backfilled onto an existing StoreKit transaction.** It must be
///    supplied at `Product.purchase(options:)` time or it is never attached. A purchase made
///    without one can never be automatically bound to a server account later — that customer
///    proves ownership by hand, forever. So `installID` must exist, stable, before the paywall.
/// 2. **Grandfathering needs to know who was already here.** There is an existing cohort: the
///    EFB-only public beta starts at build `WhatsNew.efbBetaFirstBuild` (110), and those testers
///    have had the whole app for free.
///
/// # The grandfathering signal is one we already have
///
/// `firstSeenBuild` deliberately falls back to **`atc.lastSeenBuild`** — the integer `AppModel`
/// already persists to drive the What's New sheet, and which is written on first launch for every
/// install (`AppModel` calls `markWhatsNewSeen()` when the key is absent). That means every
/// existing TestFlight install *already carries* a build number lower than whatever build the
/// paywall ships in, with no new bookkeeping and no need to have thought of this earlier.
///
/// A fresh install on a paywall build writes its own (higher) number, so the comparison separates
/// the cohorts correctly in both directions.
enum InstallIdentity {

    private static let box = KeychainBox(service: "com.flycommsight.install")
    private static let installIDKey = "install_id"

    private static let firstSeenBuildKey = "atc.install.firstSeenBuild"
    /// `AppModel`'s What's New baseline. Read-only here — this type never writes it.
    private static let appModelLastSeenBuildKey = "atc.lastSeenBuild"

    // MARK: Install id

    /// A UUID minted once per install and never changed. Doubles as the StoreKit `appAccountToken`.
    ///
    /// KEYCHAIN, NOT UserDefaults, and deliberately `...ThisDeviceOnly` (see `KeychainBox`): an id
    /// that an iCloud backup could carry to a second device would also carry that device's
    /// entitlement binding, which is a one-tap site licence.
    ///
    /// NOT `identifierForVendor`: that resets once all of a vendor's apps are removed, which would
    /// orphan the purchases bound to it. NOT the IDFA, which is a tracking identifier this app has
    /// never used and should not start using.
    ///
    /// Never traps. When the Keychain will not keep the id, this is the launch's stand-in: the same
    /// on every read until the app quits, and the log says so. A caller that must not mistake one
    /// for the other (anything that binds a purchase) reads `resolveInstallID()` instead.
    static var installID: UUID { resolveInstallID().id }

    /// An install id, and whether the Keychain is keeping it.
    struct Resolution: Equatable {
        let id: UUID
        /// `true`: read back from the Keychain, so the same id on every launch of this install.
        /// `false`: this launch's stand-in. The next launch offers another, so nothing that outlives
        /// the app (an `appAccountToken`, a server binding) may be tied to it as the install's id.
        let persisted: Bool
    }

    /// This launch's one candidate id. A `static let` initialiser runs exactly once, thread-safely,
    /// so every read in a launch agrees: it is the id a fresh install stores and the stand-in when
    /// the Keychain will not keep one. A stand-in handed out before the Keychain recovered is
    /// therefore the id it then stores, and one launch never hands out two.
    private static let launchCandidate = UUID()

    static func resolveInstallID() -> Resolution {
        resolveInstallID(in: box, candidate: launchCandidate)
    }

    /// The resolution itself, over any Keychain, so the tests can hand it one that refuses.
    ///
    /// ⚠️ MINT ONLY ON A POSITIVE ANSWER: nothing is stored, or what is stored is not a UUID and so
    /// was never issued (this type only writes `uuidString`). A Keychain that did not answer, such as
    /// a device not unlocked since boot, may be holding an id a purchase is already bound to, and
    /// writing over it would orphan that purchase for good. The code before this minted on any
    /// failed read.
    static func resolveInstallID(in keychain: some KeychainStoring, candidate: UUID) -> Resolution {
        assert(candidate.uuidString != "00000000-0000-0000-0000-000000000000",
               "InstallIdentity: the all-zero UUID would be every install's id")
        switch keychain.lookup(installIDKey) {
        case .found(let data):
            if let stored = uuid(data) { return Resolution(id: stored, persisted: true) }
            // Not a UUID, so never issued: replaced below.
        case .absent:
            break
        case .unavailable(let status):
            return standIn(candidate, "the Keychain could not be read: \(KeychainBox.describe(status))")
        }
        let wrote = keychain.set(installIDKey, string: candidate.uuidString)
        // Re-read rather than trust the write: the id to hand out is the one the Keychain now holds,
        // which is another writer's if that one got there first.
        guard case .found(let data) = keychain.lookup(installIDKey), let stored = uuid(data) else {
            return standIn(candidate, wrote ? "the Keychain took it but did not read it back"
                                            : "the Keychain refused it")
        }
        return Resolution(id: stored, persisted: true)
    }

    private static func uuid(_ data: Data) -> UUID? {
        UUID(uuidString: String(decoding: data, as: UTF8.self))
    }

    /// The candidate, for this launch only, and the log says so because nothing else will.
    private static func standIn(_ candidate: UUID, _ reason: String) -> Resolution {
        assert(!reason.isEmpty, "InstallIdentity.standIn: a stand-in must say why")
        NSLog("Obelisk: install id NOT persisted — %@. Using a stand-in for this launch only: a "
              + "purchase bound to it could not be matched to this install after a relaunch.", reason)
        return Resolution(id: candidate, persisted: false)
    }

    // MARK: First-seen build

    /// The app build at which this install was first recorded.
    ///
    /// Resolution order, and why:
    /// 1. Our own key, once written — authoritative and never moves.
    /// 2. `atc.lastSeenBuild`, for installs that predate this type. This is the whole point: it is
    ///    already on disk for the existing beta cohort.
    /// 3. The running build, for a genuinely fresh install.
    static var firstSeenBuild: Int {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: firstSeenBuildKey) != nil {
            return defaults.integer(forKey: firstSeenBuildKey)
        }
        let inherited = defaults.integer(forKey: appModelLastSeenBuildKey)   // 0 when absent
        let resolved = inherited > 0 ? inherited : currentBuild
        defaults.set(resolved, forKey: firstSeenBuildKey)
        return resolved
    }

    /// Record the first-seen build if it has not been recorded yet. Called once at launch so the
    /// value is captured even for a user who never opens a paywall.
    static func recordFirstLaunchIfNeeded() {
        _ = firstSeenBuild
    }

    /// `CFBundleVersion` as an integer. Dev builds report "1" (the build number is injected at
    /// archive time via `CURRENT_PROJECT_VERSION`), so this is 1 in the Simulator.
    static var currentBuild: Int {
        Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0
    }

    // MARK: The legacy cohort

    /// The build in which the paywall first ships. Installs first seen **before** this build are
    /// the grandfathered cohort.
    ///
    /// ⚠️ MUST BE SET before the paywall ships, and it is 0 until then **on purpose**. 0 means
    /// `isPrePaywallInstall` is false for everyone, i.e. nobody is granted anything for free — the
    /// same polarity discipline `Core/Features.swift` documents, where "off" is the safe unwritten
    /// state. The failure mode of forgetting to set it is that existing testers are asked to pay,
    /// which is recoverable by shipping the right number. The failure mode of a permissive default
    /// is handing the entire tester cohort free access, which is not.
    static let paywallFirstBuild = 0

    /// Whether this install predates the paywall and is therefore eligible for the legacy grant.
    ///
    /// The grant itself (what tier, for how long) is resolved server-side so it can be changed
    /// without an app release; this is only the client's view of which cohort it is in.
    static var isPrePaywallInstall: Bool {
        guard paywallFirstBuild > 0 else { return false }
        return firstSeenBuild > 0 && firstSeenBuild < paywallFirstBuild
    }

    // MARK: Test seam

    /// `--reset-install-identity` clears both, so a UI test can meet a genuinely fresh install.
    /// Matching `--reset-download-settings` and `--reset-widgets`, which exist for the same reason.
    ///
    /// Heed the trap `DownloadPolicy` documents: a launch argument of the form
    /// `-atc.install.firstSeenBuild <value>` lands in UserDefaults' ARGUMENT domain, which outranks
    /// everything and is read-only — so overrides are parsed from `CommandLine.arguments` directly,
    /// never through UserDefaults.
    static func resetForTesting() {
        box.remove(installIDKey)
        UserDefaults.standard.removeObject(forKey: firstSeenBuildKey)
    }
}
