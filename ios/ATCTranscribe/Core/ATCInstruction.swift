import Foundation

// Structured ATC instruction (pipeline gap D). A SIBLING of `ATCCommand`, deliberately kept separate so
// the narrow, heavily-tested `ATCCommand` (four reversible clearance kinds) is unchanged: this superset
// adds the spoken NUMERIC instructions — altitude / heading / speed / squawk / frequency — that a
// controller issues to the pilot's own aircraft, each carrying a parsed value + a confidence grade.
//
// This file follows the NASA/JPL "Power of 10" rules (Swift adaptation): no recursion, small functions,
// parameters validated on entry with explicit recovery, invariant assertions.

/// The instruction kinds the app can surface. The first four MIRROR `ATCCommandKind` 1:1 (same raw
/// values, so a legacy command lifts losslessly and bench string-compares still match); the last five
/// are the new numeric kinds.
enum ATCInstructionKind: String, Equatable, Sendable {
    case directTo          // legacy — proceed/cleared direct <FIX or AIRPORT>
    case clearedApproach   // legacy — cleared <type> approach runway <RR>
    case loadSID           // legacy — climb via the <NAME> <n> departure
    case loadStar          // legacy — descend via the <NAME> <n> arrival
    case altitude          // climb/descend/maintain <feet or FL>
    case heading           // (turn left/right | fly) heading <ddd>
    case speed             // maintain/reduce/increase <kt>
    case squawk            // squawk <4 octal digits>
    case frequencyChange   // contact/monitor <facility> <MHz>

    /// True for the four legacy kinds that drive a reversible ROUTE mutation (and are the only ones the
    /// ForeFlight hand-off can carry).
    var isLegacyRoute: Bool {
        switch self {
        case .directTo, .clearedApproach, .loadSID, .loadStar: return true
        default: return false
        }
    }
}

/// A three-level confidence grade for a parsed instruction (drives the UI 🟢🟡🔴 and the actionable gate).
/// `Comparable` so a confidence is the ordinal `min` of its input signals.
enum ATCConfidence: String, Equatable, Sendable, Comparable {
    case low, medium, high

    private var rank: Int {
        switch self { case .low: return 0; case .medium: return 1; case .high: return 2 }
    }
    static func < (a: ATCConfidence, b: ATCConfidence) -> Bool { a.rank < b.rank }
}

/// A parsed ATC instruction. Pure value type — trivially testable. `target` is the canonical display
/// string for EVERY kind (fix/runway/ident for the legacy kinds; "8000"/"FL180"/"090"/"250"/"1200"/
/// "124.5" for the numeric ones); `value` is the machine number (feet / degrees / knots / squawk-as-int)
/// for range checks, nil where only the string form matters (frequency). `rawTranscript` is the
/// normalized source it was parsed from — the input the digit-preservation validator re-checks.
struct ATCInstruction: Equatable, Sendable {
    let kind: ATCInstructionKind
    let target: String
    let qualifier: String        // legacy approach type / "airport"; "" for numeric kinds
    let value: Int?              // feet / degrees / knots / squawk-as-int; nil for frequency
    let unit: String             // "ft" | "deg" | "kt" | "squawk" | "MHz" | ""
    let modifier: String         // "climb"|"descend"|"maintain" | "left"|"right" | facility word | ""
    let callsign: String         // ownship callsign as heard/known; "" if none
    let rawTranscript: String    // the normalized span the instruction was parsed from
    let confidence: ATCConfidence
    let addressedToOwnship: Bool

    /// A parsed instruction is one-tap actionable only when addressed to ownship AND not low-confidence —
    /// a low-confidence numeric value (e.g. a possibly-misheard altitude) is displayed/logged, never staged.
    var isActionable: Bool { addressedToOwnship && confidence != .low }

    /// Lift a legacy `ATCCommand` into an instruction losslessly (the four route kinds). Used by the
    /// compat `EFBSuggestion.make(id:command:source:)` shim and the parser's legacy passthrough.
    init(command: ATCCommand, confidence: ATCConfidence = .high,
         addressedToOwnship: Bool = true, rawTranscript: String = "") {
        assert(!command.target.isEmpty, "a legacy command must carry a target")
        self.kind = ATCInstructionKind(rawValue: command.kind.rawValue) ?? .directTo
        self.target = command.target
        self.qualifier = command.qualifier
        self.value = nil
        self.unit = ""
        self.modifier = ""
        self.callsign = ""
        self.rawTranscript = rawTranscript
        self.confidence = confidence
        self.addressedToOwnship = addressedToOwnship
    }

    /// Full designated initializer for the numeric kinds.
    init(kind: ATCInstructionKind, target: String, qualifier: String = "", value: Int? = nil,
         unit: String = "", modifier: String = "", callsign: String = "", rawTranscript: String = "",
         confidence: ATCConfidence, addressedToOwnship: Bool) {
        self.kind = kind
        self.target = target
        self.qualifier = qualifier
        self.value = value
        self.unit = unit
        self.modifier = modifier
        self.callsign = callsign
        self.rawTranscript = rawTranscript
        self.confidence = confidence
        self.addressedToOwnship = addressedToOwnship
    }

    /// The legacy `ATCCommand` for a route kind, or nil for a numeric kind (back-compat for the bench /
    /// any caller that still speaks `ATCCommand`).
    var legacyCommand: ATCCommand? {
        guard kind.isLegacyRoute, let k = ATCCommandKind(rawValue: kind.rawValue) else { return nil }
        return ATCCommand(kind: k, target: target, qualifier: qualifier)
    }
}
