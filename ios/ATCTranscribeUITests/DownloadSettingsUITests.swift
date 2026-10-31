import XCTest

/// The two download settings, driven through the screen a pilot actually reaches them on.
///
/// WHY A UI TEST. `DownloadPolicyTests` proves the rule and the defaults; neither proves the switches
/// are REACHABLE, bound to the right property, or on screen at all. This session has more than once
/// shipped a setting that compiled, unit-tested green, and could not be found — and a default-ON
/// setting that renders OFF is indistinguishable, to the pilot, from one that does not work.
///
/// The Downloads screen had no UI coverage whatsoever before this.
final class DownloadSettingsUITests: XCTestCase {

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

    /// Settings → Charts & downloads, the real path.
    ///
    /// ASSERTS rather than skips when the screen cannot be reached. The first cut of this file
    /// skipped (copied from `NewChromeUITests`) and also forgot `--open-settings` — so all three
    /// tests "passed" as skips, proving nothing about a feature that had just been written. A test
    /// whose subject exists in this build must fail when it cannot find it.
    private func openDownloads(_ extra: [String] = []) -> XCUIApplication {
        let app = launch(["--open-settings"] + extra)
        let link = el(app, "settings-cat-downloads")
        XCTAssertTrue(link.waitForExistence(timeout: 60),
                      "Settings → Charts & downloads could not be reached")
        link.tap()
        return app
    }

    /// Both switches are present and ON out of the box.
    ///
    /// Fresh defaults are only fresh if nothing wrote the keys earlier, so this clears them through
    /// the launch arguments rather than trusting whatever the simulator was left in — the mistake
    /// that would make this test pass on a machine where it should fail.
    func testBothSettingsArePresentAndDefaultOn() throws {
        let app = openDownloads(["--reset-download-settings"])

        let wifi = el(app, "downloads-wifi-only-toggle")
        XCTAssertTrue(wifi.waitForExistence(timeout: 20),
                      "the Wi-Fi-only switch is not on the Downloads screen")
        XCTAssertEqual(wifi.value as? String, "1",
                       "Wi-Fi-only must default ON — the alternative is an EFB spending a pilot's "
                       + "cellular allowance on gigabytes of charts without being asked")

        let precache = el(app, "downloads-precache-toggle")
        XCTAssertTrue(precache.exists, "the pre-load switch is not on the Downloads screen")
        XCTAssertEqual(precache.value as? String, "1", "pre-loading the next cycle must default ON")
    }

    /// And they can be turned off, which is the half of "default on" that is easy to get wrong:
    /// a switch bound to a computed property renders correctly and does nothing.
    func testTheWiFiOnlySettingCanBeTurnedOffAndStaysOff() throws {
        let app = openDownloads(["--reset-download-settings"])
        let wifi = el(app, "downloads-wifi-only-toggle")
        XCTAssertTrue(wifi.waitForExistence(timeout: 20))

        // Taps the SWITCH, not the row's label, and retries a dropped tap — see `UITestToggle`.
        UITestToggle.flip(wifi)
        // Re-read through a fresh query: tapping a SwiftUI Toggle that is not actually bound leaves
        // the rendered value unchanged, and reusing the stale element can hide that.
        let after = el(app, "downloads-wifi-only-toggle")
        XCTAssertEqual(after.value as? String, "0", "the switch did not take the tap")
    }

    /// Turning pre-loading off must not disturb the Wi-Fi-only setting. They are stored under
    /// separate keys and read by one object; a copy-paste in either would couple them.
    func testTheTwoSettingsAreIndependent() throws {
        let app = openDownloads(["--reset-download-settings"])
        let precache = el(app, "downloads-precache-toggle")
        XCTAssertTrue(precache.waitForExistence(timeout: 20))
        // The Wi-Fi-only row sits directly above: the check below is also what catches a retried
        // tap that slipped onto it.
        UITestToggle.flip(precache)

        XCTAssertEqual(el(app, "downloads-precache-toggle").value as? String, "0")
        XCTAssertEqual(el(app, "downloads-wifi-only-toggle").value as? String, "1",
                       "turning off pre-loading must leave Wi-Fi-only alone")
    }
}
