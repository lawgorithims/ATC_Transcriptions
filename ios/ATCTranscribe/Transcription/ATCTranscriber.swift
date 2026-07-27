import Foundation
import CoreML
import WhisperKit

/// Whisper's own confidence for one decoded transmission, surfaced for the LLM confidence gate.
/// `avgLogprob` is the mean segment log-probability (closer to 0 = more confident; very negative =
/// the model was unsure); `compressionRatio` is the max over segments (high = repetitive/degenerate).
/// `noSpeechProb` is intentionally omitted — it's stubbed to 0 in this WhisperKit build.
struct ASRConfidence: Sendable, Equatable {
    var avgLogprob: Float
    var compressionRatio: Float
    /// Neutral "no signal" value for non-Whisper callers and tests (treated as confident).
    static let unknown = ASRConfidence(avgLogprob: 0, compressionRatio: 0)
}

/// One transcribed transmission plus the ASR confidence that produced it.
struct TranscriptionOutput: Sendable {
    var text: String
    var asr: ASRConfidence
    static let empty = TranscriptionOutput(text: "", asr: .unknown)
}

/// Fine-tuned Whisper inference for live ATC segments, on-device via WhisperKit
/// (CoreML on the Apple Neural Engine). Swift port of `atc_transcriber.ATCTranscriber`.
///
/// Decode policy mirrors the Python:
///  - **language pinned to `en`**, task `.transcribe` — no language auto-detect drift on
///    low-SNR radio (the Python clears `forced_decoder_ids` and pins per call).
///  - optional **airport-context prompt**, capped at ~220 tokens so decoding always has
///    room in Whisper's 448-token window (Python's `MAX_PROMPT_TOKENS`).
///  - **degeneracy guard**: WhisperKit's built-in temperature fallback performs the retry
///    (`compressionRatioThreshold = 2.4`, the same OpenAI heuristic the Python uses);
///    if a segment is *still* degenerate after fallback we DROP it (return ""), matching
///    the Python's "nothing usable for this segment — skip it".
///
/// The thin transcription seam (the plan's "Transcriber protocol"): `LivePipeline` depends on
/// this, not on WhisperKit, so replay/integration tests can script hypotheses through the REAL
/// pipeline and a non-Whisper engine (e.g. a transducer via sherpa-onnx) can slot in later
/// without touching the pipeline.
protocol Transcribing: Sendable {
    func transcribe(_ audio: [Float], context: String?) async throws -> TranscriptionOutput
    /// Prompt-aware entry point. The head/tail split lets the transcriber budget the priming and the
    /// history from opposite ends (see `ATCContext.PromptParts`). Defaulted so the string-based
    /// engines and the scripted test doubles keep working unchanged.
    func transcribe(_ audio: [Float], prompt: ATCContext.PromptParts?) async throws -> TranscriptionOutput
}

extension Transcribing {
    func transcribe(_ audio: [Float], prompt: ATCContext.PromptParts?) async throws -> TranscriptionOutput {
        try await transcribe(audio, context: prompt?.joined)
    }
}

/// Audio is expected already preprocessed (mono 16 kHz float32 in [-1, 1]); the
/// radio-cleanup stage (`AudioPreprocessor`, ported separately) runs upstream.
actor ATCTranscriber: Transcribing {
    /// Whisper shares a 448-token decoder window between prompt and generated text; cap
    /// the prompt well below it so generation always has room. (= Python `MAX_PROMPT_TOKENS`)
    /// Derived from WhisperKit's own constant, NOT hard-coded: `TextDecoder` trims the prompt with
    /// `suffix(Constants.maxTokenContext / 2 - 1)`, so anything larger loses its front inside
    /// WhisperKit. Deriving it means a dependency bump can't silently re-open that bug.
    static let maxPromptTokens = Constants.maxTokenContext / 2 - 1   // = 111

    private let modelFolder: String
    private let language: String
    private let compressionRatioThreshold: Float
    private let temperatureFallbackCount: Int
    private let cpuOnly: Bool
    private var pipe: WhisperKit?

    /// - Parameter cpuOnly: force CPU compute units (the iOS Simulator has no Neural
    ///   Engine). Leave false on real devices to use the ANE.
    init(modelFolder: String,
         language: String = "en",
         compressionRatioThreshold: Float = 2.4,
         temperatureFallbackCount: Int = 5,
         cpuOnly: Bool = false) {
        self.modelFolder = modelFolder
        self.language = language
        self.compressionRatioThreshold = compressionRatioThreshold
        self.temperatureFallbackCount = temperatureFallbackCount
        self.cpuOnly = cpuOnly
    }

    var isLoaded: Bool { pipe != nil }

    /// Load the converted CoreML model from a local folder. No network (`download: false`).
    /// Mirrors the model load in `ATCTranscriber.__init__`.
    func load() async throws {
        // A superseded model switch cancels its load task, but cancellation cannot interrupt the
        // WhisperKit/CoreML compile below once started — bail HERE so an already-superseded load
        // never begins the multi-GB compile at all (the caller's generation guard handles the
        // supersede-after-start case once the compile returns).
        try Task.checkCancellation()
        let compute = cpuOnly
            ? ModelComputeOptions(melCompute: .cpuOnly, audioEncoderCompute: .cpuOnly, textDecoderCompute: .cpuOnly)
            : nil
        let config = WhisperKitConfig(
            modelFolder: modelFolder,
            computeOptions: compute,
            verbose: false,
            logLevel: .error,
            prewarm: true,
            load: true,
            download: false
        )
        pipe = try await WhisperKit(config)
    }

    /// Transcribe mono 16 kHz audio with an optional context prompt. Returns the transcript +
    /// the ASR confidence; `text` is "" when the decode stays degenerate after fallback (the
    /// caller treats "" as "skip this segment"). Port of `ATCTranscriber.transcribe`.
    func transcribe(_ audio: [Float], context: String? = nil) async throws -> TranscriptionOutput {
        // A bare string has no head/tail structure, so treat it all as head (priming-priority):
        // truncating a caller-supplied prompt from the front is never what they meant.
        try await transcribe(audio, prompt: (context?.isEmpty ?? true)
                             ? nil : ATCContext.PromptParts(head: context!, tail: ""))
    }

    func transcribe(_ audio: [Float], prompt: ATCContext.PromptParts?) async throws -> TranscriptionOutput {
        guard let pipe else { throw TranscriberError.notLoaded }

        let options = DecodingOptions(
            task: .transcribe,
            language: language,                              // pin en; no auto-detect drift
            temperature: 0.0,                                // first pass greedy (clean-audio WER unchanged)
            temperatureFallbackCount: temperatureFallbackCount,  // retries with rising temp on degeneracy
            usePrefillPrompt: true,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            promptTokens: promptTokens(for: prompt, tokenizer: pipe.tokenizer),
            compressionRatioThreshold: compressionRatioThreshold,
            noSpeechThreshold: 0.6
        )

        let results = try await pipe.transcribe(audioArray: audio, decodeOptions: options)

        // Aggregate Whisper's per-segment confidence: mean avgLogprob, max compressionRatio.
        let segments = results.flatMap(\.segments)
        let compression = segments.map(\.compressionRatio).max() ?? 0
        let avgLogprob = segments.isEmpty ? 0 : segments.map(\.avgLogprob).reduce(0, +) / Float(segments.count)
        let asr = ASRConfidence(avgLogprob: avgLogprob, compressionRatio: compression)

        // If still degenerate after WhisperKit's temperature fallback (a stuck repetition loop —
        // "runway three right runway three right ...", which gzip-compresses far better than speech),
        // QW4: try ONE no-prompt re-decode before giving up. Repetition loops are frequently prompt-
        // or greedy-induced, so dropping the context prompt + starting warmer often recovers real
        // text; only if THAT is still degenerate do we drop the segment (return "").
        if compression > compressionRatioThreshold {
            if let recovered = try? await pipe.transcribe(audioArray: audio, decodeOptions: DecodingOptions(
                task: .transcribe, language: language,
                temperature: 0.4, temperatureFallbackCount: temperatureFallbackCount,
                usePrefillPrompt: true, skipSpecialTokens: true, withoutTimestamps: true,
                promptTokens: nil, compressionRatioThreshold: compressionRatioThreshold, noSpeechThreshold: 0.6)) {
                let rSegs = recovered.flatMap(\.segments)
                let rComp = rSegs.map(\.compressionRatio).max() ?? 0
                if rComp <= compressionRatioThreshold {
                    let rText = recovered.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                    let rLp = rSegs.isEmpty ? 0 : rSegs.map(\.avgLogprob).reduce(0, +) / Float(rSegs.count)
                    if !rText.isEmpty { return TranscriptionOutput(text: rText, asr: ASRConfidence(avgLogprob: rLp, compressionRatio: rComp)) }
                }
            }
            return TranscriptionOutput(text: "", asr: asr)
        }
        let text = results.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return TranscriptionOutput(text: text, asr: asr)
    }

    /// Encode the context to prompt token ids, drop special tokens, and fit the decoder's budget.
    ///
    /// The budget is NOT arbitrary: WhisperKit re-trims with `promptTokens.suffix(maxTokenContext/2 - 1)`
    /// (TextDecoder.swift). Any prompt longer than that loses its FRONT inside WhisperKit — which used
    /// to silently delete every priming section (facility, ownship, plate fixes, and the live ADS-B
    /// "Aircraft on frequency" bias) and forward only rolling history. Budgeting to exactly that size
    /// here makes WhisperKit's `suffix()` a no-op, so what we prioritize is what the model actually sees.
    private func promptTokens(for parts: ATCContext.PromptParts?,
                              tokenizer: WhisperTokenizer?) -> [Int]? {
        guard let parts, !parts.isEmpty, let tokenizer else { return nil }
        let encode = { (s: String) -> [Int] in
            s.isEmpty ? [] : tokenizer.encode(text: " " + s.trimmingCharacters(in: .whitespacesAndNewlines))
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        }
        let ids = Self.assemblePromptIds(head: encode(parts.head), tail: encode(parts.tail),
                                         budget: Self.maxPromptTokens)
        return ids.isEmpty ? nil : ids
    }

    /// Fit `head` + `tail` into `budget` tokens: the head keeps its FRONT (priming order is
    /// priority order), and whatever budget survives is filled with the END of the tail (the most
    /// recent transmissions). Pure + tokenizer-free so the budgeting is unit-testable on its own.
    static func assemblePromptIds(head: [Int], tail: [Int], budget: Int) -> [Int] {
        guard budget > 0 else { return [] }
        let h = head.count > budget ? Array(head.prefix(budget)) : head
        let remaining = budget - h.count
        let t = remaining <= 0 ? [] : (tail.count > remaining ? Array(tail.suffix(remaining)) : tail)
        let out = h + t
        assert(out.count <= budget, "prompt budget overflow — WhisperKit would re-trim from the front")
        return out
    }

    enum TranscriberError: Error { case notLoaded }
}
