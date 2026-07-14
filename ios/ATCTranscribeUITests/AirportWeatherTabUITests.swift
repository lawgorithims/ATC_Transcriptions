import XCTest

/// UI check for the airport card's Weather tab → Current / Historical sub-tabs. `--demo-airport`
/// presents the KDEN card on launch and `--demo-climate` makes the climate charts render offline, so
/// this drives the real flow (open Weather, see the current placeholder, switch to Historical, open the
/// charts) with no map-tapping and no network.
final class AirportWeatherTabUITests: XCTestCase {

    private func launched() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["--demo-airport", "--demo-climate", "-atc.onboardingDismissed", "YES", "--reset-widgets"]
        app.launch()
        return app
    }
    private func el(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    private func header(_ app: XCUIApplication, beginsWith text: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", text)).firstMatch
    }
    /// Swipe up until `el` renders — the card is a scrollable sheet, so lower rows aren't in the tree
    /// until scrolled into view. Fully automated (a gesture, not manual interaction).
    @discardableResult
    private func scrollUntil(_ app: XCUIApplication, _ el: XCUIElement, maxSwipes: Int = 8) -> Bool {
        var n = 0
        while !el.exists && n < maxSwipes { app.swipeUp(); n += 1 }
        return el.exists
    }

    func testWeatherTabCurrentAndHistoricalSubtabs() {
        let app = launched()
        // The airport card is up; open its Weather tab (a segment in the card's top tab bar).
        let weather = app.buttons["Weather"].firstMatch
        XCTAssertTrue(weather.waitForExistence(timeout: 25), "airport card Weather tab should be present")
        weather.tap()

        // The Current / Historical sub-tabs render (default = Current).
        XCTAssertTrue(app.buttons["Current"].firstMatch.waitForExistence(timeout: 6), "Current sub-tab segment should exist")
        XCTAssertTrue(app.buttons["Historical"].firstMatch.exists, "Historical sub-tab segment should exist")
        // Current sub-tab content is below the fold — scroll to the honest METAR/TAF placeholder.
        XCTAssertTrue(scrollUntil(app, app.staticTexts["Live METAR / TAF — coming soon"]),
                      "Current sub-tab should show the METAR/TAF coming-soon placeholder")

        // Switch to Historical and open the climate charts.
        app.buttons["Historical"].firstMatch.tap()
        let climate = el(app, "airport-climate")
        XCTAssertTrue(scrollUntil(app, climate), "Historical sub-tab should offer Airport Climate")
        climate.tap()

        // The charts open (best-time-of-day section, from the demo climatology).
        XCTAssertTrue(scrollUntil(app, header(app, beginsWith: "Best time of day")),
                      "opening Airport Climate should show the charts")

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "weather-historical"; shot.lifetime = .keepAlways; add(shot)
    }
}
