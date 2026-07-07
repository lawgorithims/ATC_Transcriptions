import Foundation

/// CallsignSnap — deterministic callsign correction against a live candidate list (fresh ADS-B
/// traffic in telephony form). Swift port of `python-legacy/callsign_snap.py`, validated
/// byte-identical via `snap_fixtures.json` (see `SnapParityTests`).
///
/// Measured on the US gold set: false callsign attributions 13.7% → 2.0% (whisper-small-us).
/// Two channels: the TEXT is rewritten only on a confident unique snap (unverified stays exactly
/// as heard — display honesty); the `verdict` gates aircraft ATTRIBUTION (unverified = abstain)
/// and feeds the confidence gate + LLM grounding.
enum CallsignSnap {

    struct Result: Sendable, Equatable {
        /// verified_exact | snapped | unverified | no_callsign
        let verdict: String
        var original: String?     // canonical callsign as heard
        var snapped: String?      // canonical callsign after snap (attribution-safe)
        var applied = false       // true iff the text was rewritten
    }

    /// Spoken aviation digit words + grouping cardinals (mirror of `atc_diarize._DIGIT_WORDS`).
    /// "fourty" is an ATCNormalize-only alias absent from the Python reference set — removed
    /// for byte-parity of extraction spans.
    static let digitWords: Set<String> = Set(ATCNormalize.units.keys)
        .union(ATCNormalize.teens.keys).union(ATCNormalize.tens.keys)
        .union(["hundred", "thousand"]).subtracting(["fourty"])

    /// ICAO phonetic letters (mirror of `atc_diarize._PHONETIC_WORDS`).
    static let phoneticWords: Set<String> = [
        "alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel",
        "india", "juliet", "juliett", "kilo", "lima", "mike", "november", "oscar",
        "papa", "quebec", "romeo", "sierra", "tango", "uniform", "victor", "whiskey",
        "xray", "x-ray", "yankee", "zulu",
    ]

    /// Lowercase telephony first-words that anchor an airline callsign ("delta", "united", …).
    /// Built from the knowledge base at call time so Python (airport_context) and Swift
    /// (airlines.json) stay behaviorally aligned; a small embedded fallback keeps the stage
    /// usable if the knowledge resource is missing.
    static func telephonyWords(_ knowledge: ATCKnowledgeBase?) -> Set<String> {
        var names: Set<String> = ["american", "delta", "united", "southwest", "jetblue",
                                  "spirit", "frontier", "alaska", "skywest", "fedex", "ups"]
        for name in knowledge?.allTelephonyNames ?? [] {
            if let first = name.lowercased().split(separator: " ").first { names.insert(String(first)) }
        }
        return names
    }

    /// Lowercase + strip to ASCII a-z/0-9 spaced tokens (mirror of `_normalize_for_match`,
    /// whose regex keeps only `[a-z0-9\s]` — non-ASCII Whisper output must tokenize the same
    /// way on both sides).
    static func normalizeForMatch(_ text: String) -> String {
        var s = ""
        for ch in text.lowercased() {
            s.append((("a"..."z").contains(ch) || ("0"..."9").contains(ch) || ch == " ") ? ch : " ")
        }
        return s.split(separator: " ").joined(separator: " ")
    }

    /// Best-effort spoken-callsign span (mirror of `atc_diarize.extract_callsign`): an airline
    /// telephony word or "november" followed by a run of digit words / numerals / phonetics.
    static func extractCallsign(_ text: String, telephony: Set<String>) -> String? {
        let tokens = normalizeForMatch(text).split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return nil }

        func isDigitish(_ t: String) -> Bool { digitWords.contains(t) || t.allSatisfy(\.isNumber) && !t.isEmpty }
        func run(from idx: Int) -> String {
            var out = [tokens[idx]]
            var j = idx + 1
            while j < tokens.count, isDigitish(tokens[j]) || phoneticWords.contains(tokens[j]) {
                out.append(tokens[j]); j += 1
            }
            return out.joined(separator: " ")
        }

        for (i, tok) in tokens.enumerated() where tok == "november" && i + 1 < tokens.count {
            if isDigitish(tokens[i + 1]) || phoneticWords.contains(tokens[i + 1]) { return run(from: i) }
        }
        for (i, tok) in tokens.enumerated() where telephony.contains(tok) && i + 1 < tokens.count {
            if isDigitish(tokens[i + 1]) { return run(from: i) }
        }
        return nil
    }

    /// Nearest unambiguous candidate for a canonical callsign, else nil (mirror of
    /// `match_callsign`): distance = 2·edit(telephony word) + edit(number block); ties between
    /// two real aircraft mean genuine ambiguity → abstain. Everything compares in
    /// `ATCNormalize` canonical per-digit space; the canonical match is returned.
    static func matchCallsign(_ cs: String, candidates: [String],
                              maxAirlineEd: Int = 2, maxNumEd: Int = 1) -> String? {
        let (ha, hn) = splitCallsign(ATCNormalize.normalize(cs))
        var scored: [(Int, String)] = []
        for raw in candidates {
            let c = ATCNormalize.normalize(raw)
            let (ca, cn) = splitCallsign(c)
            let da = levenshtein(ha, ca), dn = levenshtein(hn, cn)
            if da <= maxAirlineEd, dn <= maxNumEd { scored.append((2 * da + dn, c)) }
        }
        guard !scored.isEmpty else { return nil }
        scored.sort { $0.0 < $1.0 || ($0.0 == $1.0 && $0.1 < $1.1) }
        if scored.count > 1, scored[0].0 == scored[1].0 { return nil }
        return scored[0].1
    }

    /// Snap the transcript's callsign (mirror of `snap_transcript`). Returns the text in
    /// normalized-token space (the corrector pipeline's working space) plus the verdict.
    static func snapTranscript(_ text: String, candidates: [String],
                               telephony: Set<String>) -> (text: String, result: Result) {
        let norm = normalizeForMatch(text)
        guard let span = extractCallsign(norm, telephony: telephony) else {
            return (text, Result(verdict: "no_callsign"))
        }
        let heard = ATCNormalize.normalize(span)
        guard let match = matchCallsign(heard, candidates: candidates) else {
            return (text, Result(verdict: "unverified", original: heard))
        }
        if match == heard {
            return (text, Result(verdict: "verified_exact", original: heard, snapped: match))
        }
        // SECURITY (red-hat 2026-07-07): the candidate list comes from UNAUTHENTICATED ADS-B
        // (airplanes.live) — anyone can inject a ghost aircraft one digit off from a real one.
        // So the digit-changing rewrite path is disabled: the pilot-visible callsign DIGITS are
        // never invented from traffic. A snap may fix only the misheard AIRLINE WORD / phonetics
        // (digits identical to a live aircraft); if the digits differ, we display as heard and
        // do NOT attribute (verdict "unverified"). Digit correction is the exclusive domain of
        // guarded stages, never a single spoofable source.
        let (_, heardNum) = splitCallsign(heard)
        let (_, matchNum) = splitCallsign(match)
        guard heardNum == matchNum else {
            return (text, Result(verdict: "unverified", original: heard))
        }
        let tokens = norm.split(separator: " ").map(String.init)
        let sToks = span.split(separator: " ").map(String.init)
        if sToks.count <= tokens.count {
            for i in 0...(tokens.count - sToks.count) where Array(tokens[i..<(i + sToks.count)]) == sToks {
                let rebuilt = (tokens[0..<i] + match.split(separator: " ").map(String.init) + tokens[(i + sToks.count)...])
                    .joined(separator: " ")
                return (rebuilt, Result(verdict: "snapped", original: heard, snapped: match, applied: true))
            }
        }
        // span found by the extractor but not relocatable verbatim — do no harm
        return (text, Result(verdict: "unverified", original: heard))
    }

    /// Canonical callsign → (telephony word, number/letter remainder without spaces).
    static func splitCallsign(_ cs: String) -> (String, String) {
        let parts = cs.split(separator: " ").map(String.init)
        guard let first = parts.first else { return ("", "") }
        return (first, parts.dropFirst().joined())
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        if a == b { return 0 }
        let aa = Array(a), bb = Array(b)
        var prev = Array(0...bb.count)
        for (i, ca) in aa.enumerated() {
            var cur = [i + 1]
            cur.reserveCapacity(bb.count + 1)
            for (j, cb) in bb.enumerated() {
                cur.append(min(prev[j + 1] + 1, cur[j] + 1, prev[j] + (ca == cb ? 0 : 1)))
            }
            prev = cur
        }
        return prev[bb.count]
    }
}
