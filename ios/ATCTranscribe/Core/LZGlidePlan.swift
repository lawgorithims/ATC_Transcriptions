import Foundation

/// A rehearsable glide to one of the ranked areas — the circuit, the energy budget, and the moment
/// the diversion closes.
///
/// =============================================================================================
/// WHY THIS IS NOT AN `ApproachProfile`
/// =============================================================================================
/// The app already models published approaches, and it would have been quick to express this as
/// one. It would also have been a lie. `ApproachProfile` speaks in FAF, MAP, DA and MDA — a
/// vocabulary that means an obstacle-assessed, surveyed, published procedure. None of that exists
/// for a field inferred from 10 m land cover. Reusing the type would have imported that authority
/// wholesale, in a place where the whole design effort has been to avoid claiming it.
///
/// So this has its own words. A `keyPosition`, not a FAF. A `touchdownArea`, not a threshold. What
/// it borrows from the approach machinery is the SHAPE that made vertical guidance testable: a pure
/// value with an injected `dt`, so the profile can be flown in a test rather than watched on a map.
///
/// =============================================================================================
/// WHAT IT PLANS, AND WHAT IT REFUSES TO
/// =============================================================================================
/// It plans a normal circuit: a run-in to a key position abeam the ground, a downwind, a base, and a
/// final laid along the measured run and pointed into whatever wind there is. It budgets height for
/// every leg at the wind-adjusted glide ratio for THAT leg's heading, because a downwind leg and a
/// final are not the same aeroplane.
///
/// It will not plan a straight-in to unsurveyed ground from a great distance. Arriving with a
/// circuit in hand is what lets a pilot look at the field before committing, and looking is the only
/// check that covers everything this data cannot see: the fence, the crop, the livestock, the wire.
struct LZGlidePlan: Equatable {

    /// The segments of the plan, in the order they are flown.
    enum LegKind: String, Equatable {
        case runIn, energyDump, downwind, base, final

        var title: String {
            switch self {
            case .runIn:      return "Run-in"
            case .energyDump: return "Lose height"
            case .downwind:   return "Downwind"
            case .base:       return "Base"
            case .final:      return "Final"
            }
        }
    }

    struct Leg: Equatable {
        let kind: LegKind
        let from: Coord
        let to: Coord
        let headingDeg: Double
        let distanceNm: Double
        /// Height at each end, feet MSL. Falling: a glide has no other option.
        let entryAltFtMSL: Double
        let exitAltFtMSL: Double
        /// The wind-adjusted glide ratio used for THIS heading — into wind you sink more steeply
        /// over the ground, and a plan that used one ratio throughout would arrive short.
        let glideRatio: Double

        var heightLostFt: Double { entryAltFtMSL - exitAltFtMSL }
    }

    /// The last point on the run-in from which a DIFFERENT candidate is still reachable.
    ///
    /// This is the number the whole "keep options open" idea reduces to. Before it, changing your
    /// mind costs nothing but height. After it, there is one field left and the decision is made —
    /// so the pilot should be told where it is, rather than discovering it by running out of
    /// alternatives without noticing.
    struct CommitPoint: Equatable {
        let coord: Coord
        let altitudeFtMSL: Double
        /// How far along the run-in it falls, and how long that leaves.
        let alongTrackNm: Double
        /// The alternative it is the last chance to take, described the way the list describes it.
        let alternativeBearingDeg: Double
        let alternativeDistanceNm: Double
    }

    let legs: [Leg]
    /// A point INSIDE the area, never called a threshold — the same deliberate imprecision the
    /// ranked list uses.
    let touchdownArea: Coord
    let finalHeadingDeg: Double
    /// Wind component on final: positive is a headwind, which is what the final direction was chosen
    /// to get. Negative means the run only lies one way and that way is downwind — worth saying.
    let headwindKts: Double
    /// Height above the pattern floor at the key position. Negative means the plan does not close:
    /// the ground is reachable but not with a circuit in hand.
    let arrivalMarginFt: Double
    let commit: CommitPoint?
    let warnings: [String]

    /// Travels with the plan, exactly as it travels with a candidate. A profile drawn to a tenth of
    /// a mile is the single most survey-like thing this feature produces.
    var unknowns: String {
        "Inferred from 10 m land cover and terrain — not surveyed. This is a rehearsal, not a "
        + "published procedure: no obstacle assessment exists for this ground, and the circuit "
        + "assumes nothing in the way that the data cannot see."
    }

    var totalDistanceNm: Double { legs.reduce(0) { $0 + $1.distanceNm } }
    var keyPosition: Coord? { legs.first { $0.kind == .downwind }?.from }
    var startAltitudeFtMSL: Double { legs.first?.entryAltFtMSL ?? 0 }
}

// MARK: - The planner

enum LZGlidePlanner {

    /// Circuit geometry. Deliberately a small, normal pattern — this is an aeroplane without an
    /// engine, and a wide airfield-sized circuit spends height it does not have.
    static let patternHeightFt = 800.0            // above the ground at the key position
    static let downwindOffsetNm = 0.45            // abeam distance from the landing run
    static let downwindLengthNm = 0.70            // key position to the base turn
    static let baseLengthNm = downwindOffsetNm
    static let finalLengthNm = 0.60

    /// Excess height worth telling the pilot about, rather than just planning away.
    static let noteworthyExcessFt = 300.0
    /// A crosswind component this side of which the run is worth a word. On a prepared runway this
    /// is a technique problem; on unmown ground with a fence somewhere it is a landing-roll problem.
    static let noteworthyCrosswindKts = 12.0
    /// Cap on the run-in, so a plan is never drawn across ground the footprint never claimed.
    static let maxRunInNm = 60.0
    /// Steps used to walk the run-in looking for the commit point.
    static let commitSteps = 40

    /// Build a plan, or nil when the geometry cannot be formed at all.
    ///
    /// A plan that does NOT close is still returned, carrying a negative `arrivalMarginFt` and a
    /// warning. That is deliberate: "you can reach this ground but not with a circuit in hand" is a
    /// real and important answer, and returning nil would present it as "no plan", which reads as a
    /// software failure rather than as the situation the pilot is actually in.
    static func plan(from origin: Coord,
                     altitudeFtMSL: Double,
                     groundElevationFt: Double?,
                     candidate: LZSiteFinder.Candidate,
                     alternatives: [LZSiteFinder.Candidate],
                     glideRatio: Double,
                     bestGlideKts: Double,
                     windFromDeg: Double?,
                     windKts: Double?) -> LZGlidePlan? {
        assert(glideRatio > 0, "plan: non-positive glide ratio")
        let touchdown = candidate.centre
        guard Geo.nmBetween(origin, touchdown) <= maxRunInNm else { return nil }

        let fieldFt = groundElevationFt ?? 0
        var warnings = [String]()

        // 1. WHICH WAY DOWN THE RUN. The measured run is bidirectional — a 1590 m run "lying 000"
        //    can be flown as 360 or as 180 — so the wind picks the end. Into wind is shorter ground
        //    roll and a slower touchdown, which on unprepared ground is most of the argument.
        let (finalHeading, headwind) = intoWind(runHeadingDeg: candidate.runHeadingDeg,
                                                windFromDeg: windFromDeg, windKts: windKts)
        if headwind < -5 {
            warnings.append("The best available direction along this run still has about "
                            + "\(Int(-headwind.rounded())) kt on the tail.")
        }
        if let from = windFromDeg, let kts = windKts, kts > 0 {
            // A run square to the wind has NO tailwind and no headwind, so the check above stays
            // silent — and silence there would read as "the wind is fine". It is not: the component
            // is entirely across, which is the one that runs you off the side of ground that has no
            // side to spare.
            let cross = abs(kts * sin((finalHeading - from) * .pi / 180))
            if cross > noteworthyCrosswindKts {
                warnings.append("About \(Int(cross.rounded())) kt straight across this run. There is "
                                + "no marked width here to drift within.")
            }
        }

        // 2. THE CIRCUIT, BUILT BACKWARDS FROM THE GROUND. Every height is derived from where the
        //    aeroplane must end up, never from where it happens to start.
        let ratioFor: (Double) -> Double = { heading in
            windAdjustedRatio(glideRatio, bestGlideKts: bestGlideKts, headingDeg: heading,
                              windFromDeg: windFromDeg, windKts: windKts)
        }
        let finalStart = Geo.point(from: touchdown, bearingDeg: reciprocal(finalHeading),
                                   distanceNm: finalLengthNm)
        // LEFT-HAND CIRCUIT, and the sign here is the whole of it.
        //
        // ⚠️ `finalHeading - 90` puts the downwind on the RIGHT of the final course — a right-hand
        // circuit, which is what this built for a while. It is not wrong geometry: it closes, it
        // draws correctly, and every leg joins the next. It is simply the other circuit, and nothing
        // on screen distinguishes them. Left-hand is the default a pilot flies without being told.
        //
        // Read it as: base is flown 90° to the LEFT of the landing direction, so the aeroplane turns
        // left from downwind onto base and left again onto final.
        let baseHeading = normalise(finalHeading + 90)
        let baseStart = Geo.point(from: finalStart, bearingDeg: reciprocal(baseHeading),
                                  distanceNm: baseLengthNm)
        let downwindHeading = reciprocal(finalHeading)
        let keyPosition = Geo.point(from: baseStart, bearingDeg: reciprocal(downwindHeading),
                                    distanceNm: downwindLengthNm)

        let touchdownFt = fieldFt
        let finalStartFt = touchdownFt + cost(finalLengthNm, ratioFor(finalHeading))
        let baseStartFt = finalStartFt + cost(baseLengthNm, ratioFor(baseHeading))
        let keyFt = baseStartFt + cost(downwindLengthNm, ratioFor(downwindHeading))

        // 3. THE RUN-IN, AND WHAT IT COSTS. Height at the key position is whatever is left after
        //    flying there — this is the only number in the plan that is measured forwards.
        let runInHeading = Geo.bearing(origin, keyPosition)
        let runInNm = Geo.nmBetween(origin, keyPosition)
        let runInRatio = ratioFor(runInHeading)
        let atKeyFt = altitudeFtMSL - cost(runInNm, runInRatio)

        // The circuit needs `keyFt`; the pattern floor is `keyFt` plus the height the pattern itself
        // is meant to be flown at. Margin is measured against that, not against the ground.
        let wantedAtKeyFt = max(keyFt, fieldFt + patternHeightFt)
        let margin = atKeyFt - wantedAtKeyFt
        if margin < 0 {
            warnings.append("This does not close with a circuit in hand — about "
                            + "\(Int((-margin).rounded())) ft short at the key position. Reaching "
                            + "the ground is not the same as arriving able to look at it first.")
        }

        // 4. TOO MUCH HEIGHT IS ALSO A PROBLEM, and it is the one pilots improvise badly. Planning
        //    the loss as a segment means arriving at the key position ON height rather than fast and
        //    high with a decision to make.
        var legs = [LZGlidePlan.Leg]()
        var alt = altitudeFtMSL
        if runInNm > 0 {
            legs.append(.init(kind: .runIn, from: origin, to: keyPosition, headingDeg: runInHeading,
                              distanceNm: runInNm, entryAltFtMSL: alt, exitAltFtMSL: atKeyFt,
                              glideRatio: runInRatio))
            alt = atKeyFt
        }
        // ⚠️ ANY excess is dissipated, not just a large one. The circuit is a FIXED shape that ends
        // on the ground; carrying spare height through it means the plan finishes in the air, which
        // is the same error as finishing underground and reads far more innocently. An early version
        // only dumped when the excess exceeded a whole pattern, so a plan arriving 593 ft high drew
        // a perfectly ordinary circuit that stopped 593 ft up, and nothing said so.
        if margin > 0 {
            let dumpNm = margin * runInRatio / NearestAirports.ftPerNm
            legs.append(.init(kind: .energyDump, from: keyPosition, to: keyPosition,
                              headingDeg: downwindHeading, distanceNm: dumpNm,
                              entryAltFtMSL: alt, exitAltFtMSL: wantedAtKeyFt,
                              glideRatio: runInRatio))
            alt = wantedAtKeyFt
            // Only WARN when it is enough to matter. A hundred feet is a normal adjustment; half a
            // circuit's worth is a decision, and it is the one pilots improvise badly.
            if margin > noteworthyExcessFt {
                warnings.append("You arrive about \(Int(margin.rounded())) ft high. Plan to lose it "
                                + "overhead where the ground stays in sight, not by stretching the "
                                + "circuit away from it.")
            }
        }
        legs.append(.init(kind: .downwind, from: keyPosition, to: baseStart,
                          headingDeg: downwindHeading, distanceNm: downwindLengthNm,
                          entryAltFtMSL: alt, exitAltFtMSL: alt - cost(downwindLengthNm, ratioFor(downwindHeading)),
                          glideRatio: ratioFor(downwindHeading)))
        alt = legs[legs.count - 1].exitAltFtMSL
        legs.append(.init(kind: .base, from: baseStart, to: finalStart, headingDeg: baseHeading,
                          distanceNm: baseLengthNm, entryAltFtMSL: alt,
                          exitAltFtMSL: alt - cost(baseLengthNm, ratioFor(baseHeading)),
                          glideRatio: ratioFor(baseHeading)))
        alt = legs[legs.count - 1].exitAltFtMSL
        legs.append(.init(kind: .final, from: finalStart, to: touchdown, headingDeg: finalHeading,
                          distanceNm: finalLengthNm, entryAltFtMSL: alt,
                          exitAltFtMSL: alt - cost(finalLengthNm, ratioFor(finalHeading)),
                          glideRatio: ratioFor(finalHeading)))

        if candidate.coarseTerrain {
            warnings.append("This ground is on 10 m elevation — the ditch and berm checks could "
                            + "not run here, so the surface is less known than the profile looks.")
        }

        let commit = commitPoint(origin: origin, altitudeFtMSL: altitudeFtMSL,
                                 keyPosition: keyPosition, runInNm: runInNm,
                                 runInHeading: runInHeading, groundElevationFt: fieldFt,
                                 alternatives: alternatives, glideRatio: glideRatio,
                                 bestGlideKts: bestGlideKts,
                                 windFromDeg: windFromDeg, windKts: windKts)
        if commit == nil && !alternatives.isEmpty {
            warnings.append("No alternative on the list is reachable from this track — taking it "
                            + "commits you to this ground from the start.")
        }

        assert(legs.count >= 3, "plan: a circuit needs at least downwind, base and final")
        return LZGlidePlan(legs: legs, touchdownArea: touchdown, finalHeadingDeg: finalHeading,
                           headwindKts: headwind, arrivalMarginFt: margin, commit: commit,
                           warnings: warnings)
    }

    // MARK: - pieces

    /// Height in feet to fly `nm` at `ratio`.
    static func cost(_ nm: Double, _ ratio: Double) -> Double {
        assert(ratio > 0, "cost: non-positive ratio")
        return nm * NearestAirports.ftPerNm / ratio
    }

    static func normalise(_ deg: Double) -> Double {
        let d = deg.truncatingRemainder(dividingBy: 360)
        return d < 0 ? d + 360 : d
    }

    static func reciprocal(_ deg: Double) -> Double { normalise(deg + 180) }

    /// Pick the end of a bidirectional run that gives the best headwind, and report the component.
    ///
    /// ⚠️ A run has no direction. Treating `runHeadingDeg` as the landing direction would land
    /// downwind half the time, on unprepared ground, in an aeroplane with no way to go around.
    static func intoWind(runHeadingDeg: Double, windFromDeg: Double?,
                         windKts: Double?) -> (headingDeg: Double, headwindKts: Double) {
        let a = normalise(runHeadingDeg)
        let b = reciprocal(a)
        guard let from = windFromDeg, let kts = windKts, kts > 0 else { return (a, 0) }
        let ha = headwindComponent(track: a, windFromDeg: from, windKts: kts)
        let hb = headwindComponent(track: b, windFromDeg: from, windKts: kts)
        return ha >= hb ? (a, ha) : (b, hb)
    }

    /// Positive into wind. Wind FROM `windFromDeg` opposes a track along that same bearing.
    static func headwindComponent(track: Double, windFromDeg: Double, windKts: Double) -> Double {
        windKts * cos((track - windFromDeg) * .pi / 180)
    }

    /// The same first-order wind distortion the energy footprint uses, so the plan and the shading
    /// cannot disagree about how far the aeroplane goes. Bounded identically.
    static func windAdjustedRatio(_ ratio: Double, bestGlideKts: Double, headingDeg: Double,
                                  windFromDeg: Double?, windKts: Double?) -> Double {
        guard let from = windFromDeg, let kts = windKts, kts > 0 else { return ratio }
        let vbg = max(20.0, bestGlideKts > 0 ? bestGlideKts : LZGlideField.defaultBestGlideKts)
        let tail = kts * cos((headingDeg - (from + 180.0)) * .pi / 180.0)
        let scale = min(LZGlideField.windRatioMax, max(LZGlideField.windRatioMin, (vbg + tail) / vbg))
        return ratio * scale
    }

    /// Walk the run-in and find the LAST point from which some other candidate is still reachable.
    ///
    /// Reachability is tested the same way the footprint tests it — height above the arrival reserve,
    /// spent at the wind-adjusted ratio toward that specific alternative — so a candidate that the
    /// energy layer paints as reachable is reachable here too.
    static func commitPoint(origin: Coord, altitudeFtMSL: Double, keyPosition: Coord,
                            runInNm: Double, runInHeading: Double, groundElevationFt: Double,
                            alternatives: [LZSiteFinder.Candidate], glideRatio: Double,
                            bestGlideKts: Double, windFromDeg: Double?,
                            windKts: Double?) -> LZGlidePlan.CommitPoint? {
        guard !alternatives.isEmpty, runInNm > 0 else { return nil }
        let runInRatio = windAdjustedRatio(glideRatio, bestGlideKts: bestGlideKts,
                                           headingDeg: runInHeading,
                                           windFromDeg: windFromDeg, windKts: windKts)
        var last: LZGlidePlan.CommitPoint?
        for i in 0...commitSteps {                                   // bounded (rule 2)
            let f = Double(i) / Double(commitSteps)
            let along = f * runInNm
            let here = Geo.point(from: origin, bearingDeg: runInHeading, distanceNm: along)
            let alt = altitudeFtMSL - cost(along, runInRatio)
            let usable = alt - groundElevationFt - NearestAirports.arrivalReserveFt
            guard usable > 0 else { break }
            var best: (LZSiteFinder.Candidate, Double)?
            for alt2 in alternatives {                               // bounded (rule 2)
                let d = Geo.nmBetween(here, alt2.centre)
                let brg = Geo.bearing(here, alt2.centre)
                let r = windAdjustedRatio(glideRatio, bestGlideKts: bestGlideKts, headingDeg: brg,
                                          windFromDeg: windFromDeg, windKts: windKts)
                let reach = usable * r / NearestAirports.ftPerNm
                if d <= reach, best == nil || d < best!.1 { best = (alt2, d) }
            }
            guard let (cand, d) = best else { break }
            last = .init(coord: here, altitudeFtMSL: alt, alongTrackNm: along,
                         alternativeBearingDeg: Geo.bearing(here, cand.centre),
                         alternativeDistanceNm: d)
        }
        return last
    }
}
