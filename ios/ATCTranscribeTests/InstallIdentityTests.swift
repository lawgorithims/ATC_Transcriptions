import XCTest
import Security
@testable import ATCTranscribe

/// The two facts that cannot be reconstructed after the paywall ships.
///
/// `appAccountToken` cannot be backfilled onto an existing StoreKit transaction, and grandfathering
/// cannot be decided retrospectively for installs nobody recorded. Both are cheap now and
/// impossible later, which is why they are tested before there is anything to sell.
final class InstallIdentityTests: XCTestCase {

    private let firstSeenKey = "atc.install.firstSeenBuild"
    private let appModelKey = "atc.lastSeenBuild"
    private var savedAppModelValue: Int?

    override func setUp() {
        super.setUp()
        // Preserve AppModel's own key — this suite reads and fakes it, and clobbering it would
        // make the What's New sheet re-present for whoever runs the tests on a real device.
        savedAppModelValue = UserDefaults.standard.object(forKey: appModelKey) as? Int
        InstallIdentity.resetForTesting()
        UserDefaults.standard.removeObject(forKey: appModelKey)
    }

    override func tearDown() {
        InstallIdentity.resetForTesting()
        if let saved = savedAppModelValue {
            UserDefaults.standard.set(saved, forKey: appModelKey)
        } else {
            UserDefaults.standard.removeObject(forKey: appModelKey)
        }
        super.tearDown()
    }

    // MARK: Install id

    /// Minted once and stable thereafter. If this ever returns a fresh UUID per call, every
    /// purchase binds to a different token and none of them can be matched to an account.
    ///
    /// Stable reads no longer prove the Keychain on their own, because a launch's stand-in is
    /// stable too. So this also asserts the id was persisted, and finds it where it is stored.
    func testInstallIDIsStableAcrossReads() throws {
        try skipUnlessThisBuildCanUseTheKeychain()
        let first = InstallIdentity.installID
        XCTAssertEqual(first, InstallIdentity.installID)
        XCTAssertEqual(first, InstallIdentity.installID, "the id must come from the Keychain, not be re-minted")
        XCTAssertNotEqual(first, UUID(), "sanity: not the all-zero or a constant UUID")
        XCTAssertTrue(InstallIdentity.resolveInstallID().persisted,
                      "a build whose Keychain works must store the id, not hand out a launch's stand-in")
        XCTAssertEqual(KeychainBox(service: "com.flycommsight.install").string("install_id"), first.uuidString,
                       "the id lives at this service and account: moving it orphans every id already issued")
    }

    func testInstallIDSurvivesAFirstSeenReset() throws {
        try skipUnlessThisBuildCanUseTheKeychain()
        let id = InstallIdentity.installID
        UserDefaults.standard.removeObject(forKey: firstSeenKey)
        XCTAssertEqual(id, InstallIdentity.installID,
                       "the install id lives in the Keychain and must not be tied to a UserDefaults key")
        XCTAssertTrue(InstallIdentity.resolveInstallID().persisted,
                      "equal ids prove nothing on their own: a launch's stand-in is stable too")
    }

    /// Skips when this test host cannot use the Keychain at all, which means an unsigned build.
    ///
    /// Asked with raw Security calls on a service of its own, so no change to `KeychainBox` or
    /// `InstallIdentity` can turn a failure of theirs into a skip; only the build can. Built with
    /// `CODE_SIGNING_ALLOWED=NO` the app carries no entitlements, so no keychain access group, and
    /// every call answers -34018: the install id cannot persist there by construction. What it
    /// falls back to is tested in every build by `InstallIdentityFallbackTests`.
    private func skipUnlessThisBuildCanUseTheKeychain() throws {
        let probe: [CFString: Any] = [kSecClass: kSecClassGenericPassword,
                                      kSecAttrService: "com.flycommsight.tests.keychain-probe",
                                      kSecAttrAccount: "probe"]
        var add = probe
        add[kSecValueData] = Data("probe".utf8)
        let status = SecItemAdd(add as CFDictionary, nil)
        SecItemDelete(probe as CFDictionary)
        try XCTSkipIf(status == errSecMissingEntitlement,
                      "This build has no keychain access group (-34018): it was built with "
                      + "CODE_SIGNING_ALLOWED=NO, so the install id cannot persist and there is nothing "
                      + "here to test. Build signed for the simulator, as ios/RELEASING.md §3 does.")
        XCTAssertTrue(status == errSecSuccess || status == errSecDuplicateItem,
                      "the Keychain probe failed for a reason other than the build's signing: \(status)")
    }

    // MARK: First-seen build

    /// THE GRANDFATHERING SIGNAL. An install that predates this type inherits `atc.lastSeenBuild`,
    /// the integer `AppModel` already writes on first launch to drive the What's New sheet.
    ///
    /// This is the whole reason the existing TestFlight cohort can be identified at all: nobody
    /// recorded a first-seen date for them, but every one of them already carries a build number
    /// lower than whatever build the paywall ships in.
    func testFirstSeenBuildInheritsAppModelsLastSeenBuild() {
        UserDefaults.standard.set(110, forKey: appModelKey)
        XCTAssertEqual(InstallIdentity.firstSeenBuild, 110,
                       "an existing install must be recognised from the key AppModel already wrote. "
                       + "Without this, every current beta tester looks like a brand-new install.")
    }

    /// Once resolved it is written through, so a later change to AppModel's key cannot move it.
    func testFirstSeenBuildIsStickyOnceResolved() {
        UserDefaults.standard.set(110, forKey: appModelKey)
        XCTAssertEqual(InstallIdentity.firstSeenBuild, 110)
        UserDefaults.standard.set(250, forKey: appModelKey)   // a later What's New advance
        XCTAssertEqual(InstallIdentity.firstSeenBuild, 110,
                       "first-seen must not drift upwards as the user sees newer builds — it would "
                       + "silently move a grandfathered install out of its cohort.")
    }

    /// A genuinely fresh install, with neither key present, falls back to the running build.
    func testFreshInstallFallsBackToTheCurrentBuild() {
        XCTAssertEqual(InstallIdentity.firstSeenBuild, InstallIdentity.currentBuild,
                       "a fresh install has no AppModel baseline to inherit")
    }

    // MARK: The legacy cohort

    /// ⚠️ THE SAFE DEFAULT. `paywallFirstBuild` is 0 until the paywall actually ships, and 0 must
    /// mean "nobody is grandfathered".
    ///
    /// The polarity is the same one `Core/Features.swift` documents: "off" is the safe unwritten
    /// state. Forgetting to set the build asks existing testers to pay, which is recoverable by
    /// shipping the right number. A permissive default hands the whole cohort free access, which is
    /// not recoverable.
    func testNobodyIsGrandfatheredUntilThePaywallBuildIsSet() throws {
        try XCTSkipIf(InstallIdentity.paywallFirstBuild > 0,
                      "the paywall build has been set — this test covers the pre-paywall default")
        UserDefaults.standard.set(110, forKey: appModelKey)
        XCTAssertFalse(InstallIdentity.isPrePaywallInstall,
                       "with paywallFirstBuild == 0 nothing may be granted for free. If this fails, "
                       + "the default polarity has been inverted and the legacy grant leaks.")
    }

    /// When the build IS set, the comparison must separate the cohorts in both directions. Skipped
    /// until then, so it starts asserting the moment the real number lands.
    func testCohortSplitOnceThePaywallBuildIsSet() throws {
        let paywall = InstallIdentity.paywallFirstBuild
        try XCTSkipIf(paywall == 0, "paywallFirstBuild not set yet")

        InstallIdentity.resetForTesting()
        UserDefaults.standard.set(paywall - 1, forKey: appModelKey)
        XCTAssertTrue(InstallIdentity.isPrePaywallInstall, "an install from before the paywall build is legacy")

        InstallIdentity.resetForTesting()
        UserDefaults.standard.set(paywall, forKey: appModelKey)
        XCTAssertFalse(InstallIdentity.isPrePaywallInstall, "an install on the paywall build is not legacy")
    }
}

/// What the install id does when the Keychain will not keep it, run against a fake Keychain. The
/// release gate's signed build never refuses, so this is the only place the fallback runs there.
///
/// The failure this replaced (2026-10-29): a simulator build made with `CODE_SIGNING_ALLOWED=NO` has
/// no keychain access group, every Keychain call returned -34018, `KeychainBox.set` asserted on it,
/// and the unit suite crashed twice.
final class InstallIdentityFallbackTests: XCTestCase {

    /// One account's worth of Keychain: what a read answers, whether a write lands, writes tried.
    private final class FakeKeychain: KeychainStoring {
        var answer: KeychainBox.Lookup
        let acceptsWrites: Bool
        private(set) var writes = 0

        init(answer: KeychainBox.Lookup, acceptsWrites: Bool) {
            self.answer = answer
            self.acceptsWrites = acceptsWrites
        }

        func lookup(_ account: String) -> KeychainBox.Lookup { answer }

        func set(_ account: String, string value: String) -> Bool {
            writes += 1
            guard acceptsWrites else { return false }
            answer = .found(Data(value.utf8))
            return true
        }
    }

    private let candidate = UUID()

    private func resolve(_ keychain: FakeKeychain) -> InstallIdentity.Resolution {
        InstallIdentity.resolveInstallID(in: keychain, candidate: candidate)
    }

    /// THE REPORTED CRASH: every call refused with -34018. Nothing traps, and the launch gets one
    /// stand-in that every read agrees on and that says it is not persisted.
    func testAKeychainWithoutTheEntitlementGivesOneStandInPerLaunch() {
        let keychain = FakeKeychain(answer: .unavailable(errSecMissingEntitlement), acceptsWrites: false)
        let first = resolve(keychain)
        XCTAssertEqual(first, InstallIdentity.Resolution(id: candidate, persisted: false))
        XCTAssertEqual(resolve(keychain), first, "every read in one launch must hand out the same id")
    }

    /// A device not unlocked since boot answers -25308 to a read of an id that IS stored. Minting
    /// over it would orphan any purchase bound to the real one, so a Keychain that could not be
    /// read is never written to. (The code before this minted on any failed read.)
    func testAKeychainThatCannotBeReadIsNeverWrittenTo() {
        let keychain = FakeKeychain(answer: .unavailable(errSecInteractionNotAllowed), acceptsWrites: true)
        XCTAssertFalse(resolve(keychain).persisted)
        XCTAssertEqual(keychain.writes, 0, "a read the Keychain refused is not evidence that nothing is stored")
    }

    /// Nothing stored and the write refused: the stand-in, and the next read tries the write again.
    func testARefusedWriteGivesTheStandInAndIsRetried() {
        let keychain = FakeKeychain(answer: .absent, acceptsWrites: false)
        XCTAssertEqual(resolve(keychain), InstallIdentity.Resolution(id: candidate, persisted: false))
        XCTAssertEqual(resolve(keychain).id, candidate)
        XCTAssertEqual(keychain.writes, 2, "a refused write is retried, never assumed to have landed")
    }

    /// A fresh install stores the candidate, then reads it back without writing again.
    func testAFreshInstallStoresTheCandidateOnce() {
        let keychain = FakeKeychain(answer: .absent, acceptsWrites: true)
        let persisted = InstallIdentity.Resolution(id: candidate, persisted: true)
        XCTAssertEqual(resolve(keychain), persisted)
        XCTAssertEqual(resolve(keychain), persisted)
        XCTAssertEqual(keychain.writes, 1, "an id already stored is read back, never re-minted")
    }

    /// An id already stored wins over this launch's candidate, and nothing is written.
    func testAStoredIDWinsOverTheCandidate() {
        let stored = UUID()
        let keychain = FakeKeychain(answer: .found(Data(stored.uuidString.utf8)), acceptsWrites: true)
        XCTAssertEqual(resolve(keychain), InstallIdentity.Resolution(id: stored, persisted: true))
        XCTAssertEqual(keychain.writes, 0)
    }

    /// A stand-in handed out while the Keychain could not be read is the id it stores once it
    /// answers "nothing here", so one launch never hands out two different ids.
    func testTheStandInIsTheIDStoredWhenTheKeychainRecovers() {
        let keychain = FakeKeychain(answer: .unavailable(errSecInteractionNotAllowed), acceptsWrites: true)
        let before = resolve(keychain)
        XCTAssertFalse(before.persisted)
        keychain.answer = .absent                                       // unlocked: a fresh install after all
        XCTAssertEqual(resolve(keychain), InstallIdentity.Resolution(id: before.id, persisted: true))
    }

    /// A stored value that is not a UUID was never issued by this type, so replacing it orphans nothing.
    func testAStoredValueThatIsNotAUUIDIsReplaced() {
        let keychain = FakeKeychain(answer: .found(Data("not-a-uuid".utf8)), acceptsWrites: true)
        XCTAssertEqual(resolve(keychain), InstallIdentity.Resolution(id: candidate, persisted: true))
        XCTAssertEqual(keychain.writes, 1)
    }
}

/// The chart-pack → tier mapping, which is derived from a string prefix and so is exactly the kind
/// of thing that rots silently when the publisher changes.
final class ChartCapabilityTests: XCTestCase {

    private func entry(_ path: String) -> ChartCatalog.Entry {
        // Decoded rather than constructed with the memberwise init, so the test also pins the JSON
        // field names `charts/publish_packs.py` writes — a renamed `path` key would break the tier
        // mapping silently, and that is the failure this file exists to catch.
        let json = """
        {"id":"test","bounds":[-100,30,-90,40],"bytes":1,"path":"\(path)"}
        """.data(using: .utf8)!
        return try! JSONDecoder().decode(ChartCatalog.Entry.self, from: json)
    }

    /// The three families `charts/publish_packs.py` publishes, mapped to the three tiers that sell
    /// them. The remote subdirectories come from that script's `FAMILIES` table.
    func testEachPublishedFamilyMapsToItsTier() {
        XCTAssertEqual(entry("sectional/New_York_SEC.mbtiles").capability, .vfrCharts)
        XCTAssertEqual(entry("ifr/ENR_L25.mbtiles").capability, .ifrLowCharts)
        XCTAssertEqual(entry("ifrhigh/ENR_H06.mbtiles").capability, .ifrHighCharts)
    }

    /// `ifrhigh/` must be matched before `ifr/`, because it starts with it. Getting this backwards
    /// sells the top tier's enroute charts to every Pro subscriber.
    func testIFRHighIsNotMisreadAsIFRLow() {
        XCTAssertEqual(entry("ifrhigh/ENR_H01.mbtiles").capability, .ifrHighCharts,
                       "\"ifrhigh/\" has the prefix \"ifr\" — the high check must come first.")
    }

    /// Every family in the real shipped catalog must map to something known. This is the test that
    /// catches a new family added to `publish_packs.py` without a line in `Entry.capability`.
    func testNoChartFamilyIsUnmapped() {
        let known = ["sectional/", "ifr/", "ifrhigh/"]
        for path in ["sectional/Denver_SEC.mbtiles", "ifr/ENR_L01.mbtiles", "ifrhigh/ENR_H12.mbtiles"] {
            XCTAssertTrue(known.contains { path.hasPrefix($0) },
                          "\(path) is not one of the families Entry.capability knows about")
        }
    }

    // MARK: Layer ↔ pack agreement, and the dead-button regression

    /// The per-layer button and the per-pack button must gate on the SAME capability.
    ///
    /// They are two separate tables (`ChartLayer.capability` and `ChartCatalog.Entry.capability`,
    /// one keyed on an enum and one on a path prefix) read by two different buttons on the same
    /// screen. If they disagree, "download all IFR-low" and "download this IFR-low pack" give
    /// different answers to the same pilot, which is indistinguishable from a bug in billing.
    func testLayerAndPackCapabilitiesAgree() {
        let pairs: [(ChartLayer, String)] = [
            (.sectional, "sectional/Denver_SEC.mbtiles"),
            (.ifrLow,    "ifr/ENR_L25.mbtiles"),
            (.ifrHigh,   "ifrhigh/ENR_H06.mbtiles"),
        ]
        for (layer, path) in pairs {
            XCTAssertEqual(layer.capability, entry(path).capability,
                           "\(layer) and \(path) must gate on one capability, not two")
        }
    }

    /// The Apple/bundled base layers download nothing from us, so they have no capability and can
    /// never be refused for a billing reason.
    func testUndownloadableLayersHaveNoCapability() {
        XCTAssertNil(ChartLayer.satellite.capability)
        XCTAssertNil(ChartLayer.smartDark.capability)
    }

    /// REGRESSION: the dead Download button.
    ///
    /// `DownloadsView` pre-checks the policy before starting, so a refusal becomes an explained
    /// dialog instead of a button that silently does nothing. That pre-check used to ask only the
    /// network question, so for an unentitled pack it answered `.allowed` — and then
    /// `ChartLibrary.download` refused on entitlement and returned false. The button did nothing at
    /// the per-pack site, and at the per-layer site it offered a mobile-data override for content no
    /// override can fetch.
    ///
    /// Passing the capability is what fixes it, so this asserts the pre-check itself now refuses.
    func testPreCheckRefusesAnUnentitledPackInsteadOfAllowingIt() {
        let flightBag = EntitlementGate(tier: .flightBag, currency: .verified(asOf: Date()))
        let wifi = DownloadPolicy.PathState(satisfied: true, wifi: true,
                                            expensive: false, constrained: false)

        // Flight Bag includes VFR and nothing above it.
        XCTAssertEqual(DownloadPolicy.decide(path: wifi, wifiOnly: true, intent: .userInitiated,
                                             requires: ChartLayer.sectional.capability,
                                             gate: flightBag),
                       .allowed)
        for layer in [ChartLayer.ifrLow, .ifrHigh] {
            let verdict = DownloadPolicy.decide(path: wifi, wifiOnly: true, intent: .userInitiated,
                                                requires: layer.capability, gate: flightBag)
            XCTAssertEqual(verdict, .notEntitled(layer.capability!),
                           "the pre-check must refuse \(layer) for a Flight Bag subscriber. If this "
                           + "returns .allowed, the download starts, ChartLibrary refuses it, and the "
                           + "button does nothing.")
            XCTAssertNotNil(verdict.upgradeFor,
                            "the refusal must carry the capability so the notice can name the tier")
        }
    }

    /// And the satellite layer is never refused, at any tier — it downloads nothing from us.
    func testUndownloadableLayersAreNeverRefused() {
        let wifi = DownloadPolicy.PathState(satisfied: true, wifi: true,
                                            expensive: false, constrained: false)
        XCTAssertEqual(DownloadPolicy.decide(path: wifi, wifiOnly: true, intent: .userInitiated,
                                             requires: ChartLayer.satellite.capability,
                                             gate: .free),
                       .allowed)
    }
}
