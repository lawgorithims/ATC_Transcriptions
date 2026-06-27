import Foundation

/// Builds the Whisper prompt context from a hand-curated airport/feed config plus a
/// rolling history of recent transmissions. Whisper consumes the returned string as
/// a prompt prefix that biases decoding toward facility phraseology, runways, fixes,
/// and what was just said. Faithful port of `atc_context.ATCContext`.
final class ATCContext {
    private let config: AirportConfig?
    private let feedKey: String?
    private let maxHistory: Int
    private let maxPromptChars: Int

    /// The on-device ATC knowledge corpus backing the RAG retriever.
    let knowledge: ATCKnowledgeBase
    /// Lexical RAG retriever, present when a facility config is loaded.
    private let retriever: ATCKnowledgeRetriever?

    private var historyBuffer: [String] = []   // most-recent last, capped at maxHistory
    private var staticPrefix: String = ""
    private var vocabTerms: [String] = []

    // Electronic Flight Bag: the filed flight plan packed into the LLM correction context. Set
    // on the pipeline actor via `LivePipeline.setFlightPlanContext`, so only the actor mutates it.
    private var flightPlanBlock = ""
    private var flightPlanVocab: [String] = []

    init(config: AirportConfig? = nil,
         feedKey: String? = nil,
         maxHistory: Int = 3,
         maxPromptChars: Int = 800,
         knowledge: ATCKnowledgeBase = .shared) {
        self.config = config
        self.feedKey = feedKey
        self.maxHistory = maxHistory
        self.maxPromptChars = maxPromptChars
        self.knowledge = knowledge
        if let config, let feedKey {
            (staticPrefix, vocabTerms) = ATCContext.buildStaticPrefix(config: config, feedKey: feedKey)
        }
        self.retriever = config == nil ? nil
            : ATCKnowledgeRetriever(kb: knowledge, config: config, feedKey: feedKey)
    }

    /// Build the static prefix and the canonical vocab (runways + fixes). Port of
    /// `ATCContext._build_static_prefix`.
    private static func buildStaticPrefix(config: AirportConfig, feedKey: String) -> (prefix: String, vocab: [String]) {
        let entry = config.streams?[feedKey]
        let label = entry?.label ?? feedKey
        let freq = entry?.frequencyMhz ?? ""
        let tracon = config.tracon ?? ""
        let airport = config.airportName ?? config.airportCode ?? ""
        let runways = config.runways ?? []
        let fixes = config.fixes ?? config.waypoints ?? []

        let vocab = (runways + fixes).filter { !$0.isEmpty }

        var parts: [String] = ["Air traffic control radio transcript from \(label)."]
        if !airport.isEmpty { parts.append("Airport: \(airport).") }
        if !tracon.isEmpty { parts.append("Facility: \(tracon).") }
        if !freq.isEmpty { parts.append("Frequency: \(freq) MHz.") }
        if !runways.isEmpty { parts.append("Runways: " + runways.prefix(8).joined(separator: ", ") + ".") }
        if !fixes.isEmpty { parts.append("Fixes: " + fixes.prefix(10).joined(separator: ", ") + ".") }
        parts.append("Use standard ICAO phraseology, spell out numbers, include call signs and runways.")
        return (parts.joined(separator: " "), vocab)
    }

    /// Append a freshly transcribed transmission to the rolling history.
    func update(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        historyBuffer.append(trimmed)
        if historyBuffer.count > maxHistory {
            historyBuffer.removeFirst(historyBuffer.count - maxHistory)
        }
    }

    var recentHistory: [String] { historyBuffer }

    /// The context string for Whisper prompt conditioning. Port of `build_prompt`:
    /// static prefix + recent transmissions, tail-truncated to `maxPromptChars`.
    /// (The transcriber additionally caps the prompt at ~220 tokens.)
    func buildPrompt() -> String {
        if staticPrefix.isEmpty && historyBuffer.isEmpty { return "" }

        var sections: [String] = []
        if !staticPrefix.isEmpty { sections.append(staticPrefix) }
        if !historyBuffer.isEmpty {
            sections.append("Recent transmissions: " + historyBuffer.joined(separator: " "))
        }

        var prompt = sections.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        if prompt.count > maxPromptChars {
            prompt = String(prompt.suffix(maxPromptChars))
        }
        return prompt
    }

    /// Canonical terms for the optional corrector. With a facility config this is the
    /// enriched set (runways, fixes, taxiways, single-word callsigns, facility names); with
    /// no config it stays the legacy runways+fixes list (empty for a bare `ATCContext()`).
    func vocab() -> [String] { retriever?.enrichedVocab() ?? vocabTerms }

    /// Retrieve the RAG knowledge block for a transcript (callsigns mentioned, this
    /// facility's names, runways/fixes, the right phraseology, ICAO spelling) plus the
    /// language-suspect flag. Used by the local-LLM correction stage. When a flight plan is
    /// filed, its block is prepended (highest priority) so both LLM backends — which consume
    /// `RetrievedContext.block` — see the pilot's own callsign, airports, and route.
    func retrieveKnowledge(for transcript: String) -> RetrievedContext {
        let r = retriever ?? ATCKnowledgeRetriever(kb: knowledge, config: nil, feedKey: nil)
        var ctx = r.retrieve(transcript: transcript, history: recentHistory)
        if !flightPlanBlock.isEmpty {
            ctx.block = ctx.block.isEmpty ? flightPlanBlock : flightPlanBlock + "\n" + ctx.block
            ctx.vocab += flightPlanVocab   // let the validator snap a near-miss onto a filed term
        }
        return ctx
    }

    /// Inject (or clear, with an empty block) the filed flight plan as high-priority LLM context.
    func setFlightPlan(block: String, vocab: [String]) {
        flightPlanBlock = block
        flightPlanVocab = vocab
    }
}
