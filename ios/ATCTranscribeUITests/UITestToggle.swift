import XCTest

/// Flipping a SwiftUI `Toggle` that sits in a Form or List — and proving it flipped.
///
/// Two things go wrong, and each has cost a test run its meaning:
///
///   * THE IDENTIFIER LANDS ON THE ROW, NOT THE SWITCH. `.accessibilityIdentifier` on a `Toggle`
///     names the row-level element — 540 pt wide on the Downloads screen — whose centre is the label
///     text, while the control sits at the right edge. A plain `.tap()` reports `isHittable == true`,
///     hits the label and changes nothing; the first version of `DownloadSettingsUITests` read "the
///     switch did not take the tap" and looked exactly like a broken binding. Tapping at 0.9 of the
///     width hits the control.
///   * ONE TAP IS NOT PROOF. `DataActivityUITests` failed about 1 run in 5 on the shared simulator,
///     and 5 in 10 on a fresh one, with the bar icon reading "idle" after the test had "paused"
///     Radar. The screen recordings show the tap landing dead on the switch, on a list that had not
///     moved for three seconds, and the switch not so much as highlighting: the tap was dropped.
///     Each element lookup stalls this app ~0.45 s while it serves the accessibility snapshot, and a
///     coordinate tap makes three of them, so the drop lives somewhere in that interplay — the
///     dismissal tap a second later landed in both recordings. A test that taps once and moves on
///     then fails three assertions later, on a symptom that reads exactly like the bug under test.
///
/// So `flip` taps, WAITS FOR THE VALUE TO CHANGE, retries a bounded number of times when it does
/// not, and fails AT THE TAP — naming the switch and the value it is stuck on — if every try drops.
///
/// ⚠️ A retry is only safe because callers still check the end state. A tap that slipped onto a
/// neighbouring row flips THAT switch, which this helper cannot see, so callers assert the
/// neighbours they care about: the exact list of paused categories, the other download setting.
enum UITestToggle {
    /// Taps before giving up. In the recordings a dropped tap was followed by one that landed; three
    /// is margin, and keeps a switch that is genuinely dead failing in ~15 s rather than hanging.
    static let attempts = 3
    /// How long one tap gets to change the value. A tap that lands flips the value before XCUITest
    /// even reports the app idle; this is slack for a loaded simulator, not for a slow app.
    static let settle: TimeInterval = 3

    /// Flip `toggle` (a query for the Toggle's row element) and return once its value has changed.
    static func flip(_ toggle: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        guard toggle.waitForExistence(timeout: 10) else {
            return XCTFail("there is no switch to flip: \(toggle)", file: file, line: line)
        }
        let id = toggle.identifier
        let before = toggle.value as? String ?? ""
        guard before == "0" || before == "1" else {
            return XCTFail("\(id) reads \"\(before)\", not a switch's 0 or 1 — is this the Toggle row?",
                           file: file, line: line)
        }
        for attempt in 1...attempts {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            // A fresh expectation per try: XCTest refuses to wait on the same one twice.
            let moved = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value != %@", before), object: toggle)
            let result = XCTWaiter().wait(for: [moved], timeout: settle)
            if result == .completed { return }
            XCTAssertEqual(result, .timedOut, "waiting for \(id) to flip ended oddly", file: file, line: line)
            XCTContext.runActivity(named: "tap \(attempt) of \(attempts) on \(id) was dropped") { _ in }
        }
        XCTFail("tapped the \(id) switch \(attempts) times and it still reads \(before): every tap was "
                + "dropped, or the switch is not bound to anything", file: file, line: line)
    }
}
