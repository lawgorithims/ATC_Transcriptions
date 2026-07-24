import Foundation

/// Grades a parsed `ATCInstruction` as high/medium/low from the three deterministic signals already
/// produced upstream for the transmission: the callsign snap verdict, Whisper's own ASR confidence, and
/// (for kinds that have one) the relevant slot verdict. The grade is the ordinal `min` of the three, so a
/// single soft signal caps it below `high`. Pure + static → trivially testable (NASA Power-of-10).
enum ATCInstructionConfidence {

    /// - Parameters:
    ///   - kind: the parsed instruction's kind (selects which slot verdict, if any, is relevant).
    ///   - snap: the transmission's snap grounding (callsign + slot verdicts), or nil offline.
    ///   - asr: Whisper's per-transmission confidence (`.unknown` for non-Whisper callers/tests → neutral).
    static func assess(kind: ATCInstructionKind, snap: SnapGrounding?, asr: ASRConfidence) -> ATCConfidence {
        let callsign = callsignLevel(snap?.callsign)
        let asrLevel = asrLevel(asr)
        let slot = slotLevel(kind: kind, snap: snap)
        let result = min(callsign, min(asrLevel, slot))
        assert([ATCConfidence.low, .medium, .high].contains(result), "confidence out of range")
        return result
    }

    /// Callsign verdict → level. `no_callsign` is NEUTRAL (medium), not suspicion: the ownship addressing
    /// gate has already confirmed ownship was named, so a missing snap extraction is not evidence of a
    /// mishear (mirrors the pipeline's "absence of evidence ≠ suspicion" rule).
    private static func callsignLevel(_ cs: CallsignSnap.Result?) -> ATCConfidence {
        guard let cs else { return .medium }
        switch cs.verdict {
        case "verified_exact": return .high
        case "snapped":        return .medium
        case "unverified":     return .low
        default:               return .medium      // no_callsign
        }
    }

    /// ASR confidence → level, reusing the gate's own avgLogprob cutoffs. `.unknown` (offline / tests) is
    /// treated as confident so a non-Whisper path is never penalized.
    private static func asrLevel(_ asr: ASRConfidence) -> ATCConfidence {
        if asr == .unknown { return .high }
        if asr.avgLogprob >= -0.55 { return .high }
        if asr.avgLogprob >= -0.85 { return .medium }
        return .low
    }

    /// The relevant slot verdict for kinds that have deterministic slot grounding (frequency, and the
    /// legacy runway approach). Altitude/heading/speed/squawk have no slot grounding → neutral high.
    private static func slotLevel(kind: ATCInstructionKind, snap: SnapGrounding?) -> ATCConfidence {
        guard let snap else { return .high }
        let wanted: String
        switch kind {
        case .frequencyChange: wanted = "frequency"
        case .clearedApproach: wanted = "runway"
        default: return .high
        }
        guard let edit = snap.slots.first(where: { $0.slot == wanted }) else { return .high }
        switch edit.verdict {
        case "verified": return .high
        case "snapped":  return .medium
        default:         return .low      // unverified | invalid
        }
    }
}
