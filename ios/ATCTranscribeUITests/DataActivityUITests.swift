import XCTest

/// The one-tap route to the data queue, and the state the bar icon has to remember.
///
/// This screen exists for the moment the app APPEARS frozen on a weak link. Everything about it is
/// worthless if it cannot be reached from the surface the pilot is already looking at, so the thing
/// under test is the route, not the rendering.
final class DataActivityUITests: XCTestCase {

    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-atc.onboardingDismissed", "YES", "--reset-widgets"] + extra
        app.launch()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            .buttons["Allow While Using App"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        return app
    }

    private func el(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// One tap from the map. Not three through Settings.
    func testDataActivityIsOneTapFromTheMap() throws {
        let app = launch()
        let button = el(app, "data-activity-button")
        XCTAssertTrue(button.waitForExistence(timeout: 40),
                      "the data-activity control is not in the top bar — the whole point of this "
                      + "screen is being reachable when the app looks frozen")
        button.tap()
        XCTAssertTrue(el(app, "netq-toggle-radar").waitForExistence(timeout: 10),
                      "tapping the top-bar control did not open the Data activity panel")
    }

    /// ⚠️ THE STATE THAT MATTERS MOST. A category switched off an hour ago, with nothing queued
    /// behind it, leaves the queue empty — so an icon driven by "is anything happening" reads IDLE
    /// in exactly the case where the pilot needs reminding that they told the app to stop fetching
    /// weather. The bar has to remember the thing they did to themselves.
    func testTheBarIconRemembersAPausedCategoryWithAnEmptyQueue() throws {
        let app = launch()
        let button = el(app, "data-activity-button")
        XCTAssertTrue(button.waitForExistence(timeout: 40))
        // Deliberately NOT asserting "idle" here. A launch genuinely has work in flight — the first
        // run of this test found the icon reading "6 in progress", which is the feature working, not
        // a bug. Pinning a precondition on an idle launch would make this test fail on a fast
        // network and pass on a slow one. What is under test is that `paused` OUTRANKS whatever
        // else is happening, which holds either way.
        let before = button.value as? String ?? ""
        XCTAssertFalse(before.contains("paused"), "nothing is paused yet, but the icon says \(before)")

        button.tap()
        let radar = el(app, "netq-toggle-radar")
        XCTAssertTrue(radar.waitForExistence(timeout: 10))
        // Verified, not fire-and-forget. This switch has dropped taps under XCUITest (see
        // `UITestToggle`), and an unverified tap failed below as an icon reading "idle", which is
        // indistinguishable from the bug this test exists to catch.
        UITestToggle.flip(radar)

        // Dismiss the popover by tapping the map behind it — the gesture this presentation exists
        // to give a pilot who is one-handed in turbulence.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.88)).tap()

        let after = el(app, "data-activity-button")
        XCTAssertTrue(after.waitForExistence(timeout: 10))
        let spoken = after.value as? String ?? ""
        XCTAssertTrue(spoken.contains("paused"),
                      "the bar icon says \"\(spoken)\" after the pilot paused Radar. With an empty "
                      + "queue nothing else on screen remembers that choice.")
        // EXACTLY Radar. `flip` retries a dropped tap, and a tap that slipped onto the next row would
        // pause Weather as well: still "paused", still naming Radar, and wrong.
        XCTAssertEqual(spoken, "paused: Radar", "the icon should name what is paused, and only that")
    }

    /// The control is EFB, not transcription, so it must survive the beta gate — this is the file
    /// that would catch it being gated off by accident.
    func testTheControlIsPresentInTheEFBOnlyBuild() throws {
        let app = launch()
        XCTAssertTrue(el(app, "data-activity-button").waitForExistence(timeout: 40))
        // Paired with a positive check on neighbouring EFB chrome, so this cannot pass because the
        // app failed to launch and everything is "absent".
        XCTAssertTrue(el(app, "settings-button").exists, "top bar did not render")
        XCTAssertTrue(el(app, "map-layers-menu").exists)
    }
}
