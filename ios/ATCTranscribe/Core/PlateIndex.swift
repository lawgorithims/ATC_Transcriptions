import Foundation

/// Bundled per-airport PLATE INDEX (`nav/plate_index.json`, distilled from the offline OCR corpus by
/// `Tools/build_plate_index.py`): the frequencies, fix idents, and courses printed on an airport's
/// terminal-procedure plates. Injected into the ATC speech/LLM context when a flight plan is filed, so
/// transcription + correction are primed to what's on the route's charts (the reason the OCR harvest
/// kept every text box). Load-once, like `Procedures`/`NavMeta`.
enum PlateIndex {
    struct Entry { let freqs: [String]; let fixes: [String]; let courses: [String] }

    private struct DTO: Decodable {
        let cycle: String
        let airports: [String: Raw]
        struct Raw: Decodable { let f: [String]; let x: [String]; let c: [String] }
    }
    private static let data: DTO = load()

    static var cycle: String { data.cycle }
    static var count: Int { data.airports.count }

    static func lookup(_ icao: String) -> Entry? {
        let key = icao.trimmingCharacters(in: .whitespaces).uppercased()
        guard let r = data.airports[key] else { return nil }
        return Entry(freqs: r.f, fixes: r.x, courses: r.c)
    }

    /// Build the priming payload for a set of route airports:
    ///  - `promptLine`: a small chart-fixes line that biases the Whisper DECODE toward names on the
    ///    route's plates. Capped to 12 (parity with the vicinity decode-bias line) so an always-on line
    ///    can't consume a third of the ~220-token prompt or over-bias toward fixes not on frequency.
    ///  - `block`: an INFORMATIONAL LLM line naming the route's chart frequencies + fixes.
    /// No snap-vocab is returned: the fix set is large, route-wide, OCR-derived and word-colliding, so
    /// feeding it to the corrector's allow-set would widen the false-positive surface (see ATCContext).
    /// Empty when nothing is known for the route.
    static func priming(for airports: [String]) -> (promptLine: String, block: String) {
        assert(airports.count < 256, "priming: unbounded airport list")
        var freqs = Set<String>(), fixes = Set<String>()
        var named: [String] = []
        for icao in airports.prefix(8) {           // bound: a filed route has a handful of airports
            guard let e = lookup(icao) else { continue }
            named.append(icao)
            freqs.formUnion(e.freqs)
            fixes.formUnion(e.fixes)
        }
        guard !named.isEmpty, !(freqs.isEmpty && fixes.isEmpty) else { return ("", "") }
        let biasFixes = fixes.sorted().prefix(12)   // decode-bias, capped for the prompt budget
        let freqList = freqs.sorted().prefix(24)
        let blockFixes = fixes.sorted().prefix(32)
        let promptLine = biasFixes.isEmpty ? "" : "Chart fixes: " + biasFixes.joined(separator: ", ") + "."
        var parts = ["Charts for \(named.joined(separator: ", ")):"]
        if !freqList.isEmpty { parts.append("frequencies " + freqList.joined(separator: ", ")) }
        if !blockFixes.isEmpty { parts.append("fixes " + blockFixes.joined(separator: ", ")) }
        let block = parts.joined(separator: " ") + "."
        return (promptLine, block)
    }

    private static func load() -> DTO {
        let url = Bundle.main.url(forResource: "plate_index", withExtension: "json", subdirectory: "nav")
            ?? Bundle.main.url(forResource: "plate_index", withExtension: "json")
        guard let url, let d = try? Data(contentsOf: url),
              let dto = try? JSONDecoder().decode(DTO.self, from: d)
        else { return DTO(cycle: "", airports: [:]) }
        return dto
    }
}
