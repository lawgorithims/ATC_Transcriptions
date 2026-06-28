import Foundation

/// Extracts the aircraft callsign a transmission is about, as a STABLE canonical form so the same
/// aircraft groups across transmissions — which lets the transcript be filtered to one aircraft's
/// conversation, and lets a callsign be cross-referenced with the live ADS-B feed.
///
/// Heuristic + on-device (no nav DB), reusing the airline telephony table and the ICAO phonetic
/// table. Two forms it recognizes:
///   * **airline** — a telephony name + a flight number → `display "American 1234"`, `icaoKey "AAL1234"`.
///   * **GA tail** — "november" + spelled digits/letters (or a literal N-number) → `"N345AB"`.
/// Numbers are normalized first; because `normalizeNumbers` can SPLIT an ambiguous run into several
/// digit fields ("fifty six six eighteen" → "56 6 18"), the airline matcher greedily re-fuses all
/// consecutive digit tokens into one flight number so the same aircraft always yields one key.
enum CallsignExtractor {
    struct Callsign: Equatable {
        /// Human-readable canonical — the grouping/filter key and the chip text.
        let display: String
        /// Normalized matching form for the ADS-B feed (`flight` codes / registrations).
        let icaoKey: String
    }

    /// Instruction/readback words that follow the ADDRESSED aircraft's callsign — used to pick the
    /// right callsign over a leading traffic-advisory callsign ("traffic delta 890, southwest 1234
    /// cleared to land" → Southwest 1234).
    private static let directives: Set<String> = [
        "cleared", "contact", "turn", "climb", "descend", "maintain", "hold", "cross", "fly",
        "expect", "squawk", "taxi", "runway", "reduce", "increase", "proceed", "join", "report",
        "ident", "resume", "traffic", "caution", "wind", "lineup", "depart", "vacate",
    ]

    static func extract(_ text: String, knowledge: ATCKnowledgeBase) -> Callsign? {
        let normalized = normalizeNumbers(text).text
        let norm = normalized.split(whereSeparator: { $0.isWhitespace })
            .map { tok in String(tok.lowercased().filter { $0.isLetter || $0.isNumber }) }
            .filter { !$0.isEmpty }
        guard !norm.isEmpty else { return nil }
        return matchAirline(norm: norm, knowledge: knowledge) ?? matchGA(norm: norm, knowledge: knowledge)
    }

    // MARK: airline ("American 1234")

    private static func matchAirline(norm: [String], knowledge: ATCKnowledgeBase) -> Callsign? {
        var nameMap: [String: (display: String, icao: String)] = [:]
        for (icao, name) in knowledge.airlineTelephony {
            let key = normKey(name)
            if !key.isEmpty, nameMap[key] == nil { nameMap[key] = (name, icao) }
        }
        let n = norm.count
        var first: Callsign?
        var i = 0
        while i < n {
            var advanced = false
            for w in stride(from: min(3, n - i), through: 1, by: -1) {
                guard let entry = nameMap[norm[i..<(i + w)].joined()] else { continue }
                // Greedily fuse consecutive all-digit tokens — `normalizeNumbers` may split a run.
                var k = i + w
                var digits = ""
                while k < n, isDigits(norm[k]) { digits += norm[k]; k += 1 }
                // Need a real flight number: ≥2 digits rejects English-word telephony collisions
                // ("climb easy three thousand" → "easy 3" is not a callsign).
                guard digits.count >= 2 else { continue }
                let cs = Callsign(display: "\(entry.display) \(digits)",
                                  icaoKey: "\(entry.icao.uppercased())\(digits)")
                if first == nil { first = cs }
                // The addressed aircraft's callsign is immediately followed by an instruction word.
                if k < n, directives.contains(norm[k]) { return cs }
                i = k; advanced = true
                break
            }
            if !advanced { i += 1 }
        }
        return first
    }

    // MARK: GA tail ("N345AB")

    private static func matchGA(norm: [String], knowledge: ATCKnowledgeBase) -> Callsign? {
        // A literal N-number the speech model already produced. US registrations: N, a leading digit,
        // then digits/letters excluding I and O. Spelled form (below) is preferred when both match.
        if let spelled = matchSpelledGA(norm: norm, knowledge: knowledge) { return spelled }
        for t in norm {
            let up = t.uppercased()
            if up.range(of: "^N[1-9][0-9A-HJ-NP-Z]{1,4}$", options: .regularExpression) != nil {
                return Callsign(display: up, icaoKey: up)
            }
        }
        return nil
    }

    private static func matchSpelledGA(norm: [String], knowledge: ATCKnowledgeBase) -> Callsign? {
        var letterMap: [String: String] = [:]   // "alpha" -> "A", "november" -> "N", …
        for (letter, word) in knowledge.phonetic { letterMap[word.lowercased()] = letter.uppercased() }
        guard let start = norm.firstIndex(of: "november") else { return nil }
        var out = ""
        var hasLetter = false
        var digitCount = 0
        var k = start
        while k < norm.count {
            let t = norm[k]
            if isDigits(t) { out += t; if k > start { digitCount += t.count } }
            else if let letter = letterMap[t] { out += letter; if k > start { hasLetter = true } }
            else { break }
            k += 1
        }
        // Plausible US tail: N + a leading DIGIT, and either a spelled letter or ≥3 digits — so a
        // bare "november five seven" doesn't fabricate "N57".
        guard out.hasPrefix("N"), out.count >= 3,
              out.dropFirst().first?.isNumber == true,
              hasLetter || digitCount >= 3 else { return nil }
        return Callsign(display: out, icaoKey: out)
    }

    // MARK: helpers

    private static func isDigits(_ s: String) -> Bool { !s.isEmpty && s.allSatisfy(\.isNumber) }
    private static func normKey(_ s: String) -> String {
        String(s.lowercased().filter { $0.isLetter || $0.isNumber })
    }
}
