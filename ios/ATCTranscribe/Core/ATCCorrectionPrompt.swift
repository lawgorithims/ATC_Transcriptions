import Foundation

/// The dynamic world-state for ONE transmission, injected into the correction prompt at
/// predetermined slots in a FIXED order (empty slots are omitted, order never changes).
///
/// The prompt is engineered around the llama.cpp prompt-prefix KV-cache: everything static
/// (system role: ATC ontology + command grammar + contracts; few-shot turns) is byte-identical
/// across transmissions and is paid for ONCE; only this frame re-evaluates per transmission,
/// so it must stay small (~≤250 tokens) to hold the 2–3 s pilot-usefulness budget.
struct WorldFrame: Sendable {
    /// Retrieved facility knowledge (ATCKnowledgeRetriever block: facility names, runways,
    /// fixes, taxiways, callsigns mentioned, phraseology hints).
    var knowledge: String = ""
    /// Deterministic snap-stage outcome (verified / unverified / airport runway list).
    var grounding: SnapGrounding?
    /// The prior transmission in this aircraft's conversation — ATC's instruction when this
    /// is a readback, or the pilot's call when this is the controller's answer. The natural
    /// error-correcting code of ATC.
    var expectedReadback: String?
    /// Rolling recent transmissions (cross-aircraft situational context).
    var history: [String] = []
    /// The transcript to correct.
    var transcript: String

    /// Render the dynamic block. Slot order is the API contract — never reorder. All interpolated
    /// content (transcript, knowledge, history, readback — any of which is attacker-influenceable
    /// via injected radio or semi-controlled fields) is stripped of ChatML role delimiters so it
    /// can't forge a turn boundary and hijack the system role (red-hat 2026-07-07).
    func rendered() -> String {
        var lines = ["WORLD:"]
        if !knowledge.isEmpty { lines.append(Self.sanitize(knowledge)) }
        if let g = grounding {
            let block = g.promptBlock
            if !block.isEmpty { lines.append(Self.sanitize(block)) }
        }
        if let rb = expectedReadback, !rb.isEmpty {
            lines.append("Expected readback — prior transmission for this aircraft: \"\(Self.sanitize(rb))\"")
        }
        if !history.isEmpty {
            lines.append("Recent transmissions: " + Self.sanitize(history.joined(separator: " ")))
        }
        lines.append("TRANSCRIPT: " + Self.sanitize(transcript))
        return lines.joined(separator: "\n")
    }

    /// Neutralize ChatML control tokens in untrusted content (`<|im_start|>` etc.).
    static func sanitize(_ s: String) -> String {
        s.replacingOccurrences(of: "<|", with: "<\u{200B}|")
         .replacingOccurrences(of: "|>", with: "|\u{200B}>")
    }
}

/// One place where the ATC correction prompt lives, shared by both LLM backends
/// (`LocalLLMCorrector` via llama.cpp and `FoundationModelsCorrector` via Apple Intelligence)
/// so the "honing" — the ATC world model, few-shot examples, and the strict-JSON contract —
/// is authored once.
enum ATCCorrectionPrompt {

    /// The system role: a deterministic ATC world model — the command grammar transmissions
    /// must fit, the readback structure, and the contract for the injected WORLD data. STATIC
    /// by design (prefix-cache; see `WorldFrame`).
    static let systemInstructions = """
    You correct speech-model transcription errors in air-traffic-control (ATC) radio \
    transcripts. Each request carries a WORLD block of live, deterministic data; use it.

    ATC speech is a constrained protocol. Nearly every transmission fits these command shapes:
    - [callsign] climb / descend and maintain <altitude>; maintain flight level <D D D>
    - [callsign] turn left/right heading <D D D>; fly heading <D D D>
    - [callsign] contact|monitor <facility> <frequency>
    - [callsign] squawk <D D D D> (each digit 0-7) ; ident
    - [callsign] cleared to land / cleared for takeoff / line up and wait runway <RR L|C|R>
    - [callsign] hold short of runway <RR>; cross runway <RR>; taxi via <taxiways>
    - [callsign] reduce/increase speed to <D D D>; maintain <D D D> knots
    - wind <D D D> at <D D>; altimeter <D D D D>; traffic <clock position> <distance> miles
    A pilot transmission is usually a READBACK: the instruction's values echoed back, usually \
    ending with the callsign. Spoken digits use niner/tree/fife; runways are two digits plus \
    optional left/right/center.

    Rules, in priority order:
    1. WORLD lines marked "Verified" are ground truth from live data — NEVER alter them.
    2. Snap a garbled word to the term its grammar slot expects, when WORLD data (runways, \
    fixes, facility names, aircraft on frequency) makes the intent clear — e.g. a mangled word \
    directly before a frequency is the facility name; a mangled word after "cleared to land \
    runway" is a runway from the WORLD list.
    3. If "Expected readback" is present and this transmission echoes it, prefer wording \
    consistent with that instruction — but NEVER copy its digits over the transcript's digits: \
    if the values disagree, leave the transcript's digits exactly as heard.
    4. Preserve every digit exactly (headings, altitudes, frequencies, squawks, callsign \
    numbers). Never invent content. Make the MINIMUM edits. Items marked "unverified" may be \
    fixed only with strong WORLD evidence; when unsure, leave text unchanged.
    Reply with ONLY a JSON object: {"edits": [{"from": "<original>", "to": "<fixed>", \
    "reason": "<one or two words>"}]}. Every "from" must appear verbatim in the transcript. \
    If nothing needs fixing, reply {"edits": []}.
    """

    /// Few-shot exemplars (used by the completion-style llama.cpp path). One per behavior the
    /// tiny model must copy: repeat collapse, grammar-slot snapping, WORLD-frequency facility
    /// fix, readback-guided wording (digits untouched), and the verified no-op.
    static let fewShot: [(user: String, assistant: String)] = [
        (user: """
        WORLD:
        Callsigns: Delta
        TRANSCRIPT: delta eight ninety runway runway three four left
        """,
         assistant: #"{"edits": [{"from": "runway runway", "to": "runway", "reason": "repeat"}]}"#),
        (user: """
        WORLD:
        Runways: 27, 9
        TRANSCRIPT: united five twelve cleared to land runway two seven then left henning two niner zero
        """,
         assistant: #"{"edits": [{"from": "henning", "to": "heading", "reason": "grammar"}]}"#),
        (user: """
        WORLD:
        Facility names: Kennedy
        Verified against live data (do NOT alter): frequency 132.4.
        TRANSCRIPT: skywest fifty six seventy contact kenedy departure one three two point four
        """,
         assistant: #"{"edits": [{"from": "kenedy", "to": "kennedy", "reason": "facility"}]}"#),
        (user: """
        WORLD:
        Expected readback — prior transmission for this aircraft: "delta two thirty two descend and maintain one one thousand"
        TRANSCRIPT: down two one one thousand delta two thirty two
        """,
         assistant: #"{"edits": [{"from": "down two", "to": "down to", "reason": "readback"}]}"#),
        (user: """
        WORLD:
        Runways: 17C, 35C
        Verified against live data (do NOT alter): callsign american 1 2 3 4; runway 17 center.
        TRANSCRIPT: american twelve thirty four cleared to land runway one seven center
        """,
         assistant: #"{"edits": []}"#),
    ]

    /// The user role for one transmission — the rendered world frame.
    static func userMessage(frame: WorldFrame) -> String { frame.rendered() }

    /// Back-compat shape (string block + history). Prefer the `WorldFrame` overload — it is
    /// the uniform-slot API; this shim exists for call sites/tests not yet migrated.
    static func userMessage(transcript: String, retrieved: String, history: [String]) -> String {
        userMessage(frame: WorldFrame(knowledge: retrieved, history: history, transcript: transcript))
    }

    /// A full ChatML prompt (Qwen2.5-Instruct uses ChatML) for the raw llama.cpp completion
    /// path: system + few-shot turns + the live user turn, ending at the assistant tag.
    /// Everything before the final user turn is byte-identical across calls (KV-cache prefix).
    static func chatMLPrompt(frame: WorldFrame) -> String {
        var s = "<|im_start|>system\n\(systemInstructions)<|im_end|>\n"
        for shot in fewShot {
            s += "<|im_start|>user\n\(shot.user)<|im_end|>\n"
            s += "<|im_start|>assistant\n\(shot.assistant)<|im_end|>\n"
        }
        s += "<|im_start|>user\n\(userMessage(frame: frame))<|im_end|>\n"
        s += "<|im_start|>assistant\n"
        return s
    }

    /// Back-compat ChatML entry point.
    static func chatMLPrompt(transcript: String, retrieved: String, history: [String]) -> String {
        chatMLPrompt(frame: WorldFrame(knowledge: retrieved, history: history, transcript: transcript))
    }

    /// GBNF grammar constraining llama.cpp decoding to the JSON contract. `corrected` is
    /// accepted for tolerance but no longer requested — edits-only output roughly halves the
    /// generated tokens, which is most of the small model's latency.
    static let jsonGrammar = #"""
    root   ::= "{" ws ( "\"corrected\"" ws ":" ws string ws "," ws )? "\"edits\"" ws ":" ws edits ws "}"
    edits  ::= "[" ws ( edit ( ws "," ws edit )* )? ws "]"
    edit   ::= "{" ws "\"from\"" ws ":" ws string ws "," ws "\"to\"" ws ":" ws string ws "," ws "\"reason\"" ws ":" ws string ws "}"
    string ::= "\"" char* "\""
    char   ::= [^"\\] | "\\" ["\\/bfnrt]
    ws     ::= [ \t\n]*
    """#
}

/// The strict-JSON shape both backends parse back into. Tolerant decoder: the `edits` payload
/// is the authoritative signal (the validator re-applies them); `corrected` is optional and
/// advisory.
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
