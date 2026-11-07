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

    /// ⚠️ ONE NRST CONTROL, AND IT IS IN THE TOP BAR. There used to be two: this one and a
    /// floating button on the map that armed exactly the same thing. The pilot reported them as
    /// duplicates, and the map copy is gone.
    func testTheNrstButtonIsInTheTopBarAndOpensThePanel() {
        let app = launchOnMap()
        let nrst = app.buttons["emergency-button"]
        XCTAssertTrue(nrst.waitForExistence(timeout: 15), "the NRST button must be in the top bar")
        XCTAssertTrue(nrst.isHittable, "and reachable, not buried under other chrome")
        XCTAssertFalse(app.buttons["map-nrst"].exists,
                       "the map's duplicate NRST button must be gone, not merely moved")
        nrst.tap()
        XCTAssertTrue(app.otherElements["nrst-panel"].waitForExistence(timeout: 5)
                      || app.staticTexts["Nearest airports"].waitForExistence(timeout: 5),
                      "tapping NRST must bring up the glide panel")
    }

    /// ⚠️ THIS TEST USED TO ASSERT THE BUG. It pinned the map's NRST button surviving the
    /// map-controls toggle — correct in intent (an emergency aid must not be hidden by a display
    /// preference) and wrong in effect: the pilot switched the map controls off, the zoom stack went,
    /// and a lone NRST button stayed floating over the chart. Moving it to the top bar satisfies both
    /// at once. The toggle now genuinely clears the map, AND the control is always on screen —
    /// on every tab, not just this one.
    func testTurningTheMapControlsOffLeavesNoButtonOnTheMap() {
        let app = XCUIApplication()
        app.launchArguments += ["-atc.onboardingDismissed", "YES", "--reset-widgets",
                               "-atc.map.zoomControls", "NO"]
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow While Using App"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }

        XCTAssertTrue(app.buttons["emergency-button"].waitForExistence(timeout: 15),
                      "NRST lives in the top bar now, so the map setting cannot reach it")
        XCTAssertFalse(app.buttons["map-zoom-in"].exists, "the zoom stack should be off in this run")
        XCTAssertFalse(app.buttons["map-nrst"].exists,
                       "and nothing of the old floating button may be left behind on the chart")
    }
}
