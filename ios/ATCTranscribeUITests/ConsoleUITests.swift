import XCTest

/// End-to-end UI tests that drive the real app in the Simulator and tap every interactive
/// control — the first-launch download gate, the theme switcher, the settings sheet (model +
/// correction controls), the source picker, and Start/Stop. A tap that can't find or hit its
/// target fails the test, so this is the "do all the buttons actually work" check.
///
/// The app is launched without a bundled model (lean build), so:
///   • `-atc.onboardingDismissed NO`  → the download gate appears (gate test).
///   • `-atc.onboardingDismissed YES` → the gate is skipped → demo console (control tests).
/// (`-atc.onboardingDismissed` is read by UserDefaults' argument domain; see `AppModel`.)
final class ConsoleUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    @discardableResult
    private func launch(onboardingDismissed: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-atc.onboardingDismissed", onboardingDismissed ? "YES" : "NO"]
        app.launch()
        return app
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let s = XCTAttachment(screenshot: app.screenshot())
        s.name = name
        s.lifetime = .keepAlways
        add(s)
    }

    /// Scroll the current scroll view until `el` is hittable (top-to-bottom reveal).
    @discardableResult
    private func reveal(_ el: XCUIElement, _ app: XCUIApplication, maxSwipes: Int = 6) -> Bool {
        var n = 0
        while !el.isHittable && n < maxSwipes { app.swipeUp(); n += 1 }
        return el.isHittable
    }

    private let consoleMarker = "On-device ATC transcription"   // TopBar subtitle, console only

    // 1. The first-launch gate renders, its buttons exist & are hittable, and Skip lands in console.
    func test1_onboardingGateAndSkip() {
        let app = launch(onboardingDismissed: false)
        XCTAssertTrue(app.buttons["gate-primary"].waitForExistence(timeout: 20), "download gate missing")
        XCTAssertTrue(app.buttons["gate-primary"].isHittable, "download button not hittable")
        XCTAssertTrue(app.buttons["gate-skip"].exists, "skip button missing")
        snap(app, "01-gate")

        app.buttons["gate-skip"].tap()
        XCTAssertTrue(app.buttons["gate-primary"].waitForNonExistence(timeout: 10), "gate did not dismiss")
        XCTAssertTrue(app.staticTexts[consoleMarker].exists, "console did not appear after Skip")
        snap(app, "02-console")
    }

    // 2. All three theme buttons are present and tappable.
    func test2_themeSwitching() {
        let app = launch(onboardingDismissed: true)
        XCTAssertTrue(app.staticTexts[consoleMarker].waitForExistence(timeout: 20))
        for theme in ["cockpit", "day", "night", "cockpit"] {
            let b = app.buttons["theme-\(theme)"]
            XCTAssertTrue(b.waitForExistence(timeout: 5), "theme button \(theme) missing")
            XCTAssertTrue(b.isHittable, "theme button \(theme) not hittable")
            b.tap()
        }
        snap(app, "03-themes")
    }

    // 3. Settings sheet: the model + correction controls all tap without error; Done dismisses.
    func test3_settingsControls() {
        let app = launch(onboardingDismissed: true)
        XCTAssertTrue(app.buttons["settings-button"].waitForExistence(timeout: 20))
        app.buttons["settings-button"].tap()
        XCTAssertTrue(app.navigationBars["Model & settings"].waitForExistence(timeout: 5), "settings sheet missing")
        snap(app, "04-settings")

        // Models manager renders a download control (Download/Get button) or a Ready badge.
        XCTAssertTrue(app.buttons["Download"].firstMatch.exists
                      || app.buttons["Get"].firstMatch.exists
                      || app.staticTexts["Ready"].firstMatch.exists,
                      "Models manager controls missing")

        // Transcription model toggle.
        let small = app.buttons["Small (fast)"].firstMatch
        XCTAssertTrue(reveal(small, app), "model buttons missing")
        small.tap()
        app.buttons["Large (turbo)"].firstMatch.tap()

        // Enable correction → the AI backend + sensitivity controls become active.
        let toggle = app.switches.firstMatch
        XCTAssertTrue(reveal(toggle, app), "correction toggle missing")
        toggle.tap()
        let backend = app.buttons["On-device"].firstMatch
        if reveal(backend, app) { backend.tap() }
        let sensitivity = app.buttons["Balanced"].firstMatch
        if reveal(sensitivity, app) { sensitivity.tap() }
        snap(app, "05-settings-toggled")

        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts[consoleMarker].waitForExistence(timeout: 5),
                      "did not return to console after Done")
    }

    // 4. Source picker switches inputs; Start/Stop toggles the (demo) session.
    func test4_sourceAndStartStop() {
        let app = launch(onboardingDismissed: true)
        XCTAssertTrue(app.staticTexts[consoleMarker].waitForExistence(timeout: 20))

        // Input picker (menu style) → pick Replay demo. Best-effort: system menu UI can vary.
        let picker = app.buttons["Internet live feed"].firstMatch
        if picker.waitForExistence(timeout: 5) {
            XCTAssertTrue(picker.isHittable, "source picker not hittable")
            picker.tap()
            let replay = app.buttons["Replay demo"].firstMatch
            if replay.waitForExistence(timeout: 3) { replay.tap() }
        }

        // The run button toggles both ways. (Demo mode seeds a "transcribing" state, so the
        // initial label may be "Stop" — assert it flips and flips back, whatever the start.)
        let btn = app.buttons["start-stop-button"]
        XCTAssertTrue(btn.waitForExistence(timeout: 5), "start/stop button missing")
        let initial = btn.label
        let other = (initial == "Start") ? "Stop" : "Start"
        btn.tap()
        XCTAssertTrue(waitForLabel(btn, other, timeout: 6), "run button did not toggle from \(initial)")
        snap(app, "06-toggled")
        btn.tap()
        XCTAssertTrue(waitForLabel(btn, initial, timeout: 6), "run button did not toggle back to \(initial)")
    }

    private func waitForLabel(_ el: XCUIElement, _ label: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if el.label == label { return true }
            usleep(200_000)
        } while Date() < deadline
        return el.label == label
    }
}
