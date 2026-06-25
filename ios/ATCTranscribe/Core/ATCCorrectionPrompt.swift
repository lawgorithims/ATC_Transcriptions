import Foundation

/// One place where the ATC correction prompt lives, shared by both LLM backends
/// (`LocalLLMCorrector` via llama.cpp and `FoundationModelsCorrector` via Apple Intelligence)
/// so the "honing" — system instructions, retrieved RAG context, few-shot examples, and the
/// strict-JSON contract — is authored once. Extends the original
/// `FoundationModelsCorrector.instructions` and the Python `OllamaCorrector._SYSTEM`.
enum ATCCorrectionPrompt {

    /// The system role: what to fix, what never to touch, and the output contract.
    static let systemInstructions = """
    You correct transcription errors in air-traffic-control (ATC) radio transcripts produced \
    by a speech model. Use the provided KNOWN CONTEXT (facility names, runways, taxiways, \
    fixes/waypoints, callsigns, and standard ICAO phraseology) to fix only CLEAR mistakes:
    - misheard callsigns, runway / taxiway / waypoint / navaid names, and airline names that \
    closely match a known term;
    - non-standard wording that should be standard ICAO phraseology or read-back wording;
    - obvious repetition where the speech model looped a word or phrase;
    - stray non-English words that leaked in (the audio is always English ATC).
    Make the MINIMUM number of edits. NEVER invent or add information that is not in the \
    transcript. Preserve every number, heading, altitude, flight level, frequency, and squawk \
    code EXACTLY as transcribed — never change a digit. If you are not confident an edit is \
    correct, leave that text unchanged.
    Reply with ONLY a JSON object: {"corrected": "<full corrected transcript>", "edits": \
    [{"from": "<original>", "to": "<fixed>", "reason": "<one or two words>"}]}. If nothing \
    needs fixing, return the transcript unchanged with an empty edits list.
    """

    /// Few-shot exemplars (used by the completion-style llama.cpp path). They demonstrate the
    /// three core error classes and a clean no-op so the tiny model copies the JSON shape.
    static let fewShot: [(user: String, assistant: String)] = [
        (user: """
        KNOWN CONTEXT:
        Callsigns: Delta
        Transcript: delta eight ninety runway runway three four left
        """,
         assistant: #"{"corrected": "delta eight ninety runway three four left", "edits": [{"from": "runway runway", "to": "runway", "reason": "repeat"}]}"#),
        (user: """
        KNOWN CONTEXT:
        Callsigns: SkyWest
        Facility names: Kennedy
        Transcript: skywest fifty six seventy contact kenedy tower
        """,
         assistant: #"{"corrected": "skywest fifty six seventy contact kennedy tower", "edits": [{"from": "kenedy", "to": "kennedy", "reason": "facility"}]}"#),
        (user: """
        KNOWN CONTEXT:
        Runways: 17C, 35C
        Transcript: american twelve thirty four cleared to land runway one seven center
        """,
         assistant: #"{"corrected": "american twelve thirty four cleared to land runway one seven center", "edits": []}"#),
    ]

    /// The user role for one transmission: the retrieved RAG block, recent history, and the
    /// transcript to fix. Shared by both backends.
    static func userMessage(transcript: String, retrieved: String, history: [String]) -> String {
        var lines = ["KNOWN CONTEXT:"]
        if !retrieved.isEmpty { lines.append(retrieved) }
        if !history.isEmpty { lines.append("Recent transmissions: " + history.joined(separator: " ")) }
        lines.append("Transcript: " + transcript)
        return lines.joined(separator: "\n")
    }

    /// A full ChatML prompt (Qwen2.5-Instruct uses ChatML) for the raw llama.cpp completion
    /// path: system + few-shot turns + the live user turn, ending at the assistant tag.
    static func chatMLPrompt(transcript: String, retrieved: String, history: [String]) -> String {
        var s = "<|im_start|>system\n\(systemInstructions)<|im_end|>\n"
        for shot in fewShot {
            s += "<|im_start|>user\n\(shot.user)<|im_end|>\n"
            s += "<|im_start|>assistant\n\(shot.assistant)<|im_end|>\n"
        }
        s += "<|im_start|>user\n\(userMessage(transcript: transcript, retrieved: retrieved, history: history))<|im_end|>\n"
        s += "<|im_start|>assistant\n"
        return s
    }

    /// GBNF grammar that constrains llama.cpp decoding to the exact JSON contract — the local
    /// analog of Ollama's `format: "json"` / Foundation Models guided generation, essential for
    /// keeping a 0.5B model parseable.
    static let jsonGrammar = #"""
    root   ::= "{" ws "\"corrected\"" ws ":" ws string ws "," ws "\"edits\"" ws ":" ws edits ws "}"
    edits  ::= "[" ws ( edit ( ws "," ws edit )* )? ws "]"
    edit   ::= "{" ws "\"from\"" ws ":" ws string ws "," ws "\"to\"" ws ":" ws string ws "," ws "\"reason\"" ws ":" ws string ws "}"
    string ::= "\"" char* "\""
    char   ::= [^"\\] | "\\" ["\\/bfnrt]
    ws     ::= [ \t\n]*
    """#
}

/// The strict-JSON shape both backends parse back into. Tolerant decoder: the `edits` payload
/// is the authoritative signal (the validator re-applies them); `corrected` is advisory.
struct LLMCorrectionPayload: Decodable {
    struct Edit: Decodable { let from: String; let to: String; let reason: String? }
    let corrected: String?
    let edits: [Edit]?

    /// Pull the first balanced `{...}` object out of arbitrary model output and decode it, so a
    /// stray token before/after the JSON doesn't defeat parsing.
    static func parse(_ raw: String) -> LLMCorrectionPayload? {
        guard let start = raw.firstIndex(of: "{") else { return nil }
        var depth = 0, inString = false, escaped = false
        var end: String.Index?
        var i = start
        while i < raw.endIndex {
            let c = raw[i]
            if inString {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
            } else {
                if c == "\"" { inString = true }
                else if c == "{" { depth += 1 }
                else if c == "}" { depth -= 1; if depth == 0 { end = i; break } }
            }
            i = raw.index(after: i)
        }
        guard let end, let data = String(raw[start...end]).data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(LLMCorrectionPayload.self, from: data)
    }

    /// Map the parsed edits into `CorrectionEdit`s for the validator (which decides which apply).
    func correctionEdits(backend: String) -> [CorrectionEdit] {
        (edits ?? []).compactMap { e in
            let from = e.from.trimmingCharacters(in: .whitespaces)
            let to = e.to.trimmingCharacters(in: .whitespaces)
            guard !from.isEmpty, !to.isEmpty else { return nil }
            return CorrectionEdit(from: from, to: to, reason: (e.reason?.isEmpty == false ? e.reason! : "llm"), backend: backend)
        }
    }
}
