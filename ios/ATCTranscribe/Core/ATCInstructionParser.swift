import Foundation

/// Parses a NORMALIZED controller transcript into a structured `ATCInstruction`. Route clearances
/// (direct-to / approach / SID / STAR) are delegated to the unchanged `ATCCommandParser` and lifted;
/// the numeric instructions (altitude / heading / speed / squawk / frequency) are parsed here, reusing
/// `ATCCommandParser`'s ownship-clause scoping and retraction guard so a value spoken to ANOTHER aircraft
/// in the same transmission never binds to ownship. Pure + static (NASA/JPL Power-of-10): bounded scans,
/// parameters validated with recovery, invariant asserts.
enum ATCInstructionParser {

    private static let altitudeVerbs: Set<String> = ["maintain", "climb", "descend", "descending"]
    private static let speedVerbs: Set<String> = ["reduce", "increase"]
    // Benign words allowed between an altitude/speed verb and its number ("climb and maintain 8 thousand").
    private static let valueFillers: Set<String> = ["and", "to", "at", "maintain", "speed", "your"]

    /// Parse one instruction, or nil. When `addressee` is supplied, a numeric instruction binds only inside
    /// ownship's own clause (opened by an instruction verb), exactly like the legacy parser's gate.
    static func parse(_ normalized: String, grounding: ATCCommandParser.Grounding, snap: SnapGrounding?,
                      asr: ASRConfidence, addressee: ATCCommandParser.Addressee? = nil) -> ATCInstruction? {
        // Route clearances take precedence (they map to reversible route mutations).
        if let cmd = ATCCommandParser.parse(normalized, grounding: grounding, addressee: addressee) {
            let kind = ATCInstructionKind(rawValue: cmd.kind.rawValue) ?? .directTo
            let conf = ATCInstructionConfidence.assess(kind: kind, snap: snap, asr: asr)
            return ATCInstruction(command: cmd, confidence: conf, addressedToOwnship: true, rawTranscript: normalized)
        }
        guard !normalized.isEmpty, normalized.count <= ATCCommandParser.maxChars else { return nil }
        let tokens = ATCCommandParser.tokenize(normalized)
        guard tokens.count >= 2 else { return nil }
        assert(tokens.count <= ATCCommandParser.maxTokens, "tokenizer exceeded its cap")
        var scoped = tokens
        if let addressee {
            guard let (range, after) = ATCCommandParser.ownshipSegment(tokens, addressee: addressee) else { return nil }
            guard ATCCommandParser.efbClauseOpens(tokens, from: after) else { return nil }
            scoped = Array(tokens[range])
        }
        guard !ATCCommandParser.containsRetraction(scoped) else { return nil }
        return parseNumeric(scoped, asr: asr, snap: snap)
    }

    // MARK: numeric dispatch

    private static func parseNumeric(_ tokens: [String], asr: ASRConfidence, snap: SnapGrounding?) -> ATCInstruction? {
        let bound = min(tokens.count, ATCCommandParser.maxTokens)
        assert(bound <= ATCCommandParser.maxTokens, "numeric scan over an oversized token list")
        for i in 0..<bound {                                        // bounded by maxTokens
            switch tokens[i] {
            case "squawk":
                if let sq = ATCNumberComposer.composeSquawk(tokens, from: i + 1) {
                    return build(.squawk, target: sq.text, value: sq.value, unit: "squawk", modifier: "",
                                 tokens: tokens, asr: asr, snap: snap)
                }
            case "heading":
                if let h = ATCNumberComposer.composeHeading(tokens, from: i + 1) {
                    return build(.heading, target: h.text, value: h.value, unit: "deg",
                                 modifier: turnDirectionBefore(tokens, index: i),
                                 tokens: tokens, asr: asr, snap: snap)
                }
            case "contact", "monitor":
                if let f = frequencyAfter(tokens, from: i + 1) {
                    return build(.frequencyChange, target: f.freq.text, value: nil, unit: "MHz",
                                 modifier: facilityWord(tokens, from: i + 1, upTo: f.index),
                                 tokens: tokens, asr: asr, snap: snap)
                }
            default: break
            }
        }
        return parseVertical(tokens, asr: asr, snap: snap)
    }

    /// Altitude or airspeed, opened by a climb/descend/maintain (altitude, unless a "knots" unit follows)
    /// or a reduce/increase (always speed) verb.
    private static func parseVertical(_ tokens: [String], asr: ASRConfidence, snap: SnapGrounding?) -> ATCInstruction? {
        let bound = min(tokens.count, ATCCommandParser.maxTokens)
        for i in 0..<bound {                                        // bounded by maxTokens
            let isAlt = altitudeVerbs.contains(tokens[i])
            let isSpd = speedVerbs.contains(tokens[i])
            guard isAlt || isSpd else { continue }
            guard let vstart = valueStart(tokens, from: i + 1) else { continue }
            if isSpd || speedUnitNear(tokens, from: vstart), let s = ATCNumberComposer.composeSpeed(tokens, from: vstart) {
                return build(.speed, target: s.text, value: s.value, unit: "kt", modifier: "",
                             tokens: tokens, asr: asr, snap: snap)
            }
            if isAlt, let a = ATCNumberComposer.composeAltitude(tokens, from: vstart) {
                return build(.altitude, target: a.text, value: a.value, unit: "ft", modifier: altitudeModifier(tokens[i]),
                             tokens: tokens, asr: asr, snap: snap)
            }
        }
        return nil
    }

    // MARK: helpers

    /// Index of the first number-starting token (a digit or "flight") after `from`, skipping benign
    /// fillers; nil if a non-filler intervenes first. Bounded window (a value follows its verb closely).
    private static func valueStart(_ tokens: [String], from: Int) -> Int? {
        guard from >= 0 else { return nil }
        let bound = min(tokens.count, from + 4)
        var i = from
        while i < bound {                                           // bounded by the constant window
            if ATCCommandParser.digit(tokens[i]) != nil || tokens[i] == "flight" { return i }
            guard valueFillers.contains(tokens[i]) else { return nil }
            i += 1
        }
        return nil
    }

    /// True when a knots unit word sits within a few tokens after a number — the cue that a "maintain N"
    /// is a SPEED, not an altitude. Bounded window.
    private static func speedUnitNear(_ tokens: [String], from: Int) -> Bool {
        guard from >= 0 else { return false }
        let bound = min(tokens.count, from + 5)
        for i in from..<bound where tokens[i] == "knots" || tokens[i] == "knot" { return true }
        return false
    }

    /// A "turn left/right" direction in the two tokens before "heading" (licensed by a preceding "turn";
    /// a bare "fly heading" yields no modifier). Bounded (constant window).
    private static func turnDirectionBefore(_ tokens: [String], index i: Int) -> String {
        let low = max(0, i - 2)
        var sawTurn = false
        var dir = ""
        for k in low..<i {                                          // bounded (≤2)
            if tokens[k] == "turn" { sawTurn = true }
            if tokens[k] == "left" { dir = "left" }
            if tokens[k] == "right" { dir = "right" }
        }
        return sawTurn ? dir : ""
    }

    /// The first parseable frequency at/after `from` (skipping the facility name), with its index. Bounded.
    private static func frequencyAfter(_ tokens: [String], from: Int)
        -> (index: Int, freq: (text: String, mhz: Double))? {
        guard from >= 0 else { return nil }
        let bound = min(tokens.count, from + 6)
        for i in from..<bound {                                     // bounded window
            if let f = ATCNumberComposer.composeFrequency(tokens, from: i) { return (i, f) }
        }
        return nil
    }

    /// The last alphabetic (facility) word between the contact anchor and the frequency ("tower"/"ground"/
    /// "approach"/"center"…), or "".
    private static func facilityWord(_ tokens: [String], from: Int, upTo: Int) -> String {
        guard from >= 0 else { return "" }
        var name = ""
        let bound = min(upTo, tokens.count)
        for i in from..<bound where tokens[i].allSatisfy(\.isLetter) { name = tokens[i] }
        return name
    }

    private static func altitudeModifier(_ verb: String) -> String {
        switch verb {
        case "climb": return "climb"
        case "descend", "descending": return "descend"
        default: return "maintain"
        }
    }

    private static func build(_ kind: ATCInstructionKind, target: String, value: Int?, unit: String,
                              modifier: String, tokens: [String], asr: ASRConfidence,
                              snap: SnapGrounding?) -> ATCInstruction {
        assert(!target.isEmpty, "a numeric instruction must carry a target")
        let conf = ATCInstructionConfidence.assess(kind: kind, snap: snap, asr: asr)
        let callsign = snap?.callsign?.snapped ?? snap?.callsign?.original ?? ""
        return ATCInstruction(kind: kind, target: target, value: value, unit: unit, modifier: modifier,
                              callsign: callsign, rawTranscript: tokens.joined(separator: " "),
                              confidence: conf, addressedToOwnship: true)
    }
}
