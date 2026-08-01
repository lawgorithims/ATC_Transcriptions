import Foundation

/// The APPROACH PROFILE — the side-on view of the final segment, and the aircraft's place in it.
///
/// This is the chart's profile view expressed as data: reading left to right in the direction of flight,
/// it answers the one question that view exists to answer — *at every point along the final approach
/// course, how low may I be, and how do I get down?* The plan view says where; this says how low.
///
/// THE ONE BRANCH THAT MATTERS. Vertical guidance and altitude constraints are not two renderings of the
/// same thing:
///   * WITH guidance (ILS, LPV, LNAV/VNAV) the aircraft rides a fixed angle to a DECISION ALTITUDE. The
///     path descends through DA; there is no level-off, and at DA you are going around or you are visual.
///   * WITHOUT it (LOC, VOR, LNAV) the vertical plan is a sequence of FLOORS ending at a MINIMUM DESCENT
///     ALTITUDE, which is level and held until the missed approach point.
/// A DA is a point ON a descending line. An MDA is a horizontal floor with a horizontal end. Rendering
/// them the same way would teach the wrong picture, so `verticalAngleDeg` being present or absent decides
/// the shape of everything below.
///
/// WHAT THIS DELIBERATELY DOES NOT KNOW. **DA and MDA values are not in CIFP** — they are chart-only, and
/// no amount of leg data recovers them. So this draws the published PATH and the published CONSTRAINTS
/// and plots the aircraft against them; it never prints a minimum, and never implies one. The plate is
/// still the authority for minima, and the profile says so rather than leaving a gap that looks like an
/// answer.
///
/// Likewise the ADVISORY angle on a non-precision approach (`VDA`) is **not obstacle-assessed below the
/// MDA**. Where the FAA finds the visual segment penetrated it publishes no angle at all — so a missing
/// `verticalAngleDeg` means "do not synthesise guidance here", never "interpolate something".
struct ApproachProfile: Equatable {

    /// One point along the final segment, ordered from the farthest fix in to the threshold.
    struct Station: Equatable, Identifiable {
        let fix: String
        /// Along-track distance from this fix to the landing threshold, NM. Always >= 0.
        let distanceToThresholdNm: Double
        let constraint: LegConstraint?
        let role: LegRole
        var id: String { "\(fix)-\(String(format: "%.2f", distanceToThresholdNm))" }

        var isFAF: Bool { role == .finalApproachFix }
        var isMAP: Bool { role == .missedApproachPoint }
        /// The floor this fix imposes, feet MSL — what the profile line may not go below here.
        var floorFt: Double? {
            switch constraint?.alt {
            case .at(let f), .atOrAbove(let f): return Double(f)
            case .between(_, let low):          return Double(low)
            case .atOrBelow, .none:             return nil
            }
        }
        /// The ceiling this fix imposes, if any.
        var ceilingFt: Double? {
            switch constraint?.alt {
            case .at(let f), .atOrBelow(let f): return Double(f)
            case .between(let high, _):         return Double(high)
            case .atOrAbove, .none:             return nil
            }
        }
    }

    /// Ordered outermost → threshold.
    let stations: [Station]
    /// Published descent angle, degrees POSITIVE (CIFP codes it negative for a descent). nil when the
    /// procedure publishes none — see the type comment: that is a statement, not a gap.
    let descentAngleDeg: Double?
    /// Altitude the coded path crosses the threshold at, feet MSL (threshold elevation + TCH). Read from
    /// the runway leg's own published altitude, which is exactly that sum.
    let thresholdCrossingAltFt: Double?
    /// Landing threshold elevation, feet MSL, when it can be established.
    let thresholdElevFt: Double?
    let airport: String
    let approachName: String
    /// True when the published angle is an electronic glidepath rather than an advisory descent angle.
    /// Drives the DA-vs-MDA rendering branch and the wording; the two are not interchangeable.
    let hasVerticalGuidance: Bool
    /// Ground position of the outermost station — the only coordinate the profile keeps, so the terrain
    /// walk has a direction to follow. See `stationCoord`.
    let outerCoord: Coord?

    var faf: Station? { stations.first { $0.isFAF } }
    var map: Station? { stations.first { $0.isMAP } }
    /// Fixes between the FAF and the MAP that impose their own floor — the stepdowns.
    var stepdowns: [Station] {
        guard let faf, let map else { return [] }
        return stations.filter {
            $0.distanceToThresholdNm < faf.distanceToThresholdNm
                && $0.distanceToThresholdNm > map.distanceToThresholdNm
                && $0.floorFt != nil
        }
    }
    /// Enough to draw: at least a FAF and a threshold anchor.
    var isDrawable: Bool { faf != nil && thresholdCrossingAltFt != nil && stations.count >= 2 }

    static let ftPerNm = 6076.115

    // MARK: the three primitives

    /// Altitude of the published path at `d` NM from the threshold, feet MSL.
    ///
    /// `alt(d) = thresholdCrossingAlt + d * tan(theta)`, anchored at the threshold rather than at the FAF
    /// because the threshold crossing height is the fixed end of the geometry — the FAF crossing altitude
    /// is a minimum the aircraft arrives at, not a point the path is pinned to. (This is why the path
    /// altitude at the FAF is typically just BELOW the published FAF minimum: the aircraft levels there
    /// and intercepts from beneath, which is the correct picture.)
    func pathAltitudeFt(atNm d: Double) -> Double? {
        guard let tca = thresholdCrossingAltFt, let angle = descentAngleDeg, d >= 0 else { return nil }
        assert(angle > 0 && angle < 12, "ApproachProfile: implausible descent angle")
        return tca + d * Self.ftPerNm * tan(angle * .pi / 180)
    }

    /// Where the path is at `alt` feet MSL, as a distance from the threshold. nil below the crossing
    /// altitude (the path never gets there before the runway) or with no published angle.
    func distanceNm(forAltitudeFt alt: Double) -> Double? {
        guard let tca = thresholdCrossingAltFt, let angle = descentAngleDeg, alt > tca else { return nil }
        assert(angle > 0 && angle < 12, "ApproachProfile: implausible descent angle")
        return (alt - tca) / (Self.ftPerNm * tan(angle * .pi / 180))
    }

    /// Rate of descent to hold the path at `groundSpeedKt`, feet per minute.
    /// `VS = GS * tan(theta) * 6076.115 / 60` — the table on the chart's inside cover.
    func requiredVerticalSpeedFpm(groundSpeedKt: Double) -> Double? {
        guard let angle = descentAngleDeg, groundSpeedKt > 0 else { return nil }
        assert(angle > 0 && angle < 12, "ApproachProfile: implausible descent angle")
        return groundSpeedKt * tan(angle * .pi / 180) * Self.ftPerNm / 60
    }

    /// Height of the aircraft above the published path at `d` NM out — positive is HIGH. nil when there
    /// is no path to be above.
    func deviationFt(altitudeFtMSL: Double, atNm d: Double) -> Double? {
        pathAltitudeFt(atNm: d).map { altitudeFtMSL - $0 }
    }

    // MARK: construction

    /// Build the profile from an approach's coded legs.
    ///
    /// `legs` must be the APPROACH-PROPER row (transitions excluded, missed excluded) — the same split
    /// the rest of the activation path uses, passed in rather than re-derived so the two cannot disagree.
    /// `threshold` is the landing runway's coordinate; distances are measured to it, because that is what
    /// the geometry is anchored on and an airport reference point can be a mile from the touchdown zone.
    /// `publishedVerticalGuidance` is EVIDENCE from the chart itself — whether the plate's minima block
    /// actually prints a line flown to a decision altitude. Pass it whenever the plate has been parsed;
    /// pass nil when it has not, and the conservative name test below stands in.
    ///
    /// This is the distinction the coded data cannot make. "RNAV (GPS) RWY 17" is the title whether the
    /// chart publishes an LPV line, an LNAV/VNAV line, or an LNAV MDA and nothing else, and the ARINC
    /// FAS block that would settle it lives on continuation records the builder drops. The plate is the
    /// authority, so when the app has read the plate it should believe the plate rather than the title.
    static func build(legs: [CIFPLeg], threshold: Coord?, thresholdElevFt: Double?,
                      airport: String, approachName: String, codedRunway: String = "-",
                      publishedVerticalGuidance: Bool? = nil) -> ApproachProfile {
        assert(legs.count <= 512, "ApproachProfile: leg list bound")
        var stations: [Station] = []
        var angle: Double?
        var crossing: Double?

        for leg in legs.prefix(512) {                                   // bounded (rule 2)
            // CIFP codes a descent as a NEGATIVE angle; a positive one would be a climb and has no place
            // on a final segment, so it is refused rather than flipped.
            if let v = leg.verticalAngleDeg, v < 0, angle == nil { angle = -v }
            let c = leg.constraint
            // The runway pseudo-fix carries the threshold crossing ALTITUDE (threshold elevation + TCH)
            // as a plain "at" value — that is the anchor the whole path hangs from.
            if CIFP.isRunwayPseudoFix(leg.fix), case .at(let f)? = c.alt { crossing = Double(f) }
            guard let threshold else { continue }
            // THE RUNWAY PSEUDO-FIX IS THE THRESHOLD. `Tools/build_cifp.py` never adds RW* idents to its
            // fix table, so all 9,128 of these legs carry a NULL coordinate — and requiring one dropped
            // them as stations. That silently removed the missed-approach point from 89% of approaches
            // (the MAP tick and label never drew, and `stepdowns`, which guards on it, could never
            // return anything), and on 266 approaches it left so few stations that the vertical profile
            // strip did not appear at all — including the RNP AR approaches at Anchorage, Honolulu,
            // Fairbanks and Albuquerque, where a coded path over terrain is exactly what it exists for.
            //
            // No lookup is needed: `threshold` is already the landing threshold's position, which is
            // definitionally where this leg is. Every one of the 9,128 also has a cifp.runway row with
            // coordinates, so the value was never missing from the database — only from this path.
            let co = leg.coord ?? (CIFP.isRunwayPseudoFix(leg.fix) ? threshold : nil)
            guard let co else { continue }
            let d = Geo.nmBetween(co, threshold)
            stations.append(Station(fix: leg.fix, distanceToThresholdNm: d,
                                    constraint: c, role: leg.role))
        }
        // Outermost first: that is the direction of flight, and it is the order the view draws in.
        stations.sort { $0.distanceToThresholdNm > $1.distanceToThresholdNm }
        assert(stations.count <= 512, "ApproachProfile: station bound")

        // A published angle on the FINAL segment of a procedure that has an electronic glidepath is a
        // glidepath; on one that has not, the identical field is an ADVISORY descent angle. CIFP does not
        // label which, so the approach TYPE decides — and the distinction changes both the rendering
        // (DA on the slope vs MDA as a floor) and what the app is entitled to claim.
        // The chart wins when it has been read; the title is only the fallback.
        let guided = publishedVerticalGuidance
            ?? Self.impliesVerticalGuidance(approachName, codedRunway: codedRunway)
        // The farthest leg that has a coordinate, in the same order the stations were sorted into.
        let outer = stations.first.flatMap { st in
            legs.first { $0.fix == st.fix && $0.coord != nil }?.coord
        }
        return ApproachProfile(stations: stations, descentAngleDeg: angle,
                               // NO FABRICATED ANCHOR. The crossing altitude is the runway leg's OWN
                               // published value or nothing. The previous fallback — terrain elevation
                               // plus an assumed 50 ft TCH — hung the entire path off a max-aggregated
                               // SURFACE DEM cell (trees, buildings, hundreds of feet of error in the
                               // wrong direction) and printed the result as a number. 1,251 of 10,243
                               // approach rows carry no runway pseudo-fix, so that was not a corner
                               // case. With no anchor there is no path: `isDrawable` goes false and the
                               // strip does not appear — the same rule a missing descent angle follows.
                               thresholdCrossingAltFt: crossing,
                               thresholdElevFt: thresholdElevFt, airport: airport,
                               approachName: approachName, hasVerticalGuidance: guided,
                               outerCoord: outer)
    }

    /// Whether the approach NAME denotes a procedure flown to a decision altitude on a glidepath.
    ///
    /// Name-based because CIFP carries no "is this vertically guided" flag, and deliberately
    /// CONSERVATIVE: anything not recognised is treated as non-precision, which renders an MDA-style
    /// floor and calls the angle advisory. Being wrong that way understates the guidance available;
    /// being wrong the other way would draw a decision altitude on an approach that has none.
    static func impliesVerticalGuidance(_ name: String, codedRunway: String = "-") -> Bool {
        let n = name.uppercased()
        // CIRCLING-ONLY FIRST, because it outranks the type. "RNAV (GPS)-A" names a LETTER, not a runway:
        // the procedure publishes no straight-in line of minima at all — no glidepath, no DA, only a
        // circling MDA held level to the MAP. The RNAV rule below captured 271 of them, 89 with a coded
        // angle, and drew each as an unbroken glidepath to a decision altitude that does not exist
        // (KASE RNAV (GPS)-F codes -6.49°, KSMN -8.91°). The coded angle on a circling procedure is the
        // published descent GRADIENT, and on many of them it is the very reason it is circling-only.
        //
        // Two discriminators, because neither alone is complete: the dash-letter in the title, and the
        // procedure's own coded runway — empty for circling AND for the COPTER point-in-space titles,
        // which carry no letter either. `codedRunway` defaults to a non-empty sentinel so a caller that
        // genuinely only has a name still gets the title test.
        if ApproachActivation.circlingLetter(name) != nil { return false }
        if codedRunway.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        if n.contains("LOC") && !n.contains("ILS") { return false }      // LOC-only: no glideslope
        if n.contains("ILS") || n.contains("GLS") || n.contains("JPALS") { return true }
        // ⚠️ RNAV / GPS / RNP DELIBERATELY FALLS THROUGH TO FALSE, and the branch that used to return
        // true here was removed. Its comment claimed "an RNAV chart without a vertical line still codes
        // an advisory angle, which the caller shows as advisory anyway" — but the caller does not: a
        // `true` here draws an unbroken glidepath to a DECISION altitude and reports deviation against
        // it, which is the picture and the wording of an approach flown to a DA.
        //
        // The title cannot tell LPV from LNAV-only. "RNAV (GPS) RWY 17" is the name whether the chart
        // publishes an LPV line, an LNAV/VNAV line, or an LNAV MDA and nothing else. Cross-checking the
        // 6,775 straight-in RNAV approach rows against OCR'd cycle-2607 plates found 1,335 where the
        // chart publishes an MDA and NO vertically-guided line at all, and the app drew a glidepath to a
        // decision altitude on every one. A pilot is required to level at an MDA; a DA picture invites
        // continuing through it.
        //
        // What would settle it is the ARINC FAS data block, which lives on continuation records that
        // `Tools/build_cifp.py` drops — so it is not in the bundle and cannot be consulted here. Until
        // it is, this follows the policy stated at the top of this function rather than contradicting
        // it: unrecognised means non-precision, which renders an MDA-style floor and calls the coded
        // angle advisory. That understates the guidance on a genuine LPV, which is the safe direction.
        // The honest upgrade is `PlateMinima.Kind.usesDecisionAltitude` once the plate has been parsed
        // — real evidence rather than a guess from the title.
        return false
    }
}

extension ApproachProfile {
    /// Coordinate of the outermost station, captured at build time so the terrain walk has a direction
    /// to follow. Deliberately the ONLY coordinate the profile keeps: a coordinate on every station would
    /// invite drawing the profile as a map, which it is not.
    var outerCoordinate: Coord? { outerCoord }

    /// The aircraft's place in the profile, as the view needs it.
    struct Position: Equatable {
        /// Along-track distance to the threshold, NM.
        let distanceNm: Double
        let altitudeFtMSL: Double
        /// Height above the published path, positive = high. nil when no path is published.
        let deviationFt: Double?
        /// True once the aircraft is inside the FAF — the segment the profile is actually about.
        let insideFAF: Bool
    }

    /// Fix the aircraft in the profile from a live position. Returns nil when the aircraft is not
    /// meaningfully on this approach (behind the outermost fix, or past the threshold), so the view can
    /// say so instead of drawing an ownship pinned to an edge.
    /// How far off the final approach course the aircraft may be and still be drawn in the profile. The
    /// profile is a section along ONE line; an aircraft abeam it is not on it, and a picture that says
    /// otherwise is worse than no picture.
    static let maxCrossTrackNm = 4.0

    func position(of coord: Coord, altitudeFtMSL: Double, threshold: Coord?) -> Position? {
        guard let threshold, let outer = stations.first, let axis = outerCoord else { return nil }
        // ALONG-TRACK, NOT RANGE. `Geo.nmBetween` is an unsigned great-circle distance, so on its own it
        // describes a CIRCLE about the threshold: an aircraft on downwind, on the far side of the field,
        // or established on a different approach entirely all produced the same number and were drawn as
        // though established on this final — at an along-track position they were nowhere near, against a
        // glidepath they were not flying. Project onto the course, and reject anything too far off it.
        let range = Geo.nmBetween(coord, threshold)
        guard range > 1e-6 else {
            return Position(distanceNm: 0, altitudeFtMSL: altitudeFtMSL,
                            deviationFt: deviationFt(altitudeFtMSL: altitudeFtMSL, atNm: 0), insideFAF: true)
        }
        let courseToOuter = Geo.bearing(threshold, axis)
        let delta = (Geo.bearing(threshold, coord) - courseToOuter) * .pi / 180
        let along = range * cos(delta)          // + out along the approach course, - past the threshold
        let cross = abs(range * sin(delta))
        guard cross <= Self.maxCrossTrackNm else { return nil }
        guard along <= outer.distanceToThresholdNm + 2, along >= -0.5 else { return nil }
        let d = max(along, 0)
        return Position(distanceNm: d, altitudeFtMSL: altitudeFtMSL,
                        deviationFt: deviationFt(altitudeFtMSL: altitudeFtMSL, atNm: d),
                        insideFAF: faf.map { d <= $0.distanceToThresholdNm } ?? false)
    }
}
