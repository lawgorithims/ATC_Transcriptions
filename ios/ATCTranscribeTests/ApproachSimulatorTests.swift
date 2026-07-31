import XCTest
@testable import ATCTranscribe

/// Closed-loop tests of the flight model AND, through it, of the vertical guidance itself.
///
/// These are the tests the guidance never had: `ApproachProfile`'s primitives were unit-tested in
/// isolation, but nothing checked that an aircraft flown down the published path actually reads as being
/// ON it, that the advisory rate is the rate that holds it, or that the deviation sign is the right way
/// round on both sides. Flying the model is what closes that loop, and because the model is pure with an
/// injected `dt` the whole thing is arithmetic rather than a timing race.
final class ApproachSimulatorTests: XCTestCase {

    // MARK: fixtures

    private let threshold = Coord(lat: 42.3656, lon: -71.0096)      // KBOS 4R-ish

    /// A precision profile: 3.00 degrees to a 51 ft threshold crossing, FAF at 5.1 NM.
    private func ilsProfile(angle: Double = 3.0) -> ApproachProfile {
        let outer = Geo.destination(from: threshold, bearingDeg: 215, distanceNm: 10)
        return ApproachProfile(
            stations: [
                .init(fix: "WINNI", distanceToThresholdNm: 10,
                      constraint: LegConstraint(altDesc: "+", alt: "03000", alt2: "", speedLimitKt: nil, verticalAngleDeg: nil, rnpNm: nil), role: .intermediateFix),
                .init(fix: "MILTT", distanceToThresholdNm: 5.1,
                      constraint: LegConstraint(altDesc: "+", alt: "01700", alt2: "", speedLimitKt: nil, verticalAngleDeg: nil, rnpNm: nil), role: .finalApproachFix),
                .init(fix: "RW04R", distanceToThresholdNm: 0, constraint: nil, role: .missedApproachPoint),
            ],
            descentAngleDeg: angle, thresholdCrossingAltFt: 69, thresholdElevFt: 18,
            airport: "KBOS", approachName: "ILS or LOC RWY 4R",
            hasVerticalGuidance: true, outerCoord: outer)
    }

    /// A non-precision profile: published floors, NO coded angle — nothing to track.
    private func lnavProfile() -> ApproachProfile {
        let outer = Geo.destination(from: threshold, bearingDeg: 215, distanceNm: 10)
        return ApproachProfile(
            stations: [
                .init(fix: "WINNI", distanceToThresholdNm: 10,
                      constraint: LegConstraint(altDesc: "+", alt: "03000", alt2: "", speedLimitKt: nil, verticalAngleDeg: nil, rnpNm: nil), role: .intermediateFix),
                .init(fix: "MILTT", distanceToThresholdNm: 5.1,
                      constraint: LegConstraint(altDesc: "+", alt: "01700", alt2: "", speedLimitKt: nil, verticalAngleDeg: nil, rnpNm: nil), role: .finalApproachFix),
                .init(fix: "STEPD", distanceToThresholdNm: 2.5,
                      constraint: LegConstraint(altDesc: "+", alt: "00900", alt2: "", speedLimitKt: nil, verticalAngleDeg: nil, rnpNm: nil), role: .intermediateFix),
                .init(fix: "RW04R", distanceToThresholdNm: 0, constraint: nil, role: .missedApproachPoint),
            ],
            descentAngleDeg: nil, thresholdCrossingAltFt: 69, thresholdElevFt: 18,
            airport: "KBOS", approachName: "RNAV (GPS) RWY 4R",
            hasVerticalGuidance: false, outerCoord: outer)
    }

    /// Fly to the threshold at a fixed step, returning every sample.
    private func fly(_ sim: inout ApproachSimulator, dt: TimeInterval = 0.25,
                     maxSteps: Int = 4_000) -> [ApproachSimulator.Sample] {
        var out: [ApproachSimulator.Sample] = []
        for _ in 0..<maxSteps {                                      // bounded (rule 2)
            let s = sim.step(dt: dt)
            out.append(s)
            if s.phase == .finished { break }
        }
        return out
    }

    // MARK: the closed loop

    /// Flown down the published path with no offset, the guidance must read ON the path — not merely
    /// close to it. This is the test that would have caught any drift between `pathAltitudeFt` (which
    /// the model flies) and `deviationFt` (which the view reads), since they are separate primitives.
    func testFlyingThePathReadsAsOnThePath() {
        let profile = ilsProfile()
        var sim = ApproachSimulator(profile: profile, threshold: threshold,
                                    config: .init(startAtNm: ApproachSimulator.defaultStartNm(profile: profile)))!
        let samples = fly(&sim)
        let captured = samples.filter { $0.phase == .onPath }
        XCTAssertGreaterThan(captured.count, 100, "the aircraft must actually capture and track")
        for s in captured {
            guard let pos = profile.position(of: s.coord, altitudeFtMSL: s.altitudeFtMSL,
                                             threshold: threshold) else {
                return XCTFail("an aircraft on the final course must be placed in the profile")
            }
            XCTAssertEqual(pos.deviationFt ?? .nan, 0, accuracy: 5,
                           "on-path deviation at \(String(format: "%.2f", s.distanceToThresholdNm)) NM")
        }
    }

    /// The aeroplane meets the glidepath from BELOW, holding the published floor until the descending
    /// path comes down to it. Capturing from above would be a different manoeuvre and a wrong picture.
    func testTheGlidepathIsInterceptedFromBelow() {
        let profile = ilsProfile()
        var sim = ApproachSimulator(profile: profile, threshold: threshold,
                                    config: .init(startAtNm: ApproachSimulator.defaultStartNm(profile: profile)))!
        let samples = fly(&sim)
        guard let firstCapture = samples.firstIndex(where: { $0.phase == .onPath }), firstCapture > 0 else {
            return XCTFail("never captured")
        }
        for s in samples[..<firstCapture] {
            guard let pos = profile.position(of: s.coord, altitudeFtMSL: s.altitudeFtMSL,
                                             threshold: threshold), let dev = pos.deviationFt else { continue }
            XCTAssertLessThanOrEqual(dev, ApproachSimulator.captureToleranceFt,
                                     "every pre-capture sample must be at or below the path")
        }
    }

    /// The rate the model flies to hold the path must equal the rate the profile ADVISES — the number
    /// printed under the profile view. If these ever disagree the advisory is wrong.
    func testTheRealisedRateEqualsTheAdvisedRate() {
        for gs in [90.0, 120.0, 150.0] {                             // bounded (rule 2)
            let profile = ilsProfile()
            var sim = ApproachSimulator(profile: profile, threshold: threshold,
                                        config: .init(groundSpeedKt: gs, startAtNm: 8))!
            let samples = fly(&sim).filter { $0.phase == .onPath }
            guard samples.count > 20, let advised = profile.requiredVerticalSpeedFpm(groundSpeedKt: gs) else {
                return XCTFail("no tracking samples at \(gs) kt")
            }
            for s in samples.prefix(200) {                           // bounded (rule 2)
                XCTAssertEqual(-s.verticalSpeedFpm, advised, accuracy: 1.0,
                               "flown rate must match the advisory at \(gs) kt")
            }
        }
    }

    /// A deliberate offset must show up as that offset, with the sign the right way round. High is
    /// positive: a pilot reading "200 ft above path" and pushing when they should pull is the failure
    /// this pins down.
    func testDeliberateOffsetsReadBackWithTheCorrectSign() {
        for offset in [-300.0, -150.0, 150.0, 300.0] {               // bounded (rule 2)
            let profile = ilsProfile()
            var sim = ApproachSimulator(profile: profile, threshold: threshold,
                                        config: .init(verticalOffsetFt: offset, startAtNm: 8))!
            let samples = fly(&sim).filter { $0.phase == .onPath }
            XCTAssertFalse(samples.isEmpty, "no tracking samples at offset \(offset)")
            for s in samples.prefix(200) {                           // bounded (rule 2)
                guard let pos = profile.position(of: s.coord, altitudeFtMSL: s.altitudeFtMSL,
                                                 threshold: threshold), let dev = pos.deviationFt else { continue }
                XCTAssertEqual(dev, offset, accuracy: 6, "offset \(offset) must read back as itself")
            }
        }
    }

    /// Beyond the cross-track limit the profile must REFUSE to place the aircraft rather than draw it
    /// pinned to the course it is not on. The simulator can fly there deliberately to prove it.
    func testFlyingWellOffCourseIsRefusedByTheProfile() {
        let profile = ilsProfile()
        var onCourse = ApproachSimulator(profile: profile, threshold: threshold,
                                         config: .init(crossTrackNm: 1.0, startAtNm: 8))!
        let near = onCourse.step(dt: 1)
        XCTAssertNotNil(profile.position(of: near.coord, altitudeFtMSL: near.altitudeFtMSL,
                                         threshold: threshold),
                        "1 NM off course is still on this approach")

        var wayOff = ApproachSimulator(profile: profile, threshold: threshold,
                                       config: .init(crossTrackNm: 6.0, startAtNm: 8))!
        let far = wayOff.step(dt: 1)
        XCTAssertNil(profile.position(of: far.coord, altitudeFtMSL: far.altitudeFtMSL,
                                      threshold: threshold),
                     "6 NM off course is not on this approach and must not be drawn on it")
    }

    // MARK: non-precision

    /// With no published angle there is nothing to track: the model steps down the floors and levels,
    /// and the guidance offers no deviation at all. Inventing one here would be inventing a glidepath.
    func testNonPrecisionStepsDownAndOffersNoDeviation() {
        let profile = lnavProfile()
        var sim = ApproachSimulator(profile: profile, threshold: threshold, config: .init(startAtNm: 9))!
        let samples = fly(&sim)
        XCTAssertTrue(samples.contains { $0.phase == .levelAtFloor }, "must level at a published floor")
        XCTAssertFalse(samples.contains { $0.phase == .onPath }, "there is no path to be on")
        for s in samples.prefix(500) {                               // bounded (rule 2)
            guard let pos = profile.position(of: s.coord, altitudeFtMSL: s.altitudeFtMSL,
                                             threshold: threshold) else { continue }
            XCTAssertNil(pos.deviationFt, "a procedure with no published angle has no deviation")
        }
        // It must actually descend through the staircase rather than sitting at the first floor.
        let alts = samples.map(\.altitudeFtMSL)
        XCTAssertLessThan(alts.last ?? .infinity, (alts.first ?? 0) - 1_000, "must step down")
    }

    // MARK: motion sanity

    func testDistanceDecreasesMonotonicallyAndAltitudeNeverClimbsOnTheApproach() {
        let profile = ilsProfile()
        var sim = ApproachSimulator(profile: profile, threshold: threshold, config: .init(startAtNm: 9))!
        let samples = fly(&sim)
        for (a, b) in zip(samples, samples.dropFirst()).prefix(3_000) {   // bounded (rule 2)
            XCTAssertLessThanOrEqual(b.distanceToThresholdNm, a.distanceToThresholdNm + 1e-9)
            XCTAssertLessThanOrEqual(b.altitudeFtMSL, a.altitudeFtMSL + 1e-6,
                                     "an aircraft on the approach does not climb")
        }
        XCTAssertEqual(samples.last?.phase, .finished)
    }

    /// The missed approach is the one place it DOES climb — a sign flip in the integrator would show up
    /// here and nowhere else.
    func testTheMissedApproachClimbs() {
        let profile = ilsProfile()
        var sim = ApproachSimulator(profile: profile, threshold: threshold, config: .init(startAtNm: 6))!
        _ = sim.step(dt: 1)
        let before = sim.step(dt: 1).altitudeFtMSL
        sim.flyMissed()
        var after = before
        for _ in 0..<20 { after = sim.step(dt: 1).altitudeFtMSL }    // bounded (rule 2)
        XCTAssertGreaterThan(after, before + 100, "the missed approach must climb")
    }

    /// Jumping to a point puts the aircraft there without flying the intervening miles — the control
    /// that makes testing an approach take seconds instead of minutes.
    func testJumpingToAPointPlacesTheAircraftThere() {
        let profile = ilsProfile()
        var sim = ApproachSimulator(profile: profile, threshold: threshold, config: .init(startAtNm: 10))!
        sim.place(atNm: 3)
        let s = sim.step(dt: 0.01)
        XCTAssertEqual(s.distanceToThresholdNm, 3, accuracy: 0.05)
    }

    /// A procedure with no threshold anchor or no along-track axis cannot be flown, and the model says
    /// so rather than flying an aircraft down an invented course.
    func testAnUnflyableProcedureIsRefused() {
        XCTAssertNil(ApproachSimulator(profile: ilsProfile(), threshold: nil))
        let noAxis = ApproachProfile(stations: [], descentAngleDeg: 3, thresholdCrossingAltFt: 69,
                                     thresholdElevFt: 18, airport: "KBOS", approachName: "X",
                                     hasVerticalGuidance: true, outerCoord: nil)
        XCTAssertNil(ApproachSimulator(profile: noAxis, threshold: threshold))
    }

    /// Ground speed drives the required rate, so a steeper angle at the same speed must be flown faster
    /// down — the property the advisory is built on.
    func testASteeperPathIsFlownAtAHigherRate() {
        func rate(angle: Double) -> Double {
            let profile = ilsProfile(angle: angle)
            var sim = ApproachSimulator(profile: profile, threshold: threshold, config: .init(startAtNm: 8))!
            return fly(&sim).first { $0.phase == .onPath }?.verticalSpeedFpm ?? 0
        }
        XCTAssertLessThan(rate(angle: 3.5), rate(angle: 3.0), "steeper means a larger rate of descent")
    }
}
