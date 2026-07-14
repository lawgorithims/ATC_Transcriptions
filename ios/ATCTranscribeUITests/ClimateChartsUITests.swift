import XCTest

/// UI check for the Airport Climate charts — runs with NO manual button-pressing. `--demo-climate`
/// makes the store return a synthetic climatology (no network) and presents the Airport Climate sheet
/// on launch, so this test just launches and asserts the charts + their data-period timestamp exist.
final class ClimateChartsUITests: XCTestCase {

    private func launched() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["--demo-climate", "-atc.onboardingDismissed", "YES", "--reset-widgets"]
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func header(_ app: XCUIApplication, beginsWith text: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", text)).firstMatch
    }

    /// Swipe up until `el` renders — the card is a lazily-rendered scrollable list, so the lower chart
    /// sections don't exist in the tree until scrolled into view. Still fully automated (no manual step).
    @discardableResult
    private func scrollUntil(_ app: XCUIApplication, _ el: XCUIElement, maxSwipes: Int = 10) -> Bool {
        var n = 0
        while !el.exists && n < maxSwipes { app.swipeUp(); n += 1 }
        return el.exists
    }

    func testClimateChartsRenderWithoutTapping() {
        let app = launched()
        // Wait for the sheet + its async (demo) load — the period caption is in the first, on-screen section.
        XCTAssertTrue(element(app, "climate-period").waitForExistence(timeout: 25), "climate sheet should present")
        // A section header exists only if its section rendered; scroll each into view, then assert.
        XCTAssertTrue(scrollUntil(app, header(app, beginsWith: "Best time of day")),
                      "best-time-of-day chart section should render")
        XCTAssertTrue(scrollUntil(app, header(app, beginsWith: "Seasonal winds")),
                      "seasonal winds chart section should render")
        // Regression: month labels must be real names, not the ICU root-locale "M01"…"M12" fallback.
        XCTAssertTrue(app.staticTexts["Jan"].exists, "month labels should read Jan…Dec, not M01…M12")
        // Capture the rendered charts for visual review (attached to the test result).
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "climate-charts"; shot.lifetime = .keepAlways
        add(shot)
    }

    func testDataPeriodTimestampIsShown() {
        let app = launched()
        // The whole point of the timestamp: the pilot can read when the data is from.
        let period = element(app, "climate-period")
        XCTAssertTrue(period.waitForExistence(timeout: 25), "data-period caption should be present")
        XCTAssertTrue(period.label.contains("2023") || period.label.contains("2025") || period.label.contains("NASA POWER"),
                      "caption should state the period of record / source, got: \(period.label)")
    }
}
