import XCTest
@testable import ATCTranscribe

/// The bundled enroute-airway table (CIFP ER records): geometry ordering, region queries, and the coded
/// altitude band surfaced on the tap card.
final class AirwaysTests: XCTestCase {

    func testV1GeometryIsOrderedAndGeoreferenced() throws {
        try XCTSkipUnless(Airways.available, "cifp.sqlite missing from the test bundle")
        let pts = Airways.points(of: "V1")
        XCTAssertGreaterThan(pts.count, 10, "V1 should trace the east coast with dozens of fixes")
        // Northbound overall: the last fix is well north of the first (Florida → New England).
        XCTAssertGreaterThan(pts.last!.lat, pts.first!.lat + 5)
    }

    func testRegionQueryFindsAirwaysNearBoston() throws {
        try XCTSkipUnless(Airways.available, "cifp.sqlite missing from the test bundle")
        let box = BBox(minLat: 41.5, minLon: -72.5, maxLat: 43.0, maxLon: -70.0)
        let segs = Airways.inRegion(box)
        XCTAssertFalse(segs.isEmpty, "the Boston area is criss-crossed with airways")
        XCTAssertTrue(segs.allSatisfy { $0.points.count >= 2 })
    }

    func testAltitudeBandForAVictorAirway() throws {
        try XCTSkipUnless(Airways.available, "cifp.sqlite missing from the test bundle")
        let alt = Airways.altitudes(of: "V1")
        let lo = try XCTUnwrap(alt.meaLow)
        let hi = try XCTUnwrap(alt.meaHigh)
        XCTAssertTrue((500...18_000).contains(lo), "a Victor MEA is a low-altitude figure, got \(lo)")
        XCTAssertGreaterThanOrEqual(hi, lo)
        XCTAssertNotNil(alt.maa)
    }

    func testUnknownAirwayIsEmptyNotCrashing() {
        XCTAssertTrue(Airways.points(of: "ZZ99").isEmpty)
        let alt = Airways.altitudes(of: "ZZ99")
        XCTAssertNil(alt.meaLow); XCTAssertNil(alt.maa)
    }
}
