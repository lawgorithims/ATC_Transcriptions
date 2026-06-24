import Foundation

/// Optional post-ASR correction layer for live ATC transcripts — the FINAL stage,
/// running on Whisper's decoded text to fix obvious errors using the airport's known
/// vocabulary. Faithful port of `atc_corrector.py`.
///
/// Two product rules carry over verbatim:
///  1. OPTIONAL — off by default (`CorrectionConfig.enabled == false`); when off,
///     `buildCorrector` returns a `NullCorrector` and the pipeline is unchanged.
///  2. TRANSPARENT — a corrector never silently rewrites text. Every run returns a
///     `Correction` carrying the raw text, the corrected text, and the exact edits.
///
/// The Python `OllamaCorrector` (a local-LLM backend) becomes an Apple Foundation
/// Models corrector on iOS; it is added in a later phase and is off by default.

// MARK: - Protocol

/// Anything that turns a raw transcript into a `Correction`. Mirrors the
/// `Corrector` protocol in `atc_corrector.py`. `correct` is `async` here (the Python
/// is sync): the on-device LLM backend (`FoundationModelsCorrector`) is async, and the
/// pipeline already awaits the transcriber, so the deterministic stages just suspend
/// trivially.
protocol Corrector {
    func correct(_ text: String, history: [String]) async -> Correction
}

extension Corrector {
    func correct(_ text: String) async -> Correction { await correct(text, history: []) }
}

/// No-op corrector used whenever correction is disabled (the default).
struct NullCorrector: Corrector {
    func correct(_ text: String, history: [String]) async -> Correction { .unchanged(text) }
}

// MARK: - Lexicon & helpers (port of the module-level tables/functions)

/// Tokens shorter than this are never fuzzy-corrected (too easy to false-match a
/// common short word onto a vocab term).
private let kMinTokenLen = 4

/// Only unambiguous number spellings (no "for"/"to"/"oh"), incl. ICAO variants.
private let kUnits: [String: Int] = [
    "zero": 0, "one": 1, "two": 2, "three": 3, "tree": 3, "four": 4, "fower": 4,
    "five": 5, "fife": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "niner": 9,
]
private let kTeens: [String: Int] = [
    "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
    "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
]
private let kTens: [String: Int] = [
    "twenty": 20, "thirty": 30, "forty": 40, "fourty": 40, "fifty": 50,
    "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
]

/// Common ATC/English words never replaced by vocab matching (they collide
/// phonetically with short vocab terms). Mirrors `_STOPWORDS`.
private let kStopwords: Set<String> = [
    "left", "right", "center", "centre", "cleared", "clear", "runway", "tower",
    "ground", "traffic", "contact", "hold", "short", "line", "wait", "taxi",
    "cross", "descend", "climb", "maintain", "heading", "turn", "approach",
    "departure", "final", "report", "expect", "roger", "wilco", "affirm",
    "negative", "standby", "ready", "position", "holding", "follow", "behind",
    "caution", "wind", "check", "radar", "squawk", "ident", "altitude", "level",
    "knots", "gate", "ramp", "apron", "push", "start", "request", "with",
    "that", "this", "into", "after", "before",
]

private let kVowels: Set<Character> = ["a", "e", "i", "o", "u"]

/// Lowercase, strip non-`[a-z0-9]` — for matching, not display. Port of `_norm`.
private func normToken(_ token: String) -> String {
    String(token.lowercased().filter { ("a"..."z").contains($0) || ("0"..."9").contains($0) })
}

private func isAllDigits(_ s: String) -> Bool {
    !s.isEmpty && s.allSatisfy { $0.isASCII && $0.isNumber }
}

private enum NumKind { case unit, teen, tens }

/// Turn a run of number tokens into a spoken-digit string, grouping a tens word with
/// a following unit ("seventy","five" -> "75"). Port of `_assemble_digits`.
private func assembleDigits(_ run: [(NumKind, Int)]) -> String {
    var res: [String] = []
    var k = 0
    while k < run.count {
        let (kind, val) = run[k]
        if kind == .tens, k + 1 < run.count, run[k + 1].0 == .unit {
            res.append(String(val + run[k + 1].1))
            k += 2
        } else {
            res.append(String(val))
            k += 1
        }
    }
    return res.joined()
}

/// Collapse runs of spoken number words into digit strings. Vocab-independent;
/// "hundred"/"thousand" simply terminate a run. Port of `_normalize_numbers`.
private func normalizeNumbers(_ text: String) -> (text: String, edits: [CorrectionEdit]) {
    let tokens = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    var out: [String] = []
    var edits: [CorrectionEdit] = []
    var i = 0
    let n = tokens.count
    while i < n {
        var run: [(NumKind, Int)] = []
        var orig: [String] = []
        var j = i
        while j < n {
            let w = normToken(tokens[j])
            if let v = kUnits[w] { run.append((.unit, v)) }
            else if let v = kTeens[w] { run.append((.teen, v)) }
            else if let v = kTens[w] { run.append((.tens, v)) }
            else { break }
            orig.append(tokens[j])
            j += 1
        }
        if !run.isEmpty {
            let digits = assembleDigits(run)
            let span = orig.joined(separator: " ")
            if !digits.isEmpty && digits != span {
                edits.append(CorrectionEdit(from: span, to: digits, reason: "number", backend: "deterministic"))
                out.append(digits)
            } else {
                out.append(contentsOf: orig)
            }
            i = j
        } else {
            out.append(tokens[i])
            i += 1
        }
    }
    return (out.joined(separator: " "), edits)
}

/// Crude phonetic skeleton: leading char + ordered consonants, dups collapsed,
/// non-leading vowels dropped ("golf"/"gulf" -> "glf"). Port of `_phonetic_key`.
private func phoneticKey(_ norm: String) -> String {
    guard let first = norm.first else { return "" }
    var out: [Character] = [first]
    for ch in norm.dropFirst() {
        if kVowels.contains(ch) || ch == out.last! { continue }
        out.append(ch)
    }
    return String(out)
}

// Banker's rounding (round-half-to-even) to match Python's `round(score, 2)`, which the
// reference uses to record edit confidence. Swift's default `.rounded()` is half-away-from-zero.
private func round2(_ x: Double) -> Double { (x * 100).rounded(.toNearestOrEven) / 100 }

// MARK: - Deterministic corrector

/// Fix known-vocabulary errors with zero dependencies, in three recorded stages:
/// number normalization, character near-miss (`SequenceMatcher.ratio() >= threshold`),
/// and a phonetic fallback (same phonetic key + ratio `>= phoneticMin`). Conservative
/// by design — a stopword list, a min-token-length floor, and digit/known-term skips
/// guard against over-correction. Port of `atc_corrector.DeterministicCorrector`.
struct DeterministicCorrector: Corrector {
    let vocabProvider: () -> [String]
    var threshold: Double = 0.84
    var phonetic: Bool = true
    var phoneticMin: Double = 0.62
    var numbers: Bool = true
    var minTokenLen: Int = kMinTokenLen

    func correct(_ text: String, history: [String]) async -> Correction {
        if text.trimmingCharacters(in: .whitespaces).isEmpty {
            return .unchanged(text, backend: "deterministic")
        }

        var edits: [CorrectionEdit] = []
        var current = text

        // Stage 1: number normalization (runs even with no vocab).
        if numbers {
            let result = normalizeNumbers(current)
            current = result.text
            edits.append(contentsOf: result.edits)
        }

        // Stages 2 & 3: vocab matching (char near-miss, then phonetic fallback).
        var canon: [String: String] = [:]
        for term in vocabProvider() {
            let nrm = normToken(term)
            if !nrm.isEmpty, canon[nrm] == nil { canon[nrm] = term }
        }
        if !canon.isEmpty {
            let normVocab = Array(canon.keys)
            var keys: [String: String] = [:]
            if phonetic { for nv in normVocab { keys[nv] = phoneticKey(nv) } }

            var out: [String] = []
            for word in current.split(whereSeparator: { $0.isWhitespace }).map(String.init) {
                let nw = normToken(word)
                if nw.count < minTokenLen || isAllDigits(nw) || canon[nw] != nil || kStopwords.contains(nw) {
                    out.append(word)
                    continue
                }

                // Stage 2: character near-miss.
                if let match = closestMatch(nw, in: normVocab, cutoff: threshold), match.term != nw,
                   let canonical = canon[match.term] {
                    edits.append(CorrectionEdit(from: word, to: canonical, reason: "vocab match",
                                                confidence: round2(match.ratio), backend: "deterministic"))
                    out.append(canonical)
                    continue
                }

                // Stage 3: phonetic fallback.
                if phonetic {
                    let key = phoneticKey(nw)
                    var best: String?
                    var bestRatio = 0.0
                    for nv in normVocab where keys[nv] == key && nv != nw {
                        let r = SequenceMatcher(nw, nv).ratio()
                        if r >= phoneticMin && r > bestRatio { best = nv; bestRatio = r }
                    }
                    if let best, let canonical = canon[best] {
                        edits.append(CorrectionEdit(from: word, to: canonical, reason: "phonetic match",
                                                    confidence: round2(bestRatio), backend: "deterministic"))
                        out.append(canonical)
                        continue
                    }
                }

                out.append(word)
            }
            current = out.joined(separator: " ")
        }

        if edits.isEmpty || current == text {
            return .unchanged(text, backend: "deterministic")
        }
        return Correction(raw: text, corrected: current, changed: true, edits: edits, backend: "deterministic")
    }
}

// MARK: - Chain

/// Run correctors in order, threading the text through and merging edits. Each stage
/// corrects the previous stage's output; `raw` stays the original input. Port of
/// `atc_corrector.ChainCorrector`.
struct ChainCorrector: Corrector {
    let correctors: [Corrector]

    func correct(_ text: String, history: [String]) async -> Correction {
        let raw = text
        var current = raw
        var edits: [CorrectionEdit] = []
        var backends: [String] = []
        for c in correctors {
            let res = await c.correct(current, history: history)
            if res.changed, !res.corrected.isEmpty {
                edits.append(contentsOf: res.edits)
                backends.append(res.backend)
                current = res.corrected
            }
        }
        if edits.isEmpty || current == raw {
            return .unchanged(raw)
        }
        return Correction(raw: raw, corrected: current, changed: true, edits: edits,
                          backend: backends.joined(separator: "+"))
    }
}

// MARK: - Config & factory

/// Mirrors the `correction:` block of `config.yaml`. Off by default.
struct CorrectionConfig {
    var enabled = false
    var deterministic = true
    var threshold = 0.84
    var numbers = true
    var phonetic = true
    var phoneticMin = 0.62
    /// Optional local-LLM backend. On iOS this becomes Apple Foundation Models
    /// (added later); the contract matches the Python `llm:` block.
    var llmEnabled = false
}

/// Build a corrector from config + a live vocab provider, or a no-op when disabled.
/// Returns `NullCorrector` when disabled or no backend is enabled, so an "off" config
/// is a genuine no-op. Port of `atc_corrector.build_corrector`.
func buildCorrector(config: CorrectionConfig, vocab: @escaping () -> [String]) -> Corrector {
    guard config.enabled else { return NullCorrector() }

    var stages: [Corrector] = []
    if config.deterministic {
        stages.append(DeterministicCorrector(
            vocabProvider: vocab,
            threshold: config.threshold,
            phonetic: config.phonetic,
            phoneticMin: config.phoneticMin,
            numbers: config.numbers))
    }
    // Optional on-device LLM stage (Apple Foundation Models). Present only when the
    // framework is in the SDK / the OS is new enough; nil (skipped) otherwise, so a
    // device without it simply runs the deterministic stage. Off by default.
    if config.llmEnabled, let llm = makeFoundationModelsCorrector(vocab: vocab) {
        stages.append(llm)
    }

    if stages.isEmpty { return NullCorrector() }
    if stages.count == 1 { return stages[0] }
    return ChainCorrector(correctors: stages)
}
