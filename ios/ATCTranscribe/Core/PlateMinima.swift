import Foundation

/// The MINIMA BLOCK of an instrument approach plate, read off the chart the pilot is actually holding.
///
/// This is the most safety-critical number in the app, so the whole design is built around one rule:
/// **read it or refuse it — never infer it.** Minima do not exist in the coded procedure (CIFP carries
/// paths and constraints, not DA/MDA), there is no national minima feed, and a plausible-looking wrong
/// number here is worse than no number at all. So every value is extracted from the pilot's own cached
/// plate PDF, tagged with the amendment that produced it, and anything the grammar does not fully
/// account for is dropped rather than guessed at.
///
/// WHAT THE BLOCK ACTUALLY LOOKS LIKE. Under the `CATEGORY  A  B  C  D` header sits one row per approach
/// line — `S-ILS 4R`, `LPV DA`, `LNAV/VNAV DA`, `LNAV MDA`, `CIRCLING`, `RNP 0.30 DA` — and each row
/// carries between one and five *value groups*. A group that is centred across the whole band applies to
/// every category; two groups split the band; four give each category its own. The columns are separated
/// on the page by drawn rules, which are graphics and not text, so the grouping has to come from the
/// horizontal geometry of the text itself. See `assign(groups:to:)` for the rule and for the cases it
/// deliberately refuses.
///
/// CONDITIONAL BLOCKS. Some plates print a second, higher set of the same rows under a centred heading —
/// Boston's `# APPROACH MINIMA WHEN CONTROL TOWER REPORTS TALL VESSELS IN APPROACH AREA` is the canonical
/// example. On paper that is fine print a pilot has to notice, remember and apply under load. Here it
/// becomes a `ConditionalBlock`: a question with a yes/no answer that swaps the affected rows.
struct PlateMinima: Equatable {

    // MARK: categories

    /// Aircraft approach category — the FAA's speed bands (AIM 5-4-7 / 14 CFR 97.3).
    enum Category: String, CaseIterable, Identifiable, Equatable {
        case a = "A", b = "B", c = "C", d = "D", e = "E"
        var id: String { rawValue }
        /// Upper bound of V(REF) for the category, knots. `E` is open-ended (military).
        var maxSpeedKt: Int? {
            switch self {
            case .a: return 90
            case .b: return 120
            case .c: return 140
            case .d: return 165
            case .e: return nil
            }
        }
        var speedLabel: String {
            switch self {
            case .a: return "< 91 kt"
            case .b: return "91–120 kt"
            case .c: return "121–140 kt"
            case .d: return "141–165 kt"
            case .e: return "> 165 kt"
            }
        }
    }

    // MARK: visibility

    /// A published visibility: either an RVR in feet or a statute-mile figure. The two are not
    /// convertible in general — the plate publishes one or the other and the pilot flies what is
    /// published — but the TPP gives an equivalence table used when RVR is inoperative, and
    /// `rvrEquivalentFt` exists only so values can be *ordered*, never so one can be printed as the other.
    enum Visibility: Equatable, Comparable {
        case rvrFt(Int)
        /// Statute miles, in sixteenths so ½/¼/¾/1¼ stay exact in integer arithmetic.
        case statuteSixteenths(Int)

        static func sm(_ whole: Int, _ num: Int = 0, _ den: Int = 1) -> Visibility {
            assert(den > 0, "Visibility.sm: zero denominator")
            return .statuteSixteenths(whole * 16 + (num * 16) / max(den, 1))
        }

        /// Ordering key in RVR-equivalent feet, from the TPP RVR/visibility comparable-values table.
        var rvrEquivalentFt: Int {
            switch self {
            case .rvrFt(let f): return f
            case .statuteSixteenths(let s):
                switch s {
                case ..<4:  return 1_600
                case 4:     return 1_600      // ¼
                case 5...7: return 2_400      // ⅜ has no published RVR; ½ is the next published step
                case 8:     return 2_400      // ½
                case 9...10: return 3_200     // ⅝
                case 11...12: return 4_000    // ¾
                case 13...14: return 4_500    // ⅞
                case 15...16: return 5_000    // 1
                default: return 5_000 + (s - 16) * 1_000
                }
            }
        }

        static func < (l: Visibility, r: Visibility) -> Bool { l.rvrEquivalentFt < r.rvrEquivalentFt }

        var label: String {
            switch self {
            case .rvrFt(let f): return "RVR \(f)"
            case .statuteSixteenths(let s): return Self.smLabel(s) + " SM"
            }
        }

        static func smLabel(_ sixteenths: Int) -> String {
            let whole = sixteenths / 16, rem = sixteenths % 16
            let frac: String
            switch rem {
            case 0: frac = ""
            case 2: frac = "⅛"
            case 4: frac = "¼"
            case 6: frac = "⅜"
            case 8: frac = "½"
            case 10: frac = "⅝"
            case 12: frac = "¾"
            case 14: frac = "⅞"
            default: frac = "+\(rem)/16"
            }
            if whole == 0 { return frac.isEmpty ? "0" : frac }
            return frac.isEmpty ? "\(whole)" : "\(whole)\(frac)"
        }
    }

    // MARK: one published value

    /// One cell of the minima table: the altitude flown to and the visibility required.
    struct Value: Equatable {
        /// DA or MDA, feet MSL. nil only for an explicitly published `NA`.
        let altitudeFtMSL: Int?
        let visibility: Visibility?
        /// Height above touchdown (straight-in) or above airport (circling), feet — the parenthetical.
        let heightAboveFt: Int?
        /// Ceiling from the parenthetical, feet.
        let ceilingFt: Int?
        /// Published as not authorised.
        let isNA: Bool
        /// The exact characters this was read from, kept for diagnosing a bad parse.
        let rawText: String
        /// The visibility repeated inside the parentheses, in statute miles. Stored rather than derived
        /// so the cell can be redisplayed as the plate PRINTS it.
        var ceilingVisibility: Visibility?

        /// The cell as it appears on the chart — `218/18  200 (200-½)`.
        ///
        /// Rebuilt from the parsed values rather than shown as swept, because the sweep returns a typeset
        /// fraction as bare digits: `(200-12)` beside a decision altitude reads as a twelve-mile
        /// visibility and invites the pilot to distrust a figure that is correct. This is the line they
        /// check against the plate, so it has to match the plate.
        var printedForm: String {
            if isNA { return "NA" }
            guard let alt = altitudeFtMSL else { return rawText }
            var out = "\(alt)"
            switch visibility {
            case .rvrFt(let f):             out += "/\(f / 100)"
            case .statuteSixteenths(let s): out += "-" + Visibility.smLabel(s)
            case .none:                     break
            }
            if let hat = heightAboveFt { out += "  \(hat)" }
            if let c = ceilingFt {
                let vis = ceilingVisibility.map { v -> String in
                    if case .statuteSixteenths(let s) = v { return Visibility.smLabel(s) }
                    return v.label
                }
                out += " (\(c)-\(vis ?? "—"))"
            }
            return out
        }

        static func na(_ raw: String) -> Value {
            Value(altitudeFtMSL: nil, visibility: nil, heightAboveFt: nil, ceilingFt: nil,
                  isNA: true, rawText: raw)
        }
    }

    // MARK: one row

    /// What kind of minimum a row publishes — the branch that decides whether the number is a DECISION
    /// altitude (flown through, on a glidepath) or a MINIMUM DESCENT altitude (levelled at, never busted).
    enum Kind: Equatable {
        case ils, lpv, gls, rnpAR          // decision altitude
        case baroVNAV                      // decision altitude, temperature-limited
        case localizer, lnav, lp, vor, ndb, gps   // minimum descent altitude
        case circling
        case sidestep
        case other

        /// True when the published figure is a DA the aircraft descends through, false when it is an MDA
        /// it levels at. `ApproachProfile` draws these two shapes differently for the same reason.
        var usesDecisionAltitude: Bool {
            switch self {
            case .ils, .lpv, .gls, .rnpAR, .baroVNAV: return true
            default: return false
            }
        }
        var shortLabel: String {
            switch self {
            case .ils: return "ILS"
            case .lpv: return "LPV"
            case .gls: return "GLS"
            case .rnpAR: return "RNP"
            case .baroVNAV: return "LNAV/VNAV"
            case .localizer: return "LOC"
            case .lnav: return "LNAV"
            case .lp: return "LP"
            case .vor: return "VOR"
            case .ndb: return "NDB"
            case .gps: return "GPS"
            case .circling: return "CIRCLING"
            case .sidestep: return "SIDESTEP"
            case .other: return "—"
            }
        }
    }

    /// One published line of the table, with a value per category.
    struct Row: Equatable, Identifiable {
        /// The label exactly as printed — `S-ILS 4R`, `LNAV/VNAV DA`, `CIRCLING`.
        let label: String
        let kind: Kind
        /// Value per category. A category absent from the map has no published minimum on this line and
        /// must be shown as unavailable, never as "same as the neighbour".
        let values: [Category: Value]
        /// The `*` that sends the pilot to the inoperative-components table for this line.
        let hasInopAsterisk: Bool
        /// Page y of the row, used to order rows and to attach them to a conditional block.
        let pageY: Double

        var id: String { "\(label)#\(Int(pageY * 10))" }
        var categories: [Category] { Category.allCases.filter { values[$0] != nil } }
    }

    /// A second set of rows that applies only when a stated condition holds.
    struct ConditionalBlock: Equatable, Identifiable {
        /// The heading as printed, normalised to a single line.
        let heading: String
        /// A yes/no question built from the heading, for the toggle.
        let question: String
        let rows: [Row]
        var id: String { heading }
    }

    // MARK: the block

    let airport: String
    let approachName: String
    /// Base rows — what applies with no conditional block engaged.
    let rows: [Row]
    let conditionals: [ConditionalBlock]
    /// Plate notes that change the numbers: cold-temperature limits, remote-altimeter penalties, and the
    /// rest. Parsed from the note block, never assumed.
    let notes: [PlateNote]
    /// Amendment line (`Amdt 3A 13JUN24`) — the provenance shown beside every number.
    let amendment: String?
    /// Chart cycle the PDF was cached under.
    let cycle: String

    var isEmpty: Bool { rows.isEmpty }

    /// Every category any row publishes. Categories NOT in this set get blacked out in the selector —
    /// that is item 20, and the blacked-out state is information, not a disabled control.
    var publishedCategories: Set<Category> {
        var s: Set<Category> = []
        for r in rows.prefix(64) { for c in r.categories { s.insert(c) } }   // bounded (rule 2)
        return s
    }

    /// The row for `kind`, preferring the base table.
    func row(kind: Kind) -> Row? { rows.first { $0.kind == kind } }
}

/// A plate note that carries an adjustment or a restriction.
///
/// These are parsed rather than hardcoded: `LNAV/VNAV NA below -15°C` is a real published limit that
/// differs from plate to plate, and a hardcoded −15 would be silently wrong wherever the chart says
/// something else.
struct PlateNote: Equatable, Identifiable {
    enum Effect: Equatable {
        /// "When local altimeter setting not received, use X and increase all MDA nnn feet."
        case altimeterPenalty(addFt: Int, source: String)
        /// "For uncompensated Baro-VNAV, LNAV/VNAV NA below n°C (or above n°C)."
        case baroVNAVTemperatureLimit(minC: Int?, maxC: Int?)
        /// "Circling NA at night" / "Procedure NA at night" and similar hard restrictions.
        case nightRestriction(String)
        /// A note the parser recognised as conditional but whose effect it will not compute.
        case advisory
    }
    let text: String
    let effect: Effect
    var id: String { text }
}
