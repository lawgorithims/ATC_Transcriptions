import Foundation

/// A raw text-generation engine (the local llama.cpp model, or a stub in tests). Kept behind
/// a protocol so `LocalLLMCorrector` is fully testable without loading a model.
protocol LLMEngine: Sendable {
    /// Generate a completion for `prompt`. `grammar` (GBNF) constrains the output when the
    /// engine supports it; `stop` strings end generation early. Runs on a background executor.
    func generate(prompt: String, grammar: String?, maxTokens: Int, stop: [String]) async throws -> String
}

/// The slow-tier correction backend: an on-device LLM that refines a transcript using
/// retrieved ATC context. Separate from `Corrector` because it needs the RAG context (computed
/// on the pipeline actor) and runs **off** the transcription hot path. Both the llama.cpp
/// backend (`LocalLLMCorrector`) and Apple Intelligence (`FoundationModelsCorrector`) conform,
/// so the refiner is backend-agnostic.
protocol LLMCorrector: Sendable {
    func correct(text: String, history: [String], retrieved: RetrievedContext) async -> Correction
}

/// One unit of deferred refinement, snapshotted on the pipeline actor so the background refiner
/// never reads mutable pipeline state. Sendable end to end.
struct RefinementRequest: Sendable, Identifiable {
    let id: UUID            // matches the TranscriptRecord being refined
    let text: String        // best text so far (the inline/deterministic display)
    let history: [String]
    let retrieved: RetrievedContext
}

/// Result delivered back for a queued request.
enum RefinementOutcome: Sendable {
    case refined(Correction)   // the LLM produced a change
    case clean                 // the LLM ran and made no change
    case skipped               // dropped under load (queue overflow) — never ran
}
