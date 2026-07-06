import Foundation

/// The retrieved, budget-capped context block plus the enriched vocab for one transmission.
struct RetrievedContext: Sendable {
    /// A compact, labelled knowledge block to inject into the LLM prompt.
    var block: String
    /// Canonical terms (runways, fixes, taxiways, callsigns, facility names) the deterministic
    /// stage can snap onto and the LLM should prefer.
    var vocab: [String]
    /// True when the transcript looks like it is not English ATC (non-Latin / heavy non-ASCII),
    /// a cue the refiner uses to prioritise it (the user's "wrong language" error class).
    var languageSuspect: Bool
    /// Raw in-range ADS-B traffic labels (callsigns/registrations, e.g. "AAL1234"). They feed the LLM
    /// PROMPT for context but are DENIED as applied edit targets by `CorrectionValidator` — so a
    /// readable spoken callsign is never rewritten into an ADS-B code form. Empty when no live traffic.
    var trafficLabels: [String] = []
    /// Snap-stage outcome for THIS transmission (CallsignSnap/SlotSnap verdicts + airport
    /// grounding). Rides along to the refiner so the prompt can cite it and the validator can
    /// veto edits that contradict it (`groundedRunways`). Nil when the snaps didn't run.
    var snapGrounding: SnapGrounding? = nil
    /// The prior transmission in this aircraft's conversation (instruction↔readback pairing —
    /// ATC's built-in error-correcting code). Feeds the prompt's expected-readback slot.
    var expectedReadback: String? = nil
}

/// The "RAG" step: given a raw transcript plus the active facility, lexically retrieve the
/// most relevant slices of `ATCKnowledgeBase` (callsigns mentioned, this facility's spoken
/// names, runways/fixes/taxiways, the right phraseology set, ICAO spelling hints), rank them
/// by overlap with the transcript, and pack them into a small token budget.
///
/// Lexical, not embedding-based: it reuses `SequenceMatcher`/`closestMatch` (the same
/// algorithm the deterministic corrector uses), so it stays cheap on CPU and needs no model.
/// A curated KB this small doesn't benefit enough from vector search to justify an embedding
/// model on-device (noted as future work).
struct ATCKnowledgeRetriever: Sendable {
    let kb: ATCKnowledgeBase
    let config: AirportConfig?
    let feedKey: String?
    /// Approximate word budget for the assembled block (keeps the 0.5B prompt small/fast).
    var tokenBudget = 300

    private var freqType: String { frequencyType(forFeedKey: feedKey) }

    // MARK: Static vocab (transcript-independent) for the deterministic corrector.

    /// Runways + fixes/waypoints + taxiways + single-word callsign telephony + single-word
    /// facility names, deduped. Widens what the deterministic stage can match beyond the
    /// runways+fixes the old `ATCContext.vocab()` exposed.
    func enrichedVocab() -> [String] {
        var terms: [String] = []
        if let c = config {
            terms += c.runways ?? []
            terms += c.fixes ?? c.waypoints ?? []
            terms += c.taxiways ?? []
        }
        // Single-token names only — the deterministic matcher is per-token, so multi-word
        // entries ("Air Canada") would never match a single transcript token.
        terms += kb.allTelephonyNames.filter { !$0.contains(" ") }
        terms += kb.spokenNames(forAirport: config?.airportCode).flatMap { $0.split(separator: " ").map(String.init) }
        var seen = Set<String>()
        return terms.filter { !$0.isEmpty && seen.insert(norm($0)).inserted }
    }

    // MARK: Retrieval

    func retrieve(transcript: String, history: [String]) -> RetrievedContext {
        let tokens = tokenize(transcript)
        let tokenSet = Set(tokens)

        var sections: [(label: String, items: [String])] = []

        // Facility names for this airport — always relevant (fixes misheard facility names).
        let facility = Array(kb.spokenNames(forAirport: config?.airportCode).prefix(8))
        if !facility.isEmpty { sections.append(("Facility names", facility)) }

        // Local geography from the airport config.
        if let runways = config?.runways, !runways.isEmpty {
            sections.append(("Runways", Array(runways.prefix(12))))
        }
        if let fixes = config?.fixes ?? config?.waypoints, !fixes.isEmpty {
            sections.append(("Fixes", Array(fixes.prefix(12))))
        }
        if let taxiways = config?.taxiways, !taxiways.isEmpty {
            sections.append(("Taxiways", Array(taxiways.prefix(16))))
        }

        // Callsigns actually mentioned in this transmission (the RAG retrieval proper).
        let callsigns = retrieveCallsigns(tokens: tokens)
        if !callsigns.isEmpty { sections.append(("Callsigns", callsigns)) }

        // Phraseology for the frequency type, ranked by overlap with the transcript.
        let phrases = rankPhrases(kb.phrases(forType: freqType), against: tokenSet, take: 8)
        if !phrases.isEmpty { sections.append(("Phraseology", phrases)) }

        // A few spelling hints (niner/fife/squawk/…) — cheap and always on-topic.
        let spelling = Array(kb.spellingHints(forType: freqType).prefix(6))
        if !spelling.isEmpty { sections.append(("ICAO spelling", spelling)) }

        let block = pack(sections, budget: tokenBudget)
        return RetrievedContext(block: block,
                                vocab: enrichedVocab(),
                                languageSuspect: looksNonEnglish(transcript))
    }

    // MARK: Helpers

    /// Telephony names whose words closely match a transcript token (e.g. "delta" -> "Delta",
    /// "canada" -> "Air Canada"). Capped to keep the block tight.
    private func retrieveCallsigns(tokens: [String]) -> [String] {
        // word/full-name -> display telephony, deduped by normalized key.
        var keyToName: [String: String] = [:]
        for name in kb.allTelephonyNames {
            keyToName[norm(name)] = name
            for word in name.split(separator: " ") where word.count >= 3 {
                keyToName[norm(String(word))] = name
            }
        }
        let keys = Array(keyToName.keys)
        var hits: [String] = []
        var seen = Set<String>()
        for token in tokens where token.count >= 4 {
            if let m = closestMatch(token, in: keys, cutoff: 0.78), let name = keyToName[m.term] {
                if seen.insert(name).inserted { hits.append(name) }
            }
        }
        return Array(hits.prefix(6))
    }

    /// Rank phrases by how many of their words appear in the transcript; ties keep the
    /// curated order. Always returns up to `take` (generic phrases bias toward correct
    /// phraseology even with no overlap).
    private func rankPhrases(_ phrases: [String], against tokenSet: Set<String>, take: Int) -> [String] {
        let scored = phrases.enumerated().map { (idx, phrase) -> (Int, Int, String) in
            let overlap = phrase.split(separator: " ").reduce(0) { $0 + (tokenSet.contains(norm(String($1))) ? 1 : 0) }
            return (overlap, idx, phrase)
        }
        let ordered = scored.sorted { a, b in a.0 != b.0 ? a.0 > b.0 : a.1 < b.1 }
        return ordered.prefix(take).map { $0.2 }
    }

    /// Assemble "Label: a, b, c" lines, trimming from the end once the running word count
    /// would exceed the budget.
    private func pack(_ sections: [(label: String, items: [String])], budget: Int) -> String {
        var lines: [String] = []
        var words = 0
        for section in sections {
            guard !section.items.isEmpty else { continue }
            var kept: [String] = []
            for item in section.items {
                let w = item.split(separator: " ").count
                if words + w > budget { break }
                kept.append(item); words += w
            }
            if !kept.isEmpty { lines.append("\(section.label): \(kept.joined(separator: ", "))") }
            if words >= budget { break }
        }
        return lines.joined(separator: "\n")
    }

    private func tokenize(_ text: String) -> [String] {
        text.split { $0.isWhitespace }.map { norm(String($0)) }.filter { !$0.isEmpty }
    }

    /// Lowercase + strip to `[a-z0-9]` — matches the deterministic corrector's `_norm`.
    private func norm(_ s: String) -> String {
        String(s.lowercased().filter { ("a"..."z").contains($0) || ("0"..."9").contains($0) })
    }

    /// Heuristic language guard: flags transcripts with a meaningful share of non-ASCII
    /// letters (foreign-script leakage). Conservative — Whisper is already pinned to English.
    private func looksNonEnglish(_ text: String) -> Bool {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard letters.count >= 4 else { return false }
        let nonASCII = letters.filter { !$0.isASCII }.count
        return Double(nonASCII) / Double(letters.count) > 0.2
    }
}
