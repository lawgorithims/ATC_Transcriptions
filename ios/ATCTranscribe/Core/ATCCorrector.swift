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
/// phonetically with short vocab terms). Mirrors `_STOPWORDS`. Internal so the confidence
/// gate can skip these when looking for suspicious near-miss tokens.
let kStopwords: Set<String> = [
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

/// Lowercase, strip non-`[a-z0-9]` — for matching, not display. Port of `_norm`. Internal so
/// the confidence gate normalizes tokens the same way the corrector does.
func normToken(_ token: String) -> String {
    String(token.lowercased().filter { ("a"..."z").contains($0) || ("0"..."9").contains($0) })
}

private func isAllDigits(_ s: String) -> Bool {
    !s.isEmpty && s.allSatisfy { $0.isASCII && $0.isNumber }
}

/// True when a normalized token is pure digits or a spoken number word (unit/teen/tens) — the
/// confidence gate skips these (they're never suspicious mishears). Reuses the number tables.
func isNumberLikeToken(_ norm: String) -> Bool {
    !norm.isEmpty && (isAllDigits(norm) || kUnits[norm] != nil || kTeens[norm] != nil || kTens[norm] != nil)
}

private enum NumKind { case unit, teen, tens }

/// Turn a run of number tokens into spoken-digit chunks, grouping a tens word with a following
/// unit ("seventy","five" -> "75"). Returns one string per emitted chunk, each tagged as a 2-digit
/// grouped chunk (teen / tens+unit / bare tens) or a 1-digit standalone unit, so `joinDigitChunks`
/// can tell a single coherent field (fuse) from two distinct spoken fields (keep apart). Extends
/// the `_assemble_digits` port to be chunk-aware.
private func assembleDigits(_ run: [(NumKind, Int)]) -> [(digits: String, grouped: Bool)] {
    var res: [(digits: String, grouped: Bool)] = []
    var k = 0
    while k < run.count {
        let (kind, val) = run[k]
        if kind == .tens, k + 1 < run.count, run[k + 1].0 == .unit {
            res.append((String(val + run[k + 1].1), true))   // "seventy five" -> 75
            k += 2
        } else if kind == .unit {
            res.append((String(val), false))                 // lone spoken digit
            k += 1
        } else {
            res.append((String(val), true))                  // teen (18) or bare tens (50)
            k += 1
        }
    }
    return res
}

/// Join assembled chunks into spoken numbers. A run fuses into ONE number unless it contains a lone
/// unit (1-digit chunk) wedged between two grouped (2-digit) chunks — the structural signature of
/// two distinct spoken fields (e.g. "fifty six | six | eighteen" -> 56 6 18, not the implausible
/// 5-digit 56618). Pure digit-by-digit reads (all 1-digit, e.g. headings/squawks/tail numbers) and
/// all-grouped reads (paired flight numbers like "twelve thirty four" -> 1234) stay fused.
private func joinDigitChunks(_ chunks: [(digits: String, grouped: Bool)]) -> [String] {
    guard chunks.count >= 3 else { return [chunks.map(\.digits).joined()] }
    var fields: [String] = []
    var current = ""
    for (idx, chunk) in chunks.enumerated() {
        let prevGrouped = idx > 0 && chunks[idx - 1].grouped
        let nextGrouped = idx + 1 < chunks.count && chunks[idx + 1].grouped
        if !chunk.grouped, prevGrouped, nextGrouped {
            if !current.isEmpty { fields.append(current); current = "" }
            fields.append(chunk.digits)          // the wedged lone unit -> its own field
        } else {
            current += chunk.digits
        }
    }
    if !current.isEmpty { fields.append(current) }
    return fields
}

/// Collapse runs of spoken number words into digit strings. Vocab-independent;
/// "hundred"/"thousand" simply terminate a run. Port of `_normalize_numbers`.
func normalizeNumbers(_ text: String) -> (text: String, edits: [CorrectionEdit]) {
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
            let digits = joinDigitChunks(assembleDigits(run)).joined(separator: " ")
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

// MARK: - Hallucination filter

/// Strips known Whisper phantom phrases that aren't ATC phraseology and recur as insertions —
/// e.g. "no call of" in "contact no call of departure" (Whisper inventing words over static/noise).
/// Whole-phrase, case-insensitive, word-bounded; conservative — only exact known phrases.
struct HallucinationFilter: Corrector {
    /// Lowercased phrases to delete. Extend as new recurring mis-hears surface.
    static let phrases = ["no call of"]

    func correct(_ text: String, history: [String]) async -> Correction {
        var current = text
        var edits: [CorrectionEdit] = []
        for phrase in Self.phrases {
            let pattern = "\\s*\\b" + NSRegularExpression.escapedPattern(for: phrase) + "\\b"
            let replaced = current.replacingOccurrences(of: pattern, with: "",
                                                        options: [.regularExpression, .caseInsensitive])
            if replaced != current {
                edits.append(CorrectionEdit(from: phrase, to: "", reason: "removed mis-hear",
                                            backend: "deterministic"))
                current = replaced
            }
        }
        current = current.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if edits.isEmpty || current == text { return .unchanged(text, backend: "deterministic") }
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
            // Thread any change — including an intentional delete-to-empty (a wholly-hallucinated
            // transmission stripped by HallucinationFilter), which the pipeline then drops.
            if res.changed {
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

/// Which on-device LLM drives the slow (background) correction tier, if any.
enum LLMBackend: String, Sendable, CaseIterable {
    case off          // deterministic only
    case local        // bundled llama.cpp model on the CPU (primary)
    case foundation   // Apple Foundation Models / Apple Intelligence (alternate)
}

/// Mirrors the `correction:` block of `config.yaml`. Off by default.
struct CorrectionConfig {
    var enabled = false
    var deterministic = true
    /// Cheap repetition-loop collapse in the fast inline tier (on when correction is enabled).
    var repetition = true
    var threshold = 0.84
    var numbers = true
    var phonetic = true
    var phoneticMin = 0.62
    /// The slow-tier LLM backend (off / local llama.cpp / Apple Foundation Models). The LLM
    /// runs off the transcription hot path via `LLMRefiner`, not as an inline corrector stage.
    var llmBackend: LLMBackend = .off

    /// Legacy boolean shim (kept for older call sites/tests): maps to the Foundation Models
    /// backend when set on, `.off` when cleared.
    var llmEnabled: Bool {
        get { llmBackend != .off }
        set { llmBackend = newValue ? (llmBackend == .off ? .foundation : llmBackend) : .off }
    }
}

/// Build the **fast inline** corrector from config + a live vocab provider, or a no-op when
/// disabled. This is the hot-path tier (`NullCorrector` when off; else repetition collapse +
/// the deterministic vocab/number fixer). The slow LLM tier is built separately and run by
/// `LLMRefiner` so it can't stall transcription. Port of `atc_corrector.build_corrector`.
func buildCorrector(config: CorrectionConfig, vocab: @escaping () -> [String]) -> Corrector {
    guard config.enabled else { return NullCorrector() }

    var stages: [Corrector] = []
    stages.append(HallucinationFilter())   // strip known Whisper phantom phrases first
    if config.repetition { stages.append(RepetitionCollapse()) }
    if config.deterministic {
        stages.append(PhraseologyCorrector())   // BB3: multi-word ATC phraseology mis-hears, before vocab-snapping
        stages.append(DeterministicCorrector(
            vocabProvider: vocab,
            threshold: config.threshold,
            phonetic: config.phonetic,
            phoneticMin: config.phoneticMin,
            numbers: config.numbers))
    }

    if stages.isEmpty { return NullCorrector() }
    if stages.count == 1 { return stages[0] }
    return ChainCorrector(correctors: stages)
}

/// Build the optional slow-tier LLM corrector for the selected backend, or nil. The local
/// backend loads the bundled GGUF (CPU); the foundation backend weak-links Apple Intelligence.
/// Both return nil gracefully when unavailable, so the pipeline just runs deterministic-only.
func buildLLMCorrector(config: CorrectionConfig,
                       knowledge: ATCKnowledgeBase,
                       feedKey: String?) -> LLMCorrector? {
    guard config.enabled else { return nil }
    switch config.llmBackend {
    case .off:
        return nil
    case .local:
        guard let engine = makeLocalLLMEngine() else { return nil }
        return wrapWithRemoteCascade(LocalLLMCorrector(engine: engine, knowledge: knowledge, feedKey: feedKey),
                                     knowledge: knowledge, feedKey: feedKey)
    case .foundation:
        return makeFoundationModelsCorrector(knowledge: knowledge, feedKey: feedKey)
            .map { wrapWithRemoteCascade($0, knowledge: knowledge, feedKey: feedKey) }
    }
}

/// When a remote fixer endpoint is configured (Settings key `atc.remoteFixerURL`), wrap the
/// on-device corrector in the two-pass cascade: local pass first, larger internet model second,
/// hard-capped by the pilot-usefulness latency budget. No endpoint → the local corrector runs
/// exactly as before (zero overhead).
func wrapWithRemoteCascade(_ local: LLMCorrector,
                           knowledge: ATCKnowledgeBase,
                           feedKey: String?) -> LLMCorrector {
    guard let remote = RemoteLLMCorrector.fromSettings(knowledge: knowledge, feedKey: feedKey) else {
        return local
    }
    return CascadeCorrector(primary: local, secondary: remote)
}
