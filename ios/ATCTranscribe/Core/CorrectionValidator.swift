import Foundation

/// Guardrails for LLM-proposed corrections — the safety net that makes a tiny, fallible 0.5B
/// model usable on a safety-relevant feed. It does **not** trust the model's free-form
/// `corrected` text. Instead it takes the model's *edit list*, keeps only the edits that pass
/// three checks, and applies those (and only those) to the raw transcript itself. Every
/// surviving change is therefore explained by a recorded edit, numbers can't move, and the
/// model can't smuggle in a wholesale rewrite.
///
/// Checks per edit:
///   1. **Numbers preserved** — `from` and `to` must contain the exact same digit sequence
///      (so the model can never alter a heading, altitude, frequency, or squawk).
///   2. **Anti-hallucination** — `to` must be a known term (vocab / phraseology / callsign /
///      facility name) *or* be a near neighbour of `from` (`SequenceMatcher.ratio >= minEditRatio`).
///      A `to` that is neither is a fabrication and is dropped.
///   3. **Applicable** — `from` must actually occur (token-aligned) in the transcript; an edit
///      referencing text that isn't there is dropped.
/// Plus a whole-correction cap (`maxEdits`) to refuse a shotgun rewrite outright.
struct CorrectionValidator {
    /// Normalized (lowercased, non-alphanumerics stripped, spaces removed) allowed `to` forms:
    /// every vocab term, callsign, facility name, and phraseology phrase the LLM may introduce.
    let allowed: Set<String>
    var minEditRatio = 0.55
    var maxEdits = 8

    /// Apply the safe subset of `edits` to `raw`, returning a transparent `Correction`.
    func validate(raw: String, edits: [CorrectionEdit], backend: String) -> Correction {
        guard !edits.isEmpty else { return .unchanged(raw, backend: backend) }
        guard edits.count <= maxEdits else { return .unchanged(raw, backend: backend) }

        var tokens = raw.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var applied: [CorrectionEdit] = []

        for edit in edits {
            let from = edit.from.trimmingCharacters(in: .whitespaces)
            let to = edit.to.trimmingCharacters(in: .whitespaces)
            guard !from.isEmpty, !to.isEmpty, norm(from) != norm(to) else { continue }
            guard digits(from) == digits(to) else { continue }          // (1) numbers preserved
            guard isAllowed(to: to, from: from) else { continue }       // (2) anti-hallucination
            guard let replaced = replaceFirst(in: tokens, from: from, to: to) else { continue }  // (3) applicable
            tokens = replaced
            applied.append(CorrectionEdit(from: from, to: to,
                                          reason: edit.reason.isEmpty ? "llm" : edit.reason,
                                          confidence: edit.confidence, backend: backend))
        }

        let corrected = tokens.joined(separator: " ")
        if applied.isEmpty || corrected == raw { return .unchanged(raw, backend: backend) }
        return Correction(raw: raw, corrected: corrected, changed: true, edits: applied, backend: backend)
    }

    // MARK: Checks

    private func isAllowed(to: String, from: String) -> Bool {
        if allowed.contains(normNoSpace(to)) { return true }
        // Each word of a multi-word `to` known? (e.g. "Lone Star Approach")
        let words = to.split(separator: " ").map { normNoSpace(String($0)) }.filter { !$0.isEmpty }
        if !words.isEmpty, words.allSatisfy({ allowed.contains($0) }) { return true }
        // Otherwise only accept a plausible mishear fix (close to what was transcribed).
        return SequenceMatcher(norm(from), norm(to)).ratio() >= minEditRatio
    }

    /// Replace the first token-aligned occurrence of `from` (1+ words) with `to`, matching on
    /// normalized form so casing/punctuation don't block it. Returns nil if `from` isn't present.
    private func replaceFirst(in tokens: [String], from: String, to: String) -> [String]? {
        let fromTokens = from.split(separator: " ").map { norm(String($0)) }.filter { !$0.isEmpty }
        guard !fromTokens.isEmpty else { return nil }
        let normed = tokens.map(norm)
        let n = tokens.count, w = fromTokens.count
        guard w <= n else { return nil }
        for i in 0...(n - w) where Array(normed[i..<(i + w)]) == fromTokens {
            var out = Array(tokens[0..<i])
            out.append(contentsOf: to.split(separator: " ").map(String.init))
            out.append(contentsOf: tokens[(i + w)...])
            return out
        }
        return nil
    }

    // MARK: Normalization

    private func norm(_ s: String) -> String {
        String(s.lowercased().filter { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == " " })
            .trimmingCharacters(in: .whitespaces)
    }
    private func normNoSpace(_ s: String) -> String {
        String(s.lowercased().filter { ("a"..."z").contains($0) || ("0"..."9").contains($0) })
    }
    private func digits(_ s: String) -> String { String(s.filter { $0.isNumber }) }
}

extension CorrectionValidator {
    /// Build the allowed-term set from a retrieved context + the knowledge base: every term the
    /// LLM is permitted to introduce, in normalized (no-space) form, including whole-phrase keys
    /// for multi-word phraseology.
    static func allowedTerms(retrieved: RetrievedContext,
                             knowledge: ATCKnowledgeBase,
                             freqType: String) -> Set<String> {
        func key(_ s: String) -> String {
            String(s.lowercased().filter { ("a"..."z").contains($0) || ("0"..."9").contains($0) })
        }
        var set = Set<String>()
        func add(_ items: [String]) {
            for item in items {
                set.insert(key(item))                                   // whole-phrase key
                for word in item.split(separator: " ") { set.insert(key(String(word))) }  // per-word
            }
        }
        add(retrieved.vocab)
        add(knowledge.allTelephonyNames)
        add(knowledge.allSpokenNames)
        add(knowledge.phrases(forType: freqType))
        add(knowledge.spellingHints(forType: freqType))
        add(Array(knowledge.phonetic.values))
        set.remove("")
        return set
    }
}
