import XCTest

/// WHERE THIS SUITE RUNS IS PART OF WHAT IT ASSERTS.
///
/// Obelisk is universal, but it is not the same app at both widths — and that is deliberate, not a
/// gap. `ConsoleView.homeArea` is `if hSize == .regular { FloatingCanvas } else { … }`, so floating
/// widgets, the docked side panes and the NRST panel DO NOT EXIST on an iPhone; `TopBar` drops the
/// bar clock at compact width after measurement showed it squeezed to 2.00pt at 375pt. A test that
/// asserts any of that on a phone is not finding a regression, it is reading the design back.
///
/// Run on an iPhone, nine of these tests failed with messages that each read like a product bug —
/// "no clock in the top bar", "left side pane did not render", "the NRST panel has no close
/// control". Every one of them passed on an iPad in the same build. The destination was the whole
/// story, and nothing in the project made a future run pick the right one.
///
/// So two things carry that now: `Tools/uitests.sh` pins the destination, and the guards below make
/// a phone run SAY SO — an XCTSkip naming the chrome and where to run it — instead of a page of red
/// that costs someone an afternoon. Both, because either alone is a thing you have to know.
///
/// The 700pt threshold is the one already used in `ConsoleUITests` and `WidgetMultiTouchUITests`;
/// this is where it lives now. Every iPad is comfortably above it in both orientations and every
/// iPhone comfortably below, so nothing rides on the exact number.
enum UITestLayout {

    /// Below this the app is laid out compact and the regular-width chrome is not built at all.
    static let regularWidthThreshold: CGFloat = 700

    /// True when the app came up at regular width (an iPad, full screen).
    static func isRegularWidth(_ app: XCUIApplication) -> Bool {
        app.windows.firstMatch.frame.width >= regularWidthThreshold
    }

    /// Skip — with the reason and the remedy — unless this is a regular-width layout.
    ///
    /// `what` names the chrome under test, so the skip reads as a sentence about THIS test rather
    /// than a generic "wrong device": "The bar clock (Zulu readout) is regular-width (iPad) chrome…".
    static func requireRegularWidth(_ app: XCUIApplication, _ what: String,
                                    file: StaticString = #filePath, line: UInt = #line) throws {
        guard !isRegularWidth(app) else { return }
        let w = app.windows.firstMatch.frame.width
        throw XCTSkip("\(what) is regular-width (iPad) chrome — the app does not build it at "
                      + "compact width, so there is nothing here to assert. This window is \(Int(w))pt "
                      + "wide. Run the UI suite on an iPad: `bash Tools/uitests.sh` (see ios/README.md).",
                      file: file, line: line)
    }
}
