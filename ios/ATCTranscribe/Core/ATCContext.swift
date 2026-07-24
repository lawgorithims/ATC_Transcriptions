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

    // Ownship decode-bias line (pipeline gap C): the pilot's OWN filed callsign in spoken telephony form
    // + the next waypoint, biasing the Whisper DECODE toward what the pilot will be addressed as and
    // routed to. Set on the pipeline actor via `LivePipeline.setOwnshipContext`; placed at the HEAD of the
    // prompt so it survives the transcriber's ~220-token prefix cap. (The filed callsign previously
    // reached only the LLM corrector, never the acoustic decode.)
    private var ownshipPromptLine = ""

    // Electronic Flight Bag: the filed flight plan packed into the LLM correction context. Set
    // on the pipeline actor via `LivePipeline.setFlightPlanContext`, so only the actor mutates it.
    private var flightPlanBlock = ""
    private var flightPlanVocab: [String] = []
    // Route PLATE priming (PlateIndex): a decode-bias fix line + an informational LLM block of the
    // charts' freqs/fixes. No snap-vocab — see the rationale in `retrieveKnowledge`.
    private var platePromptLine = ""
    private var plateBlock = ""

    // Coded-procedure grounding (CIFP) for the active airport. `groundingIdent` is the resolved airport
    // (curated config code, else the user's typed airport) and — unlike the config-only path — also
    // drives the `AirportContextStore`/SlotSnap lookup for ANY named airport, not just the curated few.
    // The prompt line biases the Whisper decode toward the real fix names; the block gives the LLM
    // corrector the fixes + ILS frequencies to ground a misheard fix/localizer against. Built once at init.
    private let groundingIdent: String?
    private var proceduresPromptLine = ""
    private var proceduresBlock = ""

    // GPS-VICINITY procedures (in-cockpit sources: mic / USB / Stratux). Unlike the init-built
    // `proceduresBlock` above — the single TYPED airport, used only on the internet LiveATC feed — this
    // is pushed at RUNTIME by `LivePipeline.setGroundingAirports` as ownship moves, a union across the
    // surrounding-vicinity airports (map + CIFP derived). When present it SUPERSEDES the typed
    // procedures in BOTH the Whisper prompt and the LLM block (same category; the two paths are
    // source-exclusive, so this only overlaps if a LiveFeed-built context is reused for an in-cockpit
    // run — vicinity is the right answer there too). No freshness gate: it's static map data refreshed
    // on movement, not the spoofable ADS-B traffic channel. Empty clears it (back to the typed path).
    private var vicinityPromptLine = ""
    private var vicinityBlock = ""

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

    /// Build the SOFT vicinity procedures grounding from the GPS-resolved nearby airports (nearest-first):
    /// a capped Whisper "Fixes:" decode-bias line and an LLM block naming the vicinity airports + a UNION
    /// of their runways, coded-procedure fixes, and ILS frequencies — the map-derived "complete picture"
    /// the corrector grounds against in-cockpit. Purely additive to the prompt (informational, like the
    /// single-airport `buildProcedures`); the deterministic SlotSnap still grounds only on the single
    /// nearest airport (see `LivePipeline.setGroundingAirports`), so this wider soft union never widens
    /// the hard-snap surface. Caps keep it inside the ~220-token prompt budget.
    static func vicinityProcedures(_ airports: [AirportContextData]) -> (prompt: String, block: String) {
        guard !airports.isEmpty else { return ("", "") }
        let idents = orderedUnique(airports.map(\.ident))
        let fixes = orderedUnique(airports.flatMap(\.fixes))
        let runways = orderedUnique(airports.flatMap(\.runways))
        let ils = Array(Set(airports.flatMap(\.navFrequencies))).sorted()
        // Whisper decode bias — the nearest few fix names (nearest-first order is preserved by the union).
        let prompt = fixes.isEmpty ? "" : "Fixes: " + fixes.prefix(12).joined(separator: ", ") + "."
        var parts: [String] = ["Vicinity airports: " + idents.prefix(6).joined(separator: ", ") + "."]
        if !runways.isEmpty { parts.append("Runways: " + runways.prefix(16).joined(separator: ", ") + ".") }
        if !fixes.isEmpty { parts.append("Procedure fixes: " + fixes.prefix(30).joined(separator: ", ") + ".") }
        if !ils.isEmpty {
            parts.append("ILS frequencies: " + ils.map { String(format: "%.2f", $0) }.joined(separator: ", ") + ".")
        }
        return (prompt, parts.joined(separator: " "))
    }

    /// Order-preserving dedup (keeps nearest-first union order; drops empties). Used by `vicinityProcedures`.
    private static func orderedUnique(_ xs: [String]) -> [String] {
        var seen = Set<String>(); var out: [String] = []
        for x in xs where !x.isEmpty && seen.insert(x).inserted { out.append(x) }
        return out
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
        // GPS-vicinity decode bias supersedes the typed one (source-exclusive; same category).
        let procLine = vicinityPromptLine.isEmpty ? proceduresPromptLine : vicinityPromptLine
        if !procLine.isEmpty { sections.append(procLine) }
        // Own aircraft callsign + next waypoint — head-placed (before plate/traffic/history) so it stays
        // inside the transcriber's ~220-token prefix cap. One short sentence; ≈≤12 tokens.
        if !ownshipPromptLine.isEmpty { sections.append(ownshipPromptLine) }
        // Route chart-fix names (from the filed plan's plates) bias the decode toward what's printed on
        // the approaches the pilot is likely to fly — capped in `PlateIndex.priming` to protect the budget.
        if !platePromptLine.isEmpty { sections.append(platePromptLine) }
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
        // GPS-vicinity block supersedes the typed one (source-exclusive; same category).
        let procBlock = vicinityBlock.isEmpty ? proceduresBlock : vicinityBlock
        if !procBlock.isEmpty {
            ctx.block = ctx.block.isEmpty ? procBlock : procBlock + "\n" + ctx.block
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
        if !plateBlock.isEmpty {
            // Informational LLM context ONLY — deliberately NOT added to `ctx.vocab`, mirroring the
            // coded-procedures decision above. The plate fix set is large (route-wide), OCR-derived, and
            // rife with plain-word idents (DEPOT, DEVON, ADORE…); putting it in the validator's snap-set
            // would let the corrector rewrite a correctly-heard word onto a fabricated fix via the
            // unanchored `allowed.contains` path. Route fixes bias the DECODE via `platePromptLine`.
            ctx.block = ctx.block.isEmpty ? plateBlock : plateBlock + "\n" + ctx.block
        }
        return ctx
    }

    /// Inject (or clear, with an empty block) the filed flight plan as high-priority LLM context.
    func setFlightPlan(block: String, vocab: [String]) {
        flightPlanBlock = block
        flightPlanVocab = vocab
    }

    /// Set (or clear, with an empty callsign) the ownship decode-bias line: the pilot's own callsign in
    /// spoken telephony form ("november eight nine two five tango" / "jetblue …") plus the next waypoint
    /// ident. Reuses `spokenCallsign` — the SAME expansion the "Aircraft on frequency" line uses — so the
    /// form matches natural readback, not the bare token-chars the addressing gate uses. Built once per
    /// plan change (trivial string ops; `buildPrompt` only appends the cached line).
    func setOwnship(callsign: String, nextWaypoint: String) {
        let spoken = Self.spokenCallsign(callsign, knowledge: knowledge)
        guard !spoken.isEmpty else { ownshipPromptLine = ""; return }
        var line = "Own aircraft: " + spoken + "."
        let wp = nextWaypoint.trimmingCharacters(in: .whitespaces).uppercased()
        if !wp.isEmpty { line += " Next waypoint: " + wp + "." }
        ownshipPromptLine = line
    }

    /// Inject (or clear) the route's PLATE priming — the frequencies/fix idents printed on the filed
    /// route's terminal-procedure charts (`PlateIndex`). `promptLine` biases the Whisper decode toward
    /// chart fix names; `block` is informational LLM context (deliberately NOT snap-vocab — see
    /// `retrieveKnowledge`).
    func setPlatePriming(promptLine: String, block: String) {
        platePromptLine = promptLine
        plateBlock = block
    }

    /// Inject (or clear, with empty strings) the GPS-vicinity procedures grounding — the soft
    /// LLM/Whisper union built by `vicinityProcedures`, pushed by `LivePipeline.setGroundingAirports`
    /// as ownship moves. Supersedes the typed procedures while non-empty.
    func setVicinityProcedures(promptLine: String, block: String) {
        vicinityPromptLine = promptLine
        vicinityBlock = block
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
