import XCTest

/// The "where not to go" layer's controls, driven through the real layers panel.
///
/// A UI test cannot put the national map into Application Support, so what is asserted is everything
/// that does not need it: the row is there for every pilot, its key and its caveat travel with it, a
/// machine without the map says so instead of drawing an unchanged chart, and the cover option only
/// exists while the layer is on. The tile format and colours have unit tests (`AvoidMapTests`).
final class AvoidLayerUITests: XCTestCase {

    override func setUpWithError() throws { continueAfterFailure = false }

    func testTheLayerCarriesItsCaveatAndSaysWhenNothingIsInstalled() throws {
        let app = XCUIApplication()
        // No `-atc.map.avoid` argument: the argument domain would outrank the switch and pin it, and
        // this test flips it. Diagnostics and the engine are stated so a previous suite cannot hide rows.
        app.launchArguments += ["-atc.onboardingDismissed", "YES", "--reset-widgets",
                                "-atc.map.engine.maplibre", "YES", "-atc.diagnosticsEnabled", "NO"]
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow While Using App"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }

        let menu = app.buttons["map-layers-menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 30), "the map layers button never appeared")
        menu.tap()
        let layer = app.switches["layer-avoid"]
        XCTAssertTrue(layer.waitForExistence(timeout: 10), "no Where-not-to-go row for a pilot without diagnostics")
        let wasOn = (layer.value as? String) == "1"
        // Leave the switch as this test found it, even if an assertion stops it early. The panel may
        // be gone by then — in the first run the data-currency banner arrived a few seconds after
        // launch, re-laid out the top bar and closed the popover — and reading a vanished switch's
        // value FAILS rather than returning nil, so reopen it first.
        addTeardownBlock {
            guard app.state == .runningForeground else { return }
            if !layer.exists {
                let dismiss = app.otherElements["PopoverDismissRegion"]
                if dismiss.exists { dismiss.tap() }
                if menu.waitForExistence(timeout: 5) { menu.tap() }
            }
            guard layer.waitForExistence(timeout: 5) else { return }
            if ((layer.value as? String) == "1") != wasOn { UITestToggle.flip(layer) }
        }
        if !wasOn { UITestToggle.flip(layer) }

        let note = app.staticTexts["layers-avoid-note"]
        XCTAssertTrue(note.waitForExistence(timeout: 5), "the layer is on without its caveat")
        XCTAssertTrue(note.label.contains("never where to land"), "the caveat lost its first rule: \(note.label)")
        XCTAssertTrue(note.label.contains("not safe ground"), "the caveat lost unshaded-is-not-safe: \(note.label)")
        let status = app.staticTexts["layers-avoid-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5), "the layer gives no status")
        XCTAssertTrue(status.label.contains("Not downloaded") || status.label.contains("Contiguous US"),
                      "the status says neither installed nor missing: \(status.label)")
        XCTAssertTrue(app.switches["layer-avoid-cover"].exists, "no cover option while the layer is on")
        XCTAssertFalse(app.staticTexts["layers-avoid-engine"].exists, "the engine warning shows on the GPU map")

        UITestToggle.flip(layer)
        XCTAssertTrue(note.waitForNonExistence(timeout: 5), "the caveat outlived the layer")
        XCTAssertFalse(app.switches["layer-avoid-cover"].exists, "the cover option outlived the layer")
    }
}
