import XCTest
@testable import ATCTranscribe

/// The vertical-profile engine: the three primitives, the DA-vs-MDA branch, and the refusals.
///
/// The worked example is the one from the FAA's own description of the geometry, so the arithmetic is
/// checked against a number a pilot can verify by hand rather than against whatever this implementation
/// happens to produce.
final class ApproachProfileTests: XCTestCase {

    /// Threshold elevation 1,200 ft, TCH 55 ft (crossing 1,255), 3.00° path.
    private func worked() -> ApproachProfile {
        ApproachProfile(stations: [
            .init(fix: "FAFXX", distanceToThresholdNm: 6.2,
                  constraint: LegConstraint(altDesc: "+", alt: "03300", alt2: "", speedLimitKt: nil,
                                            verticalAngleDeg: nil, rnpNm: nil),
                  role: .finalApproachFix),
            .init(fix: "RW34", distanceToThresholdNm: 0,
                  constraint: LegConstraint(altDesc: "", alt: "01255", alt2: "", speedLimitKt: nil,
                                            verticalAngleDeg: -3.0, rnpNm: nil),
                  role: .missedApproachPoint),
        ], descentAngleDeg: 3.0, thresholdCrossingAltFt: 1255, thresholdElevFt: 1200,
           airport: "KTST", approachName: "ILS RWY 34", hasVerticalGuidance: true, outerCoord: nil)
    }

    /// Path altitude at the FAF lands just BELOW the published minimum — which is the correct picture:
    /// the aircraft arrives level at 3,300 and intercepts the glidepath from beneath shortly after.
    func testPathAltitudeAtTheFAF() throws {
        let p = worked()
        let alt = try XCTUnwrap(p.pathAltitudeFt(atNm: 6.2))
        XCTAssertEqual(alt, 3230, accuracy: 8,
                       "1255 + 6.2 NM x 6076.115 x tan(3deg) is about 3,230 ft")
        XCTAssertLessThan(alt, 3300,
                          "the path passes UNDER the FAF minimum — that is why you intercept from below")
    }

    /// Distance for a given altitude is the inverse of the same line.
    func testDistanceForAnAltitudeIsTheInverse() throws {
        let p = worked()
        let d = try XCTUnwrap(p.distanceNm(forAltitudeFt: 1400))
        XCTAssertEqual(d, 0.455, accuracy: 0.02, "(1400-1255)/tan(3deg) is about 2,767 ft, i.e. 0.46 NM")
        let back = try XCTUnwrap(p.pathAltitudeFt(atNm: d))
        XCTAssertEqual(back, 1400, accuracy: 1, "the two primitives must invert each other exactly")
    }

    /// Below the threshold crossing altitude there is no path left to be on, so this refuses rather than
    /// returning a negative distance the caller would happily plot off the end of the runway.
    func testDistanceRefusesBelowTheCrossingAltitude() {
        XCTAssertNil(worked().distanceNm(forAltitudeFt: 1200))
        XCTAssertNil(worked().distanceNm(forAltitudeFt: 1255))
    }

    /// The rate-of-descent table on the chart's inside cover: 120 kt on 3° is ~640 fpm (the "GS x 5"
    /// rule of thumb gives 600).
    func testRequiredVerticalSpeed() throws {
        let fpm = try XCTUnwrap(worked().requiredVerticalSpeedFpm(groundSpeedKt: 120))
        XCTAssertEqual(fpm, 637, accuracy: 8)
        XCTAssertNil(worked().requiredVerticalSpeedFpm(groundSpeedKt: 0), "no groundspeed, no rate")
    }

    /// Deviation is signed the way a pilot reads it: positive is HIGH.
    func testDeviationSign() throws {
        let p = worked()
        let onPath = try XCTUnwrap(p.pathAltitudeFt(atNm: 4))
        XCTAssertEqual(try XCTUnwrap(p.deviationFt(altitudeFtMSL: onPath + 200, atNm: 4)), 200, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(p.deviationFt(altitudeFtMSL: onPath - 150, atNm: 4)), -150, accuracy: 1)
    }

    /// No published angle means NO synthesised guidance — the FAA withholds the angle where the visual
    /// segment is obstructed, so inventing one is exactly the wrong response to its absence.
    func testNoAngleMeansNoPath() {
        let p = ApproachProfile(stations: [], descentAngleDeg: nil, thresholdCrossingAltFt: 1255,
                                thresholdElevFt: 1200, airport: "KTST", approachName: "VOR-A",
                                hasVerticalGuidance: false, outerCoord: nil)
        XCTAssertNil(p.pathAltitudeFt(atNm: 5))
        XCTAssertNil(p.distanceNm(forAltitudeFt: 3000))
        XCTAssertNil(p.requiredVerticalSpeedFpm(groundSpeedKt: 120))
        XCTAssertNil(p.deviationFt(altitudeFtMSL: 3000, atNm: 5))
    }

    /// The guidance classifier is deliberately conservative: unknown reads as non-precision, because
    /// drawing a decision altitude on an approach that has none is the dangerous direction.
    func testVerticalGuidanceClassification() {
        XCTAssertTrue(ApproachProfile.impliesVerticalGuidance("ILS OR LOC RWY 04R"))
        XCTAssertTrue(ApproachProfile.impliesVerticalGuidance("RNAV (GPS) RWY 23"))
        XCTAssertTrue(ApproachProfile.impliesVerticalGuidance("RNAV (RNP) Z RWY 07"))
        XCTAssertFalse(ApproachProfile.impliesVerticalGuidance("LOC RWY 15"),
                       "a localiser-only approach has no glideslope, whatever angle is coded")
        XCTAssertFalse(ApproachProfile.impliesVerticalGuidance("VOR-A"))
        XCTAssertFalse(ApproachProfile.impliesVerticalGuidance("NDB RWY 12"))
        XCTAssertFalse(ApproachProfile.impliesVerticalGuidance("SOMETHING UNRECOGNISED"))
    }

    /// The ownship is only placed while it is actually on this segment — otherwise the view would pin an
    /// aircraft to an edge of the chart and imply it was flying the approach.
    func testPositionRefusesOffSegment() {
        let thr = Coord(lat: 42.0, lon: -71.0)
        let p = ApproachProfile(
            stations: [.init(fix: "FAFXX", distanceToThresholdNm: 6, constraint: nil, role: .finalApproachFix),
                       .init(fix: "RW34", distanceToThresholdNm: 0, constraint: nil, role: .missedApproachPoint)],
            descentAngleDeg: 3.0, thresholdCrossingAltFt: 1255, thresholdElevFt: 1200,
            airport: "KTST", approachName: "ILS RWY 34", hasVerticalGuidance: true, outerCoord: nil)
        let far = Geo.destination(from: thr, bearingDeg: 0, distanceNm: 40)
        XCTAssertNil(p.position(of: far, altitudeFtMSL: 5000, threshold: thr),
                     "40 NM out is not on this final segment")
        let inside = Geo.destination(from: thr, bearingDeg: 0, distanceNm: 3)
        let pos = p.position(of: inside, altitudeFtMSL: 2000, threshold: thr)
        XCTAssertNotNil(pos)
        XCTAssertTrue(try! XCTUnwrap(pos).insideFAF, "3 NM is inside a 6 NM FAF")
        XCTAssertNil(p.position(of: inside, altitudeFtMSL: 2000, threshold: nil),
                     "no threshold, no along-track distance, no ownship")
    }

    /// Built from the REAL bundled CIFP, so the leg parsing, the FAF/MAP roles, the vertical angle sign
    /// and the threshold-crossing anchor are all exercised against published data rather than fixtures.
    func testBuildsFromTheBundledCIFP() throws {
        let procs = CIFP.approaches(airport: "KBED").filter { $0.ident == "R23" }
        try XCTSkipIf(procs.isEmpty, "bundled CIFP unavailable in this environment")
        let proper = try XCTUnwrap(CIFP.approachProper(airport: "KBED", ident: "R23"))
        let legs = CIFP.legs(procedureID: proper.id)
        let split = ApproachActivation.splitMissed(
            legs.map { (seq: $0.seq, fix: $0.fix, legType: $0.legType) }, roles: legs.map(\.role))
        let missed = Set(split.missed)
        let finalLegs = legs.filter { !missed.contains($0.seq) }
        let rwy = CIFP.runways(airport: "KBED").first { $0.designator.uppercased().hasSuffix("23") }
        try XCTSkipIf(rwy == nil, "runway 23 not in this CIFP cycle")

        let p = ApproachProfile.build(legs: finalLegs, threshold: rwy?.coord, thresholdElevFt: 133,
                                      airport: "KBED", approachName: "RNAV (GPS) RWY 23")
        XCTAssertEqual(p.descentAngleDeg ?? 0, 3.0, accuracy: 0.05,
                       "CIFP codes this final at -3.00 and the sign must be flipped to a descent")
        let tca = try XCTUnwrap(p.thresholdCrossingAltFt)
        XCTAssertEqual(tca, 181, accuracy: 2,
                       "the runway leg's published altitude IS threshold elevation + TCH")
        XCTAssertNotNil(p.faf, "the FAF is read from the waypoint description code, never inferred")
        XCTAssertTrue(p.isDrawable)
        // Stations must run outermost -> threshold, which is the direction of flight.
        let ds = p.stations.map(\.distanceToThresholdNm)
        XCTAssertEqual(ds, ds.sorted(by: >), "stations are ordered outermost first")
    }
}
