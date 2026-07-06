import Foundation

/// The local, CPU-bound LLM correction backend — the Swift counterpart of the Python
/// `OllamaCorrector`, but with the model running **in-process** via llama.cpp on the CPU
/// (`n_gpu_layers = 0`) so it never competes with WhisperKit on the ANE/GPU.
///
/// It is the primary on-device "context fixer": given the raw transcript plus the retrieved
/// RAG context, it asks the model for a strict-JSON `{corrected, edits}` (grammar-constrained),
/// then hands the edits to `CorrectionValidator`, which applies only the safe ones. Any failure
/// — model missing/slow, unparseable output, all edits rejected — returns the text unchanged,
/// so the LLM can never break or rewrite the live feed.
struct LocalLLMCorrector: LLMCorrector {
    let engine: LLMEngine
    let knowledge: ATCKnowledgeBase
    let feedKey: String?
    var maxTokens = 256
    var backend = "local-llm"

    func correct(text: String, history: [String], retrieved: RetrievedContext) async -> Correction {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unchanged(text, backend: backend) }

        let prompt = ATCCorrectionPrompt.chatMLPrompt(transcript: text,
                                                      retrieved: retrieved.block,
                                                      history: history)
        do {
            // NOTE: grammar is intentionally nil. llama.cpp's GBNF grammar sampler throws a
            // C++ std::runtime_error on a grammar-stack mismatch, which is UNCATCHABLE from
            // Swift and aborts the process — unacceptable for a "never break the feed" stage.
            // Instead we steer the JSON shape with the ChatML few-shot prompt and recover with
            // the brace-scanning parser + validator, both of which degrade gracefully to
            // "unchanged" on bad output. (jsonGrammar is kept for a future C++-shim path.)
            let out = try await engine.generate(prompt: prompt,
                                                grammar: nil,
                                                maxTokens: maxTokens,
                                                stop: ["<|im_end|>", "<|endoftext|>"])
            guard let payload = LLMCorrectionPayload.parse(out) else {
                return .unchanged(text, backend: backend)
            }
            let edits = payload.correctionEdits(backend: backend)
            let allowed = CorrectionValidator.allowedTerms(retrieved: retrieved,
                                                           knowledge: knowledge,
                                                           freqType: frequencyType(forFeedKey: feedKey))
            var validator = CorrectionValidator(
                allowed: allowed,
                deniedTargets: CorrectionValidator.deniedTargets(from: retrieved.trafficLabels),
                phonetic: knowledge.phoneticWordToLetter)
            if let grounding = retrieved.snapGrounding, !grounding.airportRunways.isEmpty {
                validator.groundedRunways = CorrectionValidator.runwayKeys(designators: grounding.airportRunways)
            }
            return validator.validate(raw: text, edits: edits, backend: backend)
        } catch {
            return .unchanged(text, backend: backend)
        }
    }
}

/// Locate the GGUF and build a CPU llama.cpp engine, or return nil (caller then runs without a
/// local LLM — deterministic-only, or the Foundation Models backend). Prefers a model the user
/// DOWNLOADED into Application Support (`ModelStore.downloadedLLMPath`), then a bundled copy.
/// Mirrors the graceful, optional design of `makeFoundationModelsCorrector`.
func makeLocalLLMEngine(modelPath: String? = nil, nThreads: Int = 2) -> LLMEngine? {
    guard let path = modelPath ?? ModelStore.downloadedLLMPath() ?? bundledLLMModelPath() else { return nil }
    return makeLlamaEngine(modelPath: path, nThreads: nThreads)
}

/// Find a `*.gguf` under the bundled `Models/llm/` folder reference, or nil for a build that
/// ships without the local model (download-on-first-launch is a documented later option).
func bundledLLMModelPath(in bundle: Bundle = .main) -> String? {
    guard let root = bundle.resourceURL?.appendingPathComponent("Models/llm") else { return nil }
    let fm = FileManager.default
    guard let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return nil }
    return items.first { $0.pathExtension.lowercased() == "gguf" }?.path
}
