import XCTest

/// Drives the map's manual camera controls (the semi-transparent + / − / center-on-aircraft bar) and the
/// redesigned two-column layers panel in the Simulator. The zoom/center buttons double as stable tap
/// targets so future map UI tests can frame the chart deterministically (pan/zoom before asserting).
final class MapControlsUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    private func launchMap() -> XCUIApplication {
        let app = XCUIApplication()
        // Land on the Map tab, framed over Boston with no filed route (free-pan), gate skipped.
        app.launchArguments += ["-atc.onboardingDismissed", "YES", "--start-tab", "map", "--chart-center", "42.36,-71.0"]
        app.launch()
        return app
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let s = XCTAttachment(screenshot: app.screenshot()); s.name = name; s.lifetime = .keepAlways; add(s)
    }

    // 1. The zoom-in / zoom-out / center-on-aircraft controls exist, are hittable, and drive the camera
    //    without wedging the app.
    func testZoomAndCenterControls() {
        let app = launchMap()
        let zin = app.buttons["map-zoom-in"]
        XCTAssertTrue(zin.waitForExistence(timeout: 25), "zoom-in control missing on the map")
        XCTAssertTrue(zin.isHittable, "zoom-in control not hittable")
        let zout = app.buttons["map-zoom-out"]
        let center = app.buttons["map-center-ownship"]
        XCTAssertTrue(zout.exists, "zoom-out control missing")
        XCTAssertTrue(center.exists, "center-on-aircraft control missing")
        snap(app, "01-zoom-controls")
        // Drive the camera in both directions + recenter — each tap animates the map region.
        zin.tap(); zin.tap(); zout.tap(); center.tap()
        // The app stays healthy (the always-present Settings icon survives).
        XCTAssertTrue(app.buttons["settings-button"].waitForExistence(timeout: 6), "app unhealthy after driving the camera")
        snap(app, "02-after-zoom")
    }

    // 2. The layers menu is a two-column panel: Column A = base maps (selectable rows), Column B = overlay +
    //    control toggles (incl. the zoom-controls switch). Verify both columns render and the toggle flips.
    func testLayersMenuTwoColumnPanel() {
        let app = launchMap()
        XCTAssertTrue(app.buttons["map-zoom-in"].waitForExistence(timeout: 25), "map did not come up")
        let menu = app.buttons["map-layers-menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 6), "layers menu button missing")
        menu.tap()

        // Column A — base map rows.
        XCTAssertTrue(app.buttons["base-sectional"].waitForExistence(timeout: 6), "base-map column (A) missing")
        XCTAssertTrue(app.buttons["base-ifrLow"].exists, "IFR-low base row missing")
        XCTAssertTrue(app.buttons["base-satellite"].exists, "Satellite base row missing")
        // Column B — overlay + control toggles.
        XCTAssertTrue(app.switches["layer-nearby"].exists, "overlay toggles (column B) missing")
        XCTAssertTrue(app.switches["layer-radar"].exists, "radar overlay toggle missing")
        let zoomToggle = app.switches["layer-zoom-controls"]
        XCTAssertTrue(zoomToggle.exists, "zoom-controls toggle missing from the panel")
        snap(app, "03-layers-panel")

        // The zoom-controls toggle flips (UI-test state persists across runs, so assert a change, not a value).
        let before = zoomToggle.value as? String
        zoomToggle.tap()
        XCTAssertNotEqual(zoomToggle.value as? String, before, "zoom-controls toggle did not change state")
        zoomToggle.tap()   // restore for test hygiene
        XCTAssertEqual(zoomToggle.value as? String, before, "zoom-controls toggle did not restore")
    }
}
