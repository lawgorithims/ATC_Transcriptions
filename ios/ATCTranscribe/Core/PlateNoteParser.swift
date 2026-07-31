import Foundation

/// Reads the plate's NOTES for the things that change the numbers.
///
/// Three of the adjustments a pilot has to apply by hand are printed as prose in the notes box, not as
/// rows in the table: the penalty for a remote altimeter setting, the temperature window outside which
/// Baro-VNAV is not authorised, and the night restrictions. All three are PARSED rather than assumed —
/// the temperature limit in particular is computed per procedure by the FAA and differs plate to plate,
/// so a hardcoded −15 °C would be quietly wrong wherever the chart says otherwise.
///
/// Notes wrap freely across the box, so matching runs over the page's text joined into one string. That
/// is safe here because each pattern is anchored on a long, specific phrase the FAA uses verbatim.
enum PlateNoteParser {

    /// Cap on rows joined for note matching (rule 2).
    static let maxRows = 400

    static func notes(words: [PlateWord]) -> [PlateNote] {
        let rows = PlateText.rows(words, tolerance: PlateMinimaParser.rowTolerance)
        var joined = ""
        for row in rows.prefix(maxRows) { joined += PlateText.line(row) + " " }   // bounded (rule 2)
        return notes(inText: joined)
    }

    /// Pure over the joined page text — the unit under test.
    static func notes(inText raw: String) -> [PlateNote] {
        let text = raw
            .replacingOccurrences(of: "\u{2010}", with: "-")
            .replacingOccurrences(of: "\u{2013}", with: "-")
            .replacingOccurrences(of: "\u{2212}", with: "-")      // MINUS SIGN — the FAA typesets −15°C with it
            .replacingOccurrences(of: "  ", with: " ")
        var out: [PlateNote] = []
        if let n = altimeterPenalty(text) { out.append(n) }
        if let n = baroVNAVTemperature(text) { out.append(n) }
        out.append(contentsOf: nightRestrictions(text))
        return out
    }

    // MARK: altimeter

    /// `When local altimeter setting not received, use Providence altimeter setting and increase all
    /// MDA 80 feet.` The penalty is always an INCREASE in feet; a match that cannot find the number is
    /// dropped rather than defaulted, because a default here is an invented minimum.
    static func altimeterPenalty(_ text: String) -> PlateNote? {
        let pattern = #"(?i)when\s+local\s+altimeter\s+setting\s+not\s+received[,\s]+use\s+([A-Za-z .'\-]{2,40}?)\s+altimeter\s+setting(?:[^.]{0,120}?)increase\s+all\s+(?:DA/MDA|MDA|DA|MINIMA|MINIMUMS)\s+(\d{2,3})\s*(?:feet|ft)"#
        guard let m = firstMatch(pattern, in: text), m.count >= 3,
              let add = Int(m[2]), add > 0, add <= 1_000 else { return nil }
        let source = m[1].trimmingCharacters(in: .whitespaces)
        let sentence = m[0].trimmingCharacters(in: .whitespaces)
        return PlateNote(text: sentence, effect: .altimeterPenalty(addFt: add, source: source))
    }

    // MARK: Baro-VNAV temperature window

    /// `For uncompensated Baro-VNAV systems, LNAV/VNAV NA below -15°C (5°F) or above 47°C (117°F).`
    ///
    /// This is item 24. The limit is a real airworthiness restriction on the *aircraft's* uncompensated
    /// Baro-VNAV, not on the procedure, and it exists because a cold day makes the true altitude of a
    /// barometric path lower than the indicated one — exactly the direction that matters near the ground.
    static func baroVNAVTemperature(_ text: String) -> PlateNote? {
        let pattern = #"(?i)(?:uncompensated\s+)?Baro-?VNAV[^.]{0,80}?NA\s+below\s+(-?\d{1,2})\s*°?\s*C(?:[^.]{0,60}?above\s+(\d{1,2})\s*°?\s*C)?"#
        if let m = firstMatch(pattern, in: text), m.count >= 2, let lo = Int(m[1]) {
            let hi = m.count >= 3 ? Int(m[2]) : nil
            return PlateNote(text: m[0].trimmingCharacters(in: .whitespaces),
                             effect: .baroVNAVTemperatureLimit(minC: lo, maxC: hi))
        }
        // Some plates word it the other way round: "LNAV/VNAV NA below -20°C (-4°F)."
        let alt = #"(?i)LNAV/\s?VNAV\s+NA\s+below\s+(-?\d{1,2})\s*°?\s*C"#
        if let m = firstMatch(alt, in: text), m.count >= 2, let lo = Int(m[1]) {
            return PlateNote(text: m[0].trimmingCharacters(in: .whitespaces),
                             effect: .baroVNAVTemperatureLimit(minC: lo, maxC: nil))
        }
        return nil
    }

    // MARK: night

    static func nightRestrictions(_ text: String) -> [PlateNote] {
        let pattern = #"(?i)(Circling|Procedure|Straight-in)\s+NA\s+at\s+night(?:\s+(?:to|for)\s+[A-Za-z0-9 ,]{1,40})?"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        var out: [PlateNote] = []
        var seen = Set<String>()
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)).prefix(8) {
            let s = ns.substring(with: m.range).trimmingCharacters(in: .whitespaces)
            guard seen.insert(s.uppercased()).inserted else { continue }
            out.append(PlateNote(text: s, effect: .nightRestriction(s)))
        }
        return out
    }

    // MARK: helper

    /// Capture groups of the first match, index 0 being the whole match. Empty groups become "".
    static func firstMatch(_ pattern: String, in text: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        var out: [String] = []
        for i in 0..<m.numberOfRanges {                           // bounded by the pattern (rule 2)
            let r = m.range(at: i)
            out.append(r.location == NSNotFound ? "" : ns.substring(with: r))
        }
        return out
    }
}
