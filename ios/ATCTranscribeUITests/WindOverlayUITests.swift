import XCTest

/// Drives the winds-aloft overlay end to end in the Simulator: the layers-menu toggle brings up the
/// left-edge altitude slider, the detents change the shown level, and the status chip reports the model
/// run. The particles themselves are GPU output that no assertion can see, so the screenshots attached
/// here are the visual record.
final class WindOverlayUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    /// Land on the Map tab over Fort Worth with the gate skipped — the same pattern as MapControlsUITests.
    ///
    /// The MapLibre engine is forced ON as a PRECONDITION, not an assumption: the particle layer is a
    /// sibling view of the MLNMapView, so on the classic fallback there is deliberately no overlay and no
    /// slider. Without this the test would report a false regression on any Simulator whose engine
    /// preference happens to be off.
    private func launchMap(windOn: Bool, level: Int = 5) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-atc.onboardingDismissed", "YES", "--start-tab", "map",
                               "--chart-center", "32.9,-97.0",
                               "-atc.map.engine.maplibre", "YES"]
        // Set the layer state EXPLICITLY either way. The argument domain outranks the persisted value, so a
        // run does not inherit whatever the previous run's toggle left behind.
        app.launchArguments += ["-atc.map.wind", windOn ? "YES" : "NO",
                                "-atc.map.windLevel", String(level)]
        app.launch()
        return app
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let s = XCTAttachment(screenshot: app.screenshot()); s.name = name; s.lifetime = .keepAlways; add(s)
    }

    /// Which map engine is live decides whether the overlay can exist at all: the particle layer is a
    /// sibling view of the MLNMapView, so on the classic fallback engine there is deliberately no slider.
    /// Recorded rather than asserted, so a Simulator that falls back reports WHY instead of just failing.
    private func engineDescription(_ app: XCUIApplication) -> String {
        if app.descendants(matching: .any).matching(identifier: "map-engine-maplibre").firstMatch.exists {
            return "MapLibre"
        }
        if app.descendants(matching: .any).matching(identifier: "map-engine-classic").firstMatch.exists {
            return "classic MapKit fallback"
        }
        return "unknown"
    }

    /// Match by identifier across ALL element types. SwiftUI decides what a custom `accessibilityElement`
    /// surfaces as, and a `.otherElements`-only query silently misses it.
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// The toggle exists in the layers panel and turning it on raises the slider.
    func testLayersToggleRaisesTheAltitudeSlider() {
        let app = launchMap(windOn: false)
        XCTAssertTrue(app.buttons["map-zoom-in"].waitForExistence(timeout: 30), "map did not come up")
        XCTAssertFalse(element(app, "wind-altitude-slider").exists, "the slider must be off by default")

        app.buttons["map-layers-menu"].tap()
        let toggle = app.switches["layer-wind"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 8), "winds-aloft toggle missing from the layers panel")
        snap(app, "01-layers-panel-wind-row")
        toggle.tap()

        // ⚠️ ASSERT THE TOGGLE BEFORE DISMISSING. This test was intermittent, and the old failure said
        // only that the slider never appeared — which reads as a renderer bug when it is not one. The
        // slider's mount is `showWindAloft && useMapLibreMap && !mapLibreRenderFailed`
        // (MapHostView.swift:919), and the `map-engine-maplibre` identifier is published only when the
        // second AND third are true (MapHostView.swift:374). So a failure reporting `engine: MapLibre`
        // had already proved two of the three — the one that was false was the toggle itself. Checking
        // it here turns a confusing renderer-shaped failure into "the tap did not take".
        XCTAssertEqual(toggle.value as? String, "1",
                       "tapping layer-wind did not switch it on, so nothing downstream can be asserted")

        // Dismiss the popover through the dismiss region XCUITest exposes for exactly this, rather than
        // a normalized coordinate. (0.62, 0.78) was a guess at "open chart, low and right", and on a
        // 13-inch iPad the layers popover is tall enough to still cover that point — so the dismissal
        // tap could land back INSIDE the panel and flip the switch off again, which is what made this
        // flaky rather than broken. Fall back to the old coordinate if the region is absent.
        let dismissRegion = app.otherElements["PopoverDismissRegion"]
        if dismissRegion.waitForExistence(timeout: 2) {
            dismissRegion.tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.62, dy: 0.78)).tap()
        }
        // NO post-dismissal assertion on `toggle` here. Dismissing the popover removes the switch from
        // the accessibility tree, so `toggle.value` raises "No matches found for Descendants matching
        // type Switch" before any `?? default` can apply — which is a test bug dressed up as a product
        // failure. (I wrote exactly that and it failed on the next run.) The slider check below is the
        // real end-state oracle anyway: the slider cannot mount unless `showWindAloft` is still true.

        let slider = element(app, "wind-altitude-slider")
        XCTAssertTrue(slider.waitForExistence(timeout: 10),
                      "the altitude slider did not appear after enabling the layer "
                      + "(engine: \(engineDescription(app)), toggle: \(toggle.value as? String ?? "gone"), "
                      + "chip: \(element(app, "wind-status-chip").exists))")
        XCTAssertEqual(slider.value as? String, "FL180, 500 hPa",
                       "the slider must report the restored level")
        snap(app, "02-slider-up")
    }

    /// A restored ON toggle must bring the layer up at LAUNCH with no interaction — the build-99 lesson
    /// (radar sat on "Loading radar…" for a whole session because a restored toggle is not an edge).
    func testRestoredToggleBringsTheLayerUpAtLaunch() {
        let app = launchMap(windOn: true, level: 9)          // FL390
        XCTAssertTrue(app.buttons["map-zoom-in"].waitForExistence(timeout: 30), "map did not come up")
        let slider = element(app, "wind-altitude-slider")
        XCTAssertTrue(slider.waitForExistence(timeout: 15),
                      "a persisted-on wind layer did not reconcile at launch "
                      + "(engine: \(engineDescription(app)))")
        snap(app, "03-launch-with-wind-on")

        // Give the real NOMADS fetch time to land. The status chip carries the model run, but SwiftUI does
        // not expose it under its own identifier from a promoted element, so the run is checked by eye in
        // the attached screenshot and the assertions below use the slider's own reported state.
        Thread.sleep(forTimeInterval: 12)
        snap(app, "04-after-fetch")
        XCTAssertEqual(slider.value as? String, "FL390, 200 hPa",
                       "the launch-restored level must survive the fetch")
    }

    /// Picking a level changes what the overlay shows, in both directions.
    ///
    /// Levels are chosen by tapping the tick labels, which is the deterministic path. The thumb drag was
    /// verified by hand on the simulator (FL180 → FL390 with a dwelling multi-point gesture); XCUITest's
    /// synthetic drag lands zero `onChanged` callbacks on this gesture often enough to be useless as a gate,
    /// even slowed down and held — a harness artefact, not a defect in the control.
    ///
    /// The ticks tapped here are "FL390" and "2.5k". "SFC" is deliberately NOT used: the chart itself carries
    /// "SFC" in its airspace floor labels, so matching on it is ambiguous. The surface level is asserted from
    /// the launch state instead.
    func testPickingALevelChangesWhatIsShown() {
        let app = launchMap(windOn: true, level: 0)          // surface
        XCTAssertTrue(app.buttons["map-zoom-in"].waitForExistence(timeout: 30), "map did not come up")
        let slider = element(app, "wind-altitude-slider")
        XCTAssertTrue(slider.waitForExistence(timeout: 15), "slider missing")
        XCTAssertEqual(slider.value as? String, "SFC, 10 m AGL", "the restored level is the surface")

        app.staticTexts["FL390"].tap()                       // straight to the jet
        snap(app, "05-level-fl390")
        XCTAssertEqual(slider.value as? String, "FL390, 200 hPa",
                       "got: \(String(describing: slider.value))")

        Thread.sleep(forTimeInterval: 1.0)                   // let the selection settle before re-tapping
        let low = app.staticTexts["2.5k"]
        XCTAssertTrue(low.waitForExistence(timeout: 5), "the 2.5k tick is missing")
        XCTAssertTrue(low.isHittable, "the 2.5k tick is not hittable")
        low.tap()                                            // and back down low
        snap(app, "06-level-2500")
        XCTAssertEqual(slider.value as? String, "2.5k, 925 hPa",
                       "got: \(String(describing: slider.value))")
    }

    /// EVERY detent is reachable — the one this test exists for is the BOTTOM of the track.
    ///
    /// The two lowest ticks used to be dead on an 11-inch iPad: the track runs 333 pt down from the
    /// measured console chrome, and the default Transcript card (bottomLeading, 460 tall) reached up
    /// into the last two rows, so `2.5k` and `SFC` were both invisible and un-tappable — their taps went
    /// to the card in front of them. Nothing failed loudly; the slider simply did not respond, and the
    /// levels a pilot most wants on approach were the ones they could not pick. It CLEARED on a 13-inch
    /// screen, which is why a per-device test is the only honest gate: this walks the whole track on
    /// whatever device the suite is running, so the next layout change cannot quietly bury a row again.
    ///
    /// Deliberately NOT `isHittable` — that reported true for the buried ticks. The oracle is the
    /// slider's own accessibility value actually changing.
    func testEveryAltitudeDetentIsReachable() {
        let app = launchMap(windOn: true, level: 0)
        XCTAssertTrue(app.buttons["map-zoom-in"].waitForExistence(timeout: 30), "map did not come up")
        let slider = element(app, "wind-altitude-slider")
        XCTAssertTrue(slider.waitForExistence(timeout: 15), "slider missing")

        // Bottom-up, so a failure names the lowest row that broke. "SFC" is skipped as a TAP target
        // (the chart's own airspace-floor labels also read "SFC", so the query is ambiguous) — it is the
        // launch state instead, asserted first.
        XCTAssertEqual(slider.value as? String, "SFC, 10 m AGL", "the restored level is the surface")
        let rows = [("2.5k", "2.5k, 925 hPa"), ("5k", "5k, 850 hPa"), ("10k", "10k, 700 hPa"),
                    ("14k", "14k, 600 hPa"), ("FL180", "FL180, 500 hPa"), ("FL240", "FL240, 400 hPa"),
                    ("FL300", "FL300, 300 hPa"), ("FL340", "FL340, 250 hPa"), ("FL390", "FL390, 200 hPa")]
        for (tick, expected) in rows {                      // bounded by the level table
            let label = app.staticTexts[tick]
            XCTAssertTrue(label.waitForExistence(timeout: 5), "the \(tick) tick is missing")
            label.tap()
            XCTAssertEqual(slider.value as? String, expected,
                           "tapping \(tick) did not select it — is something drawn over that row?")
        }
        snap(app, "07-every-detent")
    }
}
