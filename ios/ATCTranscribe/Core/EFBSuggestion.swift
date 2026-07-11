import Foundation

/// A one-tap Electronic-Flight-Bag suggestion derived from a controller clearance addressed to the
/// pilot's own aircraft. It is INERT until the user accepts it; accepting drives an existing, reversible
/// flight-plan / map action. The action is carried as DATA (the parsed `ATCCommand`), never a closure, so
/// the model holds no behaviour and stays trivially testable (NASA rule: no function pointers).
struct EFBSuggestion: Identifiable, Equatable {
    let id: String            // the source transmission's record id — one suggestion per transmission
    let command: ATCCommand
    let title: String         // human-facing, e.g. "Fly direct BOSOX"
    let source: String        // the transmission text, shown as context under the chip

    /// The human-facing title for a command. Pure; validates its input and never returns "".
    static func title(for command: ATCCommand) -> String {
        guard !command.target.isEmpty else { return "" }             // param check (rule 7)
        switch command.kind {
        case .directTo:
            return "Fly direct " + command.target
        case .clearedApproach:
            let kind = command.qualifier.isEmpty ? "approach" : command.qualifier
            return "Load " + kind + " runway " + command.target
        }
    }

    /// Compose a suggestion, or nil when the inputs are unusable (empty id / target). Two guards act as
    /// the parameter checks with explicit recovery; the assertion documents the post-condition.
    static func make(id: String, command: ATCCommand, source: String) -> EFBSuggestion? {
        guard !id.isEmpty else { return nil }
        guard !command.target.isEmpty else { return nil }
        let heading = title(for: command)
        assert(!heading.isEmpty, "a valid command must yield a non-empty title")
        return EFBSuggestion(id: id, command: command, title: heading, source: source)
    }
}
