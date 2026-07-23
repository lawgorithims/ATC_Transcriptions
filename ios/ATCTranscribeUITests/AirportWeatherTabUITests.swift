import XCTest

/// UI check for the airport card's Weather tab → METAR / TAF / 7-Day / History sub-tabs.
/// `--demo-airport` presents the KDEN card on launch and `--demo-climate` makes the climate charts
/// render offline, so this drives the real flow (open Weather, see the current-observations section,
/// switch to History, open the charts) with no map-tapping and no network.
///
/// The sub-tabs were a two-way Current/Historical split until M13 replaced it with the four-way
/// picker; this test asserted the old labels and the retired "coming soon" placeholder, so it had
/// been failing since 2026-07-18. Assertions now key off `weather-subtabs` and the section
/// identifiers in MapObjectView, which is what the UI actually publishes.
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
    /// The card's own scrollable list. Swiping the whole app instead pans the MAP behind the card and
    /// tears the card down, which reads as "the row never appeared" — so always scroll the list itself.
    private func scroller(_ app: XCUIApplication) -> XCUIElement {
        for candidate in [app.collectionViews.firstMatch, app.tables.firstMatch, app.scrollViews.firstMatch]
        where candidate.exists { return candidate }
        return app
    }
    /// Swipe up until `el` renders — the card is a scrollable sheet, so lower rows aren't in the tree
    /// until scrolled into view. Fully automated (a gesture, not manual interaction).
    ///
    /// Waits before each swipe: a sub-tab switch re-renders asynchronously, and a swipe fired into that
    /// gap scrolls past the row (or off the card) before it ever exists.
    @discardableResult
    private func scrollUntil(_ app: XCUIApplication, _ el: XCUIElement, maxSwipes: Int = 8) -> Bool {
        if el.waitForExistence(timeout: 3) { return true }
        let list = scroller(app)
        for _ in 0..<maxSwipes {
            list.swipeUp()
            if el.waitForExistence(timeout: 1) { return true }
        }
        return el.exists
    }

    func testWeatherTabCurrentAndHistoricalSubtabs() {
        let app = launched()
        // The airport card is up; open its Weather tab (a segment in the card's top tab bar).
        let weather = app.buttons["Weather"].firstMatch
        XCTAssertTrue(weather.waitForExistence(timeout: 25), "airport card Weather tab should be present")
        weather.tap()

        // The sub-tab picker renders (METAR / TAF / 7-Day / History; default = METAR).
        XCTAssertTrue(el(app, "weather-subtabs").waitForExistence(timeout: 6), "weather sub-tab picker should exist")
        XCTAssertTrue(app.buttons["METAR"].firstMatch.exists, "METAR sub-tab segment should exist")
        XCTAssertTrue(app.buttons["History"].firstMatch.exists, "History sub-tab segment should exist")

        // METAR is a LIVE fetch, so offline it settles into loading / failed / no-report. Asserting a
        // specific one would make this test depend on the CI box's network; the contract under test is
        // that the section renders one of its honest states, never a blank tab.
        let metarStates = ["weather-current-metar", "weather-current-failed",
                           "weather-current-none", "weather-current-loading"]
        XCTAssertTrue(scrollUntil(app, app.staticTexts["Current observations"]) || metarStates.contains { el(app, $0).exists },
                      "METAR sub-tab should render the current-observations section")

        // Switch to History and open the climate charts.
        app.buttons["History"].firstMatch.tap()
        let climate = el(app, "airport-climate")
        XCTAssertTrue(scrollUntil(app, climate), "History sub-tab should offer Airport Climate")
        climate.tap()

        // The charts open (best-time-of-day section, from the demo climatology).
        XCTAssertTrue(scrollUntil(app, header(app, beginsWith: "Best time of day")),
                      "opening Airport Climate should show the charts")

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "weather-historical"; shot.lifetime = .keepAlways; add(shot)
    }
}
