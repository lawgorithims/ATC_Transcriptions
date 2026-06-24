import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// On-device LLM correction stage — the Swift counterpart of `atc_corrector.OllamaCorrector`,
/// using Apple's **Foundation Models** framework (the on-device model behind Apple
/// Intelligence) in place of a local Ollama server. It is the FINAL, output-only stage:
/// it fixes what the deterministic vocab matcher can't — genuine semantic mishears,
/// callsign / runway / waypoint / taxiway substitutions, ICAO phraseology, and repetition
/// artifacts — while preserving the raw transcript and recording every edit.
///
/// Two product rules carry over verbatim from the Python design:
///   * OPTIONAL — only built when `CorrectionConfig.llmEnabled` is set AND the framework
///     is present (`makeFoundationModelsCorrector` returns nil otherwise), so a device
///     without it simply runs the deterministic stage.
///   * GRACEFUL — any failure (model unavailable/slow, guardrail, unparseable output)
///     returns the text unchanged, so the LLM can never break the live feed.
///
/// Requires iOS 26 / macOS 26 and an Apple-Intelligence-capable device; weak-linked via
/// `@available` so the app still builds and runs (deterministic-only) on older targets.

#if canImport(FoundationModels)

/// Structured output the model is constrained to produce — mirrors the strict-JSON
/// `{"corrected": ..., "edits": [{"from","to","reason"}]}` contract of the Ollama backend,
/// but enforced by guided generation instead of a `format: "json"` request.
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
struct FoundationModelsCorrector: Corrector {
    let vocabProvider: () -> [String]

    static let instructions = """
    You correct transcription errors in air-traffic-control (ATC) radio transcripts produced \
    by a speech model. Use the provided known vocabulary (airport facility names, runways, \
    taxiways, fixes and waypoints, navaids, procedures, and airline callsigns) together with \
    standard ICAO phraseology to fix only CLEAR mistakes:
    - misheard callsigns, runway / taxiway / waypoint / navaid names, and airline names that \
    closely match a known-vocabulary term;
    - standard ICAO phraseology and read-back wording;
    - obvious repetition where the model accidentally repeated a word or phrase.
    Make the MINIMUM number of edits. Never invent or add information that is not in the \
    transcript. Preserve every number, heading, altitude, frequency, and squawk code exactly \
    as transcribed. If you are not confident an edit is correct, leave that text unchanged.
    """

    func correct(_ text: String, history: [String]) async -> Correction {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unchanged(text, backend: "foundation") }
        // Per-device gate: Apple Intelligence may be off, downloading, or unsupported.
        guard case .available = SystemLanguageModel.default.availability else {
            return .unchanged(text, backend: "foundation")
        }

        let vocab = vocabProvider().filter { !$0.isEmpty }.joined(separator: ", ")
        let prompt = """
        Known vocabulary: \(vocab.isEmpty ? "(none)" : vocab)
        Recent transmissions: \(history.isEmpty ? "(none)" : history.joined(separator: " "))
        Transcript to correct: \(text)
        """

        do {
            // A fresh session per transmission: each correction is independent (no rolling
            // chat history that would bias the next one). The model itself is loaded once.
            let session = LanguageModelSession(instructions: { Self.instructions })
            let response = try await session.respond(
                to: prompt,
                generating: LLMCorrectionResult.self,
                options: GenerationOptions(temperature: 0))
            let result = response.content
            let corrected = result.corrected.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !corrected.isEmpty, corrected != text else {
                return .unchanged(text, backend: "foundation")
            }
            let edits = result.edits.compactMap { e -> CorrectionEdit? in
                let from = e.from.trimmingCharacters(in: .whitespaces)
                let to = e.to.trimmingCharacters(in: .whitespaces)
                guard !from.isEmpty, !to.isEmpty else { return nil }
                return CorrectionEdit(from: from, to: to,
                                      reason: e.reason.isEmpty ? "llm" : e.reason,
                                      backend: "foundation")
            }
            return Correction(raw: text, corrected: corrected, changed: true, edits: edits, backend: "foundation")
        } catch {
            // Model unavailable / slow / guardrail / unparseable — never break the feed.
            return .unchanged(text, backend: "foundation")
        }
    }
}

/// Build the on-device LLM corrector when the framework is present AND the OS is new
/// enough. Returns nil on older OSes (the caller then runs deterministic-only). The
/// per-device "is Apple Intelligence actually ready" check happens at correction time via
/// `SystemLanguageModel.availability`, so enabling the toggle on an incapable device is
/// harmless — every correction simply degrades to "unchanged".
func makeFoundationModelsCorrector(vocab: @escaping () -> [String]) -> Corrector? {
    if #available(iOS 26.0, macOS 26.0, *) {
        return FoundationModelsCorrector(vocabProvider: vocab)
    }
    return nil
}

#else

/// Framework absent in this SDK — the LLM stage is unavailable, so correction runs
/// deterministic-only.
func makeFoundationModelsCorrector(vocab: @escaping () -> [String]) -> Corrector? { nil }

#endif
