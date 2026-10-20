import XCTest

/// What a PUBLIC-BETA tester must and must not see.
///
/// The gate's other tests assert the EFB features still work; this file asserts the shape of the
/// build itself. It is the inverse of the skips in `ConsoleUITests` — those say "not testable here",
/// these say "and here is what is true instead".
///
/// Every check pairs an ABSENCE with a PRESENCE on purpose. Asserting only that the power button is
/// gone would pass just as happily if the app crashed on launch or rendered nothing at all, which is
/// the failure mode that matters most for a first public build.
final class EFBOnlyChromeUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    private func launchClean() -> XCUIApplication {
        let app = XCUIApplication()
        // NOTE: deliberately NOT passing -atc.onboardingDismissed. Every other UI-test file passes it
        // as its first argument, which means no existing test has ever exercised what a REAL fresh
        // install does on first launch — and a Whisper-model download wall on that launch was the
        // single worst thing the audit found. This test must meet the app the way a tester does.
        app.launchArguments += ["--reset-widgets"]
        app.launch()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow While Using App"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        return app
    }

    /// A fresh install lands on the chart, not on a model download.
    func testFirstLaunchGoesStraightToTheMap() throws {
        try XCTSkipIf(UITestFeatures.transcription,
                      "This asserts the EFB-only first-run shape; a transcription build legitimately "
                      + "shows the model-download gate here.")
        let app = launchClean()

        // PRESENCE: the map's own controls came up.
        XCTAssertTrue(app.buttons["map-zoom-in"].waitForExistence(timeout: 40),
                      "the map did not come up on a fresh install")

        // ABSENCE: no onboarding/model-download wall. Those controls live in OnboardingDownloadView.
        for id in ["gate-primary", "gate-skip"] {
            XCTAssertFalse(app.buttons[id].exists,
                           "\(id) is on screen — a fresh EFB install is still showing the speech-model "
                           + "download gate, which is the first thing a public-beta tester would meet")
        }
    }

    /// The bottom bar offers the EFB tabs and not the transcript.
    func testTabBarHasNoTranscriptTab() throws {
        try XCTSkipIf(UITestFeatures.transcription, "Transcript tab is correct in a transcription build.")
        let app = launchClean()
        XCTAssertTrue(app.buttons["tab-map"].waitForExistence(timeout: 40), "no map tab")

        // PRESENCE: the EFB tabs are all there.
        for tab in ["tab-map", "tab-plates", "tab-airports", "tab-notes", "tab-logbook", "tab-wx"] {
            XCTAssertTrue(app.buttons[tab].exists, "\(tab) missing from the bottom bar")
        }
        // ABSENCE: the transcript tab is not.
        XCTAssertFalse(app.buttons["tab-transcript"].exists,
                       "the Transcript tab is still in the bottom bar")
    }

    /// No transcription chrome on the map home, and no fabricated transmissions.
    func testMapHomeCarriesNoTranscriptionChrome() throws {
        try XCTSkipIf(UITestFeatures.transcription, "This chrome is correct in a transcription build.")
        let app = launchClean()
        XCTAssertTrue(app.buttons["map-zoom-in"].waitForExistence(timeout: 40), "the map did not come up")

        // PRESENCE: the EFB top-bar controls survived the gate. These share TopBar with the two gated
        // buttons, so this is the check that proves the gate cut two children and not the whole bar.
        for id in ["map-layers-menu", "widgets-menu", "settings-button", "emergency-button"] {
            XCTAssertTrue(app.buttons[id].exists, "\(id) was gated away with the transcription chrome")
        }

        // ABSENCE: power button, input bar, transcript card.
        for id in ["start-stop-button", "input-toggle"] {
            XCTAssertFalse(app.buttons[id].exists, "\(id) is still on the map home")
        }
        XCTAssertFalse(app.otherElements["input-bar"].exists, "the transcription input bar is still mounted")

        // ABSENCE of the seeded fake traffic: seedSampleData() invented four transmissions and set
        // detail = "Transcribing." on every model-less launch, which is exactly a beta install.
        XCTAssertFalse(app.staticTexts["Transcribing."].exists,
                       "the app is reporting itself as transcribing on an EFB-only build")
    }

    /// Settings offers the EFB categories and not the transcription ones.
    func testSettingsHasNoTranscriptionCategories() throws {
        try XCTSkipIf(UITestFeatures.transcription, "These categories are correct in a transcription build.")
        let app = launchClean()
        XCTAssertTrue(app.buttons["settings-button"].waitForExistence(timeout: 40), "no settings button")
        app.buttons["settings-button"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5), "settings sheet missing")

        // PRESENCE: General and the charts/downloads door. The downloads link shares the category list
        // with the transcription link, so this proves the gate did not take the EFB door with it.
        XCTAssertTrue(app.buttons["settings-cat-general"].exists, "General category missing")

        // ABSENCE: the transcription and audio categories.
        for cat in ["settings-cat-transcription", "settings-cat-audio"] {
            XCTAssertFalse(app.buttons[cat].exists, "\(cat) is still offered in Settings")
        }
    }
}
