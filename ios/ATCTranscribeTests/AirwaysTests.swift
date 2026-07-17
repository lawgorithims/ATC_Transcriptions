import XCTest
@testable import ATCTranscribe

/// The bundled enroute-airway table (CIFP ER records): geometry ordering, region queries, the coded
/// altitude band surfaced on the tap card, ARINC-area scoping, and the discontinuity/antimeridian split.
final class AirwaysTests: XCTestCase {

    func testV1GeometryIsOrderedAndGeoreferenced() throws {
        try XCTSkipUnless(Airways.available, "cifp.sqlite missing from the test bundle")
        let pts = Airways.points(of: "V1", area: "USA")
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
        // Each returned run must actually be near the box (proximity-ranked, split into runs).
        XCTAssertTrue(segs.allSatisfy { seg in
            seg.points.contains { $0.lat >= 40 && $0.lat <= 44 && $0.lon >= -74 && $0.lon <= -69 }
        })
    }

    func testAltitudeBandForAVictorAirway() throws {
        try XCTSkipUnless(Airways.available, "cifp.sqlite missing from the test bundle")
        let alt = Airways.altitudes(of: "V1", area: "USA")
        let lo = try XCTUnwrap(alt.meaLow)
        let hi = try XCTUnwrap(alt.meaHigh)
        XCTAssertTrue((500...18_000).contains(lo), "a Victor MEA is a low-altitude figure, got \(lo)")
        XCTAssertGreaterThanOrEqual(hi, lo)
        XCTAssertNotNil(alt.maa)
    }

    /// The core of the area-scoping fix: same ident in two ARINC areas is a DIFFERENT airway with its own
    /// altitudes — the East Coast V1 and the Pacific V1 must not be conflated.
    func testAltitudesAreAreaScoped() throws {
        try XCTSkipUnless(Airways.available, "cifp.sqlite missing from the test bundle")
        let usa = Airways.altitudes(of: "V1", area: "USA")
        let pac = Airways.altitudes(of: "V1", area: "PAC")
        XCTAssertNotNil(usa.meaLow); XCTAssertNotNil(pac.meaLow)
        XCTAssertNotEqual(usa.maa, pac.maa, "East Coast V1 (MAA 17,500) and Hawaii V1 (MAA 45,000) differ")
    }

    /// A designator with a revoked middle section (V210: a ~929 NM Missouri→Pennsylvania jump between
    /// consecutive fixes) must be split into separate runs, never bridged by one straight polyline.
    func testDiscontinuousAirwayIsSplit() throws {
        try XCTSkipUnless(Airways.available, "cifp.sqlite missing from the test bundle")
        let full = Airways.points(of: "V210", area: "USA")
        try XCTSkipUnless(full.count >= 2, "V210 not present in this data vintage")
        let runs = Airways.splitRuns(ident: "V210", full)
        XCTAssertGreaterThan(runs.count, 1, "V210 has a coded discontinuity and must not be one polyline")
        XCTAssertEqual(runs.reduce(0) { $0 + $1.count }, full.count, "split must preserve every point")
    }

    func testSplitRunsBreaksLongLegsAndAntimeridian() {
        // A short low-altitude chain with one implausible ~600 NM gap → two runs (Victor 250 NM cap).
        let victor = [Coord(lat: 40, lon: -100), Coord(lat: 40.5, lon: -99.5),
                      Coord(lat: 46, lon: -90)]
        XCTAssertEqual(Airways.splitRuns(ident: "V999", victor).count, 2)
        // An antimeridian crossing splits regardless of class.
        let acrossDateLine = [Coord(lat: 52, lon: 179.4), Coord(lat: 52.5, lon: -177.9)]
        XCTAssertEqual(Airways.splitRuns(ident: "G583", acrossDateLine).count, 2)
        // A clean high-altitude chain with legs under the cap stays one run.
        let jet = [Coord(lat: 40, lon: -100), Coord(lat: 41, lon: -98), Coord(lat: 42, lon: -96)]
        XCTAssertEqual(Airways.splitRuns(ident: "J80", jet).count, 1)
    }

    func testUnknownAirwayIsEmptyNotCrashing() {
        XCTAssertTrue(Airways.points(of: "ZZ99", area: "USA").isEmpty)
        let alt = Airways.altitudes(of: "ZZ99", area: "USA")
        XCTAssertNil(alt.meaLow); XCTAssertNil(alt.maa)
        XCTAssertTrue(Airways.splitRuns(ident: "ZZ99", []).isEmpty)
    }
}
