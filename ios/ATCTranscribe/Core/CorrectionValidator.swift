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
    /// Normalized (no-space) labels the LLM may CITE as context but must NEVER apply as an output form
    /// — live ADS-B traffic codes (e.g. "aal1234"). Rejected as a `to` unless independently allowed, so
    /// a readable spoken callsign is never rewritten into an ADS-B code on a safety feed. (Finding #4.)
    var deniedTargets: Set<String> = []
    /// ICAO phonetic word → letter ("alpha" -> "a"). Used to verify that a spoken callsign actually
    /// spells a filed/known identifier before snapping onto it. (Finding #9.)
    var phonetic: [String: String] = [:]
    var minEditRatio = 0.55
    var maxEdits = 8
    /// The facility's real runway designators, as "num|suffix" keys ("17|C", "22|") — the snap
    /// stages' grounding veto (PR #5 Deliverable 3): an LLM edit may never INTRODUCE a runway
    /// that does not exist at the airport. Nil disables the veto (no context available).
    var groundedRunways: Set<String>? = nil

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
            guard directionWords(from) == directionWords(to) else { continue }  // (1b) no left/right flips
            guard isAllowed(to: to, from: from) else { continue }       // (2) anti-hallucination
            guard !introducesUnknownRunway(to: to, from: from) else { continue }  // (2b) grounding veto
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
        let toKey = normNoSpace(to)
        // (a) Live ADS-B traffic codes are prompt context only — never an applied output form. Reject
        // them as an edit target unless they're independently allowed (e.g. also the filed callsign).
        if deniedTargets.contains(toKey), !allowed.contains(toKey) { return false }
        // (b) A callsign/airway-shaped target — a LEADING letter followed by a digit somewhere, e.g.
        // "n345ab" or "q105", but NOT a runway like "28r" (which leads with a digit) — that is only
        // "allowed" because it's a filed/known identifier must genuinely match what was spoken: the
        // phonetic spelling of `from` must resolve to it, or the strings must be near neighbours. This
        // blocks snapping a DIFFERENT aircraft's similar callsign ("november 345 charlie delta") onto
        // the pilot's filed one ("N345AB") just because their digits coincide. Erring toward NO snap is
        // safe here — the worst case is that a genuine callsign mishear is left as the raw transcript.
        if leadsWithLetterThenDigit(toKey), allowed.contains(toKey) {
            return phoneticSkeleton(from) == toKey
                || SequenceMatcher(norm(from), norm(to)).ratio() >= minEditRatio
        }
        if allowed.contains(toKey) { return true }
        // Each word of a multi-word `to` known? (e.g. "Lone Star Approach")
        let words = to.split(separator: " ").map { normNoSpace(String($0)) }.filter { !$0.isEmpty }
        if !words.isEmpty, words.allSatisfy({ allowed.contains($0) }) { return true }
        // Otherwise only accept a plausible mishear fix (close to what was transcribed).
        return SequenceMatcher(norm(from), norm(to)).ratio() >= minEditRatio
    }

    /// The grounding veto: reject an edit whose `to` mentions a runway designator that does not
    /// exist at the facility — unless `from` already mentioned the same designator (then the edit
    /// isn't INTRODUCING it, just rephrasing around it). Conservative by construction: with no
    /// grounding (`groundedRunways == nil`) it never fires.
    private func introducesUnknownRunway(to: String, from: String) -> Bool {
        guard let grounded = groundedRunways else { return false }
        let introduced = Self.runwayKeys(in: to).subtracting(Self.runwayKeys(in: from))
        return !introduced.isEmpty && !introduced.isSubset(of: grounded)
    }

    /// Runway designators mentioned in free text, as "num|suffix" keys, matched on the canonical
    /// per-digit form ("runway 1 7 right" / "runway 17R" / "runway one seven right" all → "17|R").
    static func runwayKeys(in text: String) -> Set<String> {
        let canon = ATCNormalize.normalize(text) as NSString
        let rx = try! NSRegularExpression(
            pattern: #"\brunway((?: \d){1,2})( (?:left|right|center)(?! (?:traffic|turn|downwind|base|closed)))?\b"#)
        var out: Set<String> = []
        for m in rx.matches(in: canon as String, range: NSRange(location: 0, length: canon.length)) {
            var num = canon.substring(with: m.range(at: 1)).replacingOccurrences(of: " ", with: "")
            while num.count > 1, num.hasPrefix("0") { num.removeFirst() }
            let suffixRange = m.range(at: 2)
            let word = suffixRange.location == NSNotFound ? ""
                : canon.substring(with: suffixRange).trimmingCharacters(in: .whitespaces)
            let suffix = ["left": "L", "right": "R", "center": "C"][word] ?? ""
            out.insert(num + "|" + suffix)
        }
        return out
    }

    /// Build "num|suffix" keys from an airport's designator list (the grounding side of the veto).
    static func runwayKeys(designators: [String]) -> Set<String> {
        Set(designators.map { d -> String in
            let p = SlotSnap.parseDesignator(d)
            return p.num + "|" + p.suffix
        }.filter { !$0.hasPrefix("|") })
    }

    /// A callsign/airway-shaped identifier leads with a letter and contains a digit ("n345ab", "q105").
    /// A runway ("28r", "4l") or a bare frequency ("12865") leads with a digit, so it's excluded — those
    /// remain freely snappable (spoken "two eight right" → "28R" is a common, legitimate correction).
    private func leadsWithLetterThenDigit(_ key: String) -> Bool {
        guard let first = key.first, first.isLetter else { return false }
        return key.contains(where: \.isNumber)
    }

    /// Resolve a spoken identifier to its skeleton by mapping ICAO phonetic words to letters and number
    /// words / digit runs to digits: "november 345 charlie delta" -> "n345cd"; "november three four five
    /// alpha bravo" -> "n345ab"; "quebec one oh five" -> "q105". Unknown tokens pass through as their raw
    /// alphanumerics (so an already-coded "n345ab" resolves to itself).
    private func phoneticSkeleton(_ s: String) -> String {
        var out = ""
        for word in s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let w = String(word)
            if let letter = phonetic[w] { out += letter }                                   // alpha -> a
            else if w == "oh" { out += "0" }                                                 // ATC "oh" -> 0
            else if let n = ATCNormalize.units[w] ?? ATCNormalize.teens[w] ?? ATCNormalize.tens[w] {
                out += String(n)                                                             // niner -> 9
            } else if w.allSatisfy(\.isNumber) { out += w }                                  // 345 -> 345
            else { out += w.filter { $0.isLetter || $0.isNumber } }                          // fallback: raw
        }
        return out
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

    /// Direction/semantic-flip guard: left/right/center (and climb/descend, east/west, north/
    /// south) are protected like digits — an edit may never add, remove, or swap them. Found by
    /// the offline LLM benchmark (2026-07-06): the 0.5B model proposed "turn left"→"left…right"
    /// class flips and the per-word phraseology vocabulary let them through.
    private static let protectedSemantics: Set<String> = [
        "left", "right", "center", "climb", "descend", "north", "south", "east", "west",
    ]
    /// Protected semantic tokens in order of appearance. A runway-designator suffix counts as
    /// its direction word ("28R" ≡ "two eight right"), so legitimate spoken→designator
    /// rewrites still pass while a genuine flip/insert/delete never does.
    private func directionWords(_ s: String) -> [String] {
        s.lowercased().split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == "." })
            .compactMap { tok -> String? in
                let t = tok.filter { $0.isLetter || $0.isNumber }
                if t.count >= 2, let last = t.last, "lrc".contains(last),
                   t.dropLast().allSatisfy(\.isNumber) {
                    return ["l": "left", "r": "right", "c": "center"][String(last)]
                }
                return Self.protectedSemantics.contains(t) ? t : nil
            }
    }
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

    /// Normalize raw in-range traffic labels to the no-space keys used for the `deniedTargets` denylist.
    static func deniedTargets(from labels: [String]) -> Set<String> {
        Set(labels
            .map { String($0.lowercased().filter { ("a"..."z").contains($0) || ("0"..."9").contains($0) }) }
            .filter { !$0.isEmpty })
    }
}
