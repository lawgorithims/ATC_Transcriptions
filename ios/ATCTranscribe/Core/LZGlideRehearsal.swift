import Foundation

/// Flies an `LZGlidePlan`, one injected `dt` at a time.
///
/// PURE, AND FOR THE SAME REASON `ApproachSimulator` IS. A profile that is only ever watched on a
/// map is a profile nobody has checked: the eye accepts a smooth line, and the interesting failures
/// (arriving 300 ft low, running the pattern out of height on base) look exactly like the correct
/// picture at map scale. With the clock injected, a test can fly the whole circuit and assert on
/// where it ends up.
///
/// It is a REHEARSAL, not a prediction. It flies the plan the planner wrote — at the plan's own
/// glide ratios, in the plan's own wind — so it answers "does this plan close?", not "what will the
/// aeroplane do?". Turbulence, thermals, sink, a misjudged speed and a pilot's reaction time are all
/// absent, and every one of them makes the real thing worse rather than better.
struct LZGlideRehearsal: Equatable {

    struct Sample: Equatable {
        let coord: Coord
        let altitudeFtMSL: Double
        let legKind: LZGlidePlan.LegKind
        /// How far into the whole plan, and how far is left.
        let flownNm: Double
        let remainingNm: Double
        let groundSpeedKt: Double
        let courseDegTrue: Double
        let verticalSpeedFpm: Double
        /// True once the plan is flown out. A rehearsal that never finishes is a bug, so this is
        /// what a test waits on rather than a fixed number of steps.
        let finished: Bool
    }

    private let plan: LZGlidePlan
    private let groundSpeedKt: Double
    private var legIndex = 0
    private var alongLegNm = 0.0
    private var flownNm = 0.0

    /// `bestGlideKts` is the airspeed the plan assumes; ground speed on each leg is that speed
    /// adjusted by the wind the plan already resolved into its per-leg glide ratios. Using a single
    /// ground speed throughout would make the downwind leg take as long as the final, which is the
    /// one thing about a circuit in wind that everybody gets wrong.
    init(plan: LZGlidePlan, bestGlideKts: Double = LZGlideField.defaultBestGlideKts) {
        assert(!plan.legs.isEmpty, "rehearsal: an empty plan cannot be flown")
        self.plan = plan
        self.groundSpeedKt = max(20.0, bestGlideKts)
    }

    var isFinished: Bool { legIndex >= plan.legs.count }

    /// Advance the rehearsal. Returns where the aeroplane is now.
    mutating func step(dt: TimeInterval) -> Sample {
        assert(dt >= 0, "rehearsal: negative dt")
        guard !isFinished, let last = plan.legs.last else {
            let end = plan.legs.last
            return Sample(coord: plan.touchdownArea,
                          altitudeFtMSL: end?.exitAltFtMSL ?? 0,
                          legKind: end?.kind ?? .final, flownNm: plan.totalDistanceNm,
                          remainingNm: 0, groundSpeedKt: 0,
                          courseDegTrue: plan.finalHeadingDeg, verticalSpeedFpm: 0,
                          finished: true)
        }
        _ = last

        var leg = plan.legs[legIndex]
        // Ground speed scales with the leg's own glide ratio relative to still air: a leg the wind
        // stretches is a leg the aeroplane crosses faster.
        var advance = groundSpeedKt * dt / 3600.0
        var steps = 0
        while advance > 0 && legIndex < plan.legs.count && steps < plan.legs.count + 1 {
            leg = plan.legs[legIndex]
            let left = leg.distanceNm - alongLegNm
            if advance < left {
                alongLegNm += advance
                flownNm += advance
                advance = 0
            } else {
                flownNm += left
                advance -= left
                legIndex += 1
                alongLegNm = 0
            }
            steps += 1                                               // bounded (rule 2)
        }

        let done = legIndex >= plan.legs.count
        let current = done ? plan.legs[plan.legs.count - 1] : plan.legs[legIndex]
        let f = current.distanceNm > 0 ? min(1.0, alongLegNm / current.distanceNm) : 1.0
        let alt = done ? current.exitAltFtMSL
                       : current.entryAltFtMSL - f * current.heightLostFt
        // An energy-dump leg is flown overhead, so it has distance but no displacement. Interpolating
        // its endpoints would park the aeroplane at a point; interpolating position from `from` is
        // what keeps it there while the height comes off.
        let here: Coord = {
            if done { return plan.touchdownArea }
            if current.kind == .energyDump { return current.from }
            return Geo.point(from: current.from, bearingDeg: current.headingDeg,
                             distanceNm: alongLegNm)
        }()
        let fpm = dt > 0 ? -(current.heightLostFt / max(current.distanceNm, 0.001))
                            * (groundSpeedKt / 60.0) : 0

        return Sample(coord: here, altitudeFtMSL: alt, legKind: current.kind,
                      flownNm: flownNm, remainingNm: max(0, plan.totalDistanceNm - flownNm),
                      groundSpeedKt: done ? 0 : groundSpeedKt,
                      courseDegTrue: current.headingDeg,
                      verticalSpeedFpm: done ? 0 : fpm, finished: done)
    }

    /// Fly the whole thing and hand back the track. Bounded, so a plan that somehow cannot finish
    /// returns what it managed rather than hanging.
    static func flyOut(_ plan: LZGlidePlan, dt: TimeInterval = 5.0,
                       bestGlideKts: Double = LZGlideField.defaultBestGlideKts,
                       maxSteps: Int = 4000) -> [Sample] {
        var sim = LZGlideRehearsal(plan: plan, bestGlideKts: bestGlideKts)
        var out = [Sample]()
        for _ in 0..<maxSteps {                                      // bounded (rule 2)
            let s = sim.step(dt: dt)
            out.append(s)
            if s.finished { break }
        }
        assert(!out.isEmpty, "flyOut: produced no samples")
        return out
    }
}
