import XCTest

/// The preflight glide-gap planner, driven the way a pilot uses it: file a route, set a cruise
/// altitude, read the OUT OF GLIDE cell, open it.
///
/// A computation that is right and never reaches the strip is the failure this suite exists for —
/// the engine has its own unit tests; this one proves a pilot can SEE the answer.
final class RouteGlideExposureUITests: XCTestCase {

    override func setUpWithError() throws { continueAfterFailure = false }

    func testFilingARouteShowsHowMuchOfItIsOutOfGlide() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-atc.onboardingDismissed", "YES", "--reset-widgets"]
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow While Using App"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }

        // By identifier, whatever its element type: the route box is a multi-line field, which
        // XCUITest exposes as a text VIEW — `textFields["plan-route"]` never matches it.
        func el(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
        // The plan and the strip's visibility both PERSIST, and whatever suite runs next inherits
        // them: a strip left open with this route filed moved the map's overlays under
        // WidgetMultiTouchUITests' drag. Leave the app as a fresh install has it — popover closed,
        // plan cleared, strip collapsed — even when an assertion below stops the test early.
        addTeardownBlock {
            if app.state != .runningForeground { app.launch() }
            let dismiss = app.descendants(matching: .any)["PopoverDismissRegion"]
            if dismiss.exists { dismiss.tap() }               // a tap outside a popover only closes it
            _ = el("glide-gap-detail").waitForNonExistence(timeout: 5)
            let clear = el("plan-clear")
            if clear.waitForExistence(timeout: 3) {
                clear.tap()
                let confirm = app.alerts.buttons["Clear"]
                if confirm.waitForExistence(timeout: 3) { confirm.tap() }
            }
            let done = el("plan-bar-done")
            if done.waitForExistence(timeout: 3) { done.tap() }
        }

        let bag = app.buttons["flight-bag-button"]
        XCTAssertTrue(bag.waitForExistence(timeout: 30), "no flight-plan control")
        // The strip's visibility PERSISTS, so a previous run may have left it open — and the
        // briefcase is a toggle. Open it only if it is not already showing.
        let route = el("plan-route")
        if !route.waitForExistence(timeout: 3) { bag.tap() }
        guard route.waitForExistence(timeout: 10) else {
            return XCTFail("the flight-plan strip did not open")
        }
        // The plan PERSISTS across launches, so clear what a previous run left before typing — typing
        // "8500" after an earlier "8500" made "85008500", which the strip clamped to 60,000 ft.
        func replace(_ field: XCUIElement, with text: String) {
            field.tap()
            let old = (field.value as? String) ?? ""
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count + 4) + text)
        }
        replace(route, with: "KLRU KTUS\n")
        let alt = el("plan-altitude")
        XCTAssertTrue(alt.waitForExistence(timeout: 5))
        replace(alt, with: "8500")
        route.tap()                         // the altitude commits on focus loss (no return key)

        let cell = el("plan-glide-exposure")
        XCTAssertTrue(cell.waitForExistence(timeout: 10), "no OUT OF GLIDE cell in the trip stats")
        // The value lands once the route resolves and the off-main assessment finishes.
        expectation(for: NSPredicate(format: "label CONTAINS '%'"), evaluatedWith: cell)
        waitForExpectations(timeout: 45)
        cell.tap()
        let summary = app.descendants(matching: .any).matching(identifier: "glide-gap-summary").firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 10), "the cell opened no detail")
        // The detail is live: a persisted plan shows ITS answer first, and the one for the altitude
        // just filed replaces it when the off-main assessment lands.
        expectation(for: NSPredicate(format: "label CONTAINS '8,500'"), evaluatedWith: summary)
        waitForExpectations(timeout: 45)
        XCTAssertTrue(summary.label.contains("%"), "the detail names no exposure: \(summary.label)")
    }
}
