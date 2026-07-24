import Foundation

/// The at-a-glance grounding/cleanliness grade for one transcript line, driving the 🟢🟡🔴 dot. Derived
/// from the best per-line signals the pipeline already produces: whether the line was ATTRIBUTED to a real
/// aircraft (`callsignKey`), the numeric confidence-gate estimate, and the refinement state. Pure + static
/// → trivially testable. Orthogonal to the AI-fixer status text (which reports the LLM stage).
enum LineConfidence: Equatable {
    case high, medium, low

    static func of(_ r: TranscriptRecord) -> LineConfidence {
        if r.refinementState == .pending { return .medium }         // AI still running → don't assert green
        let attributed = r.callsignKey != nil                        // matched to a real aircraft key
        let heardCallsign = r.callsign != nil
        let c = r.gateConfidence                                      // 0…1
        if attributed && c >= 0.75 { return .high }                  // grounded + clean
        if !heardCallsign && c < 0.45 { return .low }                // no callsign recovered + gate flagged
        return .medium                                               // heard-but-unverified, or AI-touched
    }
}
