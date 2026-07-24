import Foundation

/// Composes spoken aviation numbers into machine values, operating on the pipeline's normalized token
/// stream where every numeral is already a single spaced digit (`ATCNormalize.normalize`) and only the
/// magnitude words `hundred` / `thousand` / `flight` / `level` / `point` survive as words. Each composer
/// is a short, statically-bounded scan that returns nil on any violation (NASA/JPL Power-of-10).
enum ATCNumberComposer {

    /// A radio number is short; every scan below is bounded by this constant (rule 2).
    static let maxNumberTokens = 8

    /// Read up to `count` consecutive single-digit tokens from `tokens[from...]`, preserving leading
    /// zeros. "0 9 0" → (text: "090", value: 90). nil when no digit is present.
    static func composeDigits(_ tokens: [String], from: Int, count: Int) -> (text: String, value: Int)? {
        guard from >= 0, from < tokens.count, count >= 1, count <= maxNumberTokens else { return nil }
        var text = ""
        var value = 0
        var read = 0
        let bound = min(tokens.count, from + count)
        var i = from
        while i < bound {                                          // bounded by count (≤ maxNumberTokens)
            guard let d = ATCCommandParser.digit(tokens[i]) else { break }
            text.append(Character(String(d)))
            value = value * 10 + d
            read += 1
            i += 1
        }
        guard read >= 1 else { return nil }
        assert(text.count == read, "digit text length must equal the number of digits read")
        assert(value >= 0, "composed digit value must be non-negative")
        return (text, value)
    }

    /// Compose an altitude in feet: "8 thousand" → 8000; "8 thousand 5 hundred" → 8500; "5 hundred" → 500;
    /// "flight level 1 8 0" → 18000 (text "FL180"); a bare "3 0 0 0" → 3000. Gated to 0…60000 and a
    /// 100-ft increment. Returns (display text, feet).
    static func composeAltitude(_ tokens: [String], from: Int) -> (text: String, value: Int)? {
        guard from >= 0, from < tokens.count else { return nil }
        if tokens[from] == "flight", from + 1 < tokens.count, tokens[from + 1] == "level" {
            guard let fl = composeDigits(tokens, from: from + 2, count: 3), fl.text.count == 3 else { return nil }
            let value = fl.value * 100
            guard value >= 1000, value <= 60000 else { return nil }
            return ("FL" + fl.text, value)
        }
        guard let lead = composeDigits(tokens, from: from, count: 3) else { return nil }
        let afterLead = from + lead.text.count
        var value: Int
        if afterLead < tokens.count, tokens[afterLead] == "thousand" {
            value = lead.value * 1000
            let hundredsAt = afterLead + 1
            if let h = composeDigits(tokens, from: hundredsAt, count: 2),
               hundredsAt + h.text.count < tokens.count, tokens[hundredsAt + h.text.count] == "hundred" {
                value += h.value * 100
            }
        } else if afterLead < tokens.count, tokens[afterLead] == "hundred" {
            value = lead.value * 100
        } else {
            value = composeDigits(tokens, from: from, count: 5)?.value ?? lead.value   // bare "3 0 0 0"
        }
        guard value >= 0, value <= 60000, value % 100 == 0 else { return nil }
        return (String(value), value)
    }

    /// Compose a heading: exactly three digits, kept zero-padded ("0 9 0" → "090"). Gated to 1…360.
    static func composeHeading(_ tokens: [String], from: Int) -> (text: String, value: Int)? {
        guard let d = composeDigits(tokens, from: from, count: 3), d.text.count == 3 else { return nil }
        guard d.value >= 1, d.value <= 360 else { return nil }
        return (d.text, d.value)
    }

    /// Compose an airspeed in knots: two or three digits, gated to 40…400.
    static func composeSpeed(_ tokens: [String], from: Int) -> (text: String, value: Int)? {
        guard let d = composeDigits(tokens, from: from, count: 3), d.text.count >= 2 else { return nil }
        guard d.value >= 40, d.value <= 400 else { return nil }
        return (String(d.value), d.value)
    }

    /// Compose a transponder squawk: exactly four OCTAL digits (0…7), kept as a 4-char string ("1 2 0 0"
    /// → "1200"). Rejects any digit 8/9 (impossible on a transponder) or a wrong length.
    static func composeSquawk(_ tokens: [String], from: Int) -> (text: String, value: Int)? {
        guard from >= 0, from + 3 < tokens.count else { return nil }
        var text = ""
        var value = 0
        for k in 0..<4 {                                          // bounded (constant)
            guard let d = ATCCommandParser.digit(tokens[from + k]), d <= 7 else { return nil }
            text.append(Character(String(d)))
            value = value * 10 + d
        }
        assert(text.count == 4, "a squawk must be exactly four digits")
        return (text, value)
    }

    /// Compose a VHF COM frequency: "1 D D point D(D)(D)" or point-less "1 D D D(D)". Gated to the airband
    /// 118.000…136.975. Returns (display "124.5", MHz). value is left to the caller (kept as the string).
    static func composeFrequency(_ tokens: [String], from: Int) -> (text: String, mhz: Double)? {
        guard from >= 0, from + 2 < tokens.count else { return nil }
        guard let a = ATCCommandParser.digit(tokens[from]), a == 1,
              let b = ATCCommandParser.digit(tokens[from + 1]),
              let c = ATCCommandParser.digit(tokens[from + 2]) else { return nil }
        let intPart = a * 100 + b * 10 + c
        var idx = from + 3
        if idx < tokens.count, tokens[idx] == "point" { idx += 1 }
        var frac = ""
        var read = 0
        while idx < tokens.count, read < 3, let d = ATCCommandParser.digit(tokens[idx]) {   // bounded (≤3)
            frac.append(Character(String(d)))
            idx += 1
            read += 1
        }
        guard read >= 1 else { return nil }
        let mhz = Double(intPart) + Double(Int(frac) ?? 0) / pow(10.0, Double(frac.count))
        guard mhz >= 118.0, mhz <= 136.975 else { return nil }
        assert(frac.count >= 1, "a frequency must have a fractional part")
        return ("\(intPart)." + frac, mhz)
    }
}
