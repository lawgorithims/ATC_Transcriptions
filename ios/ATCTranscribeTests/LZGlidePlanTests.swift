import XCTest
@testable import ATCTranscribe

/// The rehearsable glide plan: its energy budget, its wind sense, and the commit point.
///
/// WHY THESE TESTS AND NOT A LOOK AT THE MAP. Every failure this file guards against draws as a
/// perfectly reasonable line. A circuit planned 300 ft short, a final laid downwind, a commit point
/// that never closes — at map scale they are all the same smooth path to the same patch of ground.
/// The only way to know is to fly it and check where it ends up, which is what the injected clock in
/// `LZGlideRehearsal` exists for.
final class LZGlidePlanTests: XCTestCase {

    private let here = Coord(lat: 32.30, lon: -106.90)

    private func candidate(bearing: Double = 90, distance: Double = 6,
                           runHeading: Double = 0, run: Double = 900,
                           coarse: Bool = false) -> LZSiteFinder.Candidate {
        LZSiteFinder.Candidate(
            centre: Geo.point(from: here, bearingDeg: bearing, distanceNm: distance),
            bearingDeg: bearing, distanceNm: distance,
            runMetres: run, runHeadingDeg: runHeading, score: 80,
            arrival: .comfortable, rules: [], coarseTerrain: coarse)
    }

    private func plan(alt: Double = 9000, groundFt: Double = 4000,
                      cand: LZSiteFinder.Candidate? = nil,
                      alternatives: [LZSiteFinder.Candidate] = [],
                      ratio: Double = 9, windFrom: Double? = nil,
                      windKts: Double? = nil) -> LZGlidePlan? {
        LZGlidePlanner.plan(from: here, altitudeFtMSL: alt, groundElevationFt: groundFt,
                            candidate: cand ?? candidate(), alternatives: alternatives,
                            glideRatio: ratio, bestGlideKts: 68,
                            windFromDeg: windFrom, windKts: windKts)
    }

    // MARK: - the circuit closes

    /// The profile must ARRIVE. Every leg's exit height is the next leg's entry, and the last one
    /// lands on the ground — not near it.
    ///
    /// 11500 ft over 4000 ft ground at 6 NM: enough to reach the key position AND fly the circuit.
    /// Picked deliberately — 9000 ft looks generous and is not, and a test written at that height
    /// asserts continuity on a plan the planner is correctly reporting as short.
    func testTheProfileIsContinuousAndReachesTheGround() throws {
        let p = try XCTUnwrap(plan(alt: 11500))
        XCTAssertGreaterThan(p.arrivalMarginFt, 0, "this scenario was meant to close")
        for i in 1..<p.legs.count {
            XCTAssertEqual(p.legs[i].entryAltFtMSL, p.legs[i - 1].exitAltFtMSL, accuracy: 0.001,
                           "a step in the profile between \(p.legs[i-1].kind) and \(p.legs[i].kind)")
        }
        XCTAssertEqual(p.legs.last?.exitAltFtMSL ?? 0, 4000, accuracy: 60,
                       "the plan does not finish at ground level")
        // Falling throughout: a glide has no other option.
        for leg in p.legs where leg.distanceNm > 0 {
            XCTAssertGreaterThan(leg.heightLostFt, 0, "\(leg.kind) does not lose height")
        }
    }

    /// The circuit is always there. A straight-in to unsurveyed ground skips the one check that
    /// covers what the data cannot see — actually looking at the field.
    func testEveryPlanEndsWithACircuitNotAStraightIn() throws {
        for distance in [2.0, 6.0, 20.0] {                       // near, normal and far
            let p = try XCTUnwrap(plan(alt: 12000, cand: candidate(distance: distance)))
            let kinds = p.legs.map(\.kind)
            XCTAssertTrue(kinds.contains(.downwind) && kinds.contains(.base)
                          && kinds.contains(.final),
                          "no circuit planned from \(distance) NM: \(kinds.map(\.rawValue))")
            XCTAssertEqual(kinds.last, .final)
        }
    }

    /// ⚠️ THE CIRCUIT IS LEFT-HAND, and only a bearing test can tell. A right-hand circuit closes
    /// just as neatly, joins leg to leg just as cleanly, and draws identically at map scale — this
    /// planner built one for a while with a comment above it saying "left-hand". A pilot handed a
    /// pattern with no note flies it left, so the geometry has to be left.
    func testTheCircuitIsLeftHanded() throws {
        for landing in [0.0, 45.0, 135.0, 270.0] {
            let p = try XCTUnwrap(plan(alt: 11500, cand: candidate(runHeading: landing)),
                                  "no plan for a run lying \(landing)")
            let fin = try XCTUnwrap(p.legs.first { $0.kind == .final })
            let base = try XCTUnwrap(p.legs.first { $0.kind == .base })
            let dwn = try XCTUnwrap(p.legs.first { $0.kind == .downwind })

            // Each turn is 90 degrees to the LEFT: downwind → base → final.
            XCTAssertEqual(turn(from: dwn.headingDeg, to: base.headingDeg), -90, accuracy: 1.0,
                           "downwind→base is not a left turn landing \(Int(fin.headingDeg))")
            XCTAssertEqual(turn(from: base.headingDeg, to: fin.headingDeg), -90, accuracy: 1.0,
                           "base→final is not a left turn landing \(Int(fin.headingDeg))")
            // And the downwind really is displaced to the left of the landing direction.
            let offset = turn(from: fin.headingDeg, to: Geo.bearing(fin.from, dwn.from))
            XCTAssertLessThan(offset, 0,
                              "the downwind sits right of the final course landing "
                              + "\(Int(fin.headingDeg)) — that is a right-hand circuit")
        }
    }

    /// Signed turn a→b, -180...180. Negative is left.
    private func turn(from a: Double, to b: Double) -> Double {
        let d = (b - a).truncatingRemainder(dividingBy: 360)
        if d > 180 { return d - 360 }
        if d < -180 { return d + 360 }
        return d
    }

    // MARK: - wind

    /// ⚠️ A RUN HAS NO DIRECTION. A 900 m run "lying 000" can be flown as 360 or 180, and taking the
    /// stated heading at face value lands downwind half the time — on unprepared ground, with no
    /// engine to go around with.
    func testTheFinalIsLaidIntoWindWhicheverEndThatMeans() throws {
        let north = try XCTUnwrap(plan(cand: candidate(runHeading: 0), windFrom: 350, windKts: 18))
        XCTAssertEqual(north.finalHeadingDeg, 0, accuracy: 0.1)
        XCTAssertGreaterThan(north.headwindKts, 15)

        // Same ground, wind reversed: the SAME run must now be flown the other way.
        let south = try XCTUnwrap(plan(cand: candidate(runHeading: 0), windFrom: 170, windKts: 18))
        XCTAssertEqual(south.finalHeadingDeg, 180, accuracy: 0.1)
        XCTAssertGreaterThan(south.headwindKts, 15)
    }

    /// A run square to the wind has no tailwind AND no headwind, so the tailwind check stays silent
    /// — and silence there reads as "the wind is fine". It is not: the whole 25 kt is across, on
    /// ground with no marked width to drift within.
    func testARunSquareToTheWindIsCalledOutAsCrosswindNotPassedOver() throws {
        let p = try XCTUnwrap(plan(cand: candidate(runHeading: 90), windFrom: 0, windKts: 25))
        XCTAssertLessThan(abs(p.headwindKts), 1, "claimed a wind component along a run square to it")
        XCTAssertTrue(p.warnings.contains { $0.localizedCaseInsensitiveContains("across") },
                      "a 25 kt crosswind went unmentioned: \(p.warnings)")
    }

    /// The converse: a run straight into wind must NOT collect a crosswind warning.
    func testAnIntoWindRunIsNotWarnedAboutCrosswind() throws {
        let p = try XCTUnwrap(plan(cand: candidate(runHeading: 0), windFrom: 0, windKts: 25))
        XCTAssertFalse(p.warnings.contains { $0.localizedCaseInsensitiveContains("across") },
                       "warned about crosswind on a run straight into wind: \(p.warnings)")
    }

    /// Wind must change the ENERGY, not just the direction. Each leg carries its own ratio, because
    /// a downwind leg and a final are not the same aeroplane.
    func testEachLegCarriesItsOwnWindAdjustedRatio() throws {
        let p = try XCTUnwrap(plan(cand: candidate(runHeading: 0), windFrom: 0, windKts: 30))
        let fin = try XCTUnwrap(p.legs.first { $0.kind == .final })
        let dwn = try XCTUnwrap(p.legs.first { $0.kind == .downwind })
        XCTAssertLessThan(fin.glideRatio, dwn.glideRatio,
                          "into-wind final should sink more steeply over the ground than downwind")
    }

    // MARK: - energy

    /// Not enough height is reported as a shortfall, WITH the number, and the plan still comes back.
    /// "You can reach it but not with a circuit in hand" is a real answer; returning nil would read
    /// as a software failure instead of as the situation the pilot is in.
    func testArrivingTooLowIsAnAnswerNotAFailure() throws {
        let p = try XCTUnwrap(plan(alt: 5000, groundFt: 4000, cand: candidate(distance: 8)))
        XCTAssertLessThan(p.arrivalMarginFt, 0)
        XCTAssertTrue(p.warnings.contains { $0.contains("ft short") },
                      "a plan that does not close said nothing about it: \(p.warnings)")
    }

    /// Too MUCH height is the failure pilots improvise badly, so it is planned as a segment.
    func testArrivingHighPlansTheHeightLossInsteadOfLeavingIt() throws {
        let p = try XCTUnwrap(plan(alt: 16000, groundFt: 4000, cand: candidate(distance: 3)))
        XCTAssertGreaterThan(p.arrivalMarginFt, LZGlidePlanner.patternHeightFt)
        let dump = try XCTUnwrap(p.legs.first { $0.kind == .energyDump },
                                 "arrived high with no plan to lose it")
        XCTAssertGreaterThan(dump.heightLostFt, 0)
        // Overhead, so the ground stays in sight — displacement zero.
        XCTAssertEqual(Geo.nmBetween(dump.from, dump.to), 0, accuracy: 0.0001)
        XCTAssertTrue(p.warnings.contains { $0.contains("high") })
    }

    /// Height in hand at the key position is measured against PATTERN height, not against the dirt.
    /// Measuring to the ground would call an arrival at 50 ft AGL "comfortable".
    func testTheMarginIsMeasuredAgainstPatternHeightNotTheGround() throws {
        let p = try XCTUnwrap(plan(alt: 11500, groundFt: 4000, cand: candidate(distance: 6)))
        let key = try XCTUnwrap(p.legs.first { $0.kind == .downwind })
        XCTAssertGreaterThanOrEqual(key.entryAltFtMSL, 4000 + LZGlidePlanner.patternHeightFt - 1,
                                    "the circuit starts below pattern height")
    }

    /// ⚠️ THE REGRESSION THIS PAIR EXISTS FOR. Spare height must be spent BEFORE the circuit, not
    /// carried through it — otherwise the plan draws an ordinary circuit that stops in mid-air, and
    /// a profile ending 600 ft up looks exactly like one ending on the ground.
    func testEvenASmallExcessIsSpentSoTheCircuitStillEndsOnTheGround() throws {
        // Tuned to arrive with a modest excess — under the threshold that earns a warning, which is
        // precisely the band the old code carried straight through.
        for altitude in stride(from: 10200.0, through: 11800.0, by: 200.0) {
            guard let p = plan(alt: altitude), p.arrivalMarginFt > 0 else { continue }
            XCTAssertEqual(p.legs.last?.exitAltFtMSL ?? 0, 4000, accuracy: 1.0,
                           "from \(Int(altitude)) ft the plan finished "
                           + "\(Int((p.legs.last?.exitAltFtMSL ?? 0) - 4000)) ft off the ground")
        }
    }

    /// Coarse ground is called out on the plan too — the profile looks just as precise either way.
    func testCoarseGroundIsRepeatedOnThePlan() throws {
        let p = try XCTUnwrap(plan(cand: candidate(coarse: true)))
        XCTAssertTrue(p.warnings.contains { $0.contains("10 m elevation") }, "\(p.warnings)")
    }

    // MARK: - keeping options open

    /// The commit point is the whole "late commit" policy in one number: the last place you could
    /// still change your mind.
    func testTheCommitPointIsTheLastPlaceAnAlternativeIsStillReachable() throws {
        let chosen = candidate(bearing: 90, distance: 10)
        let other = candidate(bearing: 270, distance: 6)
        let p = try XCTUnwrap(plan(alt: 12000, groundFt: 4000, cand: chosen,
                                   alternatives: [other]))
        let commit = try XCTUnwrap(p.commit, "no commit point on a track with a live alternative")
        XCTAssertGreaterThan(commit.alongTrackNm, 0)
        XCTAssertLessThan(commit.altitudeFtMSL, 12000, "the commit point cannot be the start")

        // PAST it, the alternative really is gone — which is the claim the number makes.
        let past = Geo.point(from: here, bearingDeg: Geo.bearing(here, chosen.centre),
                             distanceNm: commit.alongTrackNm + 1.0)
        let altThere = 12000 - LZGlidePlanner.cost(commit.alongTrackNm + 1.0, 9)
        let usable = altThere - 4000 - NearestAirports.arrivalReserveFt
        let reach = max(0, usable) * 9 / NearestAirports.ftPerNm
        XCTAssertLessThan(reach, Geo.nmBetween(past, other.centre),
                          "the alternative was still reachable after the stated commit point")
    }

    /// With nothing else on the list there is no diversion to lose — and the plan says so rather
    /// than leaving a blank where a commit point would be.
    func testNoAlternativesIsStatedNotLeftBlank() throws {
        let p = try XCTUnwrap(plan(alternatives: []))
        XCTAssertNil(p.commit)
        XCTAssertFalse(p.warnings.contains { $0.contains("No alternative") },
                       "warned about losing alternatives when none were offered")
    }

    /// An alternative that was never reachable is not a commit point — it is a warning that this
    /// track commits you from the start.
    func testAnUnreachableAlternativeCommitsYouImmediately() throws {
        let far = candidate(bearing: 270, distance: 55)
        let p = try XCTUnwrap(plan(alt: 9000, groundFt: 4000, alternatives: [far]))
        XCTAssertNil(p.commit)
        XCTAssertTrue(p.warnings.contains { $0.contains("commits you") }, "\(p.warnings)")
    }

    // MARK: - the rehearsal

    /// FLY IT. The profile is only checked when something flies it to the end and looks at where it
    /// stopped.
    func testFlyingThePlanArrivesOverTheGroundAtGroundLevel() throws {
        let p = try XCTUnwrap(plan(alt: 11500, groundFt: 4000, cand: candidate(distance: 6)))
        let track = LZGlideRehearsal.flyOut(p, dt: 2.0)
        let last = try XCTUnwrap(track.last)
        XCTAssertTrue(last.finished, "the rehearsal never finished")
        XCTAssertLessThan(Geo.nmBetween(last.coord, p.touchdownArea), 0.1,
                          "the rehearsal finished somewhere other than the chosen ground")
        XCTAssertEqual(last.altitudeFtMSL, 4000, accuracy: 60)
    }

    /// Height comes off monotonically for the whole rehearsal. A glide that gains height between two
    /// samples is a sign-error, and it would draw as a perfectly ordinary profile.
    func testTheRehearsalNeverGainsHeight() throws {
        let p = try XCTUnwrap(plan(alt: 14000, groundFt: 4000, cand: candidate(distance: 12),
                                   windFrom: 300, windKts: 20))
        let track = LZGlideRehearsal.flyOut(p, dt: 5.0)
        for i in 1..<track.count {
            XCTAssertLessThanOrEqual(track[i].altitudeFtMSL, track[i - 1].altitudeFtMSL + 0.001,
                                     "gained height at step \(i) on \(track[i].legKind)")
        }
        XCTAssertGreaterThan(track.count, 5, "the rehearsal was over before it started")
    }

    /// It flies through every leg the plan contains, in order — a rehearsal that skips the base leg
    /// has not rehearsed the circuit.
    func testTheRehearsalFliesEveryLegInOrder() throws {
        let p = try XCTUnwrap(plan(alt: 16000, groundFt: 4000, cand: candidate(distance: 4)))
        let track = LZGlideRehearsal.flyOut(p, dt: 1.0)
        var seen = [LZGlidePlan.LegKind]()
        for s in track where seen.last != s.legKind { seen.append(s.legKind) }
        XCTAssertEqual(seen, p.legs.map(\.kind), "legs flown out of order or skipped")
    }

    /// A rehearsal always terminates. Bounded, so a plan that cannot finish returns what it managed
    /// rather than hanging the caller.
    func testTheRehearsalAlwaysTerminates() throws {
        let p = try XCTUnwrap(plan(alt: 30000, groundFt: 0, cand: candidate(distance: 40)))
        let track = LZGlideRehearsal.flyOut(p, dt: 30.0)
        XCTAssertTrue(track.last?.finished ?? false)
    }

    // MARK: - claim strength

    /// The plan carries what is unknown about it, and says outright that it is not published.
    func testThePlanSaysItIsNotAPublishedProcedure() throws {
        let p = try XCTUnwrap(plan())
        XCTAssertTrue(p.unknowns.localizedCaseInsensitiveContains("not surveyed"))
        XCTAssertTrue(p.unknowns.localizedCaseInsensitiveContains("rehearsal"))
        XCTAssertTrue(p.unknowns.localizedCaseInsensitiveContains("no obstacle assessment"))
    }

    /// Nothing is planned to ground the footprint never claimed.
    func testGroundBeyondAnyPlausibleReachIsRefused() {
        XCTAssertNil(plan(cand: candidate(distance: LZGlidePlanner.maxRunInNm + 5)))
    }
}
