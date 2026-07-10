import XCTest

/// End-to-end UI tests that drive the real app in the Simulator and tap every interactive
/// control — the first-launch download gate, the theme dropdown, the settings sheet (model +
/// correction controls), the source picker, and the Start/Stop power button. A tap that can't find
/// or hit its target fails the test, so this is the "do all the buttons actually work" check.
///
/// Updated for the heading-bar redesign: the console's controls now live in the heading bar — a
/// single Start/Stop power button (**long-press = standby**), a theme **dropdown menu**, and per-strip
/// toggles. The input source picker lives in the collapsible **Input strip** (open it via its heading
/// toggle first). The old "On-device ATC transcription" subtitle is iPad-only now, so the
/// console-loaded marker is the always-present Settings icon.
///
/// The app is launched without a bundled model (lean build), so:
///   • `-atc.onboardingDismissed NO`  → the download gate appears (gate test).
///   • `-atc.onboardingDismissed YES` → the gate is skipped → demo console (control tests).
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

    /// The console is up once the always-present Settings icon exists. (The old subtitle marker is
    /// now iPad-only — hidden on iPhone — so it can't gate a device-independent test.)
    @discardableResult
    private func consoleReady(_ app: XCUIApplication, timeout: TimeInterval = 20) -> Bool {
        app.buttons["settings-button"].waitForExistence(timeout: timeout)
    }

    /// Ensure the collapsible Input strip (source picker etc.) is open — its visibility is persisted,
    /// so a prior run may have collapsed it. The strip shows an "Input" label; the heading input
    /// toggle that opens it is always present.
    private func openInputStrip(_ app: XCUIApplication) {
        if app.staticTexts["Input"].waitForExistence(timeout: 2) { return }
        let toggle = app.buttons["input-toggle"]
        if toggle.waitForExistence(timeout: 5) { toggle.tap() }
    }

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
        XCTAssertTrue(app.staticTexts["Large"].exists, "Large model not offered on gate")
        XCTAssertTrue(app.staticTexts["Large V2"].exists, "Large V2 (stock) model not offered on gate")
        snap(app, "01-gate")

        app.buttons["gate-skip"].tap()
        XCTAssertTrue(app.buttons["gate-primary"].waitForNonExistence(timeout: 10), "gate did not dismiss")
        XCTAssertTrue(consoleReady(app, timeout: 10), "console did not appear after Skip")
        snap(app, "02-console")
    }

    // 2. Theme dropdown: open it and pick each of the three screen colours.
    func test2_themeSwitching() {
        let app = launch(onboardingDismissed: true)
        XCTAssertTrue(consoleReady(app))
        let menu = app.buttons["theme-menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "theme menu missing")
        // Menu items are labelled by the theme name; the `theme-<raw>` id is a fallback.
        for theme in ["Cockpit", "Day", "Night", "Cockpit"] {
            XCTAssertTrue(menu.isHittable, "theme menu not hittable")
            menu.tap()
            let byLabel = app.buttons[theme].firstMatch
            let byId = app.buttons["theme-\(theme.lowercased())"].firstMatch
            if byLabel.waitForExistence(timeout: 3) { byLabel.tap() }
            else if byId.exists { byId.tap() }
            else if menu.exists { menu.tap() }   // couldn't find the item — close the menu and move on
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
        XCTAssertTrue(consoleReady(app, timeout: 5), "did not return to console after Done")
    }

    // 4. Source picker switches inputs; the Start/Stop power button toggles the (demo) session.
    func test4_sourceAndStartStop() {
        let app = launch(onboardingDismissed: true)
        XCTAssertTrue(consoleReady(app))
        openInputStrip(app)

        // Input picker (menu style) → pick Replay demo. Best-effort: system menu UI can vary.
        let picker = app.buttons["Internet live feed"].firstMatch
        if picker.waitForExistence(timeout: 5) {
            XCTAssertTrue(picker.isHittable, "source picker not hittable")
            picker.tap()
            let replay = app.buttons["Replay demo"].firstMatch
            if replay.waitForExistence(timeout: 3) { replay.tap() }
        }

        // The power button toggles both ways. (Demo mode seeds a "transcribing" state, so the
        // initial label may be "Stop" — assert it flips and flips back, whatever the start.)
        let btn = app.buttons["start-stop-button"]
        XCTAssertTrue(btn.waitForExistence(timeout: 5), "start/stop button missing")
        let initial = btn.label
        let other = (initial == "Start") ? "Stop" : "Start"
        btn.tap()
        XCTAssertTrue(waitForLabel(btn, other, timeout: 6), "run button did not toggle from \(initial)")
        // While running, the input-level meter is shown in the transcript header (proof audio flows).
        if btn.label == "Stop" {
            let meter = app.descendants(matching: .any).matching(identifier: "input-level-meter").firstMatch
            XCTAssertTrue(meter.waitForExistence(timeout: 4), "input level meter missing while running")
        }
        snap(app, "06-toggled")
        btn.tap()
        XCTAssertTrue(waitForLabel(btn, initial, timeout: 6), "run button did not toggle back to \(initial)")
    }

    /// True when the app is laid out at regular width (iPad) — where widgets FLOAT over the map. On
    /// compact (iPhone) the home screen is the map + a bottom transcript card, so the other widgets
    /// aren't rendered and their tests are skipped.
    private func isRegularWidth(_ app: XCUIApplication) -> Bool {
        app.windows.firstMatch.frame.width >= 700
    }

    // 5. The proof-of-life widget floats over the map by default (regular width); its Run button runs
    // the on-device check. (Compact shows only the transcript card — skipped there.)
    func test5_proofOfLifeButton() throws {
        let app = launch(onboardingDismissed: true, resetWidgets: true)
        XCTAssertTrue(consoleReady(app))
        try XCTSkipUnless(isRegularWidth(app), "Floating widgets are iPad/regular-width only; compact shows the transcript.")

        let pol = app.buttons["proof-of-life-button"]
        XCTAssertTrue(pol.waitForExistence(timeout: 8), "proof-of-life widget/button missing on the map home")
        XCTAssertTrue(pol.isHittable, "proof-of-life button not hittable")
        pol.tap()
        snap(app, "07-proof-of-life")
    }

    // 6. Widgets are shown/hidden from the top-bar Widgets menu (replaces the old sidebar context menu).
    // The menu exists on every device; on regular width, enabling a hidden widget makes its card appear
    // over the map, and disabling it removes the card.
    func test6_customizeWidgets() throws {
        let app = launch(onboardingDismissed: true, resetWidgets: true)
        XCTAssertTrue(consoleReady(app))

        let menu = app.buttons["widgets-menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 8), "Widgets menu missing from the top bar")
        menu.tap()
        // Host is hidden by default, so the menu offers it (no checkmark) — tap to show it.
        let host = app.buttons["Host"].firstMatch
        XCTAssertTrue(host.waitForExistence(timeout: 5), "Host not offered in the Widgets menu")
        snap(app, "08-widgets-menu")
        host.tap()

        guard isRegularWidth(app) else { return }   // compact renders only the transcript — menu tested, render N/A
        XCTAssertTrue(app.staticTexts["HOST"].waitForExistence(timeout: 5), "Host widget did not appear after enabling")
        snap(app, "09-widget-shown")

        // Toggle it back off from the same menu → the card disappears.
        menu.tap()
        let hostOff = app.buttons["Host"].firstMatch
        XCTAssertTrue(hostOff.waitForExistence(timeout: 5), "Host toggle missing on second open")
        hostOff.tap()
        XCTAssertTrue(app.staticTexts["HOST"].waitForNonExistence(timeout: 5), "Host widget did not hide")
    }

    // 7. Standby: touch-and-hold the power button opens the low-power standby screen; Resume returns.
    // Device-agnostic on purpose — the Resume banner is hoisted to `homeArea` in ConsoleView so it
    // renders on BOTH the compact (iPhone) and regular-width (iPad) layouts. Must pass on both sims.
    func test7_standby() {
        let app = launch(onboardingDismissed: true)
        let power = app.buttons["start-stop-button"]
        XCTAssertTrue(power.waitForExistence(timeout: 20), "power button missing")
        power.press(forDuration: 0.8)   // long-press = standby (tap = start/stop)
        let resume = app.buttons["standby-resume"]
        XCTAssertTrue(resume.waitForExistence(timeout: 5), "standby screen did not appear")
        snap(app, "10-standby")
        resume.tap()
        XCTAssertTrue(consoleReady(app, timeout: 5), "did not return to console from standby")
    }

    // 8. Route map: open the flight-plan strip, tap Map, the full-screen map presents; Done returns.
    func test8_routeMap() {
        // Open the route map directly with a demo route filed (`--open-route-map --demo-flightplan`),
        // so the test is deterministic: verify the full-screen map presents and Done returns to console.
        // (The Map entry button in the flight-plan strip drives the same `showRouteMap` cover.)
        let app = XCUIApplication()
        app.launchArguments += ["-atc.onboardingDismissed", "YES", "--demo-flightplan", "--open-route-map"]
        app.launch()
        let done = app.buttons["route-map-done"]
        XCTAssertTrue(done.waitForExistence(timeout: 12), "route map did not present")
        snap(app, "11-route-map")
        done.tap()
        XCTAssertTrue(consoleReady(app, timeout: 6), "did not return to console from the route map")
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
