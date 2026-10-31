import XCTest
@testable import ATCTranscribe

/// The pilot's two download settings, and the one rule every download path in the app now consults.
///
/// Tested as a pure function against a synthesised `PathState` because `NWPathMonitor` cannot be
/// driven from a test — which is precisely why the decision was separated from the probe.
final class DownloadPolicyTests: XCTestCase {

    private func path(wifi: Bool, expensive: Bool = false,
                      constrained: Bool = false, satisfied: Bool = true) -> DownloadPolicy.PathState {
        .init(satisfied: satisfied, wifi: wifi, expensive: expensive, constrained: constrained)
    }

    private func decide(_ p: DownloadPolicy.PathState, wifiOnly: Bool,
                        _ intent: DownloadPolicy.Intent = .background) -> DownloadPolicy.Verdict {
        DownloadPolicy.decide(path: p, wifiOnly: wifiOnly, intent: intent)
    }

    private func decide(_ p: DownloadPolicy.PathState, wifiOnly: Bool,
                        _ intent: DownloadPolicy.Intent = .background,
                        requires capability: Capability,
                        gate: EntitlementGate) -> DownloadPolicy.Verdict {
        DownloadPolicy.decide(path: p, wifiOnly: wifiOnly, intent: intent,
                              requires: capability, gate: gate)
    }

    private var pro: EntitlementGate { EntitlementGate(tier: .pro, currency: .verified(asOf: Date())) }

    // MARK: The setting ON

    func testPlainWiFiIsAllowed() {
        XCTAssertEqual(decide(path(wifi: true), wifiOnly: true), .allowed)
    }

    func testCellularIsRefusedWhenWiFiOnlyIsOn() {
        XCTAssertEqual(decide(path(wifi: false, expensive: true), wifiOnly: true), .needsWiFi)
    }

    /// ⚠️ THE CASE THE OBVIOUS IMPLEMENTATION GETS WRONG, and the one most likely in a cockpit.
    ///
    /// An iPad joined to an iPhone's Personal Hotspot is on the `.wifi` interface — `usesInterfaceType(.wifi)`
    /// is true — while every byte lands on the phone's cellular plan, which is why iOS also reports
    /// `isExpensive`. A Wi-Fi-only check written as "is this the Wi-Fi interface" therefore permits the
    /// single most expensive link a pilot is likely to be on, in the exact place they cannot change it.
    func testAPersonalHotspotIsNotWiFiEvenThoughItUsesTheWiFiInterface() {
        XCTAssertEqual(decide(path(wifi: true, expensive: true), wifiOnly: true), .needsWiFi,
                       "expensive Wi-Fi is a hotspot: the bytes are cellular")
    }

    /// Low Data Mode is the pilot asking for restraint in general; under Wi-Fi-only it is honoured too.
    func testConstrainedWiFiIsRefusedWhenWiFiOnlyIsOn() {
        XCTAssertEqual(decide(path(wifi: true, constrained: true), wifiOnly: true), .needsWiFi)
    }

    func testWiredIsTreatedAsWiFi() {
        // `PathState.wifi` folds in wired Ethernet — an iPad on a dock is not on a metered link.
        XCTAssertEqual(decide(path(wifi: true), wifiOnly: true, .userInitiated), .allowed)
    }

    // MARK: The setting OFF

    func testCellularIsAllowedOnceTheSettingIsOff() {
        XCTAssertEqual(decide(path(wifi: false, expensive: true), wifiOnly: false), .allowed)
    }

    /// With the setting off, background bulk still declines Low Data Mode — but a download the pilot
    /// just tapped is not background work and must not be refused for that reason.
    func testLowDataModeStopsBackgroundBulkButNotADeliberateTap() {
        let p = path(wifi: false, expensive: true, constrained: true)
        XCTAssertEqual(decide(p, wifiOnly: false, .background), .lowDataMode)
        XCTAssertEqual(decide(p, wifiOnly: false, .userInitiated), .allowed)
    }

    // MARK: Offline

    func testOfflineIsReportedAsOfflineNotAsNeedingWiFi() {
        // The distinction drives the UI copy: "waiting for Wi-Fi" on a dead link is a lie a pilot
        // would act on by looking for a network that is already there.
        XCTAssertEqual(decide(path(wifi: false, satisfied: false), wifiOnly: true), .offline)
        XCTAssertEqual(decide(path(wifi: false, satisfied: false), wifiOnly: false), .offline)
    }

    // MARK: Explanations

    func testEveryRefusalCanExplainItselfAndAllowedCannot() {
        XCTAssertNil(DownloadPolicy.Verdict.allowed.explanation)
        for v: DownloadPolicy.Verdict in [.needsWiFi, .lowDataMode, .offline] {
            XCTAssertFalse(v.explanation?.isEmpty ?? true,
                           "\(v) is shown to the pilot and must say something")
        }
    }

    // MARK: Defaults

    /// ⚠️ BOTH SETTINGS DEFAULT ON, AND `UserDefaults.bool` CANNOT EXPRESS THAT.
    ///
    /// `bool(forKey:)` returns false for a key that was never written, so reading a default-ON setting
    /// through it ships the feature OFF for every existing install and every fresh one — the same
    /// polarity trap `Features.transcription` exists to document. This test pins the distinction
    /// between "unset" and "set to false", which is the only thing standing between a default and a
    /// silently disabled feature.
    @MainActor
    func testUnsetMeansOnAndAnExplicitFalseMeansOff() {
        let keys = ["atc.download.wifiOnly", "atc.download.precacheNextCycle"]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer {
            for (k, v) in zip(keys, saved) {
                if let v { UserDefaults.standard.set(v, forKey: k) }
                else { UserDefaults.standard.removeObject(forKey: k) }
            }
        }

        for k in keys { UserDefaults.standard.removeObject(forKey: k) }
        let fresh = DownloadPolicy()
        XCTAssertTrue(fresh.wifiOnly, "a fresh install must not download over cellular uninvited")
        XCTAssertTrue(fresh.precacheNextCycle, "a fresh install must keep its kit current by itself")

        for k in keys { UserDefaults.standard.set(false, forKey: k) }
        let opted = DownloadPolicy()
        XCTAssertFalse(opted.wifiOnly, "an explicit false is the pilot's choice and must stick")
        XCTAssertFalse(opted.precacheNextCycle)
    }

    // MARK: Entitlement
    //
    // The tier check joined this function rather than being scattered across the download paths,
    // for the reason this type's class note gives: one arbiter, one answer, one explanation the UI
    // already knows how to render.

    /// Entitlement is checked BEFORE the network. There is no point telling a pilot to wait for
    /// Wi-Fi for a pack their tier does not include.
    func testUnentitledIsRefusedEvenOnPerfectWiFi() {
        XCTAssertEqual(decide(path(wifi: true), wifiOnly: true,
                              requires: .ifrHighCharts, gate: pro),
                       .notEntitled(.ifrHighCharts))
    }

    /// And it outranks an offline path, so the message names the real reason.
    func testUnentitledOutranksOffline() {
        XCTAssertEqual(decide(path(wifi: false, satisfied: false), wifiOnly: true,
                              requires: .ifrHighCharts, gate: pro),
                       .notEntitled(.ifrHighCharts),
                       "an unentitled pack must not be reported as a network problem — the pilot "
                       + "would wait for a connection that will never help.")
    }

    /// An entitled capability falls through to the ordinary network rules unchanged.
    func testEntitledFallsThroughToTheNetworkRules() {
        XCTAssertEqual(decide(path(wifi: true), wifiOnly: true, requires: .ifrLowCharts, gate: pro),
                       .allowed)
        XCTAssertEqual(decide(path(wifi: false, expensive: true), wifiOnly: true,
                              requires: .ifrLowCharts, gate: pro),
                       .needsWiFi,
                       "entitlement must not bypass the Wi-Fi-only promise")
        XCTAssertEqual(decide(path(wifi: false, satisfied: false), wifiOnly: false,
                              requires: .ifrLowCharts, gate: pro),
                       .offline)
    }

    /// An always-free capability is allowed at the free gate — nav data in particular, which must
    /// never be gated (see `EntitlementsPolicyTests.testAlwaysFreeCapabilitiesAreNeverGated`).
    func testAlwaysFreeContentIsAllowedAtTheFreeGate() {
        XCTAssertEqual(decide(path(wifi: true), wifiOnly: true,
                              requires: .navDataCurrency, gate: .free),
                       .allowed,
                       "nav-data currency must download for a free or lapsed user. Gating it means "
                       + "they eventually open the app to a red EXPIRED banner over procedures we "
                       + "shipped them.")
    }

    /// The defaults preserve every pre-existing call site: no capability named means no tier check,
    /// and the behaviour is exactly what the tests above this section assert.
    func testOmittingTheCapabilitySkipsTheEntitlementCheck() {
        XCTAssertEqual(DownloadPolicy.decide(path: path(wifi: true), wifiOnly: true,
                                             intent: .background),
                       .allowed)
    }

    /// A caller that names a capability but forgets the gate gets a refusal, not a free pass.
    /// Refusing a NEW download fails closed safely; it is revoking content already on disk that
    /// this design will not do.
    func testDefaultGateIsTheSafePolarity() {
        XCTAssertEqual(DownloadPolicy.decide(path: path(wifi: true), wifiOnly: false,
                                             intent: .userInitiated, requires: .ifrLowCharts),
                       .notEntitled(.ifrLowCharts),
                       "the default gate must be `.free`, so a forgotten argument cannot give paid "
                       + "content away.")
    }

    /// The refusal names the tier that would unlock it, because "Not available" tells a pilot
    /// nothing and a dead button tells them less.
    func testNotEntitledExplanationNamesTheTier() {
        XCTAssertEqual(DownloadPolicy.Verdict.notEntitled(.ifrHighCharts).explanation,
                       "Included in Pro + Performance.")
        XCTAssertEqual(DownloadPolicy.Verdict.notEntitled(.vfrCharts).explanation,
                       "Included in Flight Bag.")
        XCTAssertEqual(DownloadPolicy.Verdict.notEntitled(.ifrHighCharts).upgradeFor, .ifrHighCharts)
        XCTAssertNil(DownloadPolicy.Verdict.allowed.upgradeFor)
    }

    /// `isAllowed` must stay false for the new case — it is read by callers as the single
    /// go/no-go, and an associated-value case is easy to forget in an equality check.
    func testNotEntitledIsNotAllowed() {
        XCTAssertFalse(DownloadPolicy.Verdict.notEntitled(.ifrLowCharts).isAllowed)
    }
}
