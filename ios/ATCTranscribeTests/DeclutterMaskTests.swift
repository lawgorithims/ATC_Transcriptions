import XCTest
@testable import ATCTranscribe

/// The declutter mask.
///
/// The whole design rests on one property: it writes NOTHING to the pilot's nine layer toggles. A
/// preset that wrote nine `false`s would leave nothing to restore after a mid-flight relaunch, and a
/// "restore defaults" reset would be wrong outright here — the defaults are not the pilot's set
/// (airspace/nearby/airways/TFRs default ON, radar/wind/smoke/hazards/traffic default OFF), so a pilot
/// flying with wind up and airways down would have "reset" silently invert both.
@MainActor
final class DeclutterMaskTests: XCTestCase {

    /// The nine persisted layer keys the mask must never touch.
    private static let layerKeys = [
        "atc.map.airspace", "atc.map.nearby", "atc.map.airways", "atc.map.tfrs",
        "atc.adsbStreaming", "atc.map.hazards", "atc.map.smoke", "atc.map.wxRadar", "atc.map.wind",
    ]

    private func snapshot() -> [String: Bool?] {
        var out: [String: Bool?] = [:]
        for k in Self.layerKeys { out[k] = UserDefaults.standard.object(forKey: k) as? Bool }
        return out
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "atc.map.declutter")
        super.tearDown()
    }

    func testDeclutterIsOffByDefault() {
        UserDefaults.standard.removeObject(forKey: "atc.map.declutter")
        let m = AppModel()
        XCTAssertFalse(m.declutter, "a chart that hides things on first launch is a surprise, not a feature")
    }

    func testDeclutterWritesNoneOfTheNineLayerToggles() {
        let m = AppModel()
        let before = snapshot()
        m.declutter = true
        XCTAssertEqual(snapshot().mapValues { $0 ?? nil }, before.mapValues { $0 ?? nil },
                       "declutter must be a mask — it wrote a layer preference")
        m.declutter = false
        XCTAssertEqual(snapshot().mapValues { $0 ?? nil }, before.mapValues { $0 ?? nil })
    }

    func testResetIsNonDestructiveEvenAfterAHandEdit() {
        // The scenario the mask exists for: declutter, change one layer by hand, un-declutter. The pilot
        // must get their set back PLUS their edit — not a stale snapshot that discards it.
        let m = AppModel()
        let airwaysBefore = m.showAirways
        m.declutter = true
        m.showNearby = !m.showNearby
        let nearbyAfterEdit = m.showNearby
        m.declutter = false
        XCTAssertEqual(m.showNearby, nearbyAfterEdit, "the hand edit was rolled back by the reset")
        XCTAssertEqual(m.showAirways, airwaysBefore, "an untouched toggle changed across a declutter cycle")
    }

    func testDeclutterPersistsAcrossModelRebuild() {
        let m = AppModel()
        m.declutter = true
        XCTAssertTrue(AppModel().declutter, "the pilot's own choice should survive a relaunch")
    }

    func testTheDarkBaseIsNotRasterSoTheMaskDoesTheWholeJobThere() {
        // The honest scope note the menu shows: on an FAA raster the fixes and airways are printed INTO
        // the chart image, so masking the app's vector copy leaves the printed original. This pins which
        // bases that caveat applies to, so the copy cannot drift from the data.
        XCTAssertFalse(ChartLayer.smartDark.isRaster)
        XCTAssertFalse(ChartLayer.satellite.isRaster)
        for l in [ChartLayer.sectional, .ifrLow, .ifrHigh] {
            XCTAssertTrue(l.isRaster, "\(l) is an FAA raster chart — the caveat must name it")
        }
    }
}
