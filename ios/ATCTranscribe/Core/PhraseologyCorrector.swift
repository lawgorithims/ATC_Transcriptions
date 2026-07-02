import Foundation

/// Deterministic, CONSERVATIVE ATC phraseology / homophone repair — a fast inline stage that fixes a
/// small set of high-frequency, unambiguous multi-word mis-hears that the vocab-snapping
/// `DeterministicCorrector` can't touch (it snaps single tokens onto a facility vocab list and has no
/// notion of standard multi-word phraseology). Every rule is word-bounded and context-gated where a
/// word is ambiguous, so a correct readback can never be corrupted, and every change is recorded as a
/// transparent `CorrectionEdit`. Model-free and facility-config-INDEPENDENT, so it works on any feed
/// — including the wrong-airport / no-config case. Runs BEFORE `DeterministicCorrector` in the chain.
///
/// Kept intentionally small + high-precision: a rule fires only where the corrected phrase is standard
/// ATC and the input is a recognized mis-hear. Number/homophone tokens (to/two, for/four) are left to
/// `ATCNormalize` + `DeterministicCorrector` — this stage only handles multi-word phraseology. Extend
/// the table as real mis-hears surface (e.g. from device transcripts).
struct PhraseologyCorrector: Corrector {
    /// (regex pattern, replacement template, reason). Case-insensitive, word-bounded.
    static let rules: [(pattern: String, to: String, reason: String)] = [
        // "hold short of [runway] …" — almost always followed by "of"; on compressed VHF Whisper
        // renders "hold" as heal/hill/hole and "short" as shore (confirmed live: "heal short of 4 left").
        (#"\b(?:heal|hill|hole|hold)\s+(?:short|shore)\s+of\b"#, "hold short of", "hold short"),
        (#"\b(?:heal|hill|hole)\s+short\b"#, "hold short", "hold short"),
        // "flight level ###"
        (#"\bflight\s+(?:lever|letter|levels|leveled)\b"#, "flight level", "flight level"),
        // "line up and wait"
        (#"\bline\s+up\s+(?:in|end)\s+wait\b"#, "line up and wait", "line up and wait"),
        // "<ATC subject> in sight" — gated on an ATC subject so the ordinary word "insight" elsewhere
        // is never touched.
        (#"\b(traffic|airport|field|runway|numbers|tower|bridge)\s+insight\b"#, "$1 in sight", "in sight"),
    ]

    func correct(_ text: String, history: [String]) async -> Correction {
        var current = text
        var edits: [CorrectionEdit] = []
        for rule in Self.rules {
            guard let re = try? NSRegularExpression(pattern: rule.pattern, options: [.caseInsensitive]) else { continue }
            let full = NSRange(current.startIndex..., in: current)
            guard let m = re.firstMatch(in: current, range: full), let mr = Range(m.range, in: current) else { continue }
            let matched = String(current[mr])
            let matchedTo = re.stringByReplacingMatches(in: matched, range: NSRange(matched.startIndex..., in: matched), withTemplate: rule.to)
            let replaced = re.stringByReplacingMatches(in: current, range: full, withTemplate: rule.to)
            if replaced != current {
                edits.append(CorrectionEdit(from: matched, to: matchedTo, reason: rule.reason, backend: "deterministic"))
                current = replaced
            }
        }
        if edits.isEmpty || current == text { return .unchanged(text, backend: "deterministic") }
        return Correction(raw: text, corrected: current, changed: true, edits: edits, backend: "deterministic")
    }
}
