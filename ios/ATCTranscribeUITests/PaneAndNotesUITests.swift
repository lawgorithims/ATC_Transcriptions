import XCTest

/// The interactive paths for the two new features — side-pane controls and the Notes editor — that a
/// screenshot can't prove: a docked pane pops back out / closes from its buttons, and the Notes tab
/// opens the drawing editor and returns to the library.
final class PaneAndNotesUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    private func launch(_ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-atc.onboardingDismissed", "YES", "--reset-widgets"] + extra
        app.launch()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow While Using App"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        return app
    }

    // ⚠️ DOCK A WIDGET THAT EXISTS IN BOTH BUILDS. This docked `transcript` and `stratux`, both
    // transcription furniture, and the EFB-only build guards `--dock-left`/`--dock-right` against
    // hidden kinds (FloatingWidget.swift) — so the pane correctly refused to render and the failure
    // read "left side pane did not render", which looks like a pane regression and is not one. The
    // subject is the pane's popout/close mechanics; `.gps` and `.nrst` exercise them identically.
    func testDockedPanePopsOutThenCloses() {
        let app = launch(["--dock-left", "gps"])
        let popout = app.buttons["pane-popout-left"]
        XCTAssertTrue(popout.waitForExistence(timeout: 10), "left side pane did not render")
        // ↗ pops it back to a floating widget → the pane (and its buttons) disappear.
        popout.tap()
        XCTAssertTrue(waitGone(popout, timeout: 5), "pane did not pop out to a floating widget")

        // Re-dock (relaunch) and this time close it with the ✕.
        let app2 = launch(["--dock-right", "nrst"])
        let close = app2.buttons["pane-close-right"]
        XCTAssertTrue(close.waitForExistence(timeout: 10), "right side pane did not render")
        close.tap()
        XCTAssertTrue(waitGone(close, timeout: 5), "pane did not close from the ✕")
    }

    func testNotesEditorOpensAndReturns() {
        let app = launch(["--start-tab", "notes"])
        let newNote = app.buttons["notes-new"]
        XCTAssertTrue(newNote.waitForExistence(timeout: 10), "Notes tab did not render")
        newNote.tap()
        // The editor's Done control proves the canvas editor opened.
        let done = app.buttons["notes-done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5), "note editor did not open")
        // Back with an empty canvas discards and returns to the library.
        app.buttons["notes-back"].tap()
        XCTAssertTrue(newNote.waitForExistence(timeout: 5), "did not return to the notes library")
    }

    private func waitGone(_ el: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline { if !el.exists { return true }; usleep(200_000) }
        return !el.exists
    }
}
