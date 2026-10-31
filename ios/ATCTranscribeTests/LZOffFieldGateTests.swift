import XCTest
@testable import ATCTranscribe

/// The off-field landability shading is DEVELOPER-ONLY from build 110; the glide bands are not.
///
/// The first ground-truth test the packs ever had sampled the device's own verdict at independently
/// mapped ground and found it offering 79% of solar farms and 53% of Fresno's orchards and vineyards
/// as landing candidates. These tests pin the gate in every place it has to hold: whether the
/// heatmap draws, what the emergency button arms, whether that button then reads ARMED, and that
/// locking diagnostics takes the ranked list down with the shading.
@MainActor
final class LZOffFieldGateTests: XCTestCase {

    /// AppModel persists to UserDefaults.standard; put back whatever these tests touched.
    private func model(diagnostics: Bool) -> AppModel {
        let keys = ["atc.diagnosticsEnabled", "atc.map.lz", "atc.map.lzEnergy"]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        addTeardownBlock {
            for (k, v) in zip(keys, saved) { UserDefaults.standard.set(v, forKey: k) }
        }
        let m = AppModel()
        m.diagnosticsEnabled = diagnostics
        return m
    }

    /// THE GATE. A tester who had the shading on in 109 keeps the persisted flag — it must not draw.
    func testAPersistedFlagDoesNotDrawWithoutDiagnostics() {
        let m = model(diagnostics: false)
        m.showLZRisk = true
        XCTAssertFalse(m.lzRiskVisible, "the shading draws for a pilot without developer diagnostics")
        XCTAssertFalse(m.offFieldLayerAvailable)
    }

    func testDiagnosticsStillShowTheShading() {
        let m = model(diagnostics: true)
        m.showLZRisk = true
        XCTAssertTrue(m.lzRiskVisible, "the developer preview no longer draws")
    }

    /// Arming must light the glide bands and NRST for every pilot, leave the shading off where it is
    /// not available — and still read ARMED, or the button would sit unlit over a live emergency.
    func testArmingWithoutDiagnosticsLightsReachButNotTheShading() {
        let m = model(diagnostics: false)
        m.showLZRisk = false
        m.armEmergency(compact: true)
        XCTAssertTrue(m.showLZEnergy, "arming left the glide bands off")
        XCTAssertFalse(m.showLZRisk, "arming switched on a layer this pilot cannot have")
        XCTAssertTrue(m.showNRSTSheet, "arming did not raise the nearest airports")
        XCTAssertTrue(m.emergencyArmed(compact: true, widgets: m.widgetStore),
                      "the button would not read ARMED without the landability layer")
    }

    func testArmingWithDiagnosticsLightsBoth() {
        let m = model(diagnostics: true)
        m.armEmergency(compact: true)
        XCTAssertTrue(m.showLZRisk && m.showLZEnergy)
        XCTAssertTrue(m.emergencyArmed(compact: true, widgets: m.widgetStore))
    }

    /// The ranked list's floating panel persists its visibility, so locking diagnostics must put it
    /// away — otherwise it comes back on the next launch naming ground the map no longer draws.
    func testLockingDiagnosticsPutsTheRankedListAway() {
        let m = model(diagnostics: true)
        m.showLZRisk = true
        m.widgetStore.reveal(.landable)
        XCTAssertTrue(m.widgetStore.isVisible(.landable))
        m.diagnosticsEnabled = false
        XCTAssertFalse(m.widgetStore.isVisible(.landable),
                       "the ranked list outlived the developer unlock that allowed it")
    }
}
