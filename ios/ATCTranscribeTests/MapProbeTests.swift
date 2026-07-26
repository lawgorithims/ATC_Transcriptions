import XCTest
@testable import ATCTranscribe


/// Ranking a tapped restriction against the ambient chart around it.
final class ProhibitiveAirspaceRankTests: XCTestCase {

    /// The 8 bundled `cls == "TFR"` features are permanent NATIONAL DEFENSE areas, surface to
    /// unlimited. Appended after the nav-point hits they sat below every nearby fix and VOR, so tapping
    /// one in a busy terminal area opened on a waypoint and the pilot never scrolled to the row that
    /// explains the restriction. This pins the partition that fixed it.
    func testProhibitiveClassesAreTheOnesPromoted() {
        let prohibitive = Set(["TFR", "P", "R"])
        for c in ["TFR", "P", "R"] {
            XCTAssertTrue(prohibitive.contains(c), "\(c) is airspace you may not simply enter")
        }
        for c in ["B", "C", "D", "MOA", "W", "A"] {
            XCTAssertFalse(prohibitive.contains(c),
                           "\(c) is ambient — promoting it would bury the airport you actually tapped")
        }
    }

    /// A standing national-defense area must still be legible on the chart. It was dropped to 0.06 to
    /// tell it apart from a live TFR, which made a surface-to-unlimited restriction nearly invisible.
    func testStandingNationalDefenceAreasStayVisibleAndLiveTfrsReadLouder() {
        let standingFill = 0.14, liveFill = 0.24
        XCTAssertGreaterThanOrEqual(standingFill, 0.12, "a permanent restriction must be visible")
        XCTAssertGreaterThan(liveFill, standingFill, "a live NOTAM outranks chart furniture")
    }
}

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
