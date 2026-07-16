import XCTest
@testable import ATCTranscribe

/// Pure logic behind the Plates tab: runway extraction/sort for the collapsible approach groups, and the
/// "nearest airport with plates" position default that unsticks the tab from a far-away filed destination.
final class PlatesTabViewTests: XCTestCase {

    // MARK: runway parsing

    func testRunwayExtractedFromApproachName() {
        XCTAssertEqual(PlatesTabView.runway(of: "ILS OR LOC RWY 04R"), "04R")
        XCTAssertEqual(PlatesTabView.runway(of: "RNAV (GPS) RWY 22L"), "22L")
        XCTAssertEqual(PlatesTabView.runway(of: "VOR RWY 15"), "15")
        XCTAssertEqual(PlatesTabView.runway(of: "RNAV (GPS) Z RWY 33L"), "33L")
        XCTAssertEqual(PlatesTabView.runway(of: "ILS RWY 4R"), "4R")          // single-digit runway
    }

    func testCirclingApproachesHaveNoRunway() {
        XCTAssertNil(PlatesTabView.runway(of: "VOR-A"))                       // circling-only
        XCTAssertNil(PlatesTabView.runway(of: "RNAV (GPS)-B"))
        XCTAssertNil(PlatesTabView.runway(of: "LDA-C"))
    }

    func testRunwaySortIsNumericWithSideOrderAndCirclingLast() {
        // 04 < 15 < 22, and within a number L < C < R.
        XCTAssertLessThan(PlatesTabView.runwaySortKey("04R"), PlatesTabView.runwaySortKey("15R"))
        XCTAssertLessThan(PlatesTabView.runwaySortKey("04L"), PlatesTabView.runwaySortKey("04C"))
        XCTAssertLessThan(PlatesTabView.runwaySortKey("04C"), PlatesTabView.runwaySortKey("04R"))
        // "Circling / other" sorts after any real runway.
        XCTAssertGreaterThan(PlatesTabView.runwaySortKey("Circling / other"), PlatesTabView.runwaySortKey("28R"))
    }

    // MARK: nearest-airport default

    func testNearestPlateAirportSnapsToTheFieldYouAreOver() {
        // Sitting on Boston Logan → the nearest plate-publishing airport is KBOS itself.
        XCTAssertEqual(PlatesTabView.nearestPlateAirport(lat: 42.3656, lon: -71.0096), "KBOS")
    }

    func testNearestPlateAirportIsNilFarFromAnyField() {
        // Mid-North-Atlantic — nothing within range.
        XCTAssertNil(PlatesTabView.nearestPlateAirport(lat: 35.0, lon: -45.0))
    }
}
