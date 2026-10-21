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
}
