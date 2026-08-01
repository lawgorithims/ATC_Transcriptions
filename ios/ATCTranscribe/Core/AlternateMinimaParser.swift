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
            // ⚠️ THE BOUNDARY IS TESTED BEFORE THE ENTRY, AND IT MUST BE. A city block holds SEVERAL
            // airports — "DETROIT, MI" lists COLEMAN A YOUNG MUNI (DET) and then WILLOW RUN (YIP) — and
            // the next airport's FIRST line is both a boundary and a valid entry: "WILLOW RUN
            // (YIP)…….ILS or LOC Rwy 5". Trying the entry first consumed it, so DET absorbed Willow
            // Run's approaches and reported runways 5, 9 and 23 that Coleman A Young does not have.
            // Measured across the cycle's 27 booklets: 665 entries at 2,051 airports carried a runway
            // their own field does not publish.
            //
            // Testing the boundary first is only safe because it now knows whose block this is: the
            // block's OWN opening line carries its own "(IDENT)" and must not end it.
            if isBlockBoundary(line, ident: ident) { break }
            if let e = entry(from: line, publishedRunways: publishedRunways), entries.count < maxEntries {
                entries.append(e)
                continue
            }
            // ⚠️ THE REAL BOOKLETS PUT THE MARKER INLINE. PDFKit keeps a superscript on the same
            // baseline as its text, so a footnote arrives as "1LOC Cat C 800-2½, Cat D 900-2¾." — one
            // line, not the marker-then-text pair handled above. Handling only the split form read zero
            // footnotes out of the cycle's 27 booklets, and the footnote IS the answer to "why is this
            // approach restricted". Tried after the entry so a real approach line can never be eaten.
            if let (n, body) = inlineFootnote(line) {
                footnotes[n] = footnotes[n].map { $0 + " " + body } ?? body
                continue
            }
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
    ///
    /// ⚠️ THE PREAMBLE CAN CONTAIN THE IDENTIFIER. Every booklet opens with a paragraph naming the
    /// approach types, including "RNAV (RNP)" — and Owosso's identifier IS RNP, so the first match was
    /// prose on page 1 and the airport read as unlisted. A real block line carries the FAA's run of
    /// leader dots between the airport name and its first approach, so that is preferred when present;
    /// the first match is still the fallback for a booklet that sets its leaders differently.
    private static func blockStart(_ lines: [String], ident: String) -> Int? {
        let key = "(" + ident.trimmingCharacters(in: .whitespaces).uppercased() + ")"
        // The booklet keys by the BARE FAA code, never the ICAO one: "(LEW)", not "(KLEW)".
        let bare = "(" + AirportKey.forms(ident).alternate + ")"
        var first: Int?
        for (i, l) in lines.enumerated().prefix(20_000) {                    // bounded (rule 2)
            let u = l.uppercased()
            guard u.contains(key) || u.contains(bare) else { continue }
            if first == nil { first = i }
            if l.range(of: "[.…]{2,}", options: .regularExpression) != nil { return i }
        }
        return first
    }

    static func isBlockBoundary(_ line: String, ident: String) -> Bool {
        let u = line.uppercased()
        // ⚠️ THIS AIRPORT'S OWN PARENTHETICAL IS NOT A BOUNDARY. The block OPENS on the line carrying
        // "(DET)", so without this the block ends on the very line it starts and every airport parses
        // as empty. Both keying forms are excluded because the booklet prints the bare FAA code while
        // the app may hold the ICAO one.
        let forms = AirportKey.forms(ident)
        let mine = ["(" + forms.asGiven.uppercased() + ")", "(" + forms.alternate.uppercased() + ")"]
        if mine.contains(where: { u.contains($0) }) { return false }
        // An approach TYPE qualifier is not an airport identifier, even though both are parenthesised.
        //
        // ⚠️ A LINE CAN CARRY BOTH. "FLD (ANJ)……….RNAV (GPS) Rwy 14" opens a new airport AND names an
        // approach type, so rejecting the whole line whenever a qualifier appears anywhere in it missed
        // every boundary whose first entry is an RNAV approach — the common case. Each parenthetical is
        // judged on its own; a boundary needs one that is not a qualifier.
        let qualifiers: Set<String> = ["GPS", "RNAV", "RNP", "PRM", "SA", "CAT"]
        if let re = try? NSRegularExpression(pattern: "\\(([A-Z0-9]{2,4})\\)") {
            let ns = u as NSString
            for m in re.matches(in: u, range: NSRange(location: 0, length: ns.length)).prefix(16) {
                let code = ns.substring(with: m.range(at: 1))
                guard !qualifiers.contains(code), code.count >= 3 else { continue }
                return true                                              // bounded (rule 2)
            }
        }
        // "AUGUSTA, ME" — a city header.
        return u.range(of: ", [A-Z]{2}$", options: .regularExpression) != nil
    }

    /// A footnote whose superscript marker sits at the head of its own text — "1LOC Cat C 800-2½".
    ///
    /// ⚠️ AN AIRPORT IDENTIFIER LOOKS THE SAME AT THE FIRST TWO CHARACTERS. "9G3 SOMEWHERE MUNI" also
    /// begins digit-then-letter, so the marker is only accepted when the remainder reads like footnote
    /// PROSE: it carries a lowercase letter, opens with NA, or states a ceiling-visibility pair. Booklet
    /// names are set in full capitals, so the lowercase test separates them cleanly.
    static func inlineFootnote(_ line: String) -> (id: Int, text: String)? {
        var chars = Array(line.prefix(240))                                  // bounded (rule 2)
        guard let first = chars.first, let n = first.wholeNumberValue,
              n > 0, n <= maxFootnotes, chars.count > 4 else { return nil }
        chars.removeFirst()
        guard let second = chars.first, !second.isNumber else { return nil }
        let body = String(chars).trimmingCharacters(in: .whitespaces)
        let looksLikeProse = body.contains(where: { $0.isLowercase })
            || body.uppercased().hasPrefix("NA")
            || body.range(of: "[0-9]{3,4}-", options: .regularExpression) != nil
        guard looksLikeProse else { return nil }
        assert(n <= maxFootnotes, "alternate minima: inline marker out of range")
        return (n, body)
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
        // A circling-only approach names a LETTER, not a runway — "RNAV (GPS)-B", "VOR-A" — and is a
        // published entry like any other. Recognising it also stops the block walking into the next
        // airport looking for a "Rwy" that will never come.
        guard let r = line.range(of: "RWY", options: [.caseInsensitive]) else {
            return runwayLessEntry(from: line)
        }
        let head = String(line[..<r.lowerBound])
        let tail = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        let (runway, marks) = split(tail, publishedRunways: publishedRunways)
        guard !runway.isEmpty else { return nil }        // a "Rwy" line with no readable number
        // Strip the leader dots and any airport name preceding the approach type.
        let name = cleanedName(head) + " Rwy " + runway
        return AlternateMinima.Entry(name: name, runway: runway, footnoteIDs: marks)
    }

    /// An approach that serves no single runway: a CIRCLING approach named by letter ("RNAV (GPS)-B",
    /// "VOR-A") or a RADAR approach named by number ("RADAR-1"). Both are published entries.
    ///
    /// ⚠️ THE FOOTNOTE MARKER GLUES ON HERE TOO, and anchoring the letter to end-of-line missed it:
    /// North Adams publishes only "RNAV (GPS)-A1" and "RNAV (GPS)-B2", so BOTH its entries were
    /// unrecognised and the airport parsed as having no alternate minima at all — the failure looks
    /// exactly like "standard minima apply", which is the opposite of what the booklet says. Youngstown
    /// (RADAR-1 only) failed the same way. 11 airports in the cycle had no readable entry; these two
    /// forms were 8 of them.
    private static func runwayLessEntry(from line: String) -> AlternateMinima.Entry? {
        let u = line.uppercased()
        guard u.range(of: "\\(GPS\\)|\\(RNAV\\)|VOR|NDB|LOC|ILS|LDA|SDF|TACAN|RADAR",
                      options: .regularExpression) != nil else { return nil }
        // "-A" / "-B" is the circling letter; "RADAR-1" names the radar approach. Anything after is a
        // run of footnote markers.
        let patterns = ["-[A-Z][0-9]*$", "RADAR-[0-9][0-9]*$"]
        for p in patterns {                                                  // bounded (rule 2)
            guard let m = u.range(of: p, options: .regularExpression) else { continue }
            let tail = String(u[m])
            // Keep the designator (letter, or the radar number) with the name; the rest are markers.
            let keep = p.hasPrefix("RADAR") ? tail.prefix(7) : tail.prefix(2)
            let name = cleanedName(String(u[..<m.lowerBound])) + String(keep)
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            return AlternateMinima.Entry(name: trimmed, runway: "",
                                         footnoteIDs: marks(String(tail.dropFirst(keep.count))))
        }
        return nil
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
        // ⚠️ BOTH SIDES UNPADDED. CIFP designators are zero-padded ("RW08") and the booklet prints
        // "Rwy 8" — so hasPrefix("08") failed and the fallback regex took "81" from "8" plus its
        // footnote digit. Measured: 790 entries at 438 airports (21.4%) got a runway number with a
        // footnote marker glued on, e.g. Astoria "Rwy 81". Both the padded and unpadded forms are
        // offered so a booklet that DOES pad still matches.
        var candidates = publishedRunways
            .map { $0.uppercased().replacingOccurrences(of: "RW", with: "") }
            .filter { !$0.isEmpty }
        candidates += candidates.compactMap { d -> String? in
            guard d.hasPrefix("0") else { return nil }
            return String(d.dropFirst())
        }
        candidates.sort { $0.count > $1.count }
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
