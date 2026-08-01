import XCTest
@testable import ATCTranscribe

/// The approach brief (item 33) and the departure essentials (item 46).
///
/// The governing constraint is coverage. Measured over the 5,983 runway ends that have an instrument
/// approach: touchdown-zone elevation and runway length are published on 100%, edge lights on 99.1%,
/// a visual glideslope on 87.8% — but APPROACH lights on only 20.3%. So the brief must omit what is
/// absent rather than print a dash, which would read as "none installed".
final class ApproachBriefTests: XCTestCase {

    private func brief(alt: String = "MALSR", vgsi: String = "P4L", tdze: Double? = 120,
                       len: Double? = 7000, minimum: ApproachBrief.Minimum? = nil) -> ApproachBrief {
        ApproachBrief(inboundCourseMag: nil, minimum: minimum, runway: "04R",
                      runwayLengthFt: len, touchdownZoneElevFt: tdze,
                      approachLights: alt, vgsi: vgsi, edgeLights: "HIGH", vgsiAngleDeg: 3.00)
    }

    // MARK: absence is absence

    func testAnEmptyBriefIsNotShown() {
        let b = ApproachBrief(inboundCourseMag: nil, minimum: nil, runway: "04R", runwayLengthFt: nil,
                              touchdownZoneElevFt: nil, approachLights: "", vgsi: "", edgeLights: "", vgsiAngleDeg: nil)
        XCTAssertFalse(b.hasContent, "a brief with only a runway number is not a brief")
    }

    func testARunwayWithNoApproachLightsStillHasABrief() {
        // Four in five approach runway ends publish no approach-lighting code; the brief must still be
        // worth showing from length, TDZE and the visual glideslope.
        XCTAssertTrue(brief(alt: "").hasContent)
    }

    // MARK: the acronyms are decoded, or shown raw — never guessed

    func testVGSICodesDecode() {
        XCTAssertEqual(ApproachBrief.decodeVGSI("P4L"), "PAPI, 4 boxes on the left")
        XCTAssertEqual(ApproachBrief.decodeVGSI("P2R"), "PAPI, 2 boxes on the right")
        XCTAssertEqual(ApproachBrief.decodeVGSI("V4L"), "VASI, 4 boxes on the left")
    }

    func testANonStandardInstallationIsNotExpanded() {
        // NSTD means the installation does NOT follow the usual pattern — expanding it into a confident
        // sentence would describe something the pilot will not see.
        XCTAssertNil(ApproachBrief.decodeVGSI("NSTD"))
        XCTAssertNil(ApproachBrief.decodeApproachLights("NSTD"))
    }

    func testAnUnknownCodeYieldsNilSoTheRawAcronymShows() {
        XCTAssertNil(ApproachBrief.decodeVGSI("ZZZ"))
        XCTAssertNil(ApproachBrief.decodeApproachLights("ZZZ"))
    }

    func testTheCommonApproachLightSystemsAreNamed() {
        // MALSR (860) and ALSF-2 (184) dominate the table; every code that appears should decode.
        for code in ["MALSR", "ALSF2", "ALSF1", "ODALS", "MALSF", "MALS", "SSALR", "SSALS", "SALS",
                     "SALSF", "SSALF", "ALSAF", "RLLS"] {
            XCTAssertNotNil(ApproachBrief.decodeApproachLights(code), "\(code) is in the data undecoded")
        }
    }

    // MARK: the height above touchdown

    func testHeightAboveTouchdownIsDerivedWhenBothAreKnown() {
        let m = ApproachBrief.Minimum(category: .a, altitudeFtMSL: 320, isDecisionAltitude: true,
                                      lineLabel: "LPV")
        XCTAssertEqual(brief(tdze: 120, minimum: m).heightAboveTouchdownFt, 200)
    }

    func testAnImplausiblePairingStatesNothing() {
        // If the minimum and the touchdown elevation do not belong together the difference is nonsense;
        // saying nothing beats printing a confident wrong height.
        let m = ApproachBrief.Minimum(category: .a, altitudeFtMSL: 100, isDecisionAltitude: true,
                                      lineLabel: "LPV")
        XCTAssertNil(brief(tdze: 5000, minimum: m).heightAboveTouchdownFt, "negative height")
        XCTAssertNil(brief(tdze: -9000, minimum: m).heightAboveTouchdownFt, "absurd height")
    }

    func testNoMinimumMeansNoHeight() {
        XCTAssertNil(brief(minimum: nil).heightAboveTouchdownFt)
    }

    func testTheMinimumCarriesItsCategory() {
        // A published minimum is per approach category and the app does not know the pilot's, so the
        // value must never travel without the category it belongs to.
        let m = ApproachBrief.Minimum(category: .c, altitudeFtMSL: 460, isDecisionAltitude: false,
                                      lineLabel: "LNAV")
        XCTAssertEqual(brief(minimum: m).minimum?.category, .c)
        XCTAssertFalse(m.isDecisionAltitude, "an LNAV line is levelled at, not descended through")
    }

    // MARK: item 46 — the departure essentials exist in the data

    func testTheDepartureChartsAreFindableByCodeAndName() throws {
        try XCTSkipIf(Procedures.airportCount == 0, "procedures.json not present")
        // An ODP is chart code ODP; takeoff minimums are a MIN chart whose NAME carries "TAKEOFF".
        // Matching on the code alone finds one and misses the other.
        var withEither = 0
        for apt in ["KBOS", "KDEN", "KSEA", "KAUS"] {
            let all = Procedures.forAirport(apt)
            let odp = all.first { $0.code == "ODP" }
            let tko = all.first { $0.code == "MIN" && $0.name.uppercased().contains("TAKEOFF") }
            if odp != nil || tko != nil { withEither += 1 }
        }
        XCTAssertGreaterThan(withEither, 0, "these fields should publish departure charts")
    }
}
