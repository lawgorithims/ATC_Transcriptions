import Foundation

/// What a published transition COMMITS the aircraft to before the final approach segment.
///
/// The distinction is not cosmetic. Measured over the shipped cycle, 6,243 approaches publish a course
/// reversal and 4,106 of those publish it on only SOME of their transitions — so for 40% of every coded
/// approach in the country, which feeder the pilot joins at is what decides whether a reversal is flown
/// at all. That is the fact this whole chooser exists to surface.
///
/// ⚠️ THERE ARE TWO CODINGS AND THEY DO NOT OVERLAP. The hold in lieu of procedure turn is an `HF` leg
/// (6,689 of them, all on transition rows); the plain published procedure turn — the barb printed on the
/// plate — is a `PI` leg (1,076 of them, also all on transition rows), and no approach codes both. 848
/// approaches publish their reversal ONLY as a PI, so a `.none` derived from an HF test alone would tell
/// the pilot there is no course reversal on a procedure that plainly prints one. `HoldingPattern` models
/// HF/HM/HA and not PI, which is exactly why this type exists rather than reusing the hold machinery.
enum CourseReversal: Equatable {
    /// A hold in lieu of procedure turn at this fix (`HF`). Drawn as a racetrack and skippable.
    case holdInLieu(fix: String)
    /// A published procedure turn at this fix (`PI`) — the barb. `turn` is "L"/"R" as coded.
    case procedureTurn(fix: String, turn: String, courseMag: Double?)
    /// The row was read and codes neither. Safe to state positively.
    case none
    /// The row could not be read (no legs came back). NEVER reported as "no course reversal".
    case unknown

    /// A short phrase for the chooser row. `nil` when there is nothing trustworthy to say — the caller
    /// must render nothing rather than inventing a reassurance.
    var summary: String? {
        switch self {
        case .holdInLieu(let fix):            return "hold in lieu at \(fix)"
        case .procedureTurn(let fix, let t, _):
            let side = t.uppercased().hasPrefix("L") ? "left" : (t.uppercased().hasPrefix("R") ? "right" : "")
            return side.isEmpty ? "procedure turn at \(fix)" : "\(side) procedure turn at \(fix)"
        case .none:                           return "no course reversal"
        case .unknown:                        return nil
        }
    }

    /// Does this entry require a reversal at all? `.unknown` answers `nil`, not `false`.
    var isRequired: Bool? {
        switch self {
        case .holdInLieu, .procedureTurn: return true
        case .none:                       return false
        case .unknown:                    return nil
        }
    }
}

/// One way onto an approach, with enough read off the coded record for the pilot to choose between them.
struct ApproachEntryOption: Identifiable, Equatable {
    let entry: ApproachActivation.Entry
    /// The fix the FAA marks as this transition's INITIAL APPROACH FIX — where the approach proper
    /// begins. `nil` for a vectors join, or when the row marks none.
    ///
    /// ⚠️ NOT a direct-to target, and not what the app routes to. `joinApproach` flies direct to the
    /// transition's published NAME, which is what a controller clears you via — at PABE's I19R-Z the
    /// BET transition runs BET → KAYSE with the IAF marked on KAYSE, so routing to KAYSE would skip
    /// the feeder leg the clearance named. This field says where the approach STARTS; it never says
    /// where to go.
    let initialFix: String?
    let reversal: CourseReversal
    /// How many coded legs the transition contributes, for a rough sense of its length. 0 for vectors.
    let legCount: Int

    var id: String { entry.id }
    /// What the pilot reads. ALWAYS the published transition name, never the resolved join fix — the
    /// name is what is printed on the plate and what a controller says.
    var label: String { entry.label }
}

extension ApproachActivation {

    /// Build one option from a transition's coded legs. Pure — the CIFP read happens in the caller, so
    /// this is testable against hand-built leg sequences.
    static func option(entry: Entry, legs: [CIFPLeg]) -> ApproachEntryOption {
        guard case .transition = entry else {
            // Vectors joins the final approach course directly: no transition row, so nothing to read
            // and nothing to reverse. Stating `.none` here is a fact about the join, not an inference.
            return ApproachEntryOption(entry: entry, initialFix: nil, reversal: .none, legCount: 0)
        }
        guard !legs.isEmpty else {
            return ApproachEntryOption(entry: entry, initialFix: nil, reversal: .unknown, legCount: 0)
        }
        return ApproachEntryOption(entry: entry, initialFix: initialFix(legs: legs),
                                   reversal: reversal(legs: legs), legCount: legs.count)
    }

    /// Where the approach proper begins on this transition: the leg the FAA MARKS as the initial
    /// approach fix.
    ///
    /// Read, never guessed from position. "The first leg's fix" would be a different thing entirely —
    /// KCEV's I18 transition "RID" opens with an `IF` at SHB carrying no role, and the marked IAF is SQ
    /// two legs later. Only if no leg is marked does position stand in.
    ///
    /// Runway-threshold pseudo-fixes are never an IAF — they are leg endpoints, not points anyone is
    /// cleared to.
    static func initialFix(legs: [CIFPLeg]) -> String? {
        assert(legs.count <= 512, "initialFix given an implausible leg count")
        func usable(_ l: CIFPLeg) -> Bool {
            !l.fix.isEmpty && l.coord != nil && !CIFP.isRunwayPseudoFix(l.fix)
        }
        for leg in legs.prefix(512) where leg.role == .initialApproachFix && usable(leg) {  // bounded (rule 2)
            return leg.fix.uppercased()
        }
        for leg in legs.prefix(512) where usable(leg) {                                     // bounded (rule 2)
            return leg.fix.uppercased()
        }
        return nil
    }

    /// Read the course reversal a transition publishes, checking BOTH codings. See `CourseReversal`.
    static func reversal(legs: [CIFPLeg]) -> CourseReversal {
        assert(legs.count <= 512, "reversal given an implausible leg count")
        guard !legs.isEmpty else { return .unknown }
        for leg in legs.prefix(512) {                                                       // bounded (rule 2)
            let fix = leg.fix.uppercased()
            guard !fix.isEmpty else { continue }
            if leg.legType == "HF" { return .holdInLieu(fix: fix) }
            if leg.legType == "PI" {
                return .procedureTurn(fix: fix, turn: leg.turnDirection, courseMag: leg.course)
            }
        }
        return .none
    }
}

extension CIFP {

    /// Every published way onto an approach, with each one's join fix and course reversal read off the
    /// coded record — plus VECTORS, which is always offered because ATC can always vector to final.
    ///
    /// ⚠️ ONE `procedures(airport:)` READ, then `legs(procedureID:)` per row. `CIFP.legs(airport:ident:
    /// transition:)` re-runs the whole airport query on every call, so the obvious loop is N+1 full
    /// scans of a busy airport's procedure table — 13 of them at PAOM's I28-Z, the approach with the
    /// most transitions in the country. This is called once per activation, not per view body, but the
    /// codebase has been bitten twice by database work migrating into a render path.
    static func entryOptions(airport: String, ident: String) -> [ApproachEntryOption] {
        let key = ident.uppercased()
        let rows = procedures(airport: airport).filter {
            $0.kind == "IAP" && $0.ident.uppercased() == key && !$0.transition.isEmpty
        }
        var byName: [String: Int] = [:]                      // published transition name → procedure rowid
        for row in rows.prefix(64) {                         // bounded (rule 2)
            let name = row.transition.trimmingCharacters(in: .whitespaces).uppercased()
            guard !name.isEmpty, byName[name] == nil else { continue }
            byName[name] = row.id
        }
        let entries = ApproachActivation.entries(transitions: Array(byName.keys))
        var out: [ApproachEntryOption] = []
        for entry in entries.prefix(65) {                    // bounded (rule 2)
            guard let name = entry.iafFix, let pid = byName[name] else {
                out.append(ApproachActivation.option(entry: entry, legs: []))   // vectors
                continue
            }
            out.append(ApproachActivation.option(entry: entry, legs: legs(procedureID: pid)))
        }
        assert(out.count == entries.count, "entryOptions dropped an entry")
        assert(out.contains { $0.entry == .vectors }, "entryOptions must always offer VECTORS")
        return out
    }
}
