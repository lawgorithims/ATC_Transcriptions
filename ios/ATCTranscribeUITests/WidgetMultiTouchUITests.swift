import XCTest

/// The two-finger MOVE + pinch RESIZE additions must NOT break the existing single-finger widget drag.
/// This is the regression guard: a single-finger drag of a widget's header still relocates the card
/// (the two-finger recognizers are two-finger-only + never cancel touches, so single-finger passes
/// through). The two-finger gestures themselves can't be driven by XCUITest — it can't synthesize a
/// two-finger pan, and its synthesized pinch doesn't reach SwiftUI's MagnificationGesture — so they're
/// verified by construction (window-attached pan + native magnify) and on-device.
final class WidgetMultiTouchUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    private func isRegularWidth(_ app: XCUIApplication) -> Bool { app.windows.firstMatch.frame.width >= 700 }

    /// The proof-of-life widget's header title carries the `widget-header-proofOfLife` id (SwiftUI
    /// propagates the container id to its label); it's the drag handle for the whole card.
    private func header(_ app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(identifier: "widget-header-proofOfLife").firstMatch
    }

    func testSingleFingerDragStillMovesWidget() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-atc.onboardingDismissed", "YES", "--reset-widgets"]
        app.launch()

        let h = header(app)
        try XCTSkipUnless(h.waitForExistence(timeout: 8) && isRegularWidth(app),
                          "Floating widgets are iPad/regular-width only")

        let before = h.frame
        // Single-finger press-drag toward the screen centre. The two-finger recognizers must NOT claim a
        // one-finger touch, so this falls through to the SwiftUI header drag and relocates the card.
        let start = h.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let target = app.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.45))
        start.press(forDuration: 0.15, thenDragTo: target)

        let after = h.frame
        let moved = abs(after.minX - before.minX) + abs(after.minY - before.minY)
        XCTAssertGreaterThan(moved, 40, "single-finger drag no longer moves the widget — a two-finger recognizer is blocking it")
    }
}
