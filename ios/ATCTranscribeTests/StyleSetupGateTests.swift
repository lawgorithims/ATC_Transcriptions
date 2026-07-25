import XCTest
@testable import ATCTranscribe

/// The map builds its overlay layers into a MapLibre style, and runtime layers do NOT survive a style
/// swap. This gate decides when to (re)build them.
///
/// The bug it exists to prevent: the map comes up on MapLibre's own default style and only switches to
/// the app's once the loopback tile server binds a port. Configuring "once per coordinator" meant every
/// overlay — ownship, route, traffic, airspace, airways, and the airport symbology — was built into the
/// throwaway style, and the real style came up carrying the chart raster and nothing else.
final class StyleSetupGateTests: XCTestCase {

    private final class FakeStyle {}

    func testTheFirstStyleIsConfigured() {
        var gate = MapLibreChartView.Coordinator.StyleSetupGate()
        XCTAssertTrue(gate.shouldConfigure(FakeStyle()))
    }

    func testTheSAMEStyleIsNotConfiguredTwice() {
        var gate = MapLibreChartView.Coordinator.StyleSetupGate()
        let style = FakeStyle()
        XCTAssertTrue(gate.shouldConfigure(style))
        XCTAssertFalse(gate.shouldConfigure(style), "didFinishLoading re-firing must not rebuild the layers")
        XCTAssertFalse(gate.shouldConfigure(style))
    }

    /// The regression: a DIFFERENT style must be configured, or the pilot loses every overlay.
    func testANewStyleIsConfiguredAgain() {
        var gate = MapLibreChartView.Coordinator.StyleSetupGate()
        let defaultStyle = FakeStyle()
        XCTAssertTrue(gate.shouldConfigure(defaultStyle))
        let realStyle = FakeStyle()
        XCTAssertTrue(gate.shouldConfigure(realStyle),
                      "the app's own style must get the overlays — this is the bug that hid the whole map layer stack")
        XCTAssertFalse(gate.shouldConfigure(realStyle), "…and then settle")
    }

    func testStyleSwapsBackAndForthAreEachConfigured() {
        var gate = MapLibreChartView.Coordinator.StyleSetupGate()
        let a = FakeStyle(), b = FakeStyle()
        XCTAssertTrue(gate.shouldConfigure(a))
        XCTAssertTrue(gate.shouldConfigure(b))
        XCTAssertTrue(gate.shouldConfigure(a), "swapping back is still a different style object than the last one seen")
    }
}
