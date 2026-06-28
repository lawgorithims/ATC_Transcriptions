import Foundation

/// Extracts the aircraft callsign a transmission is about, as a STABLE canonical form so the same
/// aircraft groups across transmissions — which lets the transcript be filtered to one aircraft's
/// conversation, and lets a callsign be cross-referenced with the live ADS-B feed.
///
/// Heuristic + on-device (no nav DB), reusing the airline telephony table and the ICAO phonetic
/// table. Two forms it recognizes:
///   * **airline** — a telephony name followed by a flight number → `display "American 1234"`,
///     `icaoKey "AAL1234"`.
///   * **GA tail** — "november" + spelled digits/letters (or a literal N-number) → `"N345AB"`.
/// Numbers are normalized first (`normalizeNumbers`), so it works whether or not the inline
/// corrector already turned "twelve thirty four" into "1234".
enum CallsignExtractor {
    struct Callsign: Equatable {
        /// Human-readable canonical — the grouping/filter key and the chip text.
        let display: String
        /// Normalized matching form for the ADS-B feed (`flight` codes / registrations).
        let icaoKey: String
    }

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
        // normalized full telephony name -> (display name, ICAO code)
        var nameMap: [String: (display: String, icao: String)] = [:]
        for (icao, name) in knowledge.airlineTelephony {
            let key = normKey(name)
            if !key.isEmpty, nameMap[key] == nil { nameMap[key] = (name, icao) }
        }
        let n = norm.count
        for i in 0..<n {
            // Try a 1…3-word telephony name starting at i (longest first), then a flight-number token.
            for w in stride(from: min(3, n - i), through: 1, by: -1) {
                let key = norm[i..<(i + w)].joined()
                guard let entry = nameMap[key] else { continue }
                let j = i + w
                guard j < n, isDigits(norm[j]) else { continue }
                let digits = norm[j]
                return Callsign(display: "\(entry.display) \(digits)", icaoKey: "\(entry.icao.uppercased())\(digits)")
            }
        }
        return nil
    }

    // MARK: GA tail ("N345AB")

    private static func matchGA(norm: [String], knowledge: ATCKnowledgeBase) -> Callsign? {
        // A literal N-number token the speech model already produced (e.g. "N345AB").
        for t in norm {
            let up = t.uppercased()
            if up.range(of: "^N[0-9][0-9A-Z]{1,5}$", options: .regularExpression) != nil {
                return Callsign(display: up, icaoKey: up)
            }
        }
        // Spelled out: "november three four five alpha bravo" → N345AB.
        var letterMap: [String: String] = [:]   // "alpha" -> "A", "november" -> "N", …
        for (letter, word) in knowledge.phonetic { letterMap[word.lowercased()] = letter.uppercased() }
        guard let start = norm.firstIndex(of: "november") else { return nil }
        var out = ""
        var k = start
        while k < norm.count {
            let t = norm[k]
            if isDigits(t) { out += t }
            else if let letter = letterMap[t] { out += letter }
            else { break }
            k += 1
        }
        guard out.hasPrefix("N"), out.count >= 3 else { return nil }   // N + at least 2 → a plausible tail
        return Callsign(display: out, icaoKey: out)
    }

    // MARK: helpers

    private static func isDigits(_ s: String) -> Bool { !s.isEmpty && s.allSatisfy(\.isNumber) }
    private static func normKey(_ s: String) -> String {
        String(s.lowercased().filter { $0.isLetter || $0.isNumber })
    }
}
