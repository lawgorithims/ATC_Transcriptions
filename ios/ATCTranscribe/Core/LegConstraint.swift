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

    init(altDesc: String, alt altText: String, alt2 alt2Text: String,
         speedLimitKt: Int?, verticalAngleDeg: Double?, rnpNm: Double?) {
        self.speedLimitKt = speedLimitKt
        self.verticalAngleDeg = verticalAngleDeg
        self.rnpNm = rnpNm

        let a = Self.feet(altText), b = Self.feet(alt2Text)
        switch altDesc.trimmingCharacters(in: .whitespaces).uppercased() {
        case "":   alt = a.map { .at($0) };              altUnmodelled = false
        case "+":  alt = a.map { .atOrAbove($0) };       altUnmodelled = false
        case "-":  alt = a.map { .atOrBelow($0) };       altUnmodelled = false
        case "B":
            if let a, let b { alt = .between(high: max(a, b), low: min(a, b)); altUnmodelled = false }
            else { alt = nil; altUnmodelled = true }     // "between" without both values is not usable
        default:   alt = nil;                            altUnmodelled = true
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
        guard let v = Int(t), v >= 0 else { return nil }
        return v
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
