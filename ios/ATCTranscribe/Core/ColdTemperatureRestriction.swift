import Foundation
import CoreGraphics
#if canImport(PDFKit)
import PDFKit
#endif

/// COLD TEMPERATURE RESTRICTED AIRPORTS (CTA) — the snowflake on the plate.
///
/// At a CTA the FAA prints a snowflake icon with a temperature (`-21°C`) in the notes box of every
/// instrument approach. When the reported temperature is AT OR BELOW that figure, the pilot is expected
/// to apply a cold-temperature altitude correction (AIM 7-3, and the CTA notice in the TPP), because in
/// cold air the aircraft is lower than the altimeter says — the dangerous direction near terrain.
///
/// This is an ADVISORY, never a gate. The approach stays fully usable in the app; the point is only that
/// a special rule printed as a small glyph does not get missed. Whether and how to fly the approach is
/// the pilot's call.
///
/// WHERE THE NUMBER IS. On the plate the snowflake is a graphic, but its temperature is real text, set
/// on a line of its own in the narrow ICON column at the left of the notes box, under the `T` / `A`
/// symbols. Measured on Bozeman ILS Y 12 and Jackson Hole RNAV (RNP) Y 19 (cycle 2611):
/// `-21°C` at x 29.9–46.3 and 27.9–44.1 on a 387 pt page. The Baro-VNAV limit, which also prints
/// `-18°C`, sits INSIDE the notes prose (x ≥ 45) and is a different rule — Bismarck RNAV 31 carries one
/// and is not a CTA. So the reader keys on POSITION and on the token being alone, not on the text alone.
enum ColdTemperatureRestriction {

    /// What a plate says about cold temperature.
    struct PlateInfo: Equatable, Sendable {
        /// The snowflake temperature, °C. nil when the plate carries no CTA icon.
        var restrictionC: Int?
        /// The station the plate names for the altimeter (and so the weather) when the field has none —
        /// `use Gallatin altimeter setting`. Free text as printed; resolved to an ident separately.
        var sourceName: String?
        /// True when the file could not be read; nothing was concluded.
        var unreadable = false
    }

    // MARK: geometry (fractions of page width / height, y-DOWN)

    /// The notes box is in the top band of the page, below the title strip.
    static let notesBandTop = 0.07
    static let notesBandBottom = 0.30
    /// Lines further right than this belong to the missed-approach box, not the notes.
    static let notesColumnMaxX = 0.25
    /// Backstop when no neighbouring notes line exists to measure the margin from.
    static let iconColumnMaxX0 = 0.11
    /// Neighbouring notes lines are those within this many points vertically.
    static let neighbourWindow = 25.0
    /// How far left of the notes margin the figure must start, points.
    static let marginClearance = 4.0
    /// How far right of the `T`/`A` icons the snowflake figure may start, points.
    static let iconOffsetMax = 8.5
    /// Plausible snowflake temperatures. Published CTA figures run roughly 0 to −40 °C.
    static let plausibleRange = -60...5

    /// One laid-out line of the page, y-DOWN page points.
    struct NoteLine: Equatable, Sendable {
        let text: String
        let x0: Double
        let yMid: Double
    }

    // MARK: pure — the unit under test

    /// The snowflake temperature from the page's laid-out lines, or nil.
    ///
    /// A line that BEGINS with a temperature (`-21°C`) is the snowflake figure when either rule holds:
    ///
    /// 1. ICON ANCHOR. The figure sits in the icon column, directly under the `T` / `A` symbols: across
    ///    ~2,000 plates of cycle 2611 it starts 6–8 pt right of their left edge (8.5 accepted), while a
    ///    Baro-VNAV wrap (`-15°C or above 54°C`) starts at the notes margin, 11.1 pt or more to the
    ///    right. The rare figure set further out (9–10 pt) is left to rule 2. This rule wins even when
    ///    the figure is merged with prose on its baseline (`-26°C or above 54°C .` on Gambell RNAV 16,
    ///    where the Baro-VNAV low of -20 °C is on the line above).
    /// 2. NOTES MARGIN. It starts left of the margin measured from the neighbouring prose lines — for
    ///    plates whose icons were not extracted. Only neighbours starting at or right of the figure
    ///    count: a full-width first line (`DME required.` at x 22), a helicopter note beginning by the
    ///    icons, or a line PDFKit places at negative x is not the margin, and each of those hid a real
    ///    figure in the audit (Northway VOR-A, Alamosa VOR-B, Yankton ILS 31).
    static func restrictionC(lines: [NoteLine], pageWidth: Double, pageHeight: Double) -> Int? {
        guard pageWidth > 0, pageHeight > 0 else { return nil }
        let top = pageHeight * notesBandTop, bottom = pageHeight * notesBandBottom
        let band = lines.prefix(PlateText.maxRows).filter {                   // bounded (rule 2)
            $0.yMid >= top && $0.yMid <= bottom && $0.x0 <= pageWidth * notesColumnMaxX
        }
        let iconX = band.filter { ["T", "A"].contains($0.text.trimmingCharacters(in: .whitespacesAndNewlines))
                                  && $0.x0 >= 0 && $0.x0 <= pageWidth * iconColumnMaxX0 }
                        .map(\.x0).min()
        for l in band where l.x0 >= 0 {
            guard let t = leadingTemperatureC(l.text) else { continue }
            if let iconX, l.x0 <= pageWidth * iconColumnMaxX0, l.x0 - iconX <= iconOffsetMax { return t }
            guard !isBaroVNAVContinuation(l, in: band) else { continue }
            let neighbours = band.filter { n in
                n != l && abs(n.yMid - l.yMid) <= neighbourWindow && isProse(n.text)
                    && leadingTemperatureC(n.text) == nil && n.x0 >= l.x0 - 2
            }
            if neighbours.isEmpty {
                // Nothing to measure against: accept only a lone figure well inside the icon column.
                if isBareTemperature(l.text) && l.x0 <= pageWidth * iconColumnMaxX0 { return t }
                continue
            }
            // LOWER median: with two neighbours the plain median takes the larger, and a prose line
            // indented past the margin (`*RVR 1800…` at 42.5 against 37.7 on Macon RNAV 5) let a
            // Baro-VNAV wrap at the margin through.
            let xs = neighbours.map(\.x0).sorted()
            let margin = xs[(xs.count - 1) / 2]
            if l.x0 < margin - marginClearance { return t }
        }
        return nil
    }

    /// `-21°C` or `-17°C NA at night` → the temperature. nil unless the line STARTS with it.
    static func leadingTemperatureC(_ raw: String) -> Int? {
        let s = normalizeMinus(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let m = PlateNoteParser.firstMatch(#"^(-?\d{1,2})\s?°\s?C(?![0-9A-Za-z])"#, in: s), m.count >= 2,
              let v = Int(m[1]), plausibleRange.contains(v) else { return nil }
        return v
    }

    /// The second half of a Baro-VNAV window that wrapped onto a new line: `-7°C or above 54°C.`,
    /// or a temperature line directly under a line, in the same column, ending `below`. That is the LNAV/VNAV limit
    /// (`PlateNoteParser.baroVNAVTemperature`), a different rule from the snowflake.
    static func isBaroVNAVContinuation(_ l: NoteLine, in band: [NoteLine]) -> Bool {
        let s = normalizeMinus(l.text)
        if PlateNoteParser.firstMatch(#"(?i)^\s*-?\d{1,2}\s?°\s?C\s*(?:\([^)]*\)\s*)?or\s+above"#, in: s) != nil {
            return true
        }
        return band.contains { above in
            // Same column only: a helicopter note to the RIGHT ending `…reduction below` sits directly
            // above the snowflake figure on 00673R30, and is not what this line continues.
            above != l && above.yMid < l.yMid && l.yMid - above.yMid <= 12 && abs(above.x0 - l.x0) <= 6
                && above.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasSuffix("below")
        }
    }

    /// A line of notes PROSE — long enough and lower-case. Excludes the header-box labels
    /// (`Apt Elev`, `APP CRS`, at x 57–88 on 06281R4, which dragged the margin right and let a
    /// Baro-VNAV wrap through) and the all-caps first line `RNP APCH-GPS.` that spans the icon column.
    static func isProse(_ raw: String) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.count >= 12 && s.contains(where: { $0.isLowercase })
    }

    static func isBareTemperature(_ raw: String) -> Bool {
        let s = normalizeMinus(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        return PlateNoteParser.firstMatch(#"^-?\d{1,2}\s?°\s?C$"#, in: s) != nil
    }

    /// The station the plate tells the pilot to take the altimeter setting (and so the temperature) from.
    ///
    /// Two FAA phrasings: the conditional `When local altimeter setting not received, use Gallatin
    /// altimeter setting…` and the unconditional `Use Gallatin altimeter setting.` An explicit
    /// `use X temperature` is honoured too. `local` is not a station.
    static func temperatureSourceName(notesText raw: String) -> String? {
        let text = normalizeMinus(raw).replacingOccurrences(of: "\n", with: " ")
        let patterns = [
            #"\b[Uu]se\s+((?:[A-Z0-9][A-Za-z0-9.'\-/()]*\s+){1,6}?)(?:temperature|temp)\b"#,
            #"\b[Uu]se\s+((?:[A-Z0-9][A-Za-z0-9.'\-/()]*\s+){1,6}?)altimeter\s+setting"#,
        ]
        for p in patterns {
            guard let m = PlateNoteParser.firstMatch(p, in: text), m.count >= 2 else { continue }
            let name = m[1].trimmingCharacters(in: .whitespaces)
            let lower = name.lowercased()
            if lower == "local" || lower.hasSuffix(" local") || lower.isEmpty { continue }
            return name
        }
        return nil
    }

    static func normalizeMinus(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{2212}", with: "-")
            .replacingOccurrences(of: "\u{2010}", with: "-")
            .replacingOccurrences(of: "\u{2011}", with: "-")
            .replacingOccurrences(of: "\u{2013}", with: "-")
            .replacingOccurrences(of: "\u{00BA}", with: "°")               // masculine ordinal look-alike
    }

    // MARK: PDFKit

    #if canImport(PDFKit)
    static func read(pdfAt url: URL) -> PlateInfo {
        guard let doc = PDFDocument(url: url), let page = doc.page(at: 0) else {
            return PlateInfo(restrictionC: nil, sourceName: nil, unreadable: true)
        }
        return read(page: page)
    }

    static func read(page: PDFPage) -> PlateInfo {
        let media = page.bounds(for: .mediaBox)
        let laid = PlateText.lines(page: page)
        let lines = laid.prefix(PlateText.maxRows).map {                       // bounded (rule 2)
            NoteLine(text: $0.text, x0: Double($0.rect.minX), yMid: Double($0.rect.midY))
        }
        var prose = ""
        for l in lines { prose += l.text + " " }
        return PlateInfo(restrictionC: restrictionC(lines: lines, pageWidth: Double(media.width),
                                                    pageHeight: Double(media.height)),
                         sourceName: temperatureSourceName(notesText: prose))
    }
    #endif
}

/// Turns a plate's snowflake into an alert, using the best temperature available.
///
/// Source precedence, as asked: (1) the field's own METAR; (2) the station the PLATE names for the
/// altimeter setting; (3) the nearest reporting airport. Every answer carries where its temperature came
/// from, so a figure borrowed from 18 NM away is never presented as the field's own.
enum ColdTemperatureAdvisor {

    /// How far to look for a stand-in station when neither the field nor the plate's source reports.
    static let nearbyRadiusNm = 30.0
    /// A named source further than this from the field is a different place with the same name.
    static let sourceMaxNm = 75.0
    /// An observation older than this is not "the reported temperature". METARs are hourly; two hours
    /// allows one missed report. Older ones are treated as no report, so the chain falls through to the
    /// next source rather than letting an afternoon +3 °C hide the alert overnight.
    static let maxObservationAge: TimeInterval = 2 * 3600
    /// Show the observation's age in the text once it is at least this old.
    static let ageWorthStating: TimeInterval = 30 * 60

    enum Source: Equatable, Sendable {
        case field
        case plateSource(name: String)
        case nearby(distanceNm: Double)
    }

    struct Observation: Equatable, Sendable {
        let ident: String
        /// The REPORTED temperature, whole °C as the METAR body states it (`M21`). The rule is applied
        /// to the reported figure; the feed's tenths (`-20.6`) would read `.above` at a field reporting
        /// exactly the limit.
        let tempC: Double
        let source: Source
        /// Age of the observation, when known.
        var age: TimeInterval? = nil
    }

    enum Status: Equatable, Sendable { case atOrBelow, above, unknown }

    struct Advisory: Equatable, Sendable {
        let restrictionC: Int
        let observation: Observation?
        /// Some fetch the advisory depended on FAILED (offline, server error). "Unknown" then means
        /// "could not be checked", which is a different instruction from "nobody reports".
        var fetchFailed = false

        var status: Status {
            guard let o = observation else { return .unknown }
            return o.tempC <= Double(restrictionC) ? .atOrBelow : .above
        }

        /// One line for a badge or banner headline.
        var headline: String {
            switch status {
            case .atOrBelow: return "Cold temperature restriction in effect"
            case .above, .unknown: return "Cold temperature restricted airport"
            }
        }

        /// Where the temperature came from, in words a pilot can check.
        var sourceLine: String {
            guard let o = observation else {
                if fetchFailed {
                    return "Weather could not be fetched, so the temperature is unknown."
                }
                return "No current temperature report (last \(Int(ColdTemperatureAdvisor.maxObservationAge / 3600)) h) at the field, from the plate's named source, or nearby within \(Int(ColdTemperatureAdvisor.nearbyRadiusNm)) NM."
            }
            let t = "\(Int(o.tempC))°C"
            var when = ""
            if let a = o.age, a >= ColdTemperatureAdvisor.ageWorthStating { when = " \(Int(a / 60)) min ago" }
            let verb = when.isEmpty ? "reports" : "reported"
            switch o.source {
            case .field:
                return "\(o.ident) \(verb) \(t)\(when)."
            case .plateSource(let name):
                return "\(o.ident) \(verb) \(t)\(when) — the field has no current report; the plate names \(name) as its altimeter source."
            case .nearby(let d):
                return "\(o.ident) \(verb) \(t)\(when), \(Int(d.rounded())) NM away — the field has no current report. Nearby weather is an estimate."
            }
        }

        var detail: String {
            let limit = "Published limit \(restrictionC)°C."
            switch status {
            case .atOrBelow:
                return "\(sourceLine) \(limit) At or below this temperature the FAA expects cold-temperature altitude corrections on this approach (AIM 7-3). Advise ATC of corrected altitudes on any segment other than final. The approach is not disabled — whether to fly it is your decision."
            case .above:
                return "\(sourceLine) \(limit) Corrections apply at or below the limit."
            case .unknown:
                return "\(sourceLine) \(limit) Check the temperature before flying this approach."
            }
        }
    }

    /// A station that might stand in for the field.
    struct Station: Equatable, Sendable {
        let ident: String          // a 4-letter weather ident
        let name: String
        let distanceNm: Double
        /// Reported whole-degree temperature of a CURRENT observation; nil when none.
        let tempC: Double?
        var city: String = ""
        var age: TimeInterval? = nil
    }

    /// Pure: choose the temperature and build the advisory.
    static func assess(restrictionC: Int,
                       fieldIdent: String, fieldTempC: Double?, fieldAge: TimeInterval? = nil,
                       plateSourceName: String?, plateSource: Station?,
                       nearby: [Station], fetchFailed: Bool = false) -> Advisory {
        if let t = fieldTempC {
            return Advisory(restrictionC: restrictionC,
                            observation: Observation(ident: fieldIdent, tempC: t, source: .field, age: fieldAge))
        }
        if let s = plateSource, let t = s.tempC, let name = plateSourceName {
            return Advisory(restrictionC: restrictionC,
                            observation: Observation(ident: s.ident, tempC: t, source: .plateSource(name: name), age: s.age))
        }
        let near = nearby.filter { $0.tempC != nil && $0.distanceNm <= nearbyRadiusNm
                                   && $0.ident.uppercased() != fieldIdent.uppercased() }
                         .min { $0.distanceNm < $1.distanceNm }
        if let s = near, let t = s.tempC {
            return Advisory(restrictionC: restrictionC,
                            observation: Observation(ident: s.ident, tempC: t, source: .nearby(distanceNm: s.distanceNm), age: s.age))
        }
        return Advisory(restrictionC: restrictionC, observation: nil, fetchFailed: fetchFailed)
    }

    /// The reported whole-degree temperature. The METAR body's group (`M21/M24`) is what is reported;
    /// without one, the feed's tenths are rounded the way the body would be (half up).
    static func reportedC(raw: String?, tenths: Double?) -> Double? {
        if let r = Metar.temperatureFromRaw(raw) { return r }
        guard let t = tenths else { return nil }
        return (t + 0.5).rounded(.down)
    }

    /// A station's CURRENT reported temperature and the observation's age, or nil when it has no
    /// observation within `maxObservationAge`. `MetarStore` keeps the last good observation through a
    /// failed or empty refresh, so age is checked here rather than trusted.
    static func current(_ m: Metar?, now: Date = Date()) -> (tempC: Double, age: TimeInterval?)? {
        guard let m, let t = reportedC(raw: m.rawOb, tenths: m.tempC) else { return nil }
        guard let epoch = m.obsEpoch else { return (t, nil) }
        let age = max(0, now.timeIntervalSince1970 - Double(epoch))
        return age <= maxObservationAge ? (t, age) : nil
    }

    /// Pure: which candidate airport the plate's source NAME refers to.
    ///
    /// The plate prints an ident (`use ORE altimeter setting`), an ident pair (`use HNH/PAOH altimeter
    /// setting`), or a name in chart abbreviations (`Dane County Rgnl-Truax Fld`), sometimes a CITY
    /// (`use Butte altimeter setting` for Bert Mooney). So:
    ///   - a printed token equal to a candidate's ident wins outright, the candidate matching the most
    ///     such tokens first (`HNH/PAOH` is Hoonah, not the seaplane base nearer by name);
    ///   - otherwise a name matches when its FIRST word and at least half its words match a word of
    ///     the airport's name or city — equal, a prefix of it (two letters or more), or an abbreviation
    ///     of it (`FLD` ~ `FIELD`).
    /// Stray icon glyphs that leak into the line (`A Noatak`, `Butte NA`) are dropped first. Nothing
    /// beyond `sourceMaxNm` is accepted.
    static func resolveSource(name: String, candidates: [Station], identAliases: [String: [String]] = [:]) -> Station? {
        var want = tokens(name)
        while let f = want.first, want.count > 1, isGlyphDebris(f) { want.removeFirst() }
        while let l = want.last, want.count > 1, isGlyphDebris(l) { want.removeLast() }
        guard let first = want.first else { return nil }
        let pool = candidates.prefix(512).filter { $0.distanceNm <= sourceMaxNm }    // bounded (rule 2)

        let byIdent = pool.map { c -> (Station, Int) in
            let ids = Set([c.ident.uppercased()] + (identAliases[c.ident] ?? []).map { $0.uppercased() })
            return (c, want.filter { ids.contains($0) }.count)
        }.filter { $0.1 > 0 }
        if let best = byIdent.max(by: { ($0.1, -$0.0.distanceNm) < ($1.1, -$1.0.distanceNm) }) { return best.0 }

        let matches = pool.filter { c in
            let hay = tokens(c.name + " " + c.city)
            func hit(_ w: String) -> Bool {
                hay.contains { $0 == w || (w.count >= 2 && $0.hasPrefix(w)) || abbreviates(w, $0) }
            }
            guard hit(first) else { return false }
            return want.filter(hit).count * 2 >= want.count
        }
        return matches.min { $0.distanceNm < $1.distanceNm }
    }

    /// A single letter or `NA` — the `A`/`T` icons and the alternate-minimums `NA` that PDFKit joins
    /// into the notes line next to them.
    static func isGlyphDebris(_ t: String) -> Bool { t.count == 1 || t == "NA" }

    static func tokens(_ s: String) -> [String] {
        s.uppercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { !$0.isEmpty }
    }

    /// `FLD` abbreviates `FIELD`, `RGNL` abbreviates `REGIONAL`: same first letter, letters in order.
    static func abbreviates(_ short: String, _ long: String) -> Bool {
        guard short.count >= 2, short.count < long.count, short.first == long.first else { return false }
        var it = long.makeIterator()
        for ch in short {
            var found = false
            while let c = it.next() { if c == ch { found = true; break } }
            if !found { return false }
        }
        return true
    }
}
