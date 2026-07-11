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

    // Coded-procedure grounding (CIFP) for the active airport. `groundingIdent` is the resolved airport
    // (curated config code, else the user's typed airport) and — unlike the config-only path — also
    // drives the `AirportContextStore`/SlotSnap lookup for ANY named airport, not just the curated few.
    // The prompt line biases the Whisper decode toward the real fix names; the block gives the LLM
    // corrector the fixes + ILS frequencies to ground a misheard fix/localizer against. Built once at init.
    private let groundingIdent: String?
    private var proceduresPromptLine = ""
    private var proceduresBlock = ""

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
         groundingIdent: String? = nil,
         knowledge: ATCKnowledgeBase = .shared) {
        self.config = config
        self.feedKey = feedKey
        self.maxHistory = maxHistory
        self.maxPromptChars = maxPromptChars
        self.knowledge = knowledge
        // The resolved airport: a curated config's code wins, else the user's typed airport.
        let ident = (config?.airportCode ?? groundingIdent)?.trimmingCharacters(in: .whitespaces).uppercased()
        self.groundingIdent = (ident?.isEmpty ?? true) ? nil : ident
        if let config, let feedKey {
            (staticPrefix, vocabTerms) = ATCContext.buildStaticPrefix(config: config, feedKey: feedKey)
        }
        if let gid = self.groundingIdent {
            // Curated configs already list fixes in the static prefix; only add the CIFP "Fixes:" decode
            // bias when they didn't, to avoid doubling up in the ~220-token prompt budget.
            let hasConfigFixes = !((config?.fixes ?? config?.waypoints ?? []).isEmpty)
            (proceduresPromptLine, proceduresBlock) = ATCContext.buildProcedures(ident: gid, includePromptFixes: !hasConfigFixes)
        }
        self.retriever = config == nil ? nil
            : ATCKnowledgeRetriever(kb: knowledge, config: config, feedKey: feedKey)
    }

    /// Build the CIFP procedures grounding for an airport: a capped Whisper "Fixes:" decode-bias line
    /// (only when the facility config didn't already list fixes) and an LLM context block naming the
    /// coded-procedure fixes + ILS frequencies the corrector can ground a misheard fix/localizer against.
    private static func buildProcedures(ident: String, includePromptFixes: Bool) -> (prompt: String, block: String) {
        let fixes = CIFP.fixes(airport: ident)
        let ilsFreqs = Array(Set(CIFP.ils(airport: ident).compactMap(\.freqMHz))).sorted()
        guard !fixes.isEmpty || !ilsFreqs.isEmpty else { return ("", "") }
        let prompt = (includePromptFixes && !fixes.isEmpty)
            ? "Fixes: " + fixes.prefix(12).joined(separator: ", ") + "."
            : ""
        var parts: [String] = []
        if !fixes.isEmpty { parts.append("Procedure fixes at \(ident): " + fixes.prefix(40).joined(separator: ", ") + ".") }
        if !ilsFreqs.isEmpty {
            parts.append("ILS frequencies: " + ilsFreqs.map { String(format: "%.2f", $0) }.joined(separator: ", ") + ".")
        }
        return (prompt, parts.joined(separator: " "))
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
        if !proceduresPromptLine.isEmpty { sections.append(proceduresPromptLine) }
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

    /// The active facility's ICAO ident (drives the `AirportContextStore` lookup for SlotSnap). Resolves
    /// to the curated config's code, else the user's typed airport — so SlotSnap grounds nationwide, not
    /// just at the handful of curated facilities.
    var airportIdent: String? { groundingIdent }

    /// Fresh in-range callsigns in SPOKEN telephony form — the CallsignSnap candidate list.
    /// Same source and freshness gate as the BB1 prompt bias (airline callsigns only). This feed
    /// is UNAUTHENTICATED (airplanes.live), so CallsignSnap treats it accordingly: it never
    /// rewrites callsign DIGITS from a candidate (a lone spoofed ghost cannot invent a flight
    /// number), only the misheard airline word when the digits already match a live aircraft;
    /// digit mismatches display as heard and are not attributed. Empty when traffic is stale.
    func snapCallsignCandidates() -> [String] {
        guard !trafficVocab.isEmpty, Date() < trafficExpiry else { return [] }
        return trafficVocab.compactMap { code in
            let up = code.uppercased().filter { $0.isLetter || $0.isNumber }
            guard up.count > 3, knowledge.airlineTelephony[String(up.prefix(3))] != nil else { return nil }
            let spoken = Self.spokenCallsign(code, knowledge: knowledge)
            return spoken.isEmpty ? nil : spoken
        }
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
        // The active airport's coded-procedure fixes + ILS frequencies — sits just above the generic RAG
        // so the corrector can ground a misheard fix/localizer, but below the pilot's own plan + live
        // traffic (prepended after this). Informational only: deliberately NOT added to `ctx.vocab`, since
        // the deterministic SlotSnap fix slot already snaps fixes with anchor + stoplist guards, and a
        // large unanchored fix set in the snap-vocab would widen the false-positive surface.
        if !proceduresBlock.isEmpty {
            ctx.block = ctx.block.isEmpty ? proceduresBlock : proceduresBlock + "\n" + ctx.block
        }
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
