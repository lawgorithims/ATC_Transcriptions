import Foundation
import CoreML
import WhisperKit

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
/// Audio is expected already preprocessed (mono 16 kHz float32 in [-1, 1]); the
/// radio-cleanup stage (`AudioPreprocessor`, ported separately) runs upstream.
actor ATCTranscriber {
    /// Whisper shares a 448-token decoder window between prompt and generated text; cap
    /// the prompt well below it so generation always has room. (= Python `MAX_PROMPT_TOKENS`)
    static let maxPromptTokens = 220

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

    /// Transcribe mono 16 kHz audio with an optional context prompt. Returns the
    /// transcript, or "" when the decode stays degenerate after fallback (the caller
    /// treats "" as "skip this segment"). Port of `ATCTranscriber.transcribe`.
    func transcribe(_ audio: [Float], context: String? = nil) async throws -> String {
        guard let pipe else { throw TranscriberError.notLoaded }

        let options = DecodingOptions(
            task: .transcribe,
            language: language,                              // pin en; no auto-detect drift
            temperature: 0.0,                                // first pass greedy (clean-audio WER unchanged)
            temperatureFallbackCount: temperatureFallbackCount,  // retries with rising temp on degeneracy
            usePrefillPrompt: true,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            promptTokens: promptTokens(for: context, tokenizer: pipe.tokenizer),
            compressionRatioThreshold: compressionRatioThreshold,
            noSpeechThreshold: 0.6
        )

        let results = try await pipe.transcribe(audioArray: audio, decodeOptions: options)

        // Drop if still degenerate after WhisperKit's temperature fallback — a segment
        // above the compression-ratio threshold is a stuck repetition loop ("runway three
        // right runway three right ..."), which gzip-compresses far better than speech.
        let segments = results.flatMap(\.segments)
        if segments.contains(where: { $0.compressionRatio > compressionRatioThreshold }) {
            return ""
        }
        return results.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Encode the airport-context string to prompt token ids, drop special tokens, and cap
    /// to the budget. (WhisperKit's text decoder also trims + filters specials, but we cap
    /// here for parity with the Python prompt budget.)
    private func promptTokens(for context: String?, tokenizer: WhisperTokenizer?) -> [Int]? {
        let ctx = (context ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ctx.isEmpty, let tokenizer else { return nil }
        var ids = tokenizer.encode(text: " " + ctx)
            .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        // Keep the LEADING tokens (the static facility prefix), matching the Python
        // `prompt_ids[..., :MAX_PROMPT_TOKENS]`. Dropping the head (suffix) would discard
        // the airport/runway/phraseology priming and keep only recent-history tokens.
        if ids.count > Self.maxPromptTokens { ids = Array(ids.prefix(Self.maxPromptTokens)) }
        return ids.isEmpty ? nil : ids
    }

    enum TranscriberError: Error { case notLoaded }
}
