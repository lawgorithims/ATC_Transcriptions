import Foundation

/// Reads one printed minima cell — `218/18 200 (200-½)` — into structured values.
///
/// THE FRACTION PROBLEM. Plate visibilities are typeset as true fractions: a half-height numerator over a
/// half-height denominator, with no solidus between them in the text stream. Extracted in visual order
/// they arrive as two ordinary digits, so `½` reads as `12` and three quarters of a mile reads as
/// thirty-four. Both are numbers a regular expression will happily accept.
///
/// The resolution is CONTEXT plus a CLOSED SET. A digit pair is only ever read as a fraction in a slot
/// that holds a visibility, and only when it is one of the fractions the FAA actually publishes on an
/// instrument approach chart. `12` in the visibility slot is half a mile because twelve miles is not a
/// landing minimum; `24` after a solidus is RVR 2400 because that is what a solidus means. Everything
/// outside those sets is refused, so a misread can only ever become a missing row — never a wrong number.
///
/// The published values were taken from all 196 charts in the local plate cache: after a solidus every
/// figure is a two-digit RVR in hundreds of feet (12–60, the low end being CAT II), and after a hyphen
/// every figure is a statute-mile visibility drawn from the set below.
enum MinimaValueParser {

    /// Fraction digits → sixteenths of a statute mile, built from the eighths the FAA publishes
    /// visibilities in. `12` is half a mile, `134` is one and three quarters; the leading whole number is
    /// simply printed against the fraction, so the key is the digits as they appear with no solidus.
    static let fractionWhitelist: [String: Int] = {
        let eighths = [("18", 2), ("14", 4), ("38", 6), ("12", 8), ("58", 10), ("34", 12), ("78", 14)]
        var out: [String: Int] = [:]
        for (digits, sixteenths) in eighths {
            // A bare eighth of a mile is not a landing minimum — the lowest published visibility is a
            // quarter — and admitting it would let `18` in a statute-mile slot become ⅛ when the digits
            // are far more likely to be part of something else. Mixed numbers built on eighths ARE
            // published (Boston's RNAV 15R prints 1⅛), so those are kept.
            if digits != "18" { out[digits] = sixteenths }
            for whole in 1...4 { out["\(whole)" + digits] = whole * 16 + sixteenths }
        }
        return out
    }()
    /// Whole statute miles that appear as landing or circling visibilities.
    static let wholeMiles: Set<Int> = [1, 2, 3, 4, 5]
    /// Height above touchdown, or above the airport when circling, is bounded in practice: a few hundred
    /// feet for a precision approach and under about two thousand for a high circling minimum. The bound
    /// is what rules out reading `18200` as a one-mile visibility followed by an 8,200 ft height.
    static let maxHeightAboveFt = 3_000

    private static let fractionChars = "½¼¾⅛⅜⅝⅞"

    // MARK: entry point

    /// `218/18 200 (200-½)` → the structured cell. nil when the text is not a complete published value.
    static func parse(_ raw: String) -> PlateMinima.Value? {
        let text = normalise(raw)
        guard !text.isEmpty else { return nil }
        let upper = text.uppercased()
        if upper == "NA" || upper == "N/A" { return .na(raw) }
        if let v = parseCatII(text, raw: raw) { return v }
        return parseStandard(text, raw: raw)
    }

    static func normalise(_ raw: String) -> String {
        raw.replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "#", with: "")
            .replacingOccurrences(of: "\u{2010}", with: "-")      // hyphen variants used by the typesetter
            .replacingOccurrences(of: "\u{2013}", with: "-")
            .replacingOccurrences(of: "\u{2212}", with: "-")
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: standard straight-in and circling cells

    /// `ALT/RVR HAT (CEILING-VIS)` for a straight-in line, `MDA-VIS HAA (CEILING-VIS)` for circling.
    ///
    /// Parsed with the SPACES REMOVED. The sweep cannot reliably tell a typeset space from a wide
    /// character, so `640-1¾ 623` has arrived as both `640-134623` and `6 4 0-134 623`; requiring
    /// whitespace in the grammar would refuse rows that are perfectly legible, and trusting it would
    /// split numbers. Removing it makes the two identical and leaves the structure to carry the meaning.
    ///
    /// That structure is unambiguous after a solidus, where the RVR is always exactly two digits. After a
    /// hyphen the visibility and the height that follows it run together — `134623` — so every split is
    /// tried and one must survive: the visibility has to be a published one, the height has to be
    /// plausible, and where the plate repeats the visibility inside the parentheses the two must agree.
    /// More than one surviving split means the cell was not understood, and it is refused.
    static func parseStandard(_ text: String, raw: String) -> PlateMinima.Value? {
        let t = text.filter { !$0.isWhitespace }
        let visGlyphs = "[\(fractionChars)]"
        let pattern = "^(\\d{2,5})([/-])((?:\\d|\(visGlyphs))+)(?:\\((\\d{2,5})-((?:\\d|\(visGlyphs))+)\\))?$"
        guard let m = PlateNoteParser.firstMatch(pattern, in: t), m.count >= 4 else { return nil }
        guard let alt = Int(m[1]), alt >= 0, alt <= 20_000 else { return nil }

        var ceiling: Int?
        var parenVis: Int?
        if m.count > 5, !m[4].isEmpty {
            guard let fixed = repairParenthetical(ceiling: m[4], visibility: m[5]),
                  let v = statuteSixteenths(fixed.visibility), fixed.ceiling <= 20_000 else { return nil }
            ceiling = fixed.ceiling
            parenVis = v
        }

        guard let (visibility, hat) = splitVisibilityAndHeight(m[3],
                                                               afterSolidus: m[2] == "/",
                                                               parenSixteenths: parenVis) else { return nil }
        return PlateMinima.Value(altitudeFtMSL: alt,
                                 visibility: visibility,
                                 heightAboveFt: hat,
                                 ceilingFt: ceiling,
                                 isNA: false,
                                 rawText: raw.trimmingCharacters(in: .whitespaces),
                                 ceilingVisibility: parenVis.map { .statuteSixteenths($0) })
    }

    /// Split the run of digits after the separator into a visibility and the height above touchdown.
    /// Returns nil unless exactly one split is a published visibility followed by a plausible height.
    static func splitVisibilityAndHeight(_ run: String, afterSolidus: Bool,
                                         parenSixteenths: Int?) -> (PlateMinima.Visibility, Int?)? {
        let chars = Array(run)
        guard !chars.isEmpty, chars.count <= 9 else { return nil }
        var hits: [(PlateMinima.Visibility, Int?)] = []
        for take in 1...min(chars.count, 4) {                     // bounded (rule 2)
            let head = String(chars[0..<take])
            let tail = String(chars[take...])
            guard let vis = visibility(head, afterSolidus: afterSolidus) else { continue }
            // After a solidus the RVR is exactly two digits — anything else is a misread, not a variant.
            if afterSolidus, case .rvrFt = vis, take != 2 { continue }
            var hat: Int?
            if !tail.isEmpty {
                guard tail.count <= 4, tail.allSatisfy({ $0.isASCII && $0.isNumber }), let h = Int(tail),
                      h >= 10, h <= maxHeightAboveFt else { continue }
                hat = h
            }
            // Where the plate repeats the visibility in the parentheses, the two must agree. This is what
            // resolves `134623` into 1¾ and 623 rather than 1⅜ and 4623.
            if let p = parenSixteenths, !afterSolidus, case .statuteSixteenths(let s) = vis, s != p { continue }
            hits.append((vis, hat))
        }
        // After a solidus the two-digit RVR reading is the published one; a single-digit statute-mile
        // reading only ever survives alongside it by accident of arithmetic.
        let rvrHits = hits.filter { if case .rvrFt = $0.0 { return true } else { return false } }
        if afterSolidus, rvrHits.count == 1 { return rvrHits[0] }
        guard hits.count == 1 else { return nil }
        return hits[0]
    }

    /// Repair a parenthetical whose ceiling has swallowed the first digit of the visibility.
    ///
    /// `(300-1½)` can sweep as `3001-2`, because the raised numerator of the fraction anchors a shade to
    /// the left of the hyphen. Published ceilings are always whole hundreds of feet, so a ceiling that is
    /// not gives its trailing digits back to the visibility — a repair that can only ever move a digit
    /// from a slot where it is impossible to one where it must belong.
    static func repairParenthetical(ceiling: String, visibility: String) -> (ceiling: Int, visibility: String)? {
        guard let direct = Int(ceiling) else { return nil }
        if direct % 100 == 0 { return (direct, visibility) }
        let chars = Array(ceiling)
        for shift in 1...2 where shift < chars.count {            // bounded (rule 2)
            let head = String(chars[0..<(chars.count - shift)])
            let moved = String(chars[(chars.count - shift)...])
            guard let c = Int(head), c % 100 == 0, c >= 100 else { continue }
            let vis = moved + visibility
            if statuteSixteenths(vis) != nil { return (c, vis) }
        }
        return nil
    }

    // MARK: CAT II

    /// `CAT II RA 116/12 100 DA 116` — a Category II line, where the leading figure is a RADIO altimeter
    /// height and the decision altitude comes last. Read correctly or not at all: taking `116` for a
    /// decision altitude when it is a radio height would be right only at sea level and wrong by the
    /// field elevation everywhere else. The RVR floor is 1200 here, which is why a two-digit figure after
    /// the solidus is never treated as a fraction.
    static func parseCatII(_ text: String, raw: String) -> PlateMinima.Value? {
        // `RA` and even `CAT II` are printed hard against the row label and are often swept into it, so
        // the anchor that identifies this grammar is the trailing `DA`, not the leading `RA`.
        guard text.uppercased().contains("DA") else { return nil }
        let t = text.filter { !$0.isWhitespace }.uppercased()
        let pattern = #"^(?:CATII)?(?:RA)?(\d{2,4})/(\d{2})(\d{2,4})DA(\d{2,5})$"#
        guard let m = PlateNoteParser.firstMatch(pattern, in: t), m.count >= 5,
              let rvrHundreds = Int(m[2]), let hat = Int(m[3]), let da = Int(m[4]),
              rvrHundreds >= 10, rvrHundreds <= 75, da >= 0, da <= 20_000 else { return nil }
        return PlateMinima.Value(altitudeFtMSL: da,
                                 visibility: .rvrFt(rvrHundreds * 100),
                                 heightAboveFt: hat,
                                 ceilingFt: nil,
                                 isNA: false,
                                 rawText: raw.trimmingCharacters(in: .whitespaces))
    }

    // MARK: visibility decoding

    /// The figure in a visibility slot. After a solidus it is an RVR in hundreds of feet; after a hyphen
    /// it is statute miles.
    static func visibility(_ s: String, afterSolidus: Bool) -> PlateMinima.Visibility? {
        if afterSolidus {
            if s.count == 2, s.allSatisfy({ $0.isASCII && $0.isNumber }),
               let hundreds = Int(s), hundreds >= 10, hundreds <= 75 {
                return .rvrFt(hundreds * 100)
            }
            guard let sixteenths = statuteSixteenths(s) else { return nil }
            return .statuteSixteenths(sixteenths)
        }
        guard let sixteenths = statuteSixteenths(s) else { return nil }
        return .statuteSixteenths(sixteenths)
    }

    /// `1½` / `¾` / `2` / the bare digit pair `34` → sixteenths of a statute mile.
    static func statuteSixteenths(_ s: String) -> Int? {
        guard !s.isEmpty else { return nil }
        // Typeset with a real fraction glyph.
        if s.contains(where: { fractionChars.contains($0) }) { return mixedNumber(s) }
        guard s.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        if s.count == 1, let whole = Int(s), wholeMiles.contains(whole) { return whole * 16 }
        if let direct = fractionWhitelist[s] { return direct }
        // Some plates set the denominator a shade to the LEFT of the numerator, so a sweep in visual
        // order returns `141` where `114` — one and a quarter — is printed. The swap is only tried when
        // the direct reading is not a published visibility and only accepted when the swapped one is, so
        // it can turn a refusal into a real value but never one real value into another.
        guard s.count >= 2 else { return nil }
        var swapped = Array(s)
        swapped.swapAt(swapped.count - 1, swapped.count - 2)
        return fractionWhitelist[String(swapped)]
    }

    /// `1½` → 24 sixteenths.
    ///
    /// The whole part is taken as ASCII digits specifically: Swift counts a vulgar fraction as a number,
    /// so a plain `isNumber` prefix swallows the `½` it is supposed to be leaving behind.
    static func mixedNumber(_ s: String) -> Int? {
        var rest = Substring(s)
        var whole = 0
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        if !digits.isEmpty {
            guard let w = Int(digits), w <= 10 else { return nil }
            whole = w
            rest = rest.dropFirst(digits.count)
        }
        guard rest.count == 1, let f = rest.first else { return nil }
        let frac: Int
        switch f {
        case "⅛": frac = 2
        case "¼": frac = 4
        case "⅜": frac = 6
        case "½": frac = 8
        case "⅝": frac = 10
        case "¾": frac = 12
        case "⅞": frac = 14
        default: return nil
        }
        return whole * 16 + frac
    }
}
