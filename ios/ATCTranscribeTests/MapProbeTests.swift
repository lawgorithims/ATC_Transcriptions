import XCTest
@testable import ATCTranscribe


/// Chart labels for airspace you may not simply enter.
final class RestrictionTagTests: XCTestCase {
    func testStandingNationalDefenceAreasSayWhatTheyAre() {
        XCTAssertEqual(MapLibreChartView.Coordinator.restrictionTag(
            cls: "TFR", name: "DALLAS NATIONAL DEFENSE AIRSPACE TFR"), "NAT'L DEFENSE",
            "the published name ends in TFR, which is the one word that makes a pilot expect a live NOTAM")
    }
    func testProhibitedAndRestrictedAreasUseTheirDesignator() {
        XCTAssertEqual(MapLibreChartView.Coordinator.restrictionTag(cls: "P", name: "P-40 CAMP DAVID"), "P-40")
        XCTAssertEqual(MapLibreChartView.Coordinator.restrictionTag(cls: "R", name: "R-2301 W"), "R-2301")
        XCTAssertEqual(MapLibreChartView.Coordinator.restrictionTag(cls: "P", name: "SOMETHING ELSE"), "PROHIBITED")
    }
    func testAmbientClassesGetNoTag() {
        for c in ["B", "C", "D", "MOA", "W", "A"] {
            XCTAssertEqual(MapLibreChartView.Coordinator.restrictionTag(cls: c, name: "X"), "",
                           "\(c) is ambient — a tag on every one would clutter the chart")
        }
    }
}
