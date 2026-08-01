import Foundation

/// What the FAA publishes as a crossing restriction on one coded leg.
///
/// Pure value logic, no I/O — the CIFP read happens in the caller so this stays unit-testable.
///
/// The governing rule is that an UNRECOGNISED qualifier must produce `.unmodelled`, never a guess.
/// ARINC's altitude-description field carries step-down and glidepath variants (V, H, J, I, G, X) whose
/// meaning depends on the leg's role and on a second altitude that means different things in each. A
/// warning built on a guess about those would fire against a limit the chart does not state, which is
/// worse than staying quiet — so anything not in the four plain cases below is deliberately silent.
struct LegConstraint: Equatable {
    /// How the published altitude(s) constrain the aircraft.
    enum AltRule: Equatable {
        case at(Int)
        case atOrAbove(Int)
        case atOrBelow(Int)
        /// Between two altitudes; `high` is the published first value, `low` the second.
        case between(high: Int, low: Int)
    }

    let alt: AltRule?
    let speedLimitKt: Int?
    let verticalAngleDeg: Double?
    let rnpNm: Double?

    /// True when the source published an altitude qualifier this app does not model. Distinct from
    /// "no constraint": it means *do not draw a conclusion*, and it is why `alt` is nil here too.
    let altUnmodelled: Bool

    /// The computed vertical-path altitude the source publishes alongside the crossing restriction on
    /// the `G`/`H`/`I`/`J`/`V` qualifiers — the glideslope altitude at the FAF, the glideslope INTERCEPT
    /// altitude, or the coded VNAV path altitude at a step-down, depending on the qualifier.
    ///
    /// NOT a constraint and never labelled as one: it is where the vertical path passes, which is a
    /// different statement from where the aircraft is required to be. `alt` carries the requirement.
    /// nil on every other qualifier.
    let glidepathAltFt: Int?

    init(altDesc: String, alt altText: String, alt2 alt2Text: String,
         speedLimitKt: Int?, verticalAngleDeg: Double?, rnpNm: Double?) {
        self.speedLimitKt = speedLimitKt
        self.verticalAngleDeg = verticalAngleDeg
        self.rnpNm = rnpNm

        let a = Self.feet(altText), b = Self.feet(alt2Text)
        switch altDesc.trimmingCharacters(in: .whitespaces).uppercased() {
        case "":   alt = a.map { .at($0) };              altUnmodelled = false; glidepathAltFt = nil
        case "+":  alt = a.map { .atOrAbove($0) };       altUnmodelled = false; glidepathAltFt = nil
        case "-":  alt = a.map { .atOrBelow($0) };       altUnmodelled = false; glidepathAltFt = nil
        case "B":
            glidepathAltFt = nil
            if let a, let b { alt = .between(high: max(a, b), low: min(a, b)); altUnmodelled = false }
            else { alt = nil; altUnmodelled = true }     // "between" without both values is not usable
        // THE VERTICAL-PATH QUALIFIERS. These pair a normal procedural altitude in the FIRST field with
        // a computed glideslope / glidepath / intercept altitude in the SECOND. Falling them through to
        // "unmodelled" discarded the FIRST altitude too, and that first altitude is the published
        // crossing restriction — so on the shipped cycle 5,856 legs across 4,576 approaches drew no
        // altitude and were skipped by LegConstraintCheck, INCLUDING THE FAF ITSELF on 1,187 approaches
        // (PABE I19R-Y's FAF KAYSE is coded H/01800 and rendered blank).
        //
        // The at-vs-at-or-above split below is ARINC 424, and it is corroborated by the data rather than
        // taken on trust: on all 3,477 `V` legs that carry both values the second is at or above the
        // first (2,523 above, 953 equal, 1 anomaly), which is only consistent with field one being the
        // step-down MINIMUM and field two the VNAV path that must clear it — PABE R01R's DISVE is coded
        // 00960/00973 with a -3.0 degree angle, a path 13 ft above the minimum. H/I/J run the other way
        // (field one at or above field two), consistent with levelling at or above until intercept.
        case "G", "I":                                   // 'at' + glideslope / intercept altitude
            alt = a.map { .at($0) };                     altUnmodelled = false; glidepathAltFt = b
        case "H", "J", "V":                              // 'at or above' + glideslope / path altitude
            alt = a.map { .atOrAbove($0) };              altUnmodelled = false; glidepathAltFt = b
        default:   alt = nil;                            altUnmodelled = true;  glidepathAltFt = nil
        }
    }

    /// Feet from ARINC's altitude field: five zero-padded digits, or a flight level as `FLnnn`.
    /// Returns nil for anything else — absent stays absent.
    static func feet(_ s: String) -> Int? {
        let t = s.trimmingCharacters(in: .whitespaces).uppercased()
        guard !t.isEmpty else { return nil }
        if t.hasPrefix("FL") {
            guard let fl = Int(t.dropFirst(2)), fl > 0 else { return nil }
            return fl * 100
        }
        // ⚠️ NEGATIVE ALTITUDES ARE REAL. ARINC's altitude field is signed, and six legs in the shipped
        // cycle are below sea level — every one of them at a field that is itself below sea level:
        // KTRM's RNAV (GPS) RWY 30 threshold at -86, KCLR's RWY 08 at -145, KIPL, KBWC. Rejecting them
        // as malformed blanked the missed-approach point on four approaches and, on the two where the
        // rejected leg is the runway pseudo-fix that anchors the whole vertical profile, made the
        // approach profile strip fail to appear at all with no explanation given to the pilot.
        //
        // The floor is a plausibility bound, not a sign test: the lowest land on earth is about -1,400
        // ft, so -2,000 admits every real aerodrome while still rejecting a parse that has gone wrong.
        guard let v = Int(t), v >= -2_000 else { return nil }
        return v
    }

    /// Direct init, for deriving one constraint from others. The string-parsing init above is the only
    /// way a constraint is built from the DATABASE; this exists solely for `unioned(with:)`.
    private init(alt: AltRule?, speedLimitKt: Int?, verticalAngleDeg: Double?, rnpNm: Double?,
                 altUnmodelled: Bool, glidepathAltFt: Int?) {
        self.alt = alt; self.speedLimitKt = speedLimitKt; self.verticalAngleDeg = verticalAngleDeg
        self.rnpNm = rnpNm; self.altUnmodelled = altUnmodelled; self.glidepathAltFt = glidepathAltFt
    }

    /// The band this rule permits, as (floor, ceiling). Either end may be open.
    private var band: (floor: Int?, ceiling: Int?) {
        switch alt {
        case .at(let f):                 return (f, f)
        case .atOrAbove(let f):          return (f, nil)
        case .atOrBelow(let f):          return (nil, f)
        case .between(let hi, let lo):   return (lo, hi)
        case nil:                        return (nil, nil)
        }
    }

    /// Merge two rules published at the SAME fix into what they jointly permit.
    ///
    /// ⚠️ THE UNION, NOT THE STRICTER OF THE TWO. A procedure can pass the same fix more than once — a
    /// hold in lieu of procedure turn crosses its own fix inbound and outbound, and the two crossings
    /// carry different published altitudes. The app cannot tell WHICH pass the aircraft is on, so a rule
    /// that keeps only one of them raises a confident warning against an altitude the pilot is not on:
    /// at KAEG's RNAV RWY 22, flying the published hold at its charted 8,600 ft against a retained
    /// 13,000 ft floor produced "4,400 ft low at EYIPE" while the aircraft was exactly on the chart.
    /// Measured, 464 collapses had the retained floor more than the 700 ft warning tolerance above the
    /// discarded one.
    ///
    /// Widening under-warns — it will not flag an aircraft below the higher of the two floors — and that
    /// is the correct direction when the alternative is crying wolf at a pilot who is complying. If
    /// either side carries a qualifier the app cannot read, the result carries no rule at all, because
    /// a union with an unknown is not knowable.
    func unioned(with other: LegConstraint) -> LegConstraint {
        guard !altUnmodelled, !other.altUnmodelled else {
            return LegConstraint(alt: nil, speedLimitKt: speedLimitKt ?? other.speedLimitKt,
                                 verticalAngleDeg: verticalAngleDeg ?? other.verticalAngleDeg,
                                 rnpNm: rnpNm ?? other.rnpNm, altUnmodelled: true,
                                 glidepathAltFt: glidepathAltFt ?? other.glidepathAltFt)
        }
        // ⚠️ "STATES NOTHING" IS NOT "PERMITS EVERYTHING". `CIFPLeg.constraint` is non-optional, so a leg
        // with a blank altitude still arrives here as a fully-formed LegConstraint whose `alt` is nil.
        // Unioning that as an open band wiped the OTHER leg's real rule: measured over every adjacent
        // same-fix pair in the cycle, 1,006 legs lost a published crossing altitude and 560 a published
        // speed limit — 925 of them on STARs, which directly undid the fix that put the common
        // segment's restrictions back into constraintRoute in the first place.
        //
        // A side that states nothing is absent, not permissive. Coalesce to the other side, exactly as
        // verticalAngleDeg and rnpNm already do, and only union when BOTH sides actually state a rule.
        guard alt != nil else { return other.carryingExtras(from: self) }
        guard other.alt != nil else { return carryingExtras(from: other) }
        let a = band, b = other.band
        // An OPEN end stays open: if either rule permits arbitrarily high, so does the union.
        let floor: Int? = (a.floor == nil || b.floor == nil) ? nil : min(a.floor!, b.floor!)
        let ceiling: Int? = (a.ceiling == nil || b.ceiling == nil) ? nil : max(a.ceiling!, b.ceiling!)
        let rule: AltRule?
        switch (floor, ceiling) {
        case (nil, nil):                   rule = nil
        case (let f?, nil):                rule = .atOrAbove(f)
        case (nil, let c?):                rule = .atOrBelow(c)
        case (let f?, let c?):             rule = f == c ? .at(f) : .between(high: max(f, c), low: min(f, c))
        }
        // The invariant that matters is that the union never NARROWS: whatever either side permitted,
        // the result must still permit. ("Two stated rules collapse to no rule" is a legitimate outcome
        // — at-or-above 13,000 unioned with at-or-below 8,600 leaves nothing both crossings forbid.)
        assert(floor == nil || (floor! <= (a.floor ?? floor!) && floor! <= (b.floor ?? floor!)),
               "unioned: floor rose above one of its inputs")
        assert(ceiling == nil || (ceiling! >= (a.ceiling ?? ceiling!) && ceiling! >= (b.ceiling ?? ceiling!)),
               "unioned: ceiling fell below one of its inputs")
        // A speed LIMIT is a ceiling, so the union is the more permissive of the two — but only when
        // both state one; an absent limit is silence, not permission (same trap as the altitude above).
        let spd: Int?
        switch (speedLimitKt, other.speedLimitKt) {
        case (let x?, let y?): spd = max(x, y)
        case (let x?, nil):    spd = x
        case (nil, let y?):    spd = y
        case (nil, nil):       spd = nil
        }
        return LegConstraint(alt: rule, speedLimitKt: spd,
                             verticalAngleDeg: verticalAngleDeg ?? other.verticalAngleDeg,
                             rnpNm: rnpNm ?? other.rnpNm, altUnmodelled: false,
                             glidepathAltFt: glidepathAltFt ?? other.glidepathAltFt)
    }

    /// This constraint, keeping any non-altitude detail the other side has and it lacks. Used when the
    /// other side states no altitude rule at all, so there is nothing to union — see `unioned(with:)`.
    private func carryingExtras(from other: LegConstraint) -> LegConstraint {
        let spd: Int?
        switch (speedLimitKt, other.speedLimitKt) {
        case (let x?, let y?): spd = max(x, y)
        case (let x?, nil):    spd = x
        case (nil, let y?):    spd = y
        case (nil, nil):       spd = nil
        }
        return LegConstraint(alt: alt, speedLimitKt: spd,
                             verticalAngleDeg: verticalAngleDeg ?? other.verticalAngleDeg,
                             rnpNm: rnpNm ?? other.rnpNm, altUnmodelled: altUnmodelled,
                             glidepathAltFt: glidepathAltFt ?? other.glidepathAltFt)
    }

    /// A pilot-readable rendering of the altitude rule, for the warning's explanation.
    var altText: String? {
        switch alt {
        case .at(let f):                  return "at \(Self.ft(f))"
        case .atOrAbove(let f):           return "at or above \(Self.ft(f))"
        case .atOrBelow(let f):           return "at or below \(Self.ft(f))"
        case .between(let hi, let lo):    return "between \(Self.ft(lo)) and \(Self.ft(hi))"
        case nil:                         return nil
        }
    }

    static func ft(_ f: Int) -> String {
        f >= 18_000 ? "FL\(f / 100)" : "\(f) ft"
    }

    /// How far outside the rule `altitudeFt` sits, in feet, or nil when it complies (or nothing is
    /// published). Positive means too high, negative too low.
    func altitudeDeviation(_ altitudeFt: Int) -> Int? {
        switch alt {
        case .at(let f):
            return altitudeFt == f ? nil : altitudeFt - f
        case .atOrAbove(let f):
            return altitudeFt < f ? altitudeFt - f : nil
        case .atOrBelow(let f):
            return altitudeFt > f ? altitudeFt - f : nil
        case .between(let hi, let lo):
            if altitudeFt > hi { return altitudeFt - hi }
            if altitudeFt < lo { return altitudeFt - lo }
            return nil
        case nil:
            return nil
        }
    }
}
