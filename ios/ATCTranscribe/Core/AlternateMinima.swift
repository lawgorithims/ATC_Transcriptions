import Foundation

/// IFR ALTERNATE MINIMUMS — what ceiling and visibility this airport must be forecast to have before
/// it may be filed as an alternate (14 CFR 91.169).
///
/// A different chart and a different question from the approach minima. The approach minima say how low
/// you may descend once you are there; these say whether you may PLAN on it at all, hours earlier.
///
/// ⚠️ THE STANDARD IS THE DEFAULT AND THE CHART ONLY PRINTS EXCEPTIONS. Standard is 600-2 for a
/// precision approach and 800-2 for a non-precision one; the booklet lists an airport only when
/// something is NON-standard, and a listed approach still uses the standard figure unless a footnote
/// says otherwise. So an absent footnote means "standard", not "unknown" — the one place in this file
/// where silence is an answer rather than a gap.
struct AlternateMinima: Equatable {

    /// 14 CFR 91.169 standard alternate minima, from the booklet's own header.
    static let precisionCeilingFt = 600
    static let nonPrecisionCeilingFt = 800
    static let standardVisibilitySM = 2.0

    let airport: String
    let entries: [Entry]
    /// Footnote number → its text, exactly as printed.
    let footnotes: [Int: String]

    /// One approach listed for this airport.
    struct Entry: Equatable, Identifiable {
        /// As printed — "ILS or LOC Rwy 4", "RNAV (GPS) Rwy 22".
        let name: String
        /// The runway it serves, resolved against the airport's PUBLISHED runways. See `split`.
        let runway: String
        /// Footnote markers attached to this line, in order.
        let footnoteIDs: [Int]
        var id: String { name + runway + footnoteIDs.map(String.init).joined() }

        /// Precision for the purposes of 91.169. The booklet's own header defines the split: precision
        /// is ILS, PAR and GLS; everything else — NDB, VOR, LOC, TACAN, LDA, SDF, ASR, RNAV (GPS) and
        /// RNAV (RNP) — is non-precision. ⚠️ An RNAV approach is NON-precision here even when it
        /// publishes an LPV line, which is the opposite of how the same words are read on the approach
        /// chart, and getting it backwards understates the required ceiling by 200 ft.
        var isPrecision: Bool {
            let n = name.uppercased()
            if n.contains("LOC") && !n.contains("ILS") { return false }
            return n.contains("ILS") || n.contains("PAR") || n.contains("GLS")
        }

        var standardCeilingFt: Int {
            isPrecision ? AlternateMinima.precisionCeilingFt : AlternateMinima.nonPrecisionCeilingFt
        }
    }

    /// A condition a footnote attaches, insofar as this app can classify it.
    ///
    /// ⚠️ `.other` IS NOT A FAILURE and must be shown verbatim. The footnotes carry a long tail of
    /// one-off restrictions, and a condition the app cannot classify is still a condition the pilot
    /// must read — dropping it because no toggle matches would be the worst possible outcome.
    enum Condition: Equatable {
        /// "NA when local weather not available" — the commonest by far.
        case naWithoutLocalWeather
        /// "NA when control tower closed" and its variants.
        case naWhenTowerClosed
        /// Non-standard minima for specific approach categories.
        case categoryMinima(String)
        /// Anything else, printed as-is.
        case other(String)

        /// The condition as a pilot reads it. The two classified cases are reworded into full
        /// sentences; anything else is printed VERBATIM, because a condition the app cannot classify
        /// is still one that must be read exactly as published.
        var displayText: String {
            switch self {
            case .naWithoutLocalWeather: return "NA when local weather is not available."
            case .naWhenTowerClosed:     return "NA when the control tower is closed."
            case .categoryMinima(let t): return t
            case .other(let t):          return t
            }
        }

        static func classify(_ text: String) -> Condition {
            let t = text.uppercased()
            if t.contains("NA WHEN") || t.contains("NOT AUTHORIZED") || t.hasPrefix("NA ") {
                if t.contains("WEATHER") { return .naWithoutLocalWeather }
                if t.contains("TOWER") || t.contains("ATCT") { return .naWhenTowerClosed }
            }
            // A category-specific line names a category and a ceiling-visibility pair.
            if t.range(of: "CAT [A-E]", options: .regularExpression) != nil,
               t.range(of: "[0-9]{3,4}-", options: .regularExpression) != nil {
                return .categoryMinima(text)
            }
            return .other(text)
        }
    }

    /// The conditions attached to one entry, in printed order.
    func conditions(for entry: Entry) -> [Condition] {
        entry.footnoteIDs.compactMap { footnotes[$0] }.map(Condition.classify)
    }

    /// Is this approach usable as an alternate given what the pilot has told us?
    ///
    /// ⚠️ FAILS TOWARD UNUSABLE, and says which condition decided it. `localWeatherAvailable` and
    /// `towerOpen` are PILOT-SET: neither is derivable from the bundle. `airport.tower` carries a
    /// facility TYPE ("ATCT", "NON-ATCT") and no schedule — grepping the whole schema for hours,
    /// times or operation finds nothing — so the app must ask rather than assume, and an unanswered
    /// question is treated as the restrictive case.
    func usability(_ entry: Entry, localWeatherAvailable: Bool, towerOpen: Bool) -> Usability {
        for c in conditions(for: entry) {                        // bounded by footnote count (rule 2)
            switch c {
            case .naWithoutLocalWeather where !localWeatherAvailable:
                return .notAuthorised("local weather not available")
            case .naWhenTowerClosed where !towerOpen:
                return .notAuthorised("control tower closed")
            default: continue
            }
        }
        return .authorised
    }

    enum Usability: Equatable {
        case authorised
        case notAuthorised(String)
        var isAuthorised: Bool { self == .authorised }
    }
}
