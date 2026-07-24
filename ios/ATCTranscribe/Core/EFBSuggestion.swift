import Foundation

/// A one-tap Electronic-Flight-Bag suggestion derived from a controller instruction addressed to the
/// pilot's own aircraft. It is INERT until the user accepts it; accepting drives an existing, reversible
/// flight-plan / map action. The action is carried as DATA (the parsed `ATCInstruction`), never a closure,
/// so the model holds no behaviour and stays trivially testable (NASA rule: no function pointers). The
/// instruction is the superset of the legacy `ATCCommand` (route clearances) plus the numeric kinds
/// (altitude / heading / speed / squawk / frequency).
struct EFBSuggestion: Identifiable, Equatable {
    let id: String                 // the source transmission's record id — one suggestion per transmission
    let instruction: ATCInstruction
    let title: String              // human-facing, e.g. "Fly direct BOSOX", "Maintain 8000 ft"
    let source: String             // the transmission text, shown as context under the chip

    /// Only route-affecting (legacy) kinds have a ForeFlight meaning — the numeric assignments do not.
    var affectsRoute: Bool { instruction.kind.isLegacyRoute }

    /// The legacy `ATCCommand` for a route kind, or nil for a numeric kind — back-compat for the bench.
    var command: ATCCommand? { instruction.legacyCommand }

    // MARK: - Titles

    /// The human-facing title for a legacy command. Pure; validates its input and never returns "".
    static func title(for command: ATCCommand) -> String {
        guard !command.target.isEmpty else { return "" }             // param check (rule 7)
        switch command.kind {
        case .directTo:        return "Fly direct " + command.target
        case .clearedApproach:
            let kind = command.qualifier.isEmpty ? "approach" : command.qualifier
            return "Load " + kind + " runway " + command.target
        case .loadSID:         return "Load " + command.target + " departure"
        case .loadStar:        return "Load " + command.target + " arrival"
        }
    }

    /// The human-facing title for an instruction (all nine kinds). Renders the parsed value prominently so
    /// the pilot cross-checks it against the raw transmission before accepting.
    static func title(for instruction: ATCInstruction) -> String {
        guard !instruction.target.isEmpty else { return "" }         // param check (rule 7)
        switch instruction.kind {
        case .directTo, .clearedApproach, .loadSID, .loadStar:
            return instruction.legacyCommand.map(title(for:)) ?? ""
        case .altitude:
            let verb: String
            switch instruction.modifier {
            case "climb":   verb = "Climb to"
            case "descend": verb = "Descend to"
            default:        verb = "Maintain"
            }
            let value = instruction.target.hasPrefix("FL") ? instruction.target : instruction.target + " ft"
            return verb + " " + value
        case .heading:
            switch instruction.modifier {
            case "left":  return "Turn left heading " + instruction.target
            case "right": return "Turn right heading " + instruction.target
            default:      return "Fly heading " + instruction.target
            }
        case .speed:
            return "Maintain " + instruction.target + " kt"
        case .squawk:
            return "Squawk " + instruction.target
        case .frequencyChange:
            let facility = instruction.modifier.isEmpty ? "" : instruction.modifier.capitalized + " "
            return "Contact " + facility + instruction.target
        }
    }

    // MARK: - Make

    /// Compose a suggestion from an instruction, or nil when the inputs are unusable (empty id / target /
    /// title). The empty-title guard is the miss-safe backstop for a malformed value.
    static func make(id: String, instruction: ATCInstruction, source: String) -> EFBSuggestion? {
        guard !id.isEmpty else { return nil }
        guard !instruction.target.isEmpty else { return nil }
        let heading = title(for: instruction)
        guard !heading.isEmpty else { return nil }
        return EFBSuggestion(id: id, instruction: instruction, title: heading, source: source)
    }

    /// Back-compat shim: compose from a legacy `ATCCommand`. Guards the empty target BEFORE lifting to an
    /// instruction (the lift asserts a non-empty target).
    static func make(id: String, command: ATCCommand, source: String) -> EFBSuggestion? {
        guard !command.target.isEmpty else { return nil }
        return make(id: id, instruction: ATCInstruction(command: command), source: source)
    }
}
