import Foundation

/// Map-label text for a route waypoint's published crossing restrictions, for the decluttered
/// `ChartLayer.smartDark` base.
///
/// Pure value logic, no I/O and no UIKit — the CIFP read happened upstream (`LegConstraint`), so this
/// stays unit-testable.
///
/// The convention is the FMS legs-page one, NOT the chart's underline/overline typography: a bare number
/// means cross AT that altitude, a trailing `A` means at-or-above, `B` at-or-below, and a window prints
/// both (`7000B 5000A`). Chart typography can't survive a single-line map label — an underline drawn as
/// glyph art would be one text-shaping change away from meaning the opposite — whereas every pilot flying
/// this app has read `A`/`B` off an FMC.
///
/// The governing rule is inherited from `LegConstraint`: an unmodelled qualifier prints NOTHING. A label
/// is an assertion about a limit, and a guessed limit on a map is worse than a blank space.
enum SmartRouteLabel {
    /// Longest label this emits (`"FL230B FL180A"`); a cap the caller can assert against.
    static let maxLabelChars = 13

    /// The altitude restriction as map-label text, or nil when nothing is published (or the qualifier is
    /// one this app deliberately does not model).
    static func altText(_ c: LegConstraint?) -> String? {
        guard let c else { return nil }
        assert(!(c.altUnmodelled && c.alt != nil), "LegConstraint: unmodelled must carry no rule")
        guard let rule = c.alt else { return nil }
        let out: String
        switch rule {
        case .at(let f):                 out = ft(f)
        case .atOrAbove(let f):          out = ft(f) + "A"
        case .atOrBelow(let f):          out = ft(f) + "B"
        case .between(let hi, let lo):   out = "\(ft(hi))B \(ft(lo))A"
        }
        assert(out.count <= maxLabelChars, "SmartRouteLabel: altitude label over cap")
        return out
    }

    /// The speed restriction as map-label text (`"210K"`), or nil when none is published.
    static func speedText(_ c: LegConstraint?) -> String? {
        guard let c, let kt = c.speedLimitKt else { return nil }
        // A non-positive or absurd speed limit is bad source data, not a restriction to draw.
        guard kt > 0, kt < 1000 else { return nil }
        return "\(kt)K"
    }

    /// Flight levels above the transition altitude, plain feet below — matching how the restriction is
    /// spoken and read back. Reuses `LegConstraint`'s own threshold so the two can't drift apart.
    private static func ft(_ f: Int) -> String {
        assert(f >= 0, "SmartRouteLabel: negative altitude")
        return f >= 18_000 ? "FL\(f / 100)" : "\(f)"
    }
}
