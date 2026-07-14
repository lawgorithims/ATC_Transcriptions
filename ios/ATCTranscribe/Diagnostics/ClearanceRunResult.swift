import Foundation

// The result of replaying one scenario through the real detector — what the bench UI renders.

/// How one scripted transmission behaved when replayed.
struct TransmissionResult: Identifiable, Equatable, Sendable {
    let id: String
    let text: String
    let toOwnship: Bool         // was it addressed to our aircraft (intent)?
    let firedSuggestion: Bool   // did THIS line stage a plan change?
    let commandKind: String?    // the staged command's kind, if any
    let commandTarget: String?  // the staged command's target, if any
    /// True when this line behaved as the scenario intends: the ownship target fired (positive) /
    /// stayed silent (fail-safe target), and every decoy stayed silent.
    let asExpected: Bool
}

/// The verdict for a whole scenario run.
struct ScenarioRunResult: Identifiable, Equatable, Sendable {
    let scenarioID: String
    let title: String
    let passed: Bool
    let summary: String                 // one-line plain-English verdict
    let transmissions: [TransmissionResult]
    let resultingPlanSummary: String?   // the amended plan after accept (positive scenarios)
    let didAmendPlan: Bool              // true when a plan change was staged + accepted (→ send-to-FF)
    var id: String { scenarioID }
}
