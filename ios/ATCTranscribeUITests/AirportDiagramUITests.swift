import XCTest

/// Tapping an airport on the map shows its diagram as a thumbnail in the card's Info tab, and tapping the
/// thumbnail opens that diagram full-page in the Plates tab (the "Done" toolbar button is unique to the
/// plate viewer — the airport card closes with an X — so it's a reliable "the plate opened" signal).
final class AirportDiagramUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    func testAirportDiagramThumbnailOpensPlateInPlatesTab() {
        let app = XCUIApplication()
        app.launchArguments += ["-atc.onboardingDismissed", "YES", "--reset-widgets", "--preview-airport", "KBOS"]
        app.launch()

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow While Using App"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }

        // The KBOS card opens on the Info tab. Its details list scrolls; reveal the diagram thumbnail by
        // dragging up INSIDE the card (a coordinate drag, so it survives the scrolled-off "Details" label).
        XCTAssertTrue(app.staticTexts["KBOS"].waitForExistence(timeout: 15), "airport card never opened")
        let thumb = app.buttons["airport-diagram-thumb"]
        let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.40))
        let bottom = app.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.55))
        var scrolls = 0
        while !thumb.exists && scrolls < 8 {                 // bounded (Power of 10)
            bottom.press(forDuration: 0.05, thenDragTo: top)
            scrolls += 1
        }
        XCTAssertTrue(thumb.waitForExistence(timeout: 5), "airport-diagram thumbnail did not appear in the Info tab")

        // Tap it (works even while the raster is still loading — the pdf ref is resolved synchronously).
        thumb.tap()

        // The plate viewer opened full-page in the Plates tab.
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 10), "diagram did not open full-page in the Plates tab")
    }
}
