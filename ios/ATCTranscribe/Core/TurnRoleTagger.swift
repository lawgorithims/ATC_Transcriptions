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
        "cleared", "contact", "fly heading", "heading", "turn left", "turn right",
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
    /// STRUCTURAL first (callsign position), lexical second — mirror of the updated Python
    /// `classify_turn`. A trailing callsign is a pilot readback (echoed controller cues ignored);
    /// a leading callsign is the controller iff it also instructs, else a pilot check-in.
    static func classify(_ text: String, knowledge: ATCKnowledgeBase?) -> TurnRoleLabel {
        let norm = CallsignSnap.normalizeForMatch(text)
        guard !norm.isEmpty else { return TurnRoleLabel() }

        let tokens = norm.split(separator: " ").map(String.init)
        let telephony = CallsignSnap.telephonyWords(knowledge)
        let callsign = CallsignSnap.extractCallsign(norm, telephony: telephony)
        let position = callsignPosition(tokens: tokens, callsign: callsign)
        let scoreC = countCues(norm, controllerCues)
        let scoreP = countCues(norm, pilotCues)

        func conf(_ v: Double) -> Double { (min(1.0, v) * 100).rounded() / 100 }

        // 1) Trailing callsign = readback / ident -> pilot (echoed controller cues ignored).
        if position == .back {
            return TurnRoleLabel(role: .pilot, confidence: scoreP > 0 ? 0.8 : 0.65)
        }
        // 2) Leading callsign: controller if it instructs, else a pilot check-in / request.
        if position == .front {
            if scoreC > 0 && scoreC >= scoreP {
                return TurnRoleLabel(role: .controller,
                                     confidence: conf(0.6 + 0.2 * Double(scoreC - scoreP)))
            }
            return TurnRoleLabel(role: .pilot, confidence: 0.65)
        }
        // 3) No positional signal -> lexical cue counts decide.
        if scoreP > scoreC {
            return TurnRoleLabel(role: .pilot, confidence: conf(0.5 + 0.25 * Double(scoreP - scoreC)))
        }
        if scoreC > scoreP {
            return TurnRoleLabel(role: .controller, confidence: conf(0.5 + 0.25 * Double(scoreC - scoreP)))
        }
        // 4) Tie / no cues: a lone callsign leans pilot (ident/ack); otherwise unknown.
        if callsign != nil {
            return TurnRoleLabel(role: .pilot, confidence: 0.5)
        }
        return TurnRoleLabel()
    }

    /// Count DISTINCT matched cue phrases, dropping any that is a substring of a longer matched
    /// cue (so "cleared to land" isn't also counted as "cleared") — mirror of `_count_cues`
    /// (`c in text` is a plain substring test on both sides; keep it that way for parity).
    static func countCues(_ text: String, _ cues: [String]) -> Int {
        let hits = cues.filter { text.contains($0) }
        return hits.filter { h in !hits.contains { o in o != h && o.contains(h) } }.count
    }

    enum CallsignPosition { case front, back, mid, none }

    /// Weight-class words spoken AFTER a callsign ("delta two thirty two heavy") — they trail the
    /// callsign span, so allow them when testing for a trailing/readback callsign. Mirror of
    /// `_WEIGHT_SUFFIX`.
    static let weightSuffix: Set<String> = ["heavy", "super"]

    /// Where the full callsign span sits — mirror of `_callsign_position`. Checks BACK before
    /// FRONT (order matters for parity); a trailing weight-class word still counts as BACK.
    /// "back" = readback tag; "front" = leading callsign; "mid"/"none" = no positional signal.
    static func callsignPosition(tokens: [String], callsign: String?) -> CallsignPosition {
        guard let callsign else { return .none }
        let cs = callsign.split(separator: " ").map(String.init)
        guard !cs.isEmpty, cs.count <= tokens.count else { return .none }
        var tail = tokens
        while let last = tail.last, weightSuffix.contains(last) { tail.removeLast() }
        if cs.count <= tail.count, Array(tail.suffix(cs.count)) == cs { return .back }
        if Array(tokens.prefix(cs.count)) == cs { return .front }
        return .mid
    }
}
