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
        // ⚠️ RNAV / GPS / RNP NOW CLASSIFY AS NON-PRECISION, and this reversal is deliberate. The title
        // is identical whether the chart publishes an LPV line, an LNAV/VNAV line, or an LNAV MDA and
        // nothing else — so returning true was a guess from the name. Cross-checked against OCR'd
        // cycle-2607 plates, 1,335 straight-in RNAV approaches publish an MDA and NO vertically-guided
        // line, and the app drew an unbroken glidepath to a decision altitude on every one of them.
        //
        // The cost is real and is accepted knowingly: roughly 4,600 approaches that DO publish LPV or
        // LNAV/VNAV now render an MDA-style floor with the angle called advisory, which understates the
        // guidance available. That is the direction this function's own doc comment chooses, and the
        // asymmetry is not close — understating leaves a pilot with the guidance in their box, while
        // overstating draws a DA picture on a procedure that requires levelling at an MDA.
        //
        // The proper fix is evidence rather than a better guess: PlateMinima.Kind.usesDecisionAltitude,
        // once the plate has been parsed. Restore a `true` here only from that.
        XCTAssertFalse(ApproachProfile.impliesVerticalGuidance("RNAV (GPS) RWY 23"))
        XCTAssertFalse(ApproachProfile.impliesVerticalGuidance("RNAV (RNP) Z RWY 07"))
        XCTAssertFalse(ApproachProfile.impliesVerticalGuidance("LOC RWY 15"),
                       "a localiser-only approach has no glideslope, whatever angle is coded")
        XCTAssertFalse(ApproachProfile.impliesVerticalGuidance("VOR-A"))
        XCTAssertFalse(ApproachProfile.impliesVerticalGuidance("NDB RWY 12"))
        XCTAssertFalse(ApproachProfile.impliesVerticalGuidance("SOMETHING UNRECOGNISED"))
        // CIRCLING-ONLY outranks the type. These publish no straight-in line of minima at all — no
        // glidepath and no DA, only a circling MDA — so a coded angle on them is a descent GRADIENT.
        // 271 of them classified as guided before this, 89 with a real angle (KASE RNAV (GPS)-F at
        // 6.49 degrees), each drawn as an unbroken glidepath to a decision altitude that does not exist.
        XCTAssertFalse(ApproachProfile.impliesVerticalGuidance("RNAV (GPS)-A"))
        XCTAssertFalse(ApproachProfile.impliesVerticalGuidance("RNAV (GPS)-F"))
        XCTAssertFalse(ApproachProfile.impliesVerticalGuidance("VOR/DME-B"))
        // ...and the coded runway catches the ones with no dash-letter (COPTER point-in-space).
        XCTAssertFalse(ApproachProfile.impliesVerticalGuidance("COPTER RNAV (GPS) 027", codedRunway: ""))
        XCTAssertTrue(ApproachProfile.impliesVerticalGuidance("ILS RWY 04R", codedRunway: "04R"))
    }

    /// With no PUBLISHED crossing altitude there is no anchor, so there is no path — the previous
    /// fallback hung it off a max-aggregated SURFACE DEM cell plus an assumed TCH and printed the result.
    func testNoPublishedCrossingAltitudeMeansNoProfile() {
        let legs: [CIFPLeg] = []
        let p = ApproachProfile.build(legs: legs, threshold: Coord(lat: 42, lon: -71),
                                      thresholdElevFt: 1200, airport: "KTST",
                                      approachName: "RNAV (GPS) RWY 04", codedRunway: "04")
        XCTAssertNil(p.thresholdCrossingAltFt,
                     "terrain elevation + an assumed 50 ft TCH is a fabricated anchor, not a measurement")
        XCTAssertFalse(p.isDrawable)
        XCTAssertNil(p.pathAltitudeFt(atNm: 5))
    }

    /// The ownship is placed by ALONG-TRACK distance, so an aircraft abeam the field — on downwind, or
    /// established on a different approach — is not drawn as though it were on this final.
    func testPositionRejectsAircraftOffTheFinalCourse() {
        let thr = Coord(lat: 42.0, lon: -71.0)
        let outer = Geo.destination(from: thr, bearingDeg: 0, distanceNm: 8)     // final runs due north
        let p = ApproachProfile(
            stations: [.init(fix: "FAFXX", distanceToThresholdNm: 6, constraint: nil, role: .finalApproachFix),
                       .init(fix: "RW36", distanceToThresholdNm: 0, constraint: nil, role: .missedApproachPoint)],
            descentAngleDeg: 3.0, thresholdCrossingAltFt: 1255, thresholdElevFt: 1200,
            airport: "KTST", approachName: "ILS RWY 36", hasVerticalGuidance: true, outerCoord: outer)
        // 5 NM due EAST of the threshold: the same RANGE as a fix on final, nowhere near the course.
        let abeam = Geo.destination(from: thr, bearingDeg: 90, distanceNm: 5)
        XCTAssertNil(p.position(of: abeam, altitudeFtMSL: 2500, threshold: thr),
                     "an aircraft abeam the field is not on this final, whatever its range")
        // 5 NM out ON the course is placed at 5 NM.
        let onCourse = Geo.destination(from: thr, bearingDeg: 0, distanceNm: 5)
        let pos = p.position(of: onCourse, altitudeFtMSL: 2500, threshold: thr)
        XCTAssertEqual(try! XCTUnwrap(pos).distanceNm, 5, accuracy: 0.1)
        // Behind the threshold (past the runway) is refused rather than mirrored onto final.
        let behind = Geo.destination(from: thr, bearingDeg: 180, distanceNm: 3)
        XCTAssertNil(p.position(of: behind, altitudeFtMSL: 1500, threshold: thr))
    }

    /// The ownship is only placed while it is actually on this segment — otherwise the view would pin an
    /// aircraft to an edge of the chart and imply it was flying the approach.
    func testPositionRefusesOffSegment() {
        let thr = Coord(lat: 42.0, lon: -71.0)
        // The final runs due north from the threshold; `outerCoord` is what gives the profile its axis,
        // and without one there is no course to project onto and no position to report.
        let axis = Geo.destination(from: thr, bearingDeg: 0, distanceNm: 6)
        let p = ApproachProfile(
            stations: [.init(fix: "FAFXX", distanceToThresholdNm: 6, constraint: nil, role: .finalApproachFix),
                       .init(fix: "RW34", distanceToThresholdNm: 0, constraint: nil, role: .missedApproachPoint)],
            descentAngleDeg: 3.0, thresholdCrossingAltFt: 1255, thresholdElevFt: 1200,
            airport: "KTST", approachName: "ILS RWY 34", hasVerticalGuidance: true, outerCoord: axis)
        XCTAssertNil(ApproachProfile(
            stations: p.stations, descentAngleDeg: 3.0, thresholdCrossingAltFt: 1255,
            thresholdElevFt: 1200, airport: "KTST", approachName: "ILS RWY 34",
            hasVerticalGuidance: true, outerCoord: nil)
            .position(of: axis, altitudeFtMSL: 3000, threshold: thr),
            "no axis, no along-track projection, no ownship")
        let far = Geo.destination(from: thr, bearingDeg: 0, distanceNm: 40)
        XCTAssertNil(p.position(of: far, altitudeFtMSL: 5000, threshold: thr),
                     "40 NM out is not on this final segment")
        let inside = Geo.destination(from: thr, bearingDeg: 0, distanceNm: 3)   // on the course
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
