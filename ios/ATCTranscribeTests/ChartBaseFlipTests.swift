import XCTest
@testable import ATCTranscribe

/// Coming BACK from the decluttered dark base.
///
/// The memory used to be written only by `toggleSmartBase` itself, so a base chosen any other way — the
/// layers menu, the route sheet's picker, the `--chart-layer` launch override — was never recorded, and
/// toggling back dropped the pilot on the sectional no matter where they had been.
@MainActor
final class ChartBaseFlipTests: XCTestCase {

    func testTogglingBackReturnsToABaseChosenInTheLayersMenu() {
        let m = AppModel()
        m.chartLayer = .ifrLow                      // as if picked in MapLayersMenu, not by the toggle
        m.toggleSmartBase()
        XCTAssertEqual(m.chartLayer, .smartDark)
        m.toggleSmartBase()
        XCTAssertEqual(m.chartLayer, .ifrLow, "came back to the wrong base — the menu pick was not recorded")
    }

    func testTheToggleIsAnInvolutionFromEveryBase() {
        for start in ChartLayer.allCases where start != .smartDark {
            let m = AppModel()
            m.chartLayer = start
            m.toggleSmartBase()
            m.toggleSmartBase()
            XCTAssertEqual(m.chartLayer, start, "round trip from \(start) did not return")
        }
    }

    func testTogglingBackNeverLandsOnDarkItself() {
        // Otherwise the control becomes a no-op: tap, nothing appears to happen, tap again, still Dark.
        let m = AppModel()
        m.chartLayer = .smartDark                   // launched straight onto Dark, nothing before it
        m.toggleSmartBase()
        XCTAssertNotEqual(m.chartLayer, .smartDark)
    }

    func testThePreviousBaseIsNotPersisted() {
        // It describes this session's glance at a chart. Restoring it from a previous flight would be a
        // claim about intent the app does not have — the same reason ActiveApproach is not persisted.
        let m = AppModel()
        m.chartLayer = .ifrHigh
        m.chartLayer = .satellite
        XCTAssertEqual(m.previousChartLayer, .ifrHigh)
        XCTAssertNil(AppModel().previousChartLayer, "a fresh session must start with no memory")
    }

    func testReassigningTheSameLayerDoesNotDestroyTheMemory() {
        // A redundant assignment (a view re-applying its binding) must not make the previous base equal
        // to the current one, which would strand the toggle.
        let m = AppModel()
        m.chartLayer = .ifrLow
        m.chartLayer = .satellite
        m.chartLayer = .satellite
        XCTAssertEqual(m.previousChartLayer, .ifrLow)
    }
}
