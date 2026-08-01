import XCTest
@testable import ATCTranscribe

/// Items 30, 32, 43 and 18.
final class BuildableItemsTests: XCTestCase {

    // MARK: item 30 — the visual glideslope angle, read off the plate

    func testTheVGSIAngleIsReadFromThePlateText() {
        XCTAssertEqual(ApproachBrief.parseVGSIAngle(fromPlateText: "PAPI 3.00 TCH 55"), 3.00)
        XCTAssertEqual(ApproachBrief.parseVGSIAngle(fromPlateText: "VASI 4.00"), 4.00)
        XCTAssertEqual(ApproachBrief.parseVGSIAngle(fromPlateText: "VGSI and descent angles NA 3.50"), 3.50)
    }

    func testANumberFarFromTheSystemNameIsNotTakenAsTheAngle() {
        // A bare "3.00" on a plate is more likely a glideslope, a course or a distance. The angle must
        // sit near the system it belongs to.
        let far = "PAPI" + String(repeating: " ", count: 90) + "3.00"
        XCTAssertNil(ApproachBrief.parseVGSIAngle(fromPlateText: far))
    }

    func testAnImplausibleAngleIsRefused() {
        XCTAssertNil(ApproachBrief.parseVGSIAngle(fromPlateText: "PAPI 9.99"))
        XCTAssertNil(ApproachBrief.parseVGSIAngle(fromPlateText: "PAPI 1.00"))
    }

    func testNoSystemMeansNoAngle() {
        XCTAssertNil(ApproachBrief.parseVGSIAngle(fromPlateText: "GS 3.00 TCH 55"))
        XCTAssertNil(ApproachBrief.parseVGSIAngle(fromPlateText: ""))
    }

    func testADisagreementIsOnlyReportedWhenItMatters() {
        // THE case: a 3.00 VDA flown into a 4.00 PAPI puts the aircraft low on the visual segment.
        XCTAssertEqual(ApproachBrief.vgsiDisagreement(codedAngleDeg: 3.00, vgsiAngleDeg: 4.00) ?? 0,
                       1.00, accuracy: 0.001)
        XCTAssertNil(ApproachBrief.vgsiDisagreement(codedAngleDeg: 3.00, vgsiAngleDeg: 3.00))
        XCTAssertNil(ApproachBrief.vgsiDisagreement(codedAngleDeg: 3.00, vgsiAngleDeg: 3.20),
                     "a fifth of a degree is not a cross-check failure")
    }

    func testAnUnknownAngleIsSilenceNotAgreement() {
        XCTAssertNil(ApproachBrief.vgsiDisagreement(codedAngleDeg: 3.00, vgsiAngleDeg: nil))
        XCTAssertNil(ApproachBrief.vgsiDisagreement(codedAngleDeg: nil, vgsiAngleDeg: 4.00))
    }

    // MARK: item 43 — the lighting layouts

    func testTheALSFSignatureIsItsRedSideRows() {
        XCTAssertEqual(ApproachLightingView.layout(for: "ALSF2")?.hasRedSideRows, true)
        XCTAssertEqual(ApproachLightingView.layout(for: "ALSF1")?.hasRedSideRows, true)
        XCTAssertEqual(ApproachLightingView.layout(for: "MALSR")?.hasRedSideRows, false)
    }

    func testODALSIsFlashersWithNoBars() {
        let l = ApproachLightingView.layout(for: "ODALS")
        XCTAssertEqual(l?.isOmnidirectional, true)
        XCTAssertEqual(l?.bars, 0, "drawing bars would show a system that is not installed")
        XCTAssertEqual(l?.hasFlashers, true)
    }

    func testTheFlasherDistinctionIsKept() {
        // MALSR has the rabbit, MALS does not — that is the whole difference between the two codes.
        XCTAssertEqual(ApproachLightingView.layout(for: "MALSR")?.hasFlashers, true)
        XCTAssertEqual(ApproachLightingView.layout(for: "MALS")?.hasFlashers, false)
    }

    func testANonStandardInstallationIsNotDrawn() {
        // NSTD means it does NOT follow the pattern, so there is no standard picture to draw.
        XCTAssertNil(ApproachLightingView.layout(for: "NSTD"))
        XCTAssertNil(ApproachLightingView.layout(for: "ZZZ"))
    }

    func testEveryDrawableCodeAlsoDecodesToText() {
        // The caller falls back to text when there is no drawing; the reverse gap would leave a picture
        // with no accessible label.
        for code in ["ALSF1", "ALSF2", "MALSR", "MALSF", "MALS", "SSALR", "SSALS", "SSALF",
                     "SALS", "SALSF", "ALSAF", "ODALS"] {
            XCTAssertNotNil(ApproachLightingView.layout(for: code), "\(code) has no layout")
            XCTAssertNotNil(ApproachBrief.decodeApproachLights(code), "\(code) has no spoken name")
        }
    }

    // MARK: item 32 — NA annotations only where a position exists

    private func profile(fafNm: Double) -> ApproachProfile {
        let legs = [
            CIFPLeg(seq: 10, fix: "FAFIX", coord: Coord(lat: 42.0 + fafNm / 60, lon: -71.0),
                    legType: "TF", course: nil, altitude: "02000", wpDesc: "   F", altDesc: "+"),
            CIFPLeg(seq: 20, fix: "RW04", coord: nil, legType: "TF", course: nil, altitude: "00250",
                    wpDesc: "   M", altDesc: "", verticalAngleDeg: -3.0),
        ]
        return ApproachProfile.build(legs: legs, threshold: Coord(lat: 42.0, lon: -71.0),
                                     thresholdElevFt: 200, airport: "KTST",
                                     approachName: "RNAV (GPS) RWY 04", codedRunway: "04")
    }

    func testTheBaroVNAVLimitAnnotatesAtTheFinalApproachFix() {
        let a = profile(fafNm: 5).naAnnotations(temperatureC: -20, baroVNAVLimitC: -15)
        XCTAssertEqual(a.count, 1)
        XCTAssertTrue(a.first?.text.contains("LNAV/VNAV NA") ?? false)
        XCTAssertGreaterThan(a.first?.atNm ?? 0, 0, "the annotation must sit at a real distance")
    }

    func testNothingIsAnnotatedWhenTheTemperatureIsUnknown() {
        // An unknown temperature must not produce a warning "in case" — that is a claim the data does
        // not support, and the pilot cannot tell it apart from a real one.
        XCTAssertTrue(profile(fafNm: 5).naAnnotations(temperatureC: nil, baroVNAVLimitC: -15).isEmpty)
    }

    func testNothingIsAnnotatedAboveTheLimit() {
        XCTAssertTrue(profile(fafNm: 5).naAnnotations(temperatureC: 5, baroVNAVLimitC: -15).isEmpty)
    }

    func testNothingIsAnnotatedWithNoPublishedLimit() {
        XCTAssertTrue(profile(fafNm: 5).naAnnotations(temperatureC: -30, baroVNAVLimitC: nil).isEmpty)
    }
}
