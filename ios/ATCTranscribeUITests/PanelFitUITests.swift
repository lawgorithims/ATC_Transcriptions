import XCTest

/// Does the chrome FIT on a phone — the question this suite could not previously ask.
///
/// ⚠️ WHY THIS EXISTS. `MapLayersPanel` declared 510pt of content and shipped that way on a 402pt
/// iPhone for weeks: the base-map column read "FR sectional" / "ark (minimal)" with its header
/// sliced off, and every overlay switch was cut in half with its centre outside the window, so a
/// pilot on a phone could not reliably hit any of them. It survived because of WHERE the suite runs.
/// `MapControlsUITests`, `WindOverlayUITests` and five cases in `LZLayerUITests` all XCTSkip at
/// compact width, so the panel was exercised almost entirely on an iPad, where it fits. The single
/// unguarded case, `AvoidLayerUITests`, was the only thing that ever opened it on a phone — and its
/// failure read as "the switch is not bound to anything", which is a product-shaped sentence, so it
/// was carried as a known flake instead of being read as the layout bug it was.
///
/// So these tests assert the one thing no other test here asserts: that a control a pilot must touch
/// is ACTUALLY ON THE SCREEN. They are deliberately about geometry, not behaviour — `AvoidLayerUITests`
/// already covers whether the switches work, and would be the wrong place to discover they are
/// off-window, because a dropped tap and a dead binding look identical from the outside.
final class PanelFitUITests: XCTestCase {

    override func setUpWithError() throws { continueAfterFailure = false }

    private func launchOnMap() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-atc.onboardingDismissed", "YES", "--reset-widgets"]
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow While Using App"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        return app
    }

    /// Every control in `elements` must sit fully inside the window HORIZONTALLY.
    ///
    /// Horizontal only, and on purpose: a panel taller than the screen scrolls, which is a usable if
    /// imperfect answer, whereas a popover does not scroll sideways and gives no hint that anything
    /// is missing. Width is the dimension where overflow is silent and unrecoverable.
    private func assertFitsHorizontally(_ elements: [XCUIElement], in app: XCUIApplication,
                                        what: String, file: StaticString = #filePath,
                                        line: UInt = #line) {
        let window = app.windows.firstMatch.frame
        XCTAssertFalse(elements.isEmpty, "\(what): found no controls to measure — the panel did not "
                       + "open, or its identifiers changed", file: file, line: line)
        for e in elements.prefix(60) {                       // bounded (rule 2)
            let f = e.frame
            guard f.width > 0 else { continue }              // not laid out; nothing to say about it
            XCTAssertGreaterThanOrEqual(f.minX, window.minX - 0.5,
                "\(what): a control starts \(Int(window.minX - f.minX))pt off the LEFT edge "
                + "(control \(f), window \(window))", file: file, line: line)
            XCTAssertLessThanOrEqual(f.maxX, window.maxX + 0.5,
                "\(what): a control runs \(Int(f.maxX - window.maxX))pt past the RIGHT edge "
                + "(control \(f), window \(window)) — on a popover that is invisible and unhittable",
                file: file, line: line)
        }
    }

    /// THE REGRESSION THIS SUITE WAS MISSING. Before the compact-width fix every one of these
    /// switches had its centre outside the window.
    func testEveryLayersPanelSwitchIsOnScreenOnAPhone() throws {
        let app = launchOnMap()
        try UITestLayout.requireCompactWidth(app, "Whether the layers panel fits")

        let menu = app.buttons["map-layers-menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 20), "the layers button must be in the top bar")
        menu.tap()

        let firstSwitch = app.switches.firstMatch
        XCTAssertTrue(firstSwitch.waitForExistence(timeout: 10), "the layers panel must open")
        assertFitsHorizontally(app.switches.allElementsBoundByIndex, in: app,
                               what: "Layers panel switches")
    }

    /// The same question for the other top-bar popover. `DataActivityPanel` already solves this with
    /// a size-class-conditional frame — it hit the identical bug once ("ata activity", clipped off
    /// the left edge) and its code comment is where the house pattern is written down. This pins it
    /// so the lesson cannot be quietly undone.
    func testEveryDataActivityControlIsOnScreenOnAPhone() throws {
        let app = launchOnMap()
        try UITestLayout.requireCompactWidth(app, "Whether the data-activity panel fits")

        let button = app.buttons["data-activity-button"]
        XCTAssertTrue(button.waitForExistence(timeout: 20), "the data-activity button must be in the top bar")
        button.tap()

        let title = app.staticTexts["Data activity"]
        XCTAssertTrue(title.waitForExistence(timeout: 10), "the data-activity panel must open")
        // ⚠️ SCOPED QUERY, NOT `allElementsBoundByIndex` FILTERED IN SWIFT. The first cut of this
        // enumerated every button in the app and filtered by identifier afterwards, which races:
        // the snapshot is taken once, elements behind a popover go stale, and reading `.frame` on
        // one throws "Failed to get matching snapshot: No matches found for Element at index 34".
        // That is a TEST bug that reads like a missing control — the same class of lie this file
        // exists to stop — so the matching happens inside the query, where XCUITest keeps it live.
        let netq = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "netq-"))
        // The TITLE is the tell: the bug this guards made it render as "ata activity". It is always
        // present, so it alone satisfies the non-empty check even on a panel with nothing queued.
        assertFitsHorizontally([title] + netq.allElementsBoundByIndex, in: app,
                               what: "Data-activity panel")
    }

    /// The top bar itself. `ConsoleView` documents it as over budget at compact width, and the NRST
    /// merge spent another 14pt of it, so this pins that the controls at both ends are still whole.
    func testTheTopBarControlsAreNotClippedOffEitherEdge() throws {
        let app = launchOnMap()
        try UITestLayout.requireCompactWidth(app, "Whether the top bar fits")

        let nrst = app.buttons["emergency-button"]          // leftmost
        let gear = app.buttons["settings-button"]           // rightmost
        XCTAssertTrue(nrst.waitForExistence(timeout: 20))
        XCTAssertTrue(gear.waitForExistence(timeout: 5))
        assertFitsHorizontally([nrst, gear], in: app, what: "Top bar")
        XCTAssertTrue(nrst.isHittable, "the NRST arm must be reachable, not half off the edge")
        XCTAssertTrue(gear.isHittable, "and so must Settings")
    }
}
