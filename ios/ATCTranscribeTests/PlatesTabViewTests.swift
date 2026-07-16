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

    // MARK: movement-gate distance

    func testDistanceNMIsZeroForSamePointAndScalesWithLatitude() {
        let kbos = Coord(lat: 42.3656, lon: -71.0096)
        XCTAssertEqual(PlatesTabView.distanceNM(kbos, kbos), 0, accuracy: 1e-9)
        // 1° of latitude ≈ 60 NM anywhere.
        XCTAssertEqual(PlatesTabView.distanceNM(Coord(lat: 42, lon: -71), Coord(lat: 43, lon: -71)), 60, accuracy: 0.5)
        // 1° of longitude at ~42°N ≈ 60·cos(42°) ≈ 44.6 NM (well under a degree of latitude).
        let dLon = PlatesTabView.distanceNM(Coord(lat: 42, lon: -71), Coord(lat: 42, lon: -70))
        XCTAssertEqual(dLon, 44.6, accuracy: 1.0)
        // A ~0.2 NM jitter stays under the 0.25 NM movement gate; ~0.4 NM exceeds it.
        XCTAssertLessThan(PlatesTabView.distanceNM(kbos, Coord(lat: 42.3656 + 0.0033, lon: -71.0096)), 0.25)
        XCTAssertGreaterThan(PlatesTabView.distanceNM(kbos, Coord(lat: 42.3656 + 0.0075, lon: -71.0096)), 0.25)
    }
}
