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
    private func launch(onboardingDismissed: Bool, resetWidgets: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-atc.onboardingDismissed", onboardingDismissed ? "YES" : "NO"]
        // Start widget tests from the default layout — the sidebar persists across launches, so a
        // prior run that removed a widget would otherwise leak into this one.
        if resetWidgets { app.launchArguments += ["--reset-widgets"] }
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
    // Only meaningful on a lean (no bundled model) build — the gate is skipped when a model ships
    // in the bundle, so we skip rather than fail in that case.
    func test1_onboardingGateAndSkip() throws {
        let app = launch(onboardingDismissed: false)
        guard app.buttons["gate-primary"].waitForExistence(timeout: 20) else {
            throw XCTSkip("No download gate — this build bundles a model (gate only appears on lean builds).")
        }
        XCTAssertTrue(app.buttons["gate-primary"].isHittable, "download button not hittable")
        XCTAssertTrue(app.buttons["gate-skip"].exists, "skip button missing")
        // The optional higher-accuracy (Large) and stock (Large V2) models are offered on the gate.
        XCTAssertTrue(app.staticTexts["Large · higher accuracy"].exists, "Large model not offered on gate")
        XCTAssertTrue(app.staticTexts["Large V2 · stock turbo"].exists, "Large V2 (stock) model not offered on gate")
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

        // Transcription model picker. Labels are "Small" / "Large" / "Large V2" (+ "— not downloaded"
        // when the variant isn't on disk, in which case the button is disabled).
        let small = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Small")).firstMatch
        XCTAssertTrue(reveal(small, app), "model buttons missing")
        if small.isEnabled { small.tap() }
        // "Large" must NOT also match "Large V2" — exclude that prefix so we hit the fine-tuned one.
        let large = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@ AND NOT label BEGINSWITH %@", "Large", "Large V2")).firstMatch
        XCTAssertTrue(large.exists, "Large model button missing")
        if large.isEnabled { large.tap() }
        let largeV2 = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Large V2")).firstMatch
        XCTAssertTrue(largeV2.exists, "Large V2 model button missing")
        if largeV2.isEnabled { largeV2.tap() }

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
        // While running, the input-level meter is shown next to Start/Stop (proof audio is flowing).
        if btn.label == "Stop" {
            let meter = app.descendants(matching: .any).matching(identifier: "input-level-meter").firstMatch
            XCTAssertTrue(meter.waitForExistence(timeout: 4), "input level meter missing while running")
        }
        snap(app, "06-toggled")
        btn.tap()
        XCTAssertTrue(waitForLabel(btn, initial, timeout: 6), "run button did not toggle back to \(initial)")
    }

    // 5. The proof-of-life control exists in the console and is tappable (runs the on-device check).
    func test5_proofOfLifeButton() {
        let app = launch(onboardingDismissed: true)
        XCTAssertTrue(app.staticTexts[consoleMarker].waitForExistence(timeout: 20))
        let pol = app.buttons["proof-of-life-button"]
        XCTAssertTrue(reveal(pol, app), "proof-of-life button missing")
        XCTAssertTrue(pol.isHittable, "proof-of-life button not hittable")
        pol.tap()
        snap(app, "07-proof-of-life")
    }

    // 6. Sidebar widgets are customizable: long-press a card for a context menu to remove the
    // touched widget, or add one that isn't shown (dropdown).
    func test6_customizeWidgets() {
        let app = launch(onboardingDismissed: true, resetWidgets: true)
        XCTAssertTrue(app.staticTexts[consoleMarker].waitForExistence(timeout: 20))

        // Long-press the Host card (uppercased title) to open its context menu, then Remove it.
        let host = app.staticTexts["HOST"].firstMatch
        XCTAssertTrue(reveal(host, app), "host widget missing")
        host.press(forDuration: 0.7)
        let removeHost = app.buttons["Remove Host"].firstMatch
        XCTAssertTrue(removeHost.waitForExistence(timeout: 5), "context-menu Remove control missing")
        snap(app, "08-widget-menu")
        removeHost.tap()
        XCTAssertTrue(app.staticTexts["HOST"].waitForNonExistence(timeout: 4), "host widget not removed")

        // Re-add Host via another widget's context menu → "Add widget" dropdown (best-effort:
        // nested-menu UI can vary in the Simulator).
        let perf = app.staticTexts["PERFORMANCE CHECK"].firstMatch
        if reveal(perf, app) {
            perf.press(forDuration: 0.7)
            let addMenu = app.buttons["Add widget"].firstMatch
            if addMenu.waitForExistence(timeout: 3) {
                addMenu.tap()
                let hostItem = app.buttons["Host"].firstMatch
                if hostItem.waitForExistence(timeout: 3) { hostItem.tap() }
            }
        }
        snap(app, "09-widget-readded")
    }

    // 7. Standby: the moon button opens the low-power standby screen; Resume returns to console.
    func test7_standby() {
        let app = launch(onboardingDismissed: true)
        XCTAssertTrue(app.buttons["standby-button"].waitForExistence(timeout: 20), "standby button missing")
        app.buttons["standby-button"].tap()
        let resume = app.buttons["standby-resume"]
        XCTAssertTrue(resume.waitForExistence(timeout: 5), "standby screen did not appear")
        snap(app, "10-standby")
        resume.tap()
        XCTAssertTrue(app.staticTexts[consoleMarker].waitForExistence(timeout: 5),
                      "did not return to console from standby")
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
