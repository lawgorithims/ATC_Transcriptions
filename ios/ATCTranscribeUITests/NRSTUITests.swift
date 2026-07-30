import XCTest

/// The engine-out NRST control on the live map: the button is present and NOT hidden behind the
/// pilot-toggleable map-controls setting (an emergency control must not be removable), and tapping it
/// brings up the ranked glide panel.
///
/// The panel's CONTENT is asserted only as far as the simulator can honestly support it: a simulated
/// location carries no GPS altitude, and a glide has nothing to spend without one, so the panel states
/// its reason instead of ranking. The ranking itself is covered against the real shipped databases and
/// the bundled terrain grid in `NearestAirportsTests` / `NearestAirportsDataTests`.
final class NRSTUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    private func launchOnMap() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-atc.onboardingDismissed", "YES", "--reset-widgets"]
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow While Using App"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        return app
    }

    func testNrstButtonIsPresentAndOpensThePanel() {
        let app = launchOnMap()
        let nrst = app.buttons["map-nrst"]
        XCTAssertTrue(nrst.waitForExistence(timeout: 15), "the NRST button must be on the map")
        XCTAssertTrue(nrst.isHittable, "the NRST button must be reachable, not buried under other chrome")
        nrst.tap()
        XCTAssertTrue(app.otherElements["nrst-panel"].waitForExistence(timeout: 5)
                      || app.staticTexts["Nearest airports"].waitForExistence(timeout: 5),
                      "tapping NRST must bring up the glide panel")
    }

    /// Turning the map-controls setting OFF hides the zoom stack but must NOT hide NRST — the whole
    /// point of giving it its own ungated overlay (the same rule the plate strip documents).
    func testNrstButtonSurvivesTheMapControlsToggle() {
        let app = XCUIApplication()
        app.launchArguments += ["-atc.onboardingDismissed", "YES", "--reset-widgets",
                               "-atc.map.zoomControls", "NO"]
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow While Using App"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }

        let nrst = app.buttons["map-nrst"]
        XCTAssertTrue(nrst.waitForExistence(timeout: 15),
                      "NRST must not share the pilot-toggleable zoom-controls gate")
        XCTAssertFalse(app.buttons["map-zoom-in"].exists, "the zoom stack should be off in this run")
    }
}
