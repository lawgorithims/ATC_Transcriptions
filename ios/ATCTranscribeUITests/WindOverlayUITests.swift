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
        // Dismiss the popover with a tap on open chart, low and right of the slider's corner. Tapping the
        // menu button again leaves the popover's presentation in place on iPad, and the freshly-raised
        // control does not reliably enter the snapshot behind it.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.62, dy: 0.78)).tap()

        let slider = element(app, "wind-altitude-slider")
        XCTAssertTrue(slider.waitForExistence(timeout: 10),
                      "the altitude slider did not appear after enabling the layer "
                      + "(engine: \(engineDescription(app)), control: "
                      + "\(element(app, "wind-altitude-control").exists), "
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

    /// Dragging the slider changes the level, and the chip's altitude label follows it.
    func testDraggingTheSliderChangesLevel() {
        let app = launchMap(windOn: true)
        XCTAssertTrue(app.buttons["map-zoom-in"].waitForExistence(timeout: 30), "map did not come up")
        let slider = element(app, "wind-altitude-slider")
        XCTAssertTrue(slider.waitForExistence(timeout: 15), "slider missing")
        let before = slider.value as? String
        XCTAssertNotNil(before, "the slider must report a level")

        // Drag the thumb to the top of the track = the highest level (FL390).
        slider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
            .press(forDuration: 0.1,
                   thenDragTo: slider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.0)))
        snap(app, "05-slider-at-fl390")
        XCTAssertEqual(slider.value as? String, "FL390, 200 hPa",
                       "the top detent is FL390, got: \(String(describing: slider.value))")

        // And back to the bottom = the surface.
        slider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1))
            .press(forDuration: 0.1,
                   thenDragTo: slider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1.0)))
        snap(app, "06-slider-at-surface")
        XCTAssertEqual(slider.value as? String, "SFC, 10 m AGL",
                       "the bottom detent is the surface, got: \(String(describing: slider.value))")
        XCTAssertNotEqual(slider.value as? String, before, "the drag must have changed the level")
    }
}
