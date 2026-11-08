import XCTest

/// The App Store screenshot set.
///
/// # Why this is not `ScreenshotTests`
///
/// `ScreenshotTests` shoots the README, and it shoots the **transcription console** — the seeded
/// transcript, callsign chips, the input strip, the standby power button. Every one of those is
/// compiled out of the EFB build this app ships as (`COMMSIGHT_TRANSCRIPTION` undefined), so
/// running it for the store would quietly produce a set of shots of things that are not there.
/// It also needs the model-less "lean" build trick to force the demo console, which is irrelevant
/// here. Different job, different file.
///
/// # What a store shot has to be
///
/// Apple wants the app as it actually ships, at exact device sizes. Two consequences shape this
/// file:
///
///  * **No developer surfaces.** The flight simulator, the demo-flight view and the clearance test
///    bench all sit behind the seven-tap unlock, and the first two publish a FAKE GPS position
///    that paints a "SIMULATED GPS — this position is not real" banner across the screen. A store
///    screenshot carrying that banner is both ugly and misleading. Position here comes from
///    `simctl location`, so the app takes an ordinary CoreLocation fix and never knows the
///    difference.
///  * **Shots must not fail the run.** `continueAfterFailure` is on and every step is guarded, so
///    one surface that will not come up costs its own frame rather than the whole set.
///
/// Run it through `Tools/appstore_screenshots.sh`, which arranges the simulator, the moving
/// position and the export. It XCTSkips in the normal suite.
final class AppStoreScreenshotTests: XCTestCase {

    override func setUp() { continueAfterFailure = true }

    private var enabled: Bool { ProcessInfo.processInfo.environment["APPSTORE_SHOTS"] == "1" }

    /// Name the attachment after the shot; `Tools/appstore_screenshots.sh` exports by that name.
    /// Numbered so the exported set sorts into the order the listing should present it.
    private func snap(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Give the map a beat to finish drawing tiles before the shutter — a half-rendered sectional
    /// is the one defect that is invisible while the test passes and obvious on the store page.
    private func settle(_ seconds: TimeInterval = 2.5) {
        Thread.sleep(forTimeInterval: seconds)
    }

    /// Tap a bottom-bar tab.
    ///
    /// `isHittable`, not `exists`. The tab bar stays in the accessibility tree underneath a
    /// full-screen presentation like the plate viewer, so an `exists` check returns true, the tap
    /// lands on nothing, and the next shot is silently a duplicate of the last one. That is
    /// exactly what the second run of this produced: weather and night were both the plate
    /// screen.
    @discardableResult
    private func tapTab(_ app: XCUIApplication, _ id: String) -> Bool {
        let tab = app.buttons[id]
        guard tab.waitForExistence(timeout: 10), tab.isHittable else { return false }
        tab.tap()
        return true
    }

    /// Close whatever full-screen presentation is up, so the tab bar is reachable again.
    private func dismissIfPresented(_ app: XCUIApplication) {
        let done = app.buttons["Done"].firstMatch
        if done.exists && done.isHittable { done.tap(); settle(1.5) }
    }

    private func setTheme(_ app: XCUIApplication, _ label: String) {
        let menu = app.buttons["theme-menu"]
        guard menu.waitForExistence(timeout: 5) else { return }
        menu.tap()
        let option = app.buttons[label].firstMatch
        if option.waitForExistence(timeout: 3) { option.tap() }
        else if menu.exists { menu.tap() }          // could not find it — close the menu again
    }

    func testCaptureAppStoreScreenshots() throws {
        try XCTSkipUnless(enabled, "Set APPSTORE_SHOTS=1 to regenerate the App Store screenshots.")

        let app = XCUIApplication()
        app.launchArguments += ["-atc.onboardingDismissed", "YES", "--reset-widgets"]
        app.launch()

        // Belt and braces: the runner grants location with `simctl privacy`, which is
        // deterministic. This catches the case where it did not, and a shot of an EFB that does
        // not know where it is would be worthless — the map stays at continental zoom with no
        // ownship, which is exactly what the first run of this produced.
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            .buttons["Allow While Using App"]
        if allow.waitForExistence(timeout: 5) { allow.tap() }

        XCTAssertTrue(app.buttons["map-zoom-in"].waitForExistence(timeout: 60),
                      "the map never came up — nothing worth shooting")
        settle(8)                                   // first tile load is the slow one

        // Leave no panel open from a previous run: NRST persists across launches, and it parks a
        // panel over a third of the screen.
        if app.buttons["nrst-end"].exists { app.buttons["nrst-end"].tap(); settle(1) }

        // 1. The moving map. The one shot most people will ever look at.
        snap(app, "01-map")

        // 2 + 3. The airport directory, then a real approach plate from it.
        //
        // The plate comes via Airports rather than the Plates tab because Plates opens on an empty
        // "search an airport to open its binder" state — true to the app, useless as a shot.
        if tapTab(app, "tab-airports") {
            settle(3)
            snap(app, "02-airports")

            let row = app.buttons["airport-row"].firstMatch
            if row.waitForExistence(timeout: 5) {
                row.tap()
                settle(3)
                let thumb = app.buttons["plate-thumb"].firstMatch
                if thumb.waitForExistence(timeout: 8) {
                    thumb.tap()
                    settle(4)                       // the PDF has to render

                    // The plate AS A MAP LAYER, with ownship on it, rather than the flat PDF.
                    // The flat viewer fits the page to the screen and leaves most of an iPad
                    // letterboxed in black; the georeferenced overlay is also the thing worth
                    // showing, since reading a plate is table stakes and flying on one is not.
                    let overlay = app.buttons["plate-overlay-map"]
                    if overlay.waitForExistence(timeout: 5) && overlay.isHittable {
                        overlay.tap()
                        settle(5)
                        snap(app, "03-plate-on-map")
                    } else {
                        snap(app, "03-plate")       // not every plate is georeferenced
                    }
                }
                dismissIfPresented(app)             // or the tab bar stays unreachable
            }
        }
        dismissIfPresented(app)

        // 4. Weather.
        if tapTab(app, "tab-wx") {
            settle(4)
            snap(app, "04-weather")
        }

        // 5. Night theme, back on the map — red-only emission is a real differentiator for anyone
        //    who flies at night, and it does not read as a feature in words.
        if tapTab(app, "tab-map") {
            settle(2)
            setTheme(app, "Night")
            settle(4)
            snap(app, "05-night")
            setTheme(app, "Cockpit")
        }

        // NOT SHOT: the engine-out glide ranking.
        //
        // It needs a GPS ALTITUDE, and `simctl location` only supplies latitude and longitude — a
        // 2D fix. The app is right to refuse ("No GPS altitude — a glide range cannot be computed
        // without one"), so the only honest shot of it would be of that refusal. The alternative,
        // the in-app flight simulator, paints "SIMULATED GPS — this position is not real" across
        // the screen. If this shot is ever wanted, it has to come from a real device in the air or
        // from a recorded track replayed through CoreLocation with altitude.
    }
}
