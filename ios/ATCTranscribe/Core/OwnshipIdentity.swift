import Foundation

/// The iPad pilot's OWN aircraft identity, derived from the filed flight plan (callsign + aircraft
/// type). It decides whether a CONTROLLER transmission is ADDRESSED TO OWNSHIP — including the standard
/// ATC shorthands of a GA registration — WITHOUT ever firing on another aircraft or a mere mention.
///
/// Matching against ONE known callsign (not blind extraction) is what makes abbreviation safe: a heard
/// span addresses ownship only if it is a recognized VARIATION of the known callsign AND is in an
/// addressing position — immediately followed by a controller instruction word (drop-through a single
/// acknowledgement filler), NOT preceded by a traffic/sequencing cue ("follow the …", "traffic …"), and
/// NOT the tail of a longer callsign.
///
/// Accepted variations of a GA tail like N8925T (body "8925T", type "Seneca"):
///   • full callsign        — "November 8 9 2 5 Tango"  /  "N8925T"
///   • body (drop the N)    — "8 9 2 5 Tango"          /  "8925T"
///   • a TYPE-cued suffix (≥3 chars) — "Seneca 2 5 Tango"
/// Deliberately NOT accepted (each would fire on a DIFFERENT aircraft):
///   • a BARE suffix with no cue ("2 5 Tango") — could be any aircraft sharing the suffix;
///   • a COUNTRY-cued suffix ("November 2 5 Tango") — that is byte-identical to the FULL callsign of a
///     shorter registration (N25T), so it is another aircraft's callsign, not ours.
/// (Type cues are safe because no aircraft is registered under a type word.) For a non-GA (airline)
/// callsign only the full spoken/alnum forms are accepted — ATC does not suffix-abbreviate them.
///
/// NASA/JPL Power-of-10: every loop is statically bounded (variant count is bounded by the registration
/// length, ≤ `maxRegChars`); no recursion; parameters validated with safe recovery; invariant asserts;
/// no function pointers.
struct OwnshipIdentity: Equatable {

    // Standard ICAO phonetic alphabet, embedded so this type is pure + testable with no knowledge base.
    private static let phonetic: [Character: String] = [
        "A": "alpha", "B": "bravo", "C": "charlie", "D": "delta", "E": "echo", "F": "foxtrot",
        "G": "golf", "H": "hotel", "I": "india", "J": "juliet", "K": "kilo", "L": "lima", "M": "mike",
        "N": "november", "O": "oscar", "P": "papa", "Q": "quebec", "R": "romeo", "S": "sierra",
        "T": "tango", "U": "uniform", "V": "victor", "W": "whiskey", "X": "xray", "Y": "yankee",
        "Z": "zulu",
    ]

    // Hard caps so every loop below is statically bounded (rule 2).
    static let maxRegChars = 8        // a US tail is N + ≤5; airline ICAO+number stays under this too
    static let maxCallsignChars = 12  // fold cap (airline names collapse longer)
    static let minCuedSuffix = 3      // ATC's "last three" — shorter suffixes are too ambiguous even cued
    static let maxTypeWords = 4
    static let maxVariants = 64
    static let maxTokens = 64

    // Controller instruction words that follow an ADDRESSED callsign (never a mention). Broad so a real
    // clearance to ownship is recognized; parsing the clearance itself is the parser's job.
    private static let instructionWords: Set<String> = [
        "cleared", "recleared", "contact", "turn", "climb", "descend", "descending", "maintain",
        "hold", "cross", "fly", "expect", "squawk", "taxi", "runway", "reduce", "increase", "proceed",
        "proceeding", "join", "report", "ident", "line", "lineup", "depart", "vacate", "continue",
        "direct", "say", "verify", "advise", "intercept", "cancel", "resume",
    ]
    // Benign acknowledgement fillers allowed BETWEEN ownship's callsign and its instruction word.
    private static let fillers: Set<String> = ["roger", "and", "then"]
    // Traffic / sequencing cues: when one precedes ownship's callsign, ownship is a MENTION, not addressed.
    private static let mentionCues: Set<String> = [
        "follow", "following", "behind", "traffic", "number", "caution", "wake", "pass", "after",
    ]
    // The mention lookback scans back to the clause start, halting at a `digit` or `instructionWords`
    // token — those bound a prior aircraft's clause, so the scan never reaches across another aircraft.

    let fullAlnum: String              // "N8925T"
    let bodyAlnum: String              // "8925T" (GA: leading country letter dropped), else == fullAlnum
    let isGATail: Bool
    let countryWord: String?           // "november" for an N-number (used only for callsign-start detection)
    let typeWords: [String]            // ["piper","seneca"] — meaningful lowercase words of the type
    private let variants: [[String]]   // accepted spoken-token sequences (multi- and one-token forms)

    var isValid: Bool { fullAlnum.count >= 2 && !variants.isEmpty }

    /// - Parameters:
    ///   - callsign: the filed callsign ("N8925T", "AAL1234").
    ///   - aircraftType: the filed type ("Piper Seneca") — its words become abbreviation cues.
    ///   - spokenCallsign: the knowledge-base spelling of the callsign as spoken tokens (airline
    ///     telephony + spelled tail), supplied by the caller; an extra accepted full-form variant.
    init(callsign: String, aircraftType: String, spokenCallsign: [String] = []) {
        let alnum = OwnshipIdentity.fold(callsign)
        let ga = OwnshipIdentity.looksLikeTail(alnum)
        let country = ga ? alnum.first.flatMap { OwnshipIdentity.phonetic[$0] } : nil
        let body = ga ? String(alnum.dropFirst()) : alnum
        let types = OwnshipIdentity.typeCues(aircraftType)
        fullAlnum = alnum
        isGATail = ga
        countryWord = country
        bodyAlnum = body
        typeWords = types
        variants = OwnshipIdentity.buildVariants(fullAlnum: alnum, bodyAlnum: body, isGA: ga,
                                                 typeWords: types, spoken: spokenCallsign)
        assert(variants.count <= OwnshipIdentity.maxVariants, "variant set exceeded its cap")
        assert(!ga || body.count == max(0, alnum.count - 1), "GA body must drop exactly the country letter")
    }

    // MARK: - Address test

    /// True when this NORMALIZED transmission (lowercased, per-digit-spaced — `normalizedDisplay`)
    /// ADDRESSES ownship: an accepted variation is immediately followed by a controller instruction
    /// (through one filler), is not preceded by a traffic/sequencing cue, and is not the tail of a
    /// longer callsign. Bounded scan.
    func isAddressed(inNormalized normalized: String) -> Bool {
        guard isValid, !normalized.isEmpty, normalized.count <= 512 else { return false }
        let tokens = ATCCommandParser.tokenize(normalized)
        guard !tokens.isEmpty else { return false }
        assert(tokens.count <= OwnshipIdentity.maxTokens, "tokenizer exceeded its cap")
        let bound = min(tokens.count, OwnshipIdentity.maxTokens)
        for v in variants.prefix(OwnshipIdentity.maxVariants) where addressedMatch(tokens, v, bound: bound) {
            return true
        }
        return false
    }

    /// A specific variant `v` occurs as a contiguous span that is (a) not the tail of a longer callsign
    /// (a digit-initial variant preceded by a digit), (b) not preceded by a traffic/sequencing mention
    /// cue, and (c) addressed — immediately followed by an instruction word, allowing one filler. Both
    /// loops statically bounded.
    private func addressedMatch(_ tokens: [String], _ v: [String], bound: Int) -> Bool {
        guard v.count >= 1, v.count <= OwnshipIdentity.maxTokens, v.count <= bound else { return false }
        let last = bound - v.count
        guard last >= 0 else { return false }
        for i in 0...last {                                            // bounded by maxTokens
            var match = true
            for j in 0..<v.count where tokens[i + j] != v[j] { match = false; break }
            guard match else { continue }
            if OwnshipIdentity.isTailContinuation(v, tokens, at: i) { continue }  // tail of a longer callsign
            if precededByMention(tokens, before: i) { continue }      // "follow the <ownship>" = mention
            let after = i + v.count
            if after < tokens.count, OwnshipIdentity.digit(tokens[after]) != nil { continue }  // longer number
            if instructionSoonAfter(tokens, from: after) { return true }
        }
        return false
    }

    /// True when a controller instruction appears immediately after ownship's callsign, or one token
    /// later when the first is a benign filler ("roger"/"and"/"then"). A DISTANT instruction does NOT
    /// count — it may belong to a later aircraft in the same transmission (that is the fail-safe).
    private func instructionSoonAfter(_ tokens: [String], from: Int) -> Bool {
        guard from >= 0, from < tokens.count else { return false }
        if OwnshipIdentity.instructionWords.contains(tokens[from]) { return true }
        if OwnshipIdentity.fillers.contains(tokens[from]), from + 1 < tokens.count,
           OwnshipIdentity.instructionWords.contains(tokens[from + 1]) { return true }
        return false
    }

    /// True when a traffic/sequencing cue ("follow the slow moving small blue …", "traffic a
    /// fast-moving …", "number two …") appears anywhere from ownship's callsign back to the start of its
    /// clause, marking ownship as a MENTION rather than the addressee. Skips articles/descriptors
    /// (however many), but HALTS at a digit (a prior aircraft's number/heading) or an instruction word (a
    /// prior clause) so it can never reach across another aircraft. Statically bounded by the token count.
    private func precededByMention(_ tokens: [String], before i: Int) -> Bool {
        guard i > 0 else { return false }
        var k = i - 1
        while k >= 0 {                                                // bounded by the token count (≤ maxTokens)
            let t = tokens[k]
            if OwnshipIdentity.mentionCues.contains(t) { return true }
            if OwnshipIdentity.digit(t) != nil || OwnshipIdentity.instructionWords.contains(t) { return false }
            k -= 1
        }
        return false
    }

    /// The parser's positional-binding descriptor: ownship's accepted variants + the words that begin
    /// ANY callsign (to find where the NEXT aircraft is addressed in a multi-aircraft transmission).
    func addressee(airlineStarts: Set<String>) -> ATCCommandParser.Addressee {
        var starts = airlineStarts
        if let cw = countryWord { starts.insert(cw) }
        starts.insert("november")
        for t in typeWords.prefix(OwnshipIdentity.maxTypeWords) { starts.insert(t) }
        return ATCCommandParser.Addressee(ownshipVariants: variants, callsignStarts: starts)
    }

    // MARK: - Builders (init-time only)

    private static func fold(_ s: String) -> String {
        String(s.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(maxCallsignChars))
    }

    /// A GA-style tail: 3–6 alnum, a LETTER then a DIGIT (so "N8925T" is a tail but airline "AAL1234",
    /// whose 2nd char is a letter, is not). US-centric but generalizes to any single-letter country prefix.
    private static func looksLikeTail(_ alnum: String) -> Bool {
        guard alnum.count >= 3, alnum.count <= maxRegChars else { return false }
        let chars = Array(alnum)
        return chars[0].isLetter && chars[1].isNumber
    }

    /// Lowercase, ≥3-letter words of the aircraft type ("Piper Seneca" → ["piper","seneca"]); short
    /// tokens ("172") and filler are dropped. These become abbreviation cues.
    private static func typeCues(_ type: String) -> [String] {
        var out: [String] = []
        let parts = type.lowercased().split(whereSeparator: { !$0.isLetter })
        for p in parts.prefix(maxTypeWords) where p.count >= 3 { out.append(String(p)) }
        return out
    }

    private static func spokenChars(_ alnum: String) -> [String] {
        alnum.prefix(maxRegChars).map { c in
            if c.isNumber { return String(c) }
            return phonetic[c] ?? String(c).lowercased()
        }
    }

    /// Enumerate the accepted spoken-token variants (multi-token spoken + one-token collapsed-alnum).
    /// Bounded by the registration length × the type-word cap, so the total is ≤ `maxVariants`.
    private static func buildVariants(fullAlnum: String, bodyAlnum: String, isGA: Bool,
                                      typeWords: [String], spoken: [String]) -> [[String]] {
        var variants: [[String]] = []
        func add(_ v: [String]) { if !v.isEmpty, variants.count < maxVariants, !variants.contains(v) { variants.append(v) } }

        if !spoken.isEmpty { add(spoken) }               // knowledge-spelled full form (airline + tail)
        add(spokenChars(fullAlnum))                      // per-char full form
        if fullAlnum.count >= 2 { add([fullAlnum.lowercased()]) }   // collapsed "n8925t"

        guard isGA, bodyAlnum.count >= 2 else { return variants }
        add(spokenChars(bodyAlnum))                      // body (drop the N) — the whole reg, no cue
        add([bodyAlnum.lowercased()])                    // collapsed "8925t"
        let n = bodyAlnum.count
        var len = minCuedSuffix
        while len < n {                                  // bounded by maxRegChars
            let suffixSpoken = spokenChars(String(bodyAlnum.suffix(len)))
            // TYPE-cued suffixes only ("seneca 2 5 tango"). NOT country-cued ("november 2 5 tango"),
            // which equals a shorter registration's FULL callsign and would fire on that other aircraft.
            for t in typeWords.prefix(maxTypeWords) { add([t] + suffixSpoken) }
            len += 1
        }
        return variants
    }

    // MARK: - token helpers

    /// True when a digit-initial variant match at `i` is really the TAIL of a longer callsign — i.e. the
    /// variant starts with a spoken digit AND the token immediately before it is also a digit (so it is
    /// mid-number, e.g. "8 9 2 5 tango" inside "november 1 8 9 2 5 tango"). A word-initial variant
    /// ("november …", "seneca …", "american …") is self-anchoring and never a tail, so a preceding digit
    /// (the previous aircraft's heading/altitude) does not disqualify it.
    static func isTailContinuation(_ v: [String], _ tokens: [String], at i: Int) -> Bool {
        guard i > 0, let first = v.first, digit(first) != nil else { return false }
        return digit(tokens[i - 1]) != nil
    }

    /// A single decimal-digit token → 0…9, else nil. Length-guarded so "42" is not a digit.
    static func digit(_ token: String) -> Int? {
        guard token.count == 1, let v = Int(token), v >= 0, v <= 9 else { return nil }
        return v
    }
}
