import XCTest
@testable import ATCTranscribe

/// Asserts against the SHIPPED apt.sqlite, not a fixture. The lesson from the CIFP rebuild — where a
/// green suite of 991 code-shape tests missed the deletion of two-thirds of the country's final
/// approach fixes — is that data needs tests of its own.
final class AirportDataTests: XCTestCase {

    func testTheDatabaseIsBundledAndStamped() {
        let p = AirportData.provenance
        XCTAssertFalse(p.cycle.isEmpty, "apt.sqlite must carry its NASR cycle")
        XCTAssertNotNil(p.effective)
        XCTAssertNotNil(p.expires)
        XCTAssertTrue(p.source.contains("NASR"))
    }

    /// The gap this database exists to fill: CIFP codes runway geometry only for airports with
    /// published instrument procedures.
    func testRunwayEndsExistForABigFieldAndASmallOne() {
        XCTAssertGreaterThanOrEqual(AirportData.runwayEnds(airport: "KDFW").count, 14,
                                    "DFW has seven runways, so fourteen ends")
        XCTAssertFalse(AirportData.runwayEnds(airport: "KEGE").isEmpty)
    }

    /// NASR keys by FAA identifier; the rest of the app speaks ICAO. Both must resolve.
    func testBothIcaoAndFaaIdentifiersResolve() {
        XCTAssertEqual(AirportData.runwayEnds(airport: "KBOS").count,
                       AirportData.runwayEnds(airport: "BOS").count)
        XCTAssertFalse(AirportData.frequencies(airport: "KBOS").isEmpty)
    }

    /// The reason the frequency table matters: SlotSnap verifies a heard frequency against the
    /// published list and abstains when it is absent, so a thin list loses verifications silently.
    func testTheFrequencyListIsDeepEnoughToVerifyAgainst() {
        let dfw = AirportData.frequencies(airport: "KDFW")
        XCTAssertGreaterThan(dfw.count, 100, "the community data had seven; NASR carries 211")
        XCTAssertTrue(dfw.contains { !$0.sectorization.isEmpty }, "sectorization must survive ingest")
        XCTAssertTrue(dfw.contains { !$0.use.isEmpty }, "the use tag must survive ingest")
        let values = AirportData.frequencyValues(airport: "KDFW")
        XCTAssertEqual(values.count, Set(values).count, "the corrector's list must be deduped")
    }

    func testRunwayEndGeometryIsPlausible() {
        for e in AirportData.runwayEnds(airport: "KDFW") {
            if let c = e.coord {
                XCTAssertTrue((32...34).contains(c.lat), "\(e.end) is not near DFW")
                XCTAssertTrue((-98...(-96)).contains(c.lon), "\(e.end) is not near DFW")
            }
            if let a = e.trueAlignmentDeg { XCTAssertTrue((0...360).contains(a)) }
        }
    }

    /// Absent must stay absent. NASR publishes declared distances on only ~7% of runway ends and TDZE
    /// on ~28%, so a zero here would be a fabricated measurement, not a missing one.
    func testUnpublishedFieldsAreNilRatherThanZero() {
        let ends = AirportData.runwayEnds(airport: "KDFW") + AirportData.runwayEnds(airport: "KEGE")
        XCTAssertFalse(ends.isEmpty)
        for e in ends {
            if let t = e.touchdownZoneElevationFt { XCTAssertNotEqual(t, 0, "0 ft TDZE is sea level, not unknown") }
            if let d = e.displacedThresholdFt { XCTAssertGreaterThan(d, 0) }
        }
    }

    func testAnUnknownAirportIsEmptyNotACrash() {
        XCTAssertTrue(AirportData.runwayEnds(airport: "ZZZZ").isEmpty)
        XCTAssertTrue(AirportData.frequencies(airport: "").isEmpty)
    }
}
