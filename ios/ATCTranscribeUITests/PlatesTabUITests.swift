import XCTest

/// The Plates tab shows the RIGHT airport and is organised, not a flat wall of approaches:
///   • it opens on the requested airport (not a stale filed destination),
///   • approaches are grouped into collapsible per-runway sections, and
///   • search switches the airport (the pilot can pull up any field's plates).
final class PlatesTabUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    func testPlatesTabIsRunwayGroupedAndSearchable() {
        let app = XCUIApplication()
        app.launchArguments += ["-atc.onboardingDismissed", "YES", "--reset-widgets",
                                "--start-tab", "plates", "KBOS"]     // pin KBOS → deterministic, no GPS needed
        app.launch()

        // A location prompt can cover the tab on a fresh install; dismiss it via Springboard.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow While Using App"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }

        // Opened on the requested field.
        XCTAssertTrue(app.navigationBars["KBOS"].waitForExistence(timeout: 10), "Plates tab did not open on KBOS")

        // Approaches are grouped by runway — a "Runway NN…" disclosure header proves the reorganisation
        // (the old flat list had none). BEGINSWITH tolerates the trailing "(count)" in the same label.
        let runwayHeader = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Runway '")).firstMatch
        XCTAssertTrue(runwayHeader.waitForExistence(timeout: 5), "approaches are not grouped by runway")

        // Search switches the airport (the reported "stuck on one airport" bug). The search bar lives on
        // the ROOT "Binders" list, not inside a pushed binder — opening on KBOS means we are one level
        // deep, so pop back first. (Asserting the field from the binder detail is why this read as
        // "search field missing" even though search works.)
        let backToBinders = app.navigationBars.buttons["Binders"].firstMatch
        XCTAssertTrue(backToBinders.waitForExistence(timeout: 5), "binder detail should offer a back button to Binders")
        backToBinders.tap()

        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5), "search field missing")
        search.tap()
        search.typeText("KATL")
        let hit = app.buttons.matching(NSPredicate(format: "label CONTAINS 'KATL'")).firstMatch
        XCTAssertTrue(hit.waitForExistence(timeout: 5), "search did not surface KATL")
        hit.tap()
        XCTAssertTrue(app.navigationBars["KATL"].waitForExistence(timeout: 5), "search did not switch the airport to KATL")
    }
}
