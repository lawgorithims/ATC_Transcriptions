import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple Foundation Models correction backend — the **alternate** on-device LLM (kept pluggable
/// behind `LLMCorrector` alongside the primary llama.cpp `LocalLLMCorrector`). It uses Apple's
/// on-device model (Apple Intelligence) via guided generation. Unlike the CPU llama.cpp backend
/// it runs on Apple-managed silicon (the ANE), so it can contend with WhisperKit — offered as an
/// option, not the default.
///
/// Shares the honing (`ATCCorrectionPrompt`) and the guardrails (`CorrectionValidator`) with the
/// local backend, so both behave consistently. Two product rules carry over:
///   * OPTIONAL — only built on iOS 26 / macOS 26 (`makeFoundationModelsCorrector` returns nil
///     otherwise); the per-device "is Apple Intelligence ready" check happens at correction time.
///   * GRACEFUL — any failure returns the text unchanged, so the LLM can never break the feed.

#if canImport(FoundationModels)

/// Structured output the model is constrained to produce — the `edits` are authoritative (the
/// validator re-applies them); `corrected` is advisory, mirroring the local backend.
@available(iOS 26.0, macOS 26.0, *)
@Generable
struct LLMCorrectionResult {
    @Guide(description: "The corrected transcript. Return the input unchanged when there are no clear errors.")
    let corrected: String
    @Guide(description: "Each individual word or phrase you changed, in order.")
    let edits: [LLMCorrectionEdit]
}

@available(iOS 26.0, macOS 26.0, *)
@Generable
struct LLMCorrectionEdit {
    @Guide(description: "The original incorrect token or phrase, exactly as it appears in the transcript.")
    let from: String
    @Guide(description: "What it should be, using the known vocabulary or standard ICAO phraseology.")
    let to: String
    @Guide(description: "A one or two word reason, e.g. callsign, runway, waypoint, phraseology, repeat.")
    let reason: String
}

@available(iOS 26.0, macOS 26.0, *)
struct FoundationModelsCorrector: LLMCorrector {
    let knowledge: ATCKnowledgeBase
    let feedKey: String?
    let backend = "foundation"

    func correct(text: String, history: [String], retrieved: RetrievedContext) async -> Correction {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unchanged(text, backend: backend) }
        // Per-device gate: Apple Intelligence may be off, downloading, or unsupported.
        guard case .available = SystemLanguageModel.default.availability else {
            return .unchanged(text, backend: backend)
        }

        let prompt = ATCCorrectionPrompt.userMessage(frame: WorldFrame(
            knowledge: retrieved.block,
            grounding: retrieved.snapGrounding,
            expectedReadback: retrieved.expectedReadback,
            history: history,
            transcript: text))
        do {
            // A fresh session per transmission: each correction is independent (no rolling chat
            // history that would bias the next). The model itself is loaded once by the system.
            let session = LanguageModelSession(instructions: { ATCCorrectionPrompt.systemInstructions })
            let response = try await session.respond(
                to: prompt,
                generating: LLMCorrectionResult.self,
                options: GenerationOptions(temperature: 0))
            let edits = response.content.edits.map {
                CorrectionEdit(from: $0.from, to: $0.to,
                               reason: $0.reason.isEmpty ? "llm" : $0.reason, backend: backend)
            }
            let allowed = CorrectionValidator.allowedTerms(retrieved: retrieved, knowledge: knowledge,
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
            // Model unavailable / slow / guardrail / unparseable — never break the feed.
            return .unchanged(text, backend: backend)
        }
    }
}

/// Build the Foundation Models backend when the framework is present AND the OS is new enough.
func makeFoundationModelsCorrector(knowledge: ATCKnowledgeBase, feedKey: String?) -> LLMCorrector? {
    if #available(iOS 26.0, macOS 26.0, *) {
        return FoundationModelsCorrector(knowledge: knowledge, feedKey: feedKey)
    }
    return nil
}

#else

/// Framework absent in this SDK — the Foundation Models backend is unavailable.
func makeFoundationModelsCorrector(knowledge: ATCKnowledgeBase, feedKey: String?) -> LLMCorrector? { nil }

#endif
