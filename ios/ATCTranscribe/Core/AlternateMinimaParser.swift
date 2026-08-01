import Foundation

/// Reads one airport's block out of an IFR ALTERNATE MINIMUMS booklet.
///
/// ⚠️ A DIFFERENT PARSER FROM THE APPROACH MINIMA, not a variation of it. `PlateMinimaParser` needs a
/// `CATEGORY` header and at least two A–E column centres to anchor its grid, and an alternate-minimums
/// page has neither — it is a two-column list of prose, not a table. What DOES transfer is `PlateText`'s
/// positioned extraction and `MinimaValueParser`'s reading of a ceiling-visibility pair.
///
/// The booklets are SHARED: 27 of them cover 2,052 airports, median 71 airports each and up to 145. So
/// the parse is always "find this airport inside a large document", never "read this airport's page".
enum AlternateMinimaParser {

    /// Bounded so a malformed document cannot spin. A booklet block is a handful of lines.
    static let maxLinesPerAirport = 40
    static let maxEntries = 24
    static let maxFootnotes = 12

    /// Parse `ident`'s block out of the booklet's text.
    ///
    /// `publishedRunways` is REQUIRED and is the whole reason this can be done correctly — see `split`.
    /// Returns nil when the airport is not listed, which is the normal case and means STANDARD alternate
    /// minima apply, not that anything failed.
    static func parse(text: String, ident: String,
                      publishedRunways: [String]) -> AlternateMinima? {
        let lines = text.components(separatedBy: .newlines)
        guard let start = blockStart(lines, ident: ident) else { return nil }

        var entries: [AlternateMinima.Entry] = []
        var footnotes: [Int: String] = [:]
        var pendingFootnote: Int?

        for raw in lines[start...].prefix(maxLinesPerAirport) {              // bounded (rule 2)
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            // A bare number on its own line is a footnote MARKER; its text is the next line. The
            // extractor emits superscripts this way because they sit on their own baseline.
            if let n = Int(line), n > 0, n <= maxFootnotes {
                pendingFootnote = n
                continue
            }
            if let n = pendingFootnote {
                footnotes[n] = line
                pendingFootnote = nil
                continue
            }
            // ⚠️ AN APPROACH LINE IS TRIED FIRST. The boundary test looks for a "(IDENT)" parenthetical,
            // and an approach name carries one too — "RNAV (GPS) Rwy 4" — so checking the boundary
            // first ended every block after its first entry.
            if let e = entry(from: line, publishedRunways: publishedRunways), entries.count < maxEntries {
                entries.append(e)
                continue
            }
            // Another airport's block began — stop. A city header (ends ", XX") or a new "(IDENT)".
            if entries.count > 0, isBlockBoundary(line, ident: ident) { break }
            // An unnumbered condition line ("NA when local weather not available." with no marker)
            // applies to the whole airport. Keyed 0, which no printed marker uses.
            if isConditionLine(line) {
                footnotes[0] = footnotes[0].map { $0 + " " + line } ?? line
                for i in entries.indices where !entries[i].footnoteIDs.contains(0) {
                    entries[i] = AlternateMinima.Entry(name: entries[i].name, runway: entries[i].runway,
                                                       footnoteIDs: entries[i].footnoteIDs + [0])
                }
            }
        }
        guard !entries.isEmpty else { return nil }
        assert(entries.count <= maxEntries, "alternate minima: entry cap")
        return AlternateMinima(airport: ident.uppercased(), entries: entries, footnotes: footnotes)
    }

    /// The line index where `ident`'s block starts — the line carrying "(IDENT)".
    private static func blockStart(_ lines: [String], ident: String) -> Int? {
        let key = "(" + ident.trimmingCharacters(in: .whitespaces).uppercased() + ")"
        // The booklet keys by the BARE FAA code, never the ICAO one: "(LEW)", not "(KLEW)".
        let bare = "(" + AirportKey.forms(ident).alternate + ")"
        return lines.firstIndex { $0.uppercased().contains(key) || $0.uppercased().contains(bare) }
    }

    private static func isBlockBoundary(_ line: String, ident: String) -> Bool {
        let u = line.uppercased()
        // An approach TYPE qualifier is not an airport identifier, even though both are parenthesised.
        let qualifiers = ["(GPS)", "(RNP)", "(RNAV)", "(PRM)", "(SA)", "(CAT"]
        if qualifiers.contains(where: { u.contains($0) }) { return false }
        if u.range(of: "\\([A-Z0-9]{3,4}\\)", options: .regularExpression) != nil { return true }
        // "AUGUSTA, ME" — a city header.
        return u.range(of: ", [A-Z]{2}$", options: .regularExpression) != nil
    }

    private static func isConditionLine(_ line: String) -> Bool {
        let u = line.uppercased()
        return u.contains("NA WHEN") || u.hasPrefix("NA ") || u.contains("NOT AUTHORIZED")
            || (u.contains("CAT ") && u.range(of: "[0-9]{3,4}-", options: .regularExpression) != nil)
    }

    /// One approach line → an entry, or nil when the line is not one.
    private static func entry(from line: String, publishedRunways: [String]) -> AlternateMinima.Entry? {
        // The name runs to "Rwy"; everything after is the runway plus any footnote markers. Leader dots
        // and the airport name precede it on the first line of a block.
        guard let r = line.range(of: "RWY", options: [.caseInsensitive]) else { return nil }
        let head = String(line[..<r.lowerBound])
        let tail = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        let (runway, marks) = split(tail, publishedRunways: publishedRunways)
        guard !runway.isEmpty else { return nil }
        // Strip the leader dots and any airport name preceding the approach type.
        let name = cleanedName(head) + " Rwy " + runway
        return AlternateMinima.Entry(name: name, runway: runway, footnoteIDs: marks)
    }

    /// ⚠️ THE CENTRAL PROBLEM. Superscript footnote markers CONCATENATE onto the runway number, and the
    /// split is genuinely ambiguous from the string alone: "413" is Rwy 4 with footnotes 1 and 3 at an
    /// airport with a runway 4, and Rwy 41 with footnote 3 at an airport with a runway 41. Reading it
    /// greedily either way is wrong somewhere.
    ///
    /// It is resolvable because the app knows which runways the airport actually has. Try the LONGEST
    /// published designator that prefixes the string; the remainder is the marker list. This is the same
    /// shape as the typeset-fraction problem in the approach-minima parser — the characters do not carry
    /// the boundary, so the boundary comes from a closed set that does.
    ///
    /// Falls back to a bare leading number when no published runway matches (a runway withdrawn since
    /// the booklet was printed), because an entry with an unmatched runway is still a published entry.
    static func split(_ s: String, publishedRunways: [String]) -> (runway: String, marks: [Int]) {
        let t = s.uppercased().trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return ("", []) }
        // Longest first so "22" wins over "2" at an airport with both.
        let candidates = publishedRunways
            .map { $0.uppercased().replacingOccurrences(of: "RW", with: "") }
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }
        for rw in candidates.prefix(64) where t.hasPrefix(rw) {              // bounded (rule 2)
            return (rw, marks(String(t.dropFirst(rw.count))))
        }
        // No match — take the leading digits and an optional side letter.
        guard let m = t.range(of: "^[0-9]{1,2}[LCR]?", options: .regularExpression) else { return ("", []) }
        return (String(t[m]), marks(String(t[m.upperBound...])))
    }

    /// The trailing digits, each ONE footnote marker. Markers are single digits — a booklet does not
    /// print a footnote 10 in superscript beside a runway — so "13" is markers 1 and 3, not marker 13.
    private static func marks(_ s: String) -> [Int] {
        var out: [Int] = []
        for ch in s.prefix(maxFootnotes) {                                   // bounded (rule 2)
            guard let d = ch.wholeNumberValue, d > 0 else { continue }
            out.append(d)
        }
        assert(out.count <= maxFootnotes, "alternate minima: marker cap")
        return out
    }

    /// Strip leader dots, the airport name and stray punctuation, leaving the approach type.
    private static func cleanedName(_ head: String) -> String {
        var s = head
        // The FAA uses a run of leader dots (and ellipsis characters) between name and approach.
        if let r = s.range(of: "[.…]{2,}", options: [.regularExpression, .backwards]) {
            s = String(s[r.upperBound...])
        }
        return s.trimmingCharacters(in: CharacterSet(charactersIn: " .…\u{00A0}"))
    }
}
