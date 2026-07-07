import Foundation

/// Content-based role attribution for one ATC transmission — controller vs pilot — as a Swift
/// port of `python-legacy/atc_diarize.py:classify_turn`. Parity-checked against the Python
/// reference via `role_fixtures.json` (see `TurnRoleParityTests`).
///
/// WHY content, not acoustics: ATC is single-channel, band-limited, push-to-talk, with short
/// turns and many pilots who sound alike, so voice diarization is unreliable here. The robust
/// signal is what is SAID: controllers issue instructions/clearances; pilots read back / request
/// / acknowledge. Deliberately conservative — a tie returns `.unknown` rather than guessing.
enum TurnRole: String, Sendable, Equatable {
    case controller, pilot, unknown
}

struct TurnRoleLabel: Sendable, Equatable {
    var role: TurnRole = .unknown
    var confidence: Double = 0        // 0…1 heuristic margin
}

enum TurnRoleTagger {

    /// Phrases that strongly indicate the CONTROLLER is speaking (instructions/clearances).
    static let controllerCues: [String] = [
        "cleared to land", "cleared for takeoff", "cleared for the option",
        "cleared", "contact", "fly heading", "turn left", "turn right",
        "climb and maintain", "descend and maintain", "climb", "descend", "maintain",
        "radar contact", "traffic", "wind", "expect", "reduce speed", "increase speed",
        "say again", "ident", "squawk", "go around", "line up and wait",
        "hold short", "taxi to", "taxi via", "runway", "cross runway",
        "frequency change approved", "resume own navigation", "no delay", "caution",
        "altimeter", "report", "join", "intercept",
    ]

    /// Phrases that indicate a PILOT is speaking (readbacks/requests/acknowledgements).
    static let pilotCues: [String] = [
        "with you", "checking in", "check in", "request", "requesting", "roger",
        "wilco", "we'd like", "we would like", "looking for", "unable", "going around",
        "say intentions", "ready", "in sight", "field in sight", "traffic in sight",
        "negative contact", "missed approach", "for the", "out of", "descending to",
        "climbing to", "leaving",
    ]

    /// Classify one transmission. `knowledge` supplies telephony words for callsign extraction.
    static func classify(_ text: String, knowledge: ATCKnowledgeBase?) -> TurnRoleLabel {
        let norm = CallsignSnap.normalizeForMatch(text)
        guard !norm.isEmpty else { return TurnRoleLabel() }

        let tokens = norm.split(separator: " ").map(String.init)
        let telephony = CallsignSnap.telephonyWords(knowledge)
        let callsign = CallsignSnap.extractCallsign(norm, telephony: telephony)
        let trailing = callsignIsTrailing(tokens: tokens, callsign: callsign)

        var scoreC = countCues(norm, controllerCues)
        var scoreP = countCues(norm, pilotCues)
        if trailing { scoreP += 1 }   // a transmission ENDING in the callsign is a readback tag

        if scoreC == 0 && scoreP == 0 { return TurnRoleLabel() }
        if scoreC == scoreP { return TurnRoleLabel() }   // ambiguous — stay honest

        let role: TurnRole = scoreC > scoreP ? .controller : .pilot
        let margin = abs(scoreC - scoreP)
        let confidence = (min(1.0, 0.5 + 0.25 * Double(margin)) * 100).rounded() / 100
        return TurnRoleLabel(role: role, confidence: confidence)
    }

    /// Count DISTINCT matched cue phrases, dropping any that is a substring of a longer matched
    /// cue (so "cleared to land" isn't also counted as "cleared") — mirror of `_count_cues`
    /// (`c in text` is a plain substring test on both sides; keep it that way for parity).
    static func countCues(_ text: String, _ cues: [String]) -> Int {
        let hits = cues.filter { text.contains($0) }
        return hits.filter { h in !hits.contains { o in o != h && o.contains(h) } }.count
    }

    /// True iff the full callsign span sits at the END of the transmission (a readback tag).
    /// Only "back" is a signal; "front" is ambiguous (both roles lead with a callsign) — mirror
    /// of `_callsign_position`.
    static func callsignIsTrailing(tokens: [String], callsign: String?) -> Bool {
        guard let callsign else { return false }
        let cs = callsign.split(separator: " ").map(String.init)
        guard !cs.isEmpty, cs.count <= tokens.count else { return false }
        return Array(tokens.suffix(cs.count)) == cs
    }
}
