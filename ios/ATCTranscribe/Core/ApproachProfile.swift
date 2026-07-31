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
    static func build(legs: [CIFPLeg], threshold: Coord?, thresholdElevFt: Double?,
                      airport: String, approachName: String) -> ApproachProfile {
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
            guard let co = leg.coord, let threshold else { continue }
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
        let guided = Self.impliesVerticalGuidance(approachName)
        // The farthest leg that has a coordinate, in the same order the stations were sorted into.
        let outer = stations.first.flatMap { st in
            legs.first { $0.fix == st.fix && $0.coord != nil }?.coord
        }
        return ApproachProfile(stations: stations, descentAngleDeg: angle,
                               thresholdCrossingAltFt: crossing ?? thresholdElevFt.map { $0 + 50 },
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
    static func impliesVerticalGuidance(_ name: String) -> Bool {
        let n = name.uppercased()
        if n.contains("LOC") && !n.contains("ILS") { return false }      // LOC-only: no glideslope
        if n.contains("ILS") || n.contains("GLS") || n.contains("JPALS") { return true }
        // RNAV procedures publish LPV / LNAV+VNAV lines with a real glidepath; an RNAV chart without a
        // vertical line still codes an advisory angle, which the caller shows as advisory anyway.
        if n.contains("RNAV") || n.contains("GPS") || n.contains("RNP") { return true }
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
    func position(of coord: Coord, altitudeFtMSL: Double, threshold: Coord?) -> Position? {
        guard let threshold, let outer = stations.first else { return nil }
        let d = Geo.nmBetween(coord, threshold)
        // A little slack past the threshold so the symbol does not vanish in the flare, and a little
        // beyond the outermost fix so joining traffic still appears.
        guard d <= outer.distanceToThresholdNm + 2, d >= -0.5 else { return nil }
        return Position(distanceNm: d, altitudeFtMSL: altitudeFtMSL,
                        deviationFt: deviationFt(altitudeFtMSL: altitudeFtMSL, atNm: d),
                        insideFAF: faf.map { d <= $0.distanceToThresholdNm } ?? false)
    }
}
