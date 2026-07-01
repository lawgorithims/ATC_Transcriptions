import Foundation

/// The on-device ATC knowledge corpus — the data the RAG retriever draws on to give the
/// local correction LLM domain context. Ported from `python-legacy/airport_context/`
/// (`airlines.json`, `airport_overrides.json`, `phrases.py`/`spoken.py`) into bundled JSON
/// under `Resources/knowledge/`.
///
/// Loaded once and held immutably (`Sendable`), so it can be shared freely across the
/// transcription actor and the background refiner. Loading never throws into the pipeline:
/// a missing/unreadable resource yields an empty base and the LLM simply runs with less
/// context (the deterministic stage is unaffected).
struct ATCKnowledgeBase: Sendable {
    /// ICAO airline code -> ATC telephony name, e.g. "AAL" -> "American".
    let airlineTelephony: [String: String]
    /// Airport ident -> curated spoken facility names, e.g. "KJFK" -> ["Kennedy", "New York", …].
    let spokenNamesByAirport: [String: [String]]
    /// Airport ident -> spoken base, e.g. "KORD" -> "Chicago".
    let spokenBaseByAirport: [String: String]
    /// Frequency type ("tower", "ground", …) -> standard phraseology phrases.
    let phrasesByType: [String: [String]]
    /// Frequency type -> spelling/pronunciation hints.
    let spellingByType: [String: [String]]
    /// ICAO phonetic alphabet, "A" -> "alpha".
    let phonetic: [String: String]
    /// Aviation digit pronunciations, "9" -> "niner".
    let digits: [String: String]

    static let empty = ATCKnowledgeBase(
        airlineTelephony: [:], spokenNamesByAirport: [:], spokenBaseByAirport: [:],
        phrasesByType: [:], spellingByType: [:], phonetic: [:], digits: [:])

    /// Process-wide instance, loaded from the main bundle on first use.
    static let shared: ATCKnowledgeBase = load() ?? .empty

    /// All curated telephony names (deduped, comment-free) — the candidate pool the
    /// retriever fuzzy-matches transcript tokens against.
    var allTelephonyNames: [String] {
        Array(Set(airlineTelephony.values)).sorted()
    }

    /// All curated spoken facility names across airports (deduped).
    var allSpokenNames: [String] {
        Array(Set(spokenNamesByAirport.values.flatMap { $0 } + spokenBaseByAirport.values)).sorted()
    }

    /// The ICAO phonetic alphabet inverted to word → letter, lowercased ("alpha" -> "a"). Used by the
    /// correction validator to check that a spoken callsign actually spells a filed/known identifier
    /// before snapping onto it, so a different aircraft's similar callsign can't be misattributed.
    var phoneticWordToLetter: [String: String] {
        var m: [String: String] = [:]
        for (letter, word) in phonetic { m[word.lowercased()] = letter.lowercased() }
        return m
    }

    /// Phrases for a frequency type, falling back to the generic "unknown" set.
    func phrases(forType type: String) -> [String] {
        phrasesByType[type] ?? phrasesByType["unknown"] ?? []
    }

    /// Spelling hints for a frequency type, falling back to "unknown".
    func spellingHints(forType type: String) -> [String] {
        spellingByType[type] ?? spellingByType["unknown"] ?? []
    }

    /// Curated spoken names for an airport ident (uppercased), or an empty list.
    func spokenNames(forAirport ident: String?) -> [String] {
        guard let ident = ident?.uppercased() else { return [] }
        if let names = spokenNamesByAirport[ident], !names.isEmpty { return names }
        if let base = spokenBaseByAirport[ident] { return [base] }
        return []
    }

    // MARK: - Loading

    static func load(in bundle: Bundle = .main) -> ATCKnowledgeBase? {
        guard let airlinesData = jsonData("airlines", in: bundle),
              let overridesData = jsonData("airport_overrides", in: bundle),
              let phraseologyData = jsonData("phraseology", in: bundle) else { return nil }

        let airlines = parseStringMap(airlinesData)

        var spokenNames: [String: [String]] = [:]
        var spokenBase: [String: String] = [:]
        if let overrides = (try? JSONSerialization.jsonObject(with: overridesData)) as? [String: Any] {
            for (key, value) in overrides where !key.hasPrefix("_") {
                guard let entry = value as? [String: Any] else { continue }
                if let names = entry["spoken_names"] as? [String] { spokenNames[key.uppercased()] = names }
                if let base = entry["spoken_base"] as? String { spokenBase[key.uppercased()] = base }
            }
        }

        var phrases: [String: [String]] = [:]
        var spelling: [String: [String]] = [:]
        var phonetic: [String: String] = [:]
        var digits: [String: String] = [:]
        if let root = (try? JSONSerialization.jsonObject(with: phraseologyData)) as? [String: Any] {
            phrases = (root["phrases"] as? [String: [String]]) ?? [:]
            spelling = (root["spelling"] as? [String: [String]]) ?? [:]
            phonetic = (root["phonetic"] as? [String: String]) ?? [:]
            digits = (root["digits"] as? [String: String]) ?? [:]
        }

        return ATCKnowledgeBase(
            airlineTelephony: airlines,
            spokenNamesByAirport: spokenNames,
            spokenBaseByAirport: spokenBase,
            phrasesByType: phrases,
            spellingByType: spelling,
            phonetic: phonetic,
            digits: digits)
    }

    /// Read a `knowledge/<name>.json` resource. The folder ships as a `type: folder`
    /// reference (so the `knowledge/` subdirectory survives in the bundle); we still fall
    /// back to a flat lookup in case it was added as a plain group.
    private static func jsonData(_ name: String, in bundle: Bundle) -> Data? {
        if let url = bundle.url(forResource: name, withExtension: "json", subdirectory: "knowledge") {
            return try? Data(contentsOf: url)
        }
        if let url = bundle.url(forResource: name, withExtension: "json") {
            return try? Data(contentsOf: url)
        }
        return nil
    }

    /// Decode a flat `{String: String}` map, dropping `_comment`-style metadata keys.
    private static func parseStringMap(_ data: Data) -> [String: String] {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        var out: [String: String] = [:]
        for (key, value) in obj where !key.hasPrefix("_") {
            if let s = value as? String { out[key] = s }
        }
        return out
    }
}

/// Map an airport feed/stream key (e.g. "lone_star_approach_17c_final", "tower_east",
/// "clearance_delivery") to a frequency type, so the retriever can pull the right
/// phraseology set. Keyword-matched, mirroring the resolver in the Python `airport_context`.
func frequencyType(forFeedKey key: String?) -> String {
    guard let key = key?.lowercased() else { return "unknown" }
    // Order matters: check the more specific labels first.
    if key.contains("clearance") || key.contains("delivery") || key.contains("cd") { return "clearance" }
    if key.contains("ground") || key.contains("gnd") { return "ground" }
    if key.contains("ctaf") || key.contains("unicom") || key.contains("multicom") { return "ctaf" }
    if key.contains("center") || key.contains("centre") || key.contains("artcc") || key.contains("ztl") { return "center" }
    if key.contains("departure") || key.contains("dep") { return "departure" }
    if key.contains("approach") || key.contains("app") || key.contains("final") || key.contains("tracon") { return "approach" }
    if key.contains("tower") || key.contains("twr") || key.contains("local") { return "tower" }
    return "unknown"
}
