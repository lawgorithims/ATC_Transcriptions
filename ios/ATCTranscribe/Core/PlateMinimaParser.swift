import Foundation

/// Reads the minima block out of a plate's positioned text.
///
/// The parser is deliberately brittle in one direction only: every step that cannot be resolved with
/// certainty drops the row instead of producing a value. A minima table with three of its four rows read
/// correctly and the fourth missing is a usable aid; one with four rows where the fourth is a guess is a
/// hazard. `refusals` records what was dropped and why, so the UI can say "this plate did not parse
/// cleanly — read it" rather than quietly showing a short table.
enum PlateMinimaParser {

    /// Rows are grouped with this vertical tolerance. Body glyphs on a minima line are ~4.2 pt tall and
    /// the line pitch is ~10 pt, so 3.0 pt keeps a fraction with its own row without swallowing the next.
    static let rowTolerance = 3.0
    /// A wrapped label (`LNAV/` over `VNAV`) sits within this many points of its value row.
    static let labelWrapWindow = 7.0
    /// A new value group starts on a gap wider than this fraction of the COLUMN pitch.
    ///
    /// The unit has to be the column spacing, not the character advance: what separates two printed
    /// cells is that they sit under different category columns, and the gap inside a cell — between the
    /// altitude/visibility pair and the height above touchdown that follows it — is only about twice a
    /// character wide. Measured on real plates the two are 8 pt and 28 pt against a 49 pt column.
    static let cellGapFraction = 0.22
    /// …with a character-advance floor for the rare table whose columns are unusually tight.
    static let cellGapAdvanceFactor = 2.5
    /// A space is written into a cell's text on a gap wider than this multiple of the character advance.
    static let spaceGapFactor = 0.35
    /// Rows this far below the CATEGORY header are still inside the band. FAA minima blocks run about
    /// 60 pt; 80 gives headroom without reaching the city/airport line.
    static let bandDepth = 80.0
    /// Hard row cap (rule 2).
    static let maxRows = 40

    /// Everything the parse produced, including what it refused.
    struct Result {
        var minima: PlateMinima?
        var refusals: [String] = []
    }

    // MARK: entry point

    static func parse(words: [PlateWord], notesText: String,
                      airport: String, approachName: String, cycle: String) -> Result {
        assert(!approachName.isEmpty, "PlateMinimaParser: unnamed approach")
        var refusals: [String] = []
        guard let header = findHeader(words) else {
            return Result(minima: nil, refusals: ["No CATEGORY header found — plate may be a scanned raster."])
        }
        guard header.centers.count >= 2 else {
            return Result(minima: nil, refusals: ["CATEGORY header found but fewer than two category columns."])
        }

        // The band: everything below the header, inside the table's horizontal extent. The right edge
        // is deliberately tight — the timing table (`Knots 60 90 120 150 180`) begins only a few points
        // past the last category column, and letting it in turns every row it shares a line with into an
        // unreadable one.
        let leftEdge = header.categoryWord.x0 - 4
        let rightEdge = header.bandRight
        let band = words.filter {
            $0.yMid > header.categoryWord.yMid + 1
                && $0.yMid < header.categoryWord.yMid + bandDepth
                && $0.x1 > leftEdge && $0.x0 < rightEdge
        }
        let allRows = absorbWrappedLabels(PlateText.rows(band, tolerance: rowTolerance), header: header)

        var baseRows: [PlateMinima.Row] = []
        var conditionals: [PlateMinima.ConditionalBlock] = []
        var pendingHeading: String?
        var pendingRows: [PlateMinima.Row] = []

        func closeConditional() {
            guard let h = pendingHeading else { return }
            if pendingRows.isEmpty {
                refusals.append("Conditional block “\(h)” had no readable rows.")
            } else {
                conditionals.append(PlateMinima.ConditionalBlock(
                    heading: h, question: question(from: h), rows: pendingRows))
            }
            pendingHeading = nil
            pendingRows = []
        }

        var headingParts: [String] = []
        for row in allRows.prefix(maxRows) {                      // bounded (rule 2)
            if row.isEmpty { continue }
            let text = PlateText.line(row)
            if isBandTerminator(text) { break }

            // A centred all-caps line with no numeric cell may be a conditional heading. It can wrap over
            // two or three rows, so the first fragment has to STATE a condition and the rest merely
            // continue it — that is what keeps captions like `AUTHORIZATION REQUIRED` out.
            if let raw = captionFragment(row, header: header) {
                let fragment = respace(raw, using: notesText)
                if !headingParts.isEmpty {
                    headingParts.append(fragment)
                    continue
                }
                if statesACondition(fragment) {
                    closeConditional()
                    headingParts.append(fragment)
                }
                continue
            }

            guard let parsed = parseRow(row, header: header, prose: notesText, refusals: &refusals)
            else { continue }
            if !headingParts.isEmpty {
                pendingHeading = headingParts.joined(separator: " ")
                headingParts = []
            }
            if pendingHeading != nil { pendingRows.append(parsed) } else { baseRows.append(parsed) }
        }
        closeConditional()

        guard !baseRows.isEmpty else {
            refusals.append("CATEGORY header found but no minima row parsed.")
            return Result(minima: nil, refusals: refusals)
        }

        let m = PlateMinima(airport: airport,
                            approachName: approachName,
                            rows: baseRows,
                            conditionals: conditionals,
                            notes: PlateNoteParser.notes(inText: notesText),
                            amendment: amendment(words).map { respace($0, using: notesText) },
                            cycle: cycle)
        return Result(minima: m, refusals: refusals)
    }

    // MARK: header

    struct Header {
        let categoryWord: PlateWord
        /// x-centre of each published category column, in order.
        let centers: [(PlateMinima.Category, Double)]
        /// Right edge of the table — beyond this lie the lighting box and the timing table.
        let bandRight: Double
        /// Left edge of the first value column; everything left of it is the row label.
        let valuesLeft: Double

        /// Nominal column pitch, used for the assignment tolerance.
        var pitch: Double {
            guard centers.count >= 2 else { return 48 }
            return (centers[centers.count - 1].1 - centers[0].1) / Double(centers.count - 1)
        }
    }

    /// Locate `CATEGORY` and the A…E letters that follow it on the same row.
    ///
    /// The header row also carries text from the panels to the right of the table — runway lists, lighting
    /// notes — and some of it is a bare capital letter. The letters are therefore accepted only in strict
    /// alphabetical order starting at A, and only while the spacing stays regular; the first letter that
    /// breaks either rule ends the header and fixes the table's right edge.
    static func findHeader(_ words: [PlateWord]) -> Header? {
        guard let cat = words.first(where: { $0.text.uppercased() == "CATEGORY" }) else { return nil }
        let sameRow = words
            .filter { abs($0.yMid - cat.yMid) <= rowTolerance && $0.x0 > cat.x1 }
            .sorted { $0.x0 < $1.x0 }

        var centers: [(PlateMinima.Category, Double)] = []
        var expected = 0
        let order = PlateMinima.Category.allCases
        var lastPitch: Double?
        for w in sameRow.prefix(64) {                             // bounded (rule 2)
            guard expected < order.count else { break }
            guard w.text.count == 1, w.text.uppercased() == order[expected].rawValue else { continue }
            let c = w.xMid
            if let prev = centers.last?.1 {
                let pitch = c - prev
                guard pitch > 8 else { continue }                 // same letter twice / stray glyph
                if let lp = lastPitch, pitch > lp * 1.8 { break } // column stopped being a column
                lastPitch = pitch
            }
            centers.append((order[expected], c))
            expected += 1
        }
        guard centers.count >= 2 else { return nil }
        let pitch = (centers[centers.count - 1].1 - centers[0].1) / Double(centers.count - 1)
        return Header(categoryWord: cat,
                      centers: centers,
                      bandRight: centers[centers.count - 1].1 + pitch * 0.55,
                      valuesLeft: centers[0].1 - pitch * 0.75)
    }

    // MARK: rows

    /// Where a printed minima cell begins: two-to-five digits followed by the altitude/visibility
    /// separator, or an explicit `NA`.
    ///
    /// The split between the row's LABEL and its VALUES is made on this rather than on an x threshold,
    /// because a wide category-A circling cell (`1300-1 641 (700-1)`) reaches further left than the label
    /// column ends, and a threshold that accommodated it would swallow `DA` out of `LPV DA`.
    static func isValueStart(_ text: String) -> Bool {
        let t = text.uppercased()
        if t == "NA" || t == "N/A" { return true }
        return t.range(of: #"^\d{2,5}\s*[/-]"#, options: .regularExpression) != nil
    }

    /// Parse one physical row into a minima row, or nil when it is not one.
    static func parseRow(_ row: [PlateWord], header: Header, prose: String,
                         refusals: inout [String]) -> PlateMinima.Row? {
        guard let split = row.firstIndex(where: { isValueStart($0.text) }) else { return nil }
        let labelWords = Array(row[..<split])
        let valueWords = Array(row[split...])
        guard !labelWords.isEmpty, !valueWords.isEmpty else { return nil }

        let label = respace(labelText(labelWords), using: prose)
        let cleaned = label.replacingOccurrences(of: "*", with: "").trimmingCharacters(in: .whitespaces)
        let groups = reconcile(valueGroups(valueWords, columnPitch: header.pitch), header: header)
        guard !groups.isEmpty else { return nil }

        guard let kind = classify(cleaned) else {
            // A row carrying real minima whose LABEL could not be identified is the one failure that must
            // never be silent: the pilot would see a short table with no sign that a published line is
            // missing from it. Say what was found and send them to the chart.
            if groups.contains(where: { MinimaValueParser.parse($0.text) != nil }) {
                let printed = groups.compactMap { MinimaValueParser.parse($0.text)?.printedForm }
                refusals.append("A line reading “\(printed.joined(separator: "  |  "))” could not be identified — read it on the chart.")
            }
            return nil
        }

        var parsedGroups: [(range: ClosedRange<Double>, value: PlateMinima.Value)] = []
        for g in groups.prefix(8) {                               // bounded (rule 2)
            guard let v = MinimaValueParser.parse(g.text) else {
                refusals.append("“\(cleaned)”: could not read “\(g.text)”.")
                return nil                                        // refuse the row, never a partial row
            }
            parsedGroups.append((g.range, v))
        }

        guard let values = assign(groups: parsedGroups, to: header) else {
            refusals.append("“\(cleaned)”: value columns did not line up with the category header.")
            return nil
        }
        return PlateMinima.Row(label: displayLabel(cleaned, kind: kind, prose: prose),
                               kind: kind,
                               values: values,
                               hasInopAsterisk: label.contains("*"),
                               pageY: row[0].yMid)
    }

    /// Fold label-only rows back into the value row they belong to.
    ///
    /// `LNAV/VNAV DA` wraps onto a second line, and the wrap lands far enough below the value row to
    /// become a row of its own. Left alone it takes `VNAV` with it, leaving the value row labelled
    /// `LNAV/ DA`. A candidate for absorption must lie ENTIRELY inside the label column, which is what
    /// keeps a conditional heading — always a wide, centred caption — from being swallowed.
    static func absorbWrappedLabels(_ rows: [[PlateWord]], header: Header) -> [[PlateWord]] {
        let labelRight = header.centers[0].1 - header.pitch * 0.5
        var out: [[PlateWord]] = []
        var pending: [[PlateWord]] = []                           // wraps waiting for their value row

        func isWrap(_ row: [PlateWord]) -> Bool {
            guard !row.isEmpty, row.count <= 3 else { return false }
            guard !row.contains(where: { isValueStart($0.text) }) else { return false }
            return row.allSatisfy { $0.x1 <= labelRight }
        }
        func hasValues(_ row: [PlateWord]) -> Bool { row.contains { isValueStart($0.text) } }
        func yMid(_ row: [PlateWord]) -> Double { row.isEmpty ? 0 : row[0].yMid }

        for row in rows.prefix(maxRows) {                         // bounded (rule 2)
            if isWrap(row) {
                // Attach backwards if the previous row is a value row within the wrap window.
                if let last = out.last, hasValues(last), abs(yMid(row) - yMid(last)) <= labelWrapWindow {
                    out[out.count - 1] = (last + row).sorted { $0.x0 < $1.x0 }
                } else {
                    pending.append(row)
                }
                continue
            }
            var merged = row
            if hasValues(row) {
                for p in pending.prefix(4) where abs(yMid(p) - yMid(row)) <= labelWrapWindow {
                    merged += p                                   // forward wrap: label line above its values
                }
                merged.sort { $0.x0 < $1.x0 }
            } else {
                out.append(contentsOf: pending)                   // not a value row — hand the fragments back
            }
            pending = []
            out.append(merged)
        }
        out.append(contentsOf: pending)
        return out
    }

    /// The label to show beside a number.
    ///
    /// The swept text is used whenever the page's own prose confirms it reads that way. When it does not
    /// — a wrapped label the sweep could not re-flow — a canonical name for the kind is shown instead,
    /// because `LNAV/DAVNAV` beside a decision altitude invites the pilot to distrust a figure that is
    /// in fact correct, and distrust of the right number is its own hazard.
    static func displayLabel(_ swept: String, kind: PlateMinima.Kind, prose: String) -> String {
        if respaced(swept, in: prose) != nil, !swept.isEmpty { return respaced(swept, in: prose) ?? swept }
        let runway = swept.range(of: #"\b\d{1,2}[LRC]?\b"#, options: .regularExpression).map { String(swept[$0]) }
        switch kind {
        case .baroVNAV: return "LNAV/VNAV DA"
        case .lpv:      return "LPV DA"
        case .lp:       return "LP DA"
        case .lnav:     return "LNAV MDA"
        case .circling: return "CIRCLING"
        case .ils:      return runway.map { "S-ILS \($0)" } ?? "S-ILS"
        case .localizer: return runway.map { "S-LOC \($0)" } ?? "S-LOC"
        default:        return swept
        }
    }

    /// Reassemble a row label from its runs, re-flowing the wraps.
    ///
    /// `LNAV/VNAV DA` is set as `LNAV/` over `VNAV`, with `DA` beside the first line — so reading the
    /// lines in order gives `LNAV/ DA VNAV`, and a label that merely *contains* `LNAV` classifies as an
    /// LNAV line. Presenting a Baro-VNAV decision altitude as an LNAV minimum descent altitude would put
    /// a number 34 ft lower than the MDA on screen under the wrong name, so the wrap is undone here: a
    /// continuation line begins at the SAME left margin as the word it continues, and is spliced back in
    /// after it rather than appended at the end.
    static func labelText(_ words: [PlateWord]) -> String {
        guard !words.isEmpty else { return "" }
        let lines = PlateText.rows(words, tolerance: rowTolerance)
        guard let first = lines.first else { return "" }
        var ordered: [(word: PlateWord, joinsPrevious: Bool)] = first.map { (word: $0, joinsPrevious: false) }

        for line in lines.dropFirst().prefix(4) {                 // bounded (rule 2)
            for w in line.prefix(8) {                             // bounded (rule 2)
                if let at = ordered.lastIndex(where: { abs($0.word.x0 - w.x0) < 3.0 }) {
                    ordered.insert((word: w, joinsPrevious: true), at: at + 1)
                } else {
                    ordered.append((word: w, joinsPrevious: false))
                }
            }
        }

        var out = ""
        var cursor = -Double.greatestFiniteMagnitude
        for t in ordered.prefix(24) {                             // bounded (rule 2)
            if !out.isEmpty && !t.joinsPrevious && t.word.x0 - cursor > t.word.pitch * spaceGapFactor {
                out += " "
            }
            out += t.word.text
            cursor = max(cursor, t.word.x1)
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// Repair the cell split using the grammar itself, and drop what is not a cell at all.
    ///
    /// Two failure modes, both of which a gap threshold alone cannot resolve. A cell can be split in the
    /// middle — the gap inside `440/24  422 (500-½)` is real and on a tight table exceeds the threshold —
    /// so adjacent fragments are rejoined whenever the join PARSES and the pieces separately do not. And
    /// text from the panels beside the table can drift in — the lighting box, the `Min:Sec` timing row —
    /// so a fragment that parses as nothing and sits under no category column is discarded rather than
    /// being allowed to refuse the whole row.
    static func reconcile(_ groups: [(text: String, range: ClosedRange<Double>)],
                          header: Header) -> [(text: String, range: ClosedRange<Double>)] {
        guard !groups.isEmpty else { return [] }
        // Join neighbours that only parse together.
        var merged: [(text: String, range: ClosedRange<Double>)] = []
        var i = 0
        while i < groups.count && i < 16 {                         // bounded (rule 2)
            let g = groups[i]
            if MinimaValueParser.parse(g.text) == nil, i + 1 < groups.count {
                let n = groups[i + 1]
                let joined = g.text + n.text
                if MinimaValueParser.parse(joined) != nil {
                    merged.append((joined, g.range.lowerBound...n.range.upperBound))
                    i += 2
                    continue
                }
            }
            if let last = merged.last, MinimaValueParser.parse(g.text) == nil {
                let joined = last.text + g.text
                if MinimaValueParser.parse(joined) != nil {
                    merged[merged.count - 1] = (joined, last.range.lowerBound...g.range.upperBound)
                    i += 1
                    continue
                }
            }
            merged.append(g)
            i += 1
        }
        // Drop unreadable fragments that lie under no category column. The tolerance here is tighter
        // than the one `assign` uses: a fragment only earns the right to refuse a row if it genuinely
        // sits in the table, and half a column of slack lets the timing panel just past the last column
        // claim to be a cell.
        let tolerance = header.pitch * 0.25
        return merged.filter { g in
            if MinimaValueParser.parse(g.text) != nil { return true }
            return header.centers.contains { c in
                c.1 >= g.range.lowerBound - tolerance && c.1 <= g.range.upperBound + tolerance
            }
        }
    }

    /// Break a row's value text into groups on the wide gaps between printed cells.
    ///
    /// Fractions are folded FIRST: a half-height `1` over `2` has to become `½` before any gap arithmetic
    /// runs, or the two glyphs get spaced apart into the number twelve.
    static func valueGroups(_ words: [PlateWord], columnPitch: Double) -> [(text: String, range: ClosedRange<Double>)] {
        guard !words.isEmpty else { return [] }
        let sorted = words.sorted { $0.x0 < $1.x0 }
        let advance = medianPitch(sorted)
        let cellBreak = max(columnPitch * cellGapFraction, advance * cellGapAdvanceFactor)
        var out: [(String, ClosedRange<Double>)] = []
        var text = ""
        var lo = sorted[0].x0
        var hi = sorted[0].x0
        for w in sorted.prefix(128) {                             // bounded (rule 2)
            let gap = w.x0 - hi
            if !text.isEmpty && gap > cellBreak {
                out.append((text, lo...hi))
                text = ""; lo = w.x0
            }
            if !text.isEmpty && gap > advance * spaceGapFactor { text += " " }
            text += w.text
            hi = max(hi, w.x1)
        }
        if !text.isEmpty { out.append((text, lo...hi)) }
        return out.map { (text: $0.0, range: $0.1) }
    }

    /// Representative character advance for a set of runs.
    static func medianPitch(_ words: [PlateWord]) -> Double {
        PlateText.median(words.map(\.pitch), fallback: 3.5)
    }

    /// Map value groups onto category columns.
    ///
    /// A single group is centred across the whole table and applies to EVERY category — this is the
    /// commonest layout on the plate (`S-ILS 4R  218/18  200 (200-½)` under A B C D) and the one case
    /// where horizontal overlap gives the wrong answer, because the centred cell only physically covers
    /// the middle columns. With more than one group each is matched to the columns its printed extent
    /// covers, and the result is accepted only if **every** category received exactly one value. A gap or
    /// an overlap means the geometry was not understood, and the row is refused.
    static func assign(groups: [(range: ClosedRange<Double>, value: PlateMinima.Value)],
                       to header: Header) -> [PlateMinima.Category: PlateMinima.Value]? {
        guard !groups.isEmpty else { return nil }
        if groups.count == 1 {
            var out: [PlateMinima.Category: PlateMinima.Value] = [:]
            for (cat, _) in header.centers { out[cat] = groups[0].value }
            return out
        }
        guard groups.count <= header.centers.count else { return nil }

        let tolerance = header.pitch * 0.5
        var out: [PlateMinima.Category: PlateMinima.Value] = [:]
        for (cat, centre) in header.centers.prefix(8) {           // bounded (rule 2)
            var hits = 0
            for g in groups.prefix(8) {                           // bounded (rule 2)
                if centre >= g.range.lowerBound - tolerance && centre <= g.range.upperBound + tolerance {
                    out[cat] = g.value
                    hits += 1
                }
            }
            guard hits == 1 else { return nil }                   // unclaimed or contested → refuse
        }
        return out
    }

    // MARK: classification

    /// Which kind of minimum a printed row label denotes. nil for a line that is not a minima row at all.
    static func classify(_ label: String) -> PlateMinima.Kind? {
        let u = squash(label).uppercased()
        guard u.rangeOfCharacter(from: .letters) != nil else { return nil }
        if u.contains("CIRCLING") { return .circling }
        if u.contains("SIDESTEP") { return .sidestep }
        if u.hasPrefix("RNP") { return .rnpAR }
        // `LNAV/VNAV DA` is typeset as `LNAV/` over `VNAV` with `DA` beside the first line, and the sweep
        // can return it as `LNAV/DA` + `VNAV` — so the two halves are looked for INDEPENDENTLY of order.
        // Reading that row as a plain LNAV line would present a Baro-VNAV decision altitude, which the
        // aircraft descends through on a computed path, as a minimum descent altitude it must level at.
        if u.contains("LNAV/") && u.contains("VNAV") { return .baroVNAV }
        // …and when the two stacked lines sit close enough to share one swept band, their characters come
        // back INTERLEAVED: `LNAV/` over `VNAV` reads as `LVNNAAVV/`. Both words are still present in
        // order, just not contiguously, so they are looked for as subsequences. Requiring BOTH — and the
        // solidus that only the first carries — keeps this from matching an ordinary `LNAV MDA`, which
        // has a single V and cannot spell VNAV.
        if u.contains("/"), containsSubsequence(u, "LNAV"), containsSubsequence(u, "VNAV") { return .baroVNAV }
        if u.contains("LPV") { return .lpv }
        if u.hasPrefix("LPDA") || u.hasPrefix("LPMDA") || u == "LP" { return .lp }
        if u.contains("LNAV") { return .lnav }
        if u.contains("GLS") { return .gls }
        if u.contains("ILS") { return .ils }
        if u.contains("LOC") || u.contains("LDA") || u.contains("SDF") { return .localizer }
        if u.contains("VOR") { return .vor }
        if u.contains("NDB") { return .ndb }
        if u.contains("GPS") { return .gps }
        return nil
    }

    /// Are `needle`'s characters present in `haystack`, in order but not necessarily together?
    static func containsSubsequence(_ haystack: String, _ needle: String) -> Bool {
        var it = haystack.makeIterator()
        for want in needle.prefix(32) {                           // bounded (rule 2)
            var found = false
            while let c = it.next() {                             // bounded by haystack (rule 2)
                if c == want { found = true; break }
            }
            if !found { return false }
        }
        return true
    }

    // MARK: conditional headings

    /// A caption is a wholly non-numeric all-caps line inside the band — a candidate heading fragment.
    static func captionFragment(_ row: [PlateWord], header: Header) -> String? {
        let text = PlateText.line(row).trimmingCharacters(in: .whitespaces)
        guard text.count >= 4 else { return nil }
        guard text.rangeOfCharacter(from: CharacterSet(charactersIn: "0123456789")) == nil else { return nil }
        let letters = text.filter { $0.isLetter }
        guard !letters.isEmpty, letters.allSatisfy({ $0.isUppercase }) else { return nil }
        // Must actually be inside the table, not a caption drifting in from the right-hand panels.
        guard let first = row.first, first.x0 < header.centers[0].1 + header.pitch else { return nil }
        return text.replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespaces)
    }

    /// Only a caption that states a CONDITION may open a conditional block. Without this, standing
    /// annotations — `AUTHORIZATION REQUIRED` over an RNP AR line, `INOPERATIVE TABLE DOES NOT APPLY` —
    /// would capture every row beneath them and hide the base minima behind a meaningless toggle.
    /// Matched against the SPACE-STRIPPED caption, because the sweep cannot always tell a typeset space
    /// from a wide letter and `APPROACH MINIMA WHEN…` can come back as one word.
    static func statesACondition(_ fragment: String) -> Bool {
        let u = squash(fragment).uppercased()
        for marker in ["WHEN", "UNLESS", "WHILE", "DURING"] {     // bounded (rule 2)
            if u.contains(marker) { return true }
        }
        return false
    }

    /// Text with every space removed — the form in which swept and printed text can be compared.
    static func squash(_ s: String) -> String { s.filter { !$0.isWhitespace } }

    /// Recover a caption's real word spacing from the page's own prose.
    ///
    /// The character sweep reads the table in visual order but cannot reliably tell a typeset space from
    /// a wide letter, so a heading can arrive as `MINIMAWHENCONTROLTOWER`. The same words appear in the
    /// page's laid-out text with their spaces intact, so the squashed form is matched there and the
    /// spaced original returned. Falls back to the swept text, which is legible if ugly.
    static func respace(_ swept: String, using prose: String) -> String {
        respaced(swept, in: prose) ?? swept
    }

    /// The spaced form, or nil when the swept text does not appear in the prose at all.
    static func respaced(_ swept: String, in prose: String) -> String? {
        let needle = squash(swept)
        guard needle.count >= 4 else { return nil }
        var flat = ""
        var map: [String.Index] = []
        for i in prose.indices.prefix(20_000) {                   // bounded (rule 2)
            guard !prose[i].isWhitespace else { continue }
            flat.append(prose[i]); map.append(i)
        }
        guard let r = flat.range(of: needle) else { return nil }
        let lo = flat.distance(from: flat.startIndex, to: r.lowerBound)
        let hi = flat.distance(from: flat.startIndex, to: r.upperBound) - 1
        guard lo >= 0, hi < map.count, lo <= hi else { return nil }
        return String(prose[map[lo]...map[hi]]).trimmingCharacters(in: .whitespaces)
    }

    /// Turn `APPROACH MINIMA WHEN CONTROL TOWER REPORTS TALL VESSELS IN APPROACH AREA` into a question a
    /// pilot can answer with a button. This is item 25: the buried note becomes a control.
    static func question(from heading: String) -> String {
        let h = heading.trimmingCharacters(in: .whitespaces)
        if let r = h.range(of: "WHEN ", options: [.caseInsensitive]) {
            let cond = String(h[r.upperBound...]).lowercased()
            return sentence(cond) + "?"
        }
        return sentence(h.lowercased()) + "?"
    }

    private static func sentence(_ s: String) -> String {
        guard let f = s.first else { return s }
        return f.uppercased() + s.dropFirst()
    }

    /// The band ends at the city/airport identification line or the amendment stamp.
    static func isBandTerminator(_ text: String) -> Bool {
        let u = text.uppercased()
        if u.hasPrefix("AMDT") || u.hasPrefix("ORIG") { return true }
        // "BOSTON, MASSACHUSETTS" — a comma-separated place line, all caps, no digits.
        if u.contains(","), !u.contains("("), u.rangeOfCharacter(from: CharacterSet(charactersIn: "0123456789")) == nil,
           u.count > 8, u.filter({ $0.isLetter }).allSatisfy({ $0.isUppercase }) { return true }
        return false
    }

    /// `Amdt 3A 13JUN24` / `Orig-B 05SEP19` — the provenance line under the minima block.
    static func amendment(_ words: [PlateWord]) -> String? {
        let rows = PlateText.rows(words, tolerance: rowTolerance)
        for row in rows.prefix(400) {                             // bounded (rule 2)
            let text = PlateText.line(row)
            guard let r = text.range(of: #"\b(Amdt|AMDT|Orig|ORIG)[^A-Za-z]?[-\w]*\s+\d{2}[A-Z]{3}\d{2}"#,
                                     options: .regularExpression) else { continue }
            return String(text[r])
        }
        return nil
    }
}
