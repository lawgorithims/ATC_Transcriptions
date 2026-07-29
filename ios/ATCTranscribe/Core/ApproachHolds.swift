import Foundation

/// A holding pattern that applies to the approach being flown, with the entry worked out for the
/// direction the aircraft is actually arriving from.
struct ApproachHold: Equatable, Identifiable {
    let pattern: HoldingPattern
    /// The published entry procedure for this arrival, or nil when the arrival direction is unknown
    /// (no previous fix and no present position) — in which case the app shows the pattern but does
    /// NOT invent an entry.
    let entry: HoldingPattern.Entry?
    /// Where the arrival course was measured FROM, so the card can say why the entry is what it is.
    let arrivingFrom: String

    var id: String { pattern.id }
    var isSkippable: Bool { pattern.kind.isRoutinelySkipped }

    /// One line for the UI: what to fly, and why.
    var summary: String {
        let dir = pattern.turn == .right ? "right" : "left"
        let base = String(format: "Hold at %@ — %@ turns, inbound %03.0f°",
                          pattern.fix, dir, pattern.inboundCourseMag)
        guard let entry else { return base + " · entry depends on arrival direction" }
        return base + " · \(entry.label.lowercased()) from \(arrivingFrom)"
    }
}

/// Resolves which published holds apply to an approach, and how to enter each one.
///
/// Two holds can appear on one approach and they are used at opposite ends of it:
///
///   * The **hold in lieu of procedure turn** (HILPT) — an `HF` leg that OPENS the row at an IAF. It
///     is a course reversal, flown only when the aircraft needs to lose the arrival direction. Arrive
///     on a NoPT transition, get a straight-in clearance, or take radar vectors and it is omitted —
///     which is most of the time, so this one is offered as skippable.
///   * The **missed-approach hold** — an `HM` (or `HA`) leg that CLOSES the missed approach. It is the
///     published termination of the go-around and is not dropped by default.
///
/// The entry is computed from where the aircraft is coming FROM, which differs per hold: the HILPT is
/// entered from the aircraft's present position (or the fix preceding it in the transition), while the
/// missed-approach hold is entered from the preceding missed-approach fix. Getting that backwards
/// would name a plausible-looking but wrong entry, so each is resolved against its own predecessor.
enum ApproachHolds {

    /// The holds on one approach, resolved against `arrivingFrom` (typically the aircraft's present
    /// position at activation). Legs are supplied by the caller so this stays pure and testable.
    ///
    /// `missedSeqs` marks which legs belong to the missed-approach segment — the same split the rest
    /// of the activation path uses, passed in rather than re-derived so the two can never disagree.
    static func resolve(legs: [CIFPLeg], missedSeqs: Set<Int>,
                        arrivingFrom: Coord?, arrivingFromLabel: String = "present position",
                        magneticVariation: Double = 0) -> [ApproachHold] {
        var out: [ApproachHold] = []
        for (i, leg) in legs.enumerated() {
            assert(i <= 4096, "resolve: leg bound")
            let isMissed = missedSeqs.contains(leg.seq)
            let kind = HoldingPattern.kind(legType: leg.legType, isMissedApproachSegment: isMissed)
            guard let pattern = HoldingPattern(leg: leg, kind: kind) else { continue }

            // Where this hold is entered FROM: the preceding leg that has a position, else the
            // caller's origin. A missed-approach hold is reached from the missed approach itself, so
            // its predecessor is the right answer and the aircraft's pre-approach position is not.
            var origin = arrivingFrom
            var label = arrivingFromLabel
            if let prev = previousFix(before: i, in: legs) {
                origin = prev.coord
                label = prev.fix
            }
            let entry = origin.flatMap { pattern.entry(arrivingFrom: $0, magneticVariation: magneticVariation) }
            out.append(ApproachHold(pattern: pattern, entry: entry, arrivingFrom: label))
        }
        return out
    }

    /// The nearest earlier leg that carries a usable position and is not the hold fix repeated.
    private static func previousFix(before i: Int, in legs: [CIFPLeg]) -> (fix: String, coord: Coord)? {
        var j = i - 1
        while j >= 0 {                                            // bounded by the leg list (rule 2)
            assert(j < 4096, "previousFix: scan bound")
            let leg = legs[j]
            if let c = leg.coord, !leg.fix.isEmpty, leg.fix != legs[i].fix { return (leg.fix, c) }
            j -= 1
        }
        return nil
    }

    /// The course-reversal hold to offer at activation, if the approach publishes one AND the chosen
    /// entry actually flies it.
    ///
    /// Radar vectors put the aircraft on final with no course reversal at all, so a HILPT is not
    /// offered for a vectors join — presenting one there would invite a pilot to fly a reversal ATC
    /// did not clear. A transition/IAF join may or may not need it, which is exactly why it is a
    /// choice rather than an assumption.
    static func courseReversal(in holds: [ApproachHold], joinIsVectors: Bool) -> ApproachHold? {
        guard !joinIsVectors else { return nil }
        return holds.first { $0.pattern.kind == .holdInLieuOfProcedureTurn }
    }

    /// The published hold that ends the missed approach, if any.
    static func missedApproachHold(in holds: [ApproachHold]) -> ApproachHold? {
        holds.first { $0.pattern.kind == .missedApproach || $0.pattern.kind == .holdToAltitude }
    }
}
