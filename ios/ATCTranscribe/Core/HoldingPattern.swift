import Foundation

/// A published holding pattern from a coded procedure — the racetrack itself plus everything needed
/// to fly it: which way it turns, the inbound course, and how the aircraft should ENTER it.
///
/// Holds reach the app from ARINC 424 path terminators:
///
///   * `HF` — hold, terminating at the fix after ONE circuit. This is the "hold in lieu of procedure
///     turn" (HILPT) that opens an approach at the IAF (6,689 in cycle 2607, characteristically the
///     first leg of the row).
///   * `HM` — hold, terminating MANUALLY (i.e. hold until ATC clears you onward). This is the
///     missed-approach hold at the end of the row (10,223).
///   * `HA` — hold until an ALTITUDE is reached (78) — a climb-in-hold.
///
/// The pattern is charted, not invented: the fix, the inbound course and the turn direction all come
/// from the coded leg. Only the leg LENGTH is assumed — ARINC publishes it in a field the builder does
/// not yet extract — so `legMinutes` carries the ICAO/FAA standard (1 minute at or below 14,000 ft,
/// 1½ minutes above) and is marked as an assumption rather than a published value.
struct HoldingPattern: Equatable, Identifiable {
    /// Which way the turns go. ARINC codes this per leg; `R` is the standard pattern.
    enum Turn: String, Equatable { case right = "R", left = "L" }

    /// What the hold is FOR — this drives whether it may be skipped and what the UI calls it.
    enum Kind: Equatable {
        case holdInLieuOfProcedureTurn   // HF at the IAF — a course reversal
        case missedApproach              // HM at the end of the missed approach
        case holdToAltitude              // HA — climb in the hold
        case enroute                     // anything else

        /// Whether skipping is a normal, legal choice for the pilot.
        ///
        /// A HILPT is NOT required when ATC clears you straight in, when you arrive on a NoPT
        /// transition, or when radar-vectored to final — which is most of the time — so it is
        /// routinely omitted. A MISSED-APPROACH hold is the published end of the missed approach and
        /// dropping it silently would leave the procedure without its termination, so while the pilot
        /// may still choose to omit it, it is not offered as a default.
        var isRoutinelySkipped: Bool { self == .holdInLieuOfProcedureTurn }
    }

    let id: String                 // "<fix>-<seq>" — stable across rebuilds of the same procedure
    let fix: String
    let coord: Coord
    /// The INBOUND course to the fix, magnetic degrees — the course flown TOWARD the fix in the hold.
    let inboundCourseMag: Double
    let turn: Turn
    let kind: Kind
    /// Standard leg timing. ASSUMED (see the type comment), not read from the source.
    var legMinutes: Double = 1.0
    /// The published altitude text for the hold leg, verbatim ("07500"); "" when none.
    var altitudeText: String = ""

    /// The outbound course — the reciprocal of the inbound.
    var outboundCourseMag: Double { HoldingPattern.normalize(inboundCourseMag + 180) }

    // MARK: entry

    /// The three published entry procedures (AIM 5-3-8 / ICAO Doc 8168).
    enum Entry: String, Equatable {
        case direct, parallel, teardrop

        var label: String {
            switch self {
            case .direct:   return "Direct entry"
            case .parallel: return "Parallel entry"
            case .teardrop: return "Teardrop entry"
            }
        }
        /// One line of what the pilot actually does, so the card doesn't just name a sector.
        func detail(inbound: Double, outbound: Double, turn: Turn) -> String {
            let t = turn == .right ? "right" : "left"
            let opposite = turn == .right ? "left" : "right"
            switch self {
            case .direct:
                return String(format: "Cross the fix and turn %@ onto the outbound leg (%03.0f°).", t, outbound)
            case .parallel:
                return String(format: "Cross the fix, turn %@ to parallel the outbound leg (%03.0f°) on the "
                              + "non-holding side, then turn %@ to intercept inbound (%03.0f°).",
                              opposite, outbound, t, inbound)
            case .teardrop:
                // ⚠️ The 30° offset goes TOWARD the holding side, which for a RIGHT-hand pattern means
                // SUBTRACTING from the outbound course. Inbound 090 + right turns puts the racetrack
                // south of the inbound track, so the teardrop is flown on 240° — NOT 300°, which points
                // north into the unprotected non-holding side. The sign was inverted here, and a pilot
                // following it would have left protected airspace.
                return String(format: "Cross the fix, turn to about %03.0f° (30° off the outbound) on the "
                              + "holding side, then turn %@ to intercept inbound (%03.0f°).",
                              HoldingPattern.teardropHeading(outbound: outbound, turn: turn), t, inbound)
            }
        }
    }

    /// The entry procedure for an aircraft arriving at the fix on `track` (its magnetic COURSE OVER
    /// GROUND toward the fix — not a bearing FROM anything).
    ///
    /// AIM 5-3-8 divides the fix into three sectors, measured from the inbound holding course, for a
    /// STANDARD right-turn pattern:
    ///
    ///     Δ = track − inboundCourse, normalised to [0, 360)
    ///       Δ ∈ [290, 360) ∪ [0, 110)  → DIRECT    (180° — the whole holding side and then some)
    ///       Δ ∈ [110, 180)             → TEARDROP  (70°)
    ///       Δ ∈ [180, 290)             → PARALLEL  (110°)
    ///
    /// A LEFT-turn pattern is the mirror image, so the same table is applied to the mirrored angle.
    /// On a sector boundary either adjacent entry is acceptable in the real world; the boundary is
    /// assigned deterministically here so the app never shows two different answers for one geometry.
    func entry(arrivingOn track: Double) -> Entry {
        let raw = HoldingPattern.normalize(track - inboundCourseMag)
        // Mirror for a left-hand pattern so one table serves both.
        let d = turn == .right ? raw : HoldingPattern.normalize(-raw)
        if d >= 110 && d < 180 { return .teardrop }
        if d >= 180 && d < 290 { return .parallel }
        return .direct
    }

    /// The entry for an aircraft coming FROM `origin` (the previous fix, or the aircraft's present
    /// position) — the common case, where the arrival track is simply the great-circle course from
    /// there to the holding fix. Returns nil when the two points coincide and no course exists.
    func entry(arrivingFrom origin: Coord, magneticVariation: Double = 0) -> Entry? {
        guard let trueTrack = HoldingPattern.course(from: origin, to: coord) else { return nil }
        // The published inbound course is MAGNETIC, so the arrival track has to be magnetic too.
        return entry(arrivingOn: HoldingPattern.normalize(trueTrack - magneticVariation))
    }

    // MARK: geometry (for drawing the racetrack)

    /// The racetrack as a closed polyline, for the map. Built from the two straight legs plus the two
    /// 180° end turns, on the correct side of the inbound course.
    ///
    /// Standard-rate (3°/s) turns at `groundSpeedKt` give the turn radius; the straight legs are
    /// `legMinutes` long at the same speed. Bounded and allocation-light — this is drawn per frame's
    /// worth of route rebuilds, not per frame.
    func racetrack(groundSpeedKt: Double = 150, arcSteps: Int = 12) -> [Coord] {
        assert(arcSteps >= 2 && arcSteps <= 180, "racetrack: absurd arc resolution")
        assert(groundSpeedKt > 0, "racetrack: non-positive ground speed")
        let legNm = groundSpeedKt * (legMinutes / 60)
        // Standard rate: 360° in 2 min → radius = v / (π · 2) NM with v in kt... derived from
        // circumference = speed × time: 2πr = gs × (2/60) h → r = gs / (60π).
        let radiusNm = groundSpeedKt / (60 * .pi)
        let sign: Double = turn == .right ? 1 : -1
        let inbound = inboundCourseMag
        // Centre of the inbound-end turn: abeam the fix, on the holding side.
        let toHoldingSide = HoldingPattern.normalize(inbound + 90 * sign)
        let c1 = HoldingPattern.offset(coord, courseDeg: toHoldingSide, distanceNm: radiusNm)
        // The outbound leg starts at the far side of that turn and runs back along the outbound course.
        let outboundStart = HoldingPattern.offset(c1, courseDeg: toHoldingSide, distanceNm: radiusNm)
        let outboundEnd = HoldingPattern.offset(outboundStart, courseDeg: outboundCourseMag, distanceNm: legNm)
        let c2 = HoldingPattern.offset(outboundEnd, courseDeg: HoldingPattern.normalize(toHoldingSide + 180),
                                       distanceNm: radiusNm)
        let inboundStart = HoldingPattern.offset(c2, courseDeg: HoldingPattern.normalize(toHoldingSide + 180),
                                                 distanceNm: radiusNm)
        var pts: [Coord] = [coord, outboundStart]                     // fix → around the first turn
        pts.insert(contentsOf: arc(centre: c1, from: coord, steps: arcSteps, clockwise: turn == .right),
                   at: 1)
        pts.append(outboundEnd)
        pts.append(contentsOf: arc(centre: c2, from: outboundEnd, steps: arcSteps, clockwise: turn == .right))
        pts.append(inboundStart)
        pts.append(coord)                                             // inbound leg closes at the fix
        return pts
    }

    /// Intermediate points of a 180° turn about `centre`, starting at `from`.
    private func arc(centre: Coord, from: Coord, steps: Int, clockwise: Bool) -> [Coord] {
        guard let start = HoldingPattern.course(from: centre, to: from) else { return [] }
        let r = HoldingPattern.distanceNm(centre, from)
        var out: [Coord] = []
        var i = 1
        while i < steps {                                             // bounded by `steps` (rule 2)
            assert(i <= 180, "arc: step bound")
            let sweep = 180.0 * Double(i) / Double(steps) * (clockwise ? 1 : -1)
            out.append(HoldingPattern.offset(centre, courseDeg: HoldingPattern.normalize(start + sweep),
                                             distanceNm: r))
            i += 1
        }
        return out
    }

    // MARK: small geodesy (kept local so the type is testable without the map stack)

    /// The teardrop's outbound heading: 30° off the outbound course, TOWARD the holding side. Split out
    /// so the side is asserted by a test rather than buried in a format string (it was inverted there).
    /// Right-hand patterns hold to the right of the inbound course, so their teardrop is outbound − 30.
    static func teardropHeading(outbound: Double, turn: Turn) -> Double {
        normalize(outbound + (turn == .right ? -30 : 30))
    }

    static func normalize(_ deg: Double) -> Double {
        let d = deg.truncatingRemainder(dividingBy: 360)
        return d < 0 ? d + 360 : d
    }

    /// Initial great-circle course from `a` to `b`, true degrees. nil when the points coincide.
    static func course(from a: Coord, to b: Coord) -> Double? {
        let φ1 = a.lat * .pi / 180, φ2 = b.lat * .pi / 180
        let Δλ = (b.lon - a.lon) * .pi / 180
        let y = sin(Δλ) * cos(φ2)
        let x = cos(φ1) * sin(φ2) - sin(φ1) * cos(φ2) * cos(Δλ)
        guard abs(y) > 1e-12 || abs(x) > 1e-12 else { return nil }
        return normalize(atan2(y, x) * 180 / .pi)
    }

    static func distanceNm(_ a: Coord, _ b: Coord) -> Double {
        let φ1 = a.lat * .pi / 180, φ2 = b.lat * .pi / 180
        let dφ = φ2 - φ1, dλ = (b.lon - a.lon) * .pi / 180
        let h = sin(dφ / 2) * sin(dφ / 2) + cos(φ1) * cos(φ2) * sin(dλ / 2) * sin(dλ / 2)
        return 2 * 3440.065 * asin(min(1, sqrt(h)))
    }

    /// The point `distanceNm` from `from` along `courseDeg`.
    static func offset(_ from: Coord, courseDeg: Double, distanceNm: Double) -> Coord {
        let δ = distanceNm / 3440.065, θ = courseDeg * .pi / 180
        let φ1 = from.lat * .pi / 180, λ1 = from.lon * .pi / 180
        let φ2 = asin(sin(φ1) * cos(δ) + cos(φ1) * sin(δ) * cos(θ))
        let λ2 = λ1 + atan2(sin(θ) * sin(δ) * cos(φ1), cos(δ) - sin(φ1) * sin(φ2))
        return Coord(lat: φ2 * 180 / .pi, lon: (λ2 * 180 / .pi + 540).truncatingRemainder(dividingBy: 360) - 180)
    }
}

extension HoldingPattern {
    /// Build a hold from a coded leg, or nil when the leg is not a hold (or lacks the geometry to
    /// draw one). The course and turn direction are READ from the source — never inferred — so a leg
    /// missing either is not turned into a guessed pattern.
    init?(leg: CIFPLeg, kind: Kind) {
        guard ["HF", "HM", "HA"].contains(leg.legType),
              let coord = leg.coord, let course = leg.course,
              let turn = Turn(rawValue: leg.turnDirection.uppercased())
        else { return nil }
        self.init(id: "\(leg.fix)-\(leg.seq)", fix: leg.fix, coord: coord,
                  inboundCourseMag: HoldingPattern.normalize(course), turn: turn, kind: kind,
                  legMinutes: 1.0, altitudeText: leg.altitude)
    }

    /// The kind implied by an ARINC path terminator plus where the leg sits in the procedure.
    static func kind(legType: String, isMissedApproachSegment: Bool) -> Kind {
        switch legType {
        case "HA": return .holdToAltitude
        case "HM": return isMissedApproachSegment ? .missedApproach : .enroute
        case "HF": return isMissedApproachSegment ? .missedApproach : .holdInLieuOfProcedureTurn
        default:   return .enroute
        }
    }
}
