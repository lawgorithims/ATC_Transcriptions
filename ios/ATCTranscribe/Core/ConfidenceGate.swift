import Foundation

/// How readily the gate skips the background LLM. Conservative runs the LLM more (safer, fewer
/// missed refinements); aggressive skips more (more CPU/battery/thermal savings). User-selectable.
enum GateSensitivity: String, Sendable, CaseIterable, Codable {
    case conservative, balanced, aggressive
}

/// The gate's verdict for one transmission.
struct GateDecision: Sendable, Equatable {
    /// True → enqueue the LLM; false → skip (the transmission looks clean).
    let shouldRefine: Bool
    /// A rough 0…1 cleanliness estimate (1 = very confident the text is already correct), for display.
    let confidence: Double
    /// Why the LLM ran (the signal(s) that fired), or "high confidence" when skipped.
    let reason: String
}

/// Cheap, deterministic decision — run in the inline path — of whether the slow LLM should even
/// look at a transmission. It does NOT ask "are all words known?" (that over-triggers on normal
/// English chatter); it asks the inverse — "is anything actually suspicious?" — and enqueues the
/// LLM if **any** signal fires:
///   1. ASR confidence: Whisper's own `avgLogprob` is low (unsure) or `compressionRatio` is high.
///   2. Lexical near-miss: a token fuzzy-matches a known callsign/runway/fix in the *uncertain*
///      band `[floor, 0.84)` — close to a known term but below the deterministic auto-fix bar.
///   3. Language leakage (`RetrievedContext.languageSuspect`).
///   4. Residual repetition (the inline collapser fired).
/// No signal → high confidence → skip. Skipping is safe: it only costs a missed refinement (the
/// raw + deterministic text still shows), never a wrong correction.
struct ConfidenceGate: Sendable {
    var sensitivity: GateSensitivity = .conservative
    /// ASR-confidence signals are ignored below this length (a 1–2 word fragment's avgLogprob is
    /// noisy and the LLM has little to work with); specific lexical signals still fire.
    var minRefineWords = 3

    func assess(text: String,
                retrieved: RetrievedContext,
                asr: ASRConfidence?,
                inlineEdits: [CorrectionEdit],
                snapReasons: [String] = []) -> GateDecision {
        let th = Thresholds.forSensitivity(sensitivity)
        let tokens = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)

        var reasons: [String] = []
        // 0. Snap-stage grounding signals (signal 5 in the PR #5 plan): an unverified callsign
        //    or an invalid/unverified slot is direct evidence something was misheard — and it is
        //    genuinely additive here because `noSpeechProb` is stubbed in this WhisperKit build.
        reasons.append(contentsOf: snapReasons)

        // 1. ASR confidence (only for non-trivial transmissions).
        if let asr, tokens.count >= minRefineWords {
            if asr.avgLogprob < th.minAvgLogprob { reasons.append("low ASR confidence") }
            if asr.compressionRatio > th.maxCompressionRatio { reasons.append("repetitive decode") }
        }
        // 2. Lexical near-miss to a known term.
        if let nm = nearMissToken(tokens, vocab: retrieved.vocab, floor: th.nearMissFloor) {
            reasons.append("possible mishear “\(nm)”")
        }
        // 3. Language leakage.
        if retrieved.languageSuspect { reasons.append("non-English") }
        // 4. Residual repetition that the inline collapser already had to fix.
        if inlineEdits.contains(where: { $0.reason == "repeat" }) { reasons.append("repetition") }

        let shouldRefine = !reasons.isEmpty
        return GateDecision(shouldRefine: shouldRefine,
                            confidence: confidence(asr: asr, hasSignal: shouldRefine),
                            reason: reasons.isEmpty ? "high confidence" : reasons.joined(separator: ", "))
    }

    // MARK: Signals

    /// The first token that is close to a known vocab term but below the deterministic auto-fix
    /// threshold (i.e. an ambiguous mishear), or nil. Skips numbers, stopwords, and short tokens.
    private func nearMissToken(_ tokens: [String], vocab: [String], floor: Double) -> String? {
        guard !vocab.isEmpty else { return nil }
        let normVocab = vocab.map(normToken).filter { !$0.isEmpty }
        guard !normVocab.isEmpty else { return nil }
        let vocabSet = Set(normVocab)
        for raw in tokens {
            let nw = normToken(raw)
            guard nw.count >= 4, !isNumberLikeToken(nw), !kStopwords.contains(nw), !vocabSet.contains(nw) else { continue }
            if let m = closestMatch(nw, in: normVocab, cutoff: floor), m.ratio < Thresholds.autoFix {
                return raw
            }
        }
        return nil
    }

    /// A rough display-only cleanliness estimate from avgLogprob, reduced when any signal fired.
    private func confidence(asr: ASRConfidence?, hasSignal: Bool) -> Double {
        var c = 1.0
        if let asr {
            let lp = Double(max(-2.0, min(0.0, asr.avgLogprob)))   // -2 → 0.0, 0 → 1.0
            c = min(c, (lp + 2.0) / 2.0)
        }
        if hasSignal { c = min(c, 0.45) }
        return (c * 100).rounded() / 100
    }

    /// Per-sensitivity trigger thresholds. NOTE: the avgLogprob/compressionRatio cutoffs are seeded
    /// here and calibrated against the diagnostic clips' real values via the ATCKitProbe gate log.
    private struct Thresholds {
        /// The deterministic corrector's vocab-match threshold; ≥ this is already auto-fixed.
        static let autoFix = 0.84

        let minAvgLogprob: Float        // avgLogprob below this → unsure → run LLM
        let maxCompressionRatio: Float  // compressionRatio above this → repetitive → run LLM
        let nearMissFloor: Double       // fuzzy ratio in [floor, autoFix) → ambiguous mishear

        static func forSensitivity(_ s: GateSensitivity) -> Thresholds {
            switch s {
            case .conservative: return .init(minAvgLogprob: -0.55, maxCompressionRatio: 1.8, nearMissFloor: 0.55)
            case .balanced:     return .init(minAvgLogprob: -0.85, maxCompressionRatio: 2.0, nearMissFloor: 0.62)
            case .aggressive:   return .init(minAvgLogprob: -1.15, maxCompressionRatio: 2.2, nearMissFloor: 0.70)
            }
        }
    }
}
