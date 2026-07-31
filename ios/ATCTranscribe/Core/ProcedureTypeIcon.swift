import SwiftUI

/// The symbol shown beside a published chart in every list that offers one.
///
/// WHY THIS EXISTS, precisely — because the obvious objection is that the chart's name already says
/// what it is. Measured over all 24,078 rows of the bundled d-TPP index, that is true for approaches
/// (11,178 of 11,193 names contain their own type token — 99.9%), airport diagrams (908/908) and
/// obstacle departures (287/287). It is NOT true for the two kinds that are named after a fix:
///
///   * departures      1,862 of 2,990 self-evident — 62.3%
///   * arrivals        2,096 of 2,943 self-evident — 71.2%
///
/// So 1,975 charts are called things like "BOTCH ONE" or "TARPN TWO" and say nothing about whether
/// they take you out or bring you in. A list mixing those is genuinely ambiguous, and that — not the
/// approach rows, which read fine as text — is what the icon is for.
///
/// COLOUR IS NOT THE SIGNAL. The symbol carries the kind; colour is reserved for the one distinction
/// that is a caution rather than a category (a hot spot). Encoding five categories as five tints would
/// spend the palette's alarm vocabulary on filing.
enum ProcedureTypeIcon {

    /// SF Symbol for a published chart. Keyed on the raw FAA chart code rather than
    /// `AirportProcedure.Category`, because the category deliberately folds hot spots and hold-short
    /// charts in with airport diagrams — useful for tab grouping, wrong for an icon.
    static func symbol(for procedure: AirportProcedure) -> String {
        switch procedure.code {
        case "IAP", "CVFP": return "arrow.down.right"        // descending onto the runway
        case "DP":          return "airplane.departure"
        case "ODP":         return "airplane.departure"
        case "STR":         return "airplane.arrival"
        case "APD":         return "airplane.circle"
        case "HOT":         return "exclamationmark.triangle"
        case "LAH":         return "arrow.right.to.line"     // land and hold short
        case "MIN":         return "tablecells"              // a minimums TABLE, not a procedure
        default:            return "doc.text"
        }
    }

    /// True when this chart is a published CAUTION rather than a procedure — the one case that earns a
    /// colour. Hot spots mark surface-movement conflict areas; they are the reason a pilot scans this
    /// list before taxiing.
    static func isCaution(_ procedure: AirportProcedure) -> Bool { procedure.code == "HOT" }

    /// A short accessibility label, since the symbol alone is not readable by VoiceOver and the name
    /// may not say the kind — the same 1,975 charts that motivate the icon.
    static func accessibilityLabel(for procedure: AirportProcedure) -> String {
        switch procedure.code {
        case "IAP", "CVFP": return "Approach"
        case "DP":          return "Departure"
        case "ODP":         return "Obstacle departure"
        case "STR":         return "Arrival"
        case "APD":         return "Airport diagram"
        case "HOT":         return "Hot spot"
        case "LAH":         return "Land and hold short"
        case "MIN":         return "Minimums"
        default:            return "Chart"
        }
    }
}

/// The icon as a view, so the four listing surfaces share one appearance instead of four.
struct ProcedureTypeBadge: View {
    let procedure: AirportProcedure
    let palette: Palette
    var size: Font = .dsLabel

    var body: some View {
        Image(systemName: ProcedureTypeIcon.symbol(for: procedure))
            .font(size)
            .foregroundStyle(ProcedureTypeIcon.isCaution(procedure) ? palette.warn : palette.accent)
            .accessibilityLabel(ProcedureTypeIcon.accessibilityLabel(for: procedure))
    }
}
