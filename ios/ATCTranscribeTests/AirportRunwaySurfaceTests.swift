import XCTest
@testable import ATCTranscribe

/// What the airport symbol draws, asserted against the SHIPPED apt.sqlite rather than fixtures — the
/// chart symbol is a claim about where an aircraft can land, so the claim has to hold on real data.
final class AirportRunwaySurfaceTests: XCTestCase {

    /// The reported case. KTCS publishes five runways and four of them are gravel; the symbol drew all
    /// five, which said "five ways to land here" about a field with one paved runway.
    func testKTCSDrawsOnlyItsOnePavedRunway() {
        let all = AirportData.runways(airport: "KTCS")
        XCTAssertGreaterThan(all.count, 1, "KTCS is only interesting because it publishes several")
        XCTAssertEqual(AirportSymbolData.runways("KTCS").count, 1,
                       "only 13/31 is asphalt; the rest are gravel")
    }

    /// …while a fully paved field is unchanged.
    func testAFullyPavedFieldKeepsEveryRunway() {
        let drawn = AirportSymbolData.runways("KDFW")
        XCTAssertEqual(drawn.count, AirportData.runways(airport: "KDFW").filter { !$0.isHelipad }.count)
        XCTAssertGreaterThanOrEqual(drawn.count, 7, "DFW has seven paved runways")
    }

    /// A hyphenated NASR surface is PRIMARY-first, so the order carries the meaning.
    func testTheFirstSurfaceComponentDecides() {
        func rw(_ s: String) -> AirportData.Runway {
            AirportData.Runway(designator: "09/27", lengthFt: 3000, widthFt: 75, surface: s, condition: "GOOD")
        }
        XCTAssertTrue(rw("ASPH").isPaved)
        XCTAssertTrue(rw("CONC").isPaved)
        XCTAssertTrue(rw("ASPH-TURF").isPaved, "asphalt with a turf shoulder is a paved runway")
        XCTAssertFalse(rw("TURF-ASPH").isPaved, "a grass strip with some paving is not")
        XCTAssertFalse(rw("TURF").isPaved)
        XCTAssertFalse(rw("GRVL").isPaved)
        XCTAssertFalse(rw("WATER").isPaved)
        XCTAssertFalse(rw("").isPaved, "no published surface is not an assertion of pavement")
    }

    /// A helipad is published in the runway table but is not a runway; drawing one put a strip across
    /// an airport that has none. 5,140 of the paved records nationwide are pads.
    func testHelipadsAreNotDrawnAsRunways() {
        func pad(_ d: String) -> AirportData.Runway {
            AirportData.Runway(designator: d, lengthFt: 60, widthFt: 60, surface: "CONC", condition: "GOOD")
        }
        XCTAssertTrue(pad("H1").isHelipad)
        XCTAssertTrue(pad("H2").isHelipad)
        XCTAssertNil(pad("H1").bearingDeg, "a pad has no runway heading")
        XCTAssertFalse(pad("09/27").isHelipad)
    }

    /// Bearing comes from the runway NUMBER, which every real runway has — the published true alignment
    /// is only on 32% of ends.
    func testBearingComesFromTheRunwayNumber() {
        func rw(_ d: String) -> AirportData.Runway {
            AirportData.Runway(designator: d, lengthFt: 3000, widthFt: 75, surface: "ASPH", condition: "")
        }
        XCTAssertEqual(rw("04L/22R").bearingDeg, 40)
        XCTAssertEqual(rw("36/18").bearingDeg, 360)
        XCTAssertEqual(rw("09/27").bearingDeg, 90)
        XCTAssertNil(rw("N/S").bearingDeg, "a compass-named turf strip carries no runway number")
        XCTAssertNil(rw("").bearingDeg)
        XCTAssertNil(rw("99/12").bearingDeg, "99 is not a runway")
    }

    /// An out-of-service runway is still published; it must not be offered as somewhere to land.
    func testFailedRunwaysAreNotDrawn() {
        let failed = AirportData.Runway(designator: "09/27", lengthFt: 3000, widthFt: 75,
                                        surface: "ASPH", condition: "FAILED")
        XCTAssertTrue(failed.isFailed)
        XCTAssertTrue(failed.isPaved, "it is paved — it is just not usable")
    }

    /// The surface flag driving the symbol's SHAPE now comes from the published surface rather than the
    /// approximation derived from aviationweather.gov when NASR was unavailable.
    func testHardSurfaceIsReadFromThePublishedSurface() {
        XCTAssertEqual(AirportSymbolData.hardSurface("KDFW"), true)
        XCTAssertEqual(AirportSymbolData.hardSurface("KTCS"), true, "one asphalt runway makes it hard-surfaced")
        XCTAssertNil(AirportSymbolData.hardSurface("ZZZZ"), "silence is not an assertion of soft surface")
    }
}
