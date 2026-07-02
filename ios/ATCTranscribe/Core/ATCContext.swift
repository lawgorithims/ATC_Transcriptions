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

    // Live ADS-B traffic in range — a FRESHNESS-SELF-ENFORCING channel. The block is consumed only
    // while `Date() < trafficExpiry`, so a stalled/failed poller self-expires within the trust
    // window and stale aircraft can never leak into a prompt or the snap-vocab. `trafficEpoch` lets
    // a clear (toggle-off / standby / airport-change) win over any in-flight re-inject.
    private var trafficBlock = ""
    private var trafficVocab: [String] = []
    private var trafficExpiry = Date.distantPast
    private var trafficEpoch = 0

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
        var sections: [String] = []
        if !staticPrefix.isEmpty { sections.append(staticPrefix) }
        // BB1: bias the DECODE toward the aircraft actually on frequency right now (fresh ADS-B), in
        // SPOKEN form — the strongest lever for misheard callsigns, and stronger than post-correction
        // because it shifts the acoustic decode. Freshness-gated like the LLM traffic block (a stalled
        // poller self-expires); capped small to fit the ~220-token prompt budget and to bound the risk
        // of the model over-emitting a listed callsign that wasn't actually said.
        if !trafficVocab.isEmpty, Date() < trafficExpiry {
            // Only AIRLINE callsigns (telephony-matched) bias the decode — NOT tail numbers. A tail's
            // phonetic spelling ("november … zulu zulu") injects many stray letter tokens that an
            // imperfect/stale hint can leak into a low-confidence decode (measured); an airline name is
            // a single strong token and is the higher-value "misheard callsign" class anyway. Capped small.
            let airline = trafficVocab.filter { code in
                let up = code.uppercased().filter { $0.isLetter || $0.isNumber }
                return up.count > 3 && knowledge.airlineTelephony[String(up.prefix(3))] != nil
            }
            let spoken = airline.prefix(4).map { Self.spokenCallsign($0, knowledge: knowledge) }.filter { !$0.isEmpty }
            if !spoken.isEmpty {
                sections.append("Aircraft on frequency: " + spoken.joined(separator: ", ") + ".")
            }
        }
        if !historyBuffer.isEmpty {
            sections.append("Recent transmissions: " + historyBuffer.joined(separator: " "))
        }
        if sections.isEmpty { return "" }

        var prompt = sections.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        if prompt.count > maxPromptChars {
            prompt = String(prompt.suffix(maxPromptChars))
        }
        return prompt
    }

    private static let digitWords: [Character: String] = [
        "0": "zero", "1": "one", "2": "two", "3": "three", "4": "four",
        "5": "five", "6": "six", "7": "seven", "8": "eight", "9": "nine",
    ]

    /// Expand an ADS-B callsign/registration CODE to its spoken ATC form for decoder biasing:
    /// "JBU1234" → "jetblue one two three four"; "N123AB" → "november one two three alpha bravo".
    /// A leading 3-letter ICAO airline code becomes its telephony name; otherwise every character is
    /// spelled (letters phonetic, digits spoken individually — the common US readback form). Returns ""
    /// for an unusable code. Static + injected knowledge so it's trivially unit-testable.
    static func spokenCallsign(_ code: String, knowledge: ATCKnowledgeBase) -> String {
        let up = code.uppercased().filter { $0.isLetter || $0.isNumber }
        guard !up.isEmpty else { return "" }
        func spell(_ s: Substring) -> [String] {
            s.map { c in
                if c.isNumber { return digitWords[c] ?? String(c) }
                return knowledge.phonetic[String(c)]?.lowercased() ?? String(c).lowercased()
            }
        }
        if up.count > 3 {
            let prefix = String(up.prefix(3))
            if let tel = knowledge.airlineTelephony[prefix] {
                return ([tel.lowercased()] + spell(up.dropFirst(3))).joined(separator: " ")
            }
        }
        return spell(up[...]).joined(separator: " ")
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
        // Order (top → bottom): own flight plan, then live traffic, then the retrieved RAG. The
        // traffic block is the LOAD-BEARING freshness gate: it's only injected while unexpired, so a
        // stalled poller self-expires and stale aircraft never reach the prompt or snap-vocab.
        if !trafficBlock.isEmpty, Date() < trafficExpiry {
            // Traffic feeds the LLM PROMPT (context) only — deliberately NOT the corrector's
            // snap-vocab. Adding raw ADS-B codes (e.g. AAL1234) to the validator's allowed set would
            // let the LLM rewrite a readable spoken callsign ("american 1234") into the code form on
            // a safety feed. `matchTraffic` keeps its own copy of these labels for the chip.
            ctx.block = ctx.block.isEmpty ? trafficBlock : trafficBlock + "\n" + ctx.block
            // Belt-and-suspenders: also hand the raw labels to the validator as a DENYLIST of applied
            // edit targets, so even the near-miss ratio path can't turn a spoken callsign into a code.
            ctx.trafficLabels = trafficVocab
        }
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

    /// Inject the fresh in-range ADS-B traffic block with an absolute read-site `expiry`. Stored
    /// only when `epoch >= trafficEpoch` (a stale-epoch write loses to a more-recent clear); an
    /// empty block clears unconditionally.
    func setTraffic(block: String, vocab: [String], expiry: Date, epoch: Int) {
        guard epoch >= trafficEpoch else { return }
        trafficEpoch = epoch
        if block.isEmpty {
            trafficBlock = ""; trafficVocab = []; trafficExpiry = .distantPast
        } else {
            trafficBlock = block; trafficVocab = vocab; trafficExpiry = expiry
        }
    }

    /// Clear traffic and advance the epoch so any in-flight non-empty write becomes a no-op
    /// (toggle-off / standby / airport-change).
    func clearTraffic(epoch: Int) {
        trafficEpoch = max(trafficEpoch, epoch)
        trafficBlock = ""; trafficVocab = []; trafficExpiry = .distantPast
    }

}
