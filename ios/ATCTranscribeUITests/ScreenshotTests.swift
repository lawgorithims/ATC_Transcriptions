import XCTest

/// Generates the README screenshots from the **demo console** — no model, no network, fully
/// deterministic (`AppModel.seedSampleData` populates the transcript with callsign chips +
/// correction edits). Requires a model-less (lean) build so the app takes the demo path; that's
/// what `Tools/screenshots.sh` arranges (it moves `Resources/Models` aside).
///
/// Skipped in the normal UI suite; run it deliberately with `SCREENSHOTS=1` on an iPad simulator:
///
///   SCREENSHOTS=1 xcodebuild test -project ATCTranscribe.xcodeproj -scheme ATCTranscribe \
///     -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' \
///     -only-testing:ATCTranscribeUITests/ScreenshotTests
///
/// Each shot is attached with `.keepAlways`; `Tools/screenshots.sh` exports + renames them into
/// docs/screenshots/.
final class ScreenshotTests: XCTestCase {

    // One flaky shot shouldn't drop the rest of the set.
    override func setUp() { continueAfterFailure = true }

    private var enabled: Bool { ProcessInfo.processInfo.environment["SCREENSHOTS"] == "1" }
    private let consoleMarker = "On-device ATC transcription"   // TopBar subtitle — console is up

    private func snap(_ app: XCUIApplication, _ name: String) {
        let s = XCTAttachment(screenshot: app.screenshot())
        s.name = name                  // becomes the exported file's suggested name
        s.lifetime = .keepAlways
        add(s)
    }

    @discardableResult
    private func reveal(_ el: XCUIElement, _ app: XCUIApplication, maxSwipes: Int = 6) -> Bool {
        var n = 0
        while !el.isHittable && n < maxSwipes { app.swipeUp(); n += 1 }
        return el.isHittable
    }

    func testCaptureReadmeScreenshots() throws {
        try XCTSkipUnless(enabled, "Set SCREENSHOTS=1 to regenerate the README screenshots.")

        let app = XCUIApplication()
        // Demo console (lean build → no model → seeded sample data); start from the default sidebar so
        // the layout is the documented one regardless of any persisted Simulator state.
        app.launchArguments += ["-atc.onboardingDismissed", "YES", "--reset-widgets"]
        app.launch()
        XCTAssertTrue(app.staticTexts[consoleMarker].waitForExistence(timeout: 30), "console did not load")

        // 1. The console — cockpit theme: brand + status carousel, the live transcript with tappable
        //    callsign chips and inline correction edits, and the customizable sidebar.
        snap(app, "console")

        // 2 + 3. Day and night themes.
        if app.buttons["theme-day"].waitForExistence(timeout: 5) { app.buttons["theme-day"].tap() }
        snap(app, "day")
        if app.buttons["theme-night"].exists { app.buttons["theme-night"].tap() }
        snap(app, "night")
        if app.buttons["theme-cockpit"].exists { app.buttons["theme-cockpit"].tap() }

        // 4. Callsign linking + conversation filter — tap a callsign chip to filter the transcript to
        //    that one aircraft's exchanges (banner + count).
        let chip = app.buttons.matching(identifier: "callsign-chip").firstMatch
        if reveal(chip, app) {
            chip.tap()
            _ = app.buttons["callsign-filter-clear"].waitForExistence(timeout: 3)
            snap(app, "callsign_filter")
            if app.buttons["callsign-filter-clear"].exists { app.buttons["callsign-filter-clear"].tap() }
        }

        // 5. Electronic Flight Bag — the ForeFlight-style editor (paste-a-route + manual fields).
        if app.buttons["flight-bag-button"].waitForExistence(timeout: 5) {
            app.buttons["flight-bag-button"].tap()
            if app.navigationBars["Flight bag"].waitForExistence(timeout: 5) {
                snap(app, "flight_bag")
                if app.buttons["Done"].exists { app.buttons["Done"].tap() }
            }
        }

        // 6. Settings — models manager + the two-tier correction controls.
        if app.buttons["settings-button"].waitForExistence(timeout: 5) {
            app.buttons["settings-button"].tap()
            if app.navigationBars["Model & settings"].waitForExistence(timeout: 5) {
                snap(app, "settings")
                if app.buttons["Done"].exists { app.buttons["Done"].tap() }
            }
        }

        // 7. Standby — the one-tap low-power state (capture paused, transcript dimmed).
        if app.buttons["standby-button"].waitForExistence(timeout: 5) {
            app.buttons["standby-button"].tap()
            if app.buttons["standby-resume"].waitForExistence(timeout: 5) {
                snap(app, "standby")
                app.buttons["standby-resume"].tap()
            }
        }
    }
}
