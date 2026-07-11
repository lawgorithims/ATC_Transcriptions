import Foundation

// ATC command interpreter (Phase 4). Turns a finished CONTROLLER transmission into a single, grounded,
// actionable Electronic-Flight-Bag command — "cleared direct BOSOX" → route direct-to; "cleared ILS
// runway 4 right" → preview that approach. It only PROPOSES: the UI requires a tap before anything
// changes, and a command is emitted only for a transmission addressed to the pilot's own aircraft.
//
// This file follows the NASA/JPL "Power of 10" rules (Swift adaptation): simple control flow with no
// recursion; every loop has a fixed, statically-provable bound; small functions; parameters validated
// on entry with explicit recovery (return nil); assertions guard invariants that must never hold.

/// The closed set of controller clearances the app can act on. Small ON PURPOSE: each maps to one
/// existing, reversible EFB action, so the interpreter never has to guess an effect.
enum ATCCommandKind: String, Equatable, Sendable {
    case directTo          // proceed/cleared direct <FIX or AIRPORT>
    case clearedApproach   // cleared <ILS|RNAV|VOR|LOC|…> (approach)? runway <RR>
    case loadSID           // climb via the <NAME> <n> departure
    case loadStar          // descend via the <NAME> <n> arrival
}

/// A parsed, grounded clearance. `target` is a fix/airport ident (directTo), a runway designator
/// (clearedApproach), or a procedure ARINC ident (loadSID/loadStar); `qualifier` is the approach type,
/// "airport" for a direct-to-airport, else "". Pure value type — trivially testable.
struct ATCCommand: Equatable, Sendable {
    let kind: ATCCommandKind
    let target: String
    let qualifier: String
}

enum ATCCommandParser {

    /// Who a transmission must be addressed to for a command to fire — used to POSITIONALLY bind a
    /// clearance to ownship when several aircraft are named in one transmission. `ownshipTokens` is the
    /// pilot's own callsign as NORMALIZED spoken tokens (e.g. `["american","1","2","3"]` or
    /// `["november","3","4","5","alpha","bravo"]`); `callsignStarts` are the words that BEGIN any callsign
    /// (airline telephony names, "november", GA type words), used to find where the NEXT aircraft is addressed.
    struct Addressee: Equatable {
        let ownshipTokens: [String]
        let callsignStarts: Set<String>
    }

    /// The grounded data a clearance must match, so the parser only ever proposes a REAL target: filed /
    /// nearby fix idents (direct-to fix), airport ICAO codes (direct-to airport), and the active airport's
    /// coded SID / STAR ARINC idents (procedure loads). Empty sets simply disable that clearance class.
    struct Grounding {
        var fixes: Set<String> = []
        var airports: Set<String> = []
        var sids: [String] = []
        var stars: [String] = []
    }

    // Hard caps so every loop below is statically bounded (rule 2). A radio transmission is short.
    static let maxChars = 512
    static let maxTokens = 64
    static let maxCallsignChars = 32
    static let maxCallsignTokens = 12
    static let minFixLen = 3
    static let maxFixLen = 6

    private static let directAnchors: Set<String> = ["direct", "directly"]
    private static let approachTypes: [String: String] = [
        "ils": "ILS", "rnav": "RNAV", "gps": "RNAV", "visual": "visual", "localizer": "LOC",
        "vor": "VOR", "ndb": "NDB", "lda": "LDA", "sdf": "SDF", "tacan": "TACAN", "rnp": "RNP",
    ]
    private static let sides: [String: String] = ["left": "L", "right": "R", "center": "C"]

    // SID/STAR: a load fires only in a positive-clearance context with a real, uniquely-matched procedure.
    // `procedureVerbs` are the phraseology that opens the window ("climb/descend via the … departure").
    private static let procedureVerbs: Set<String> = [
        "climb", "descend", "cleared", "recleared", "proceed", "via", "fly", "join", "resume",
    ]
    // A retraction/self-correction word ANYWHERE makes every single procedure match unreliable (the
    // controller is changing or cancelling what they said), so its presence forces an abstain.
    private static let retractionTokens: Set<String> = ["disregard", "cancel", "correction", "belay"]
    // A STRONG negation of the just-named procedure, checked only in the short window right AFTER the
    // keyword ("… departure is no longer in use" / "… is not authorized"). Soft anticipatory words
    // (when/after/expect/if/hold) are deliberately EXCLUDED so "… departure when able direct …" still
    // fires. Kept a strict subset of `negators`.
    private static let strongNegators: Set<String> = ["not", "no", "longer", "unable", "negative"]
    static let maxProcedures = 512
    static let maxIdentLen = 16

    // A clearance fires ONLY inside a positive clearance window — never on an anticipatory ("expect"),
    // denied ("unable"), or negated ("not cleared") mention. `clearanceVerbs` opens the window; a
    // `negators` word in the window closes it. `approachFiller` are the only words allowed between the
    // "cleared" anchor and the approach type.
    private static let clearanceVerbs: Set<String> = ["cleared", "recleared", "proceed", "proceeding", "fly"]
    private static let negators: Set<String> = [
        "expect", "unable", "request", "requesting", "when", "after", "no", "longer",
        "hold", "cancel", "disregard", "negative", "not", "able", "if",
    ]
    private static let approachFiller: Set<String> = ["for", "the"]
    private static let clearanceWindow = 3

    // MARK: - Ownship gate

    /// True when a transmission about `subject` (ADS-B key `subjectKey`) is addressed to the pilot's own
    /// aircraft `own`. Empty `own` NEVER matches — with no known ownship we must not act (safety default).
    /// Compares on the alphanumeric-folded form so "American 1234", "AAL1234", "aal 1234" all match.
    static func addressesOwnship(subject: String?, subjectKey: String?, own: String) -> Bool {
        let ownFold = fold(own)
        guard !ownFold.isEmpty else { return false }                 // no ownship set → never act
        assert(ownFold.count <= maxCallsignChars, "ownship fold exceeded cap")
        let subjectFold = fold(subject ?? "")
        let keyFold = fold(subjectKey ?? "")
        guard !subjectFold.isEmpty || !keyFold.isEmpty else { return false }   // names no aircraft
        return subjectFold == ownFold || keyFold == ownFold
    }

    /// Uppercased, alphanumeric-only fold of a callsign, capped at `maxCallsignChars`. The scan is
    /// statically bounded by `maxChars` (a constant) regardless of the input's content (rule 2).
    static func fold(_ s: String) -> String {
        guard !s.isEmpty else { return "" }
        var out = ""
        out.reserveCapacity(maxCallsignChars)
        for ch in s.uppercased().prefix(maxChars) {                  // bounded by maxChars (constant)
            if out.count >= maxCallsignChars { break }
            if ch.isLetter || ch.isNumber { out.append(ch) }
        }
        assert(out.count <= maxCallsignChars, "fold exceeded cap")
        return out
    }

    // MARK: - Parse

    /// Parse a NORMALIZED controller transcript (lowercase, per-digit-spaced — `TranscriptRecord.
    /// normalizedDisplay`) into one actionable command, or nil. `grounding` supplies the REAL targets each
    /// clearance class must match. When `addressee` is supplied AND the transmission names more than one
    /// aircraft, the clearance is bound to ownship's own segment, so a clearance to another aircraft in the
    /// same transmission never fires. Ordered most- to least-specific; first match wins.
    static func parse(_ normalized: String, grounding: Grounding, addressee: Addressee? = nil) -> ATCCommand? {
        guard !normalized.isEmpty, normalized.count <= maxChars else { return nil }   // param check
        let tokens = tokenize(normalized)
        guard tokens.count >= 2 else { return nil }
        assert(tokens.count <= maxTokens, "tokenizer exceeded its cap")
        // A single-aircraft transmission (0 or 1 callsign named) parses whole — current behavior. Only a
        // MULTI-aircraft transmission is restricted to ownship's segment; if ownship's segment can't be
        // located there, abstain (a wrong suggestion is worse than a miss).
        var scoped = tokens
        if let addressee, boundaryCount(tokens, starts: addressee.callsignStarts) > 1 {
            guard let range = ownshipSegment(tokens, addressee: addressee) else { return nil }
            scoped = Array(tokens[range])
        }
        if let direct = parseDirectTo(scoped, fixes: grounding.fixes, airports: grounding.airports) { return direct }
        if let approach = parseApproach(scoped) { return approach }
        if let sid = parseProcedure(scoped, idents: grounding.sids, keyword: "departure", kind: .loadSID) { return sid }
        return parseProcedure(scoped, idents: grounding.stars, keyword: "arrival", kind: .loadStar)
    }

    /// Backward-compatible convenience: parse with only grounded direct-to FIX idents (the pre-Phase-6
    /// entry point). Validates its parameter (rule 7).
    static func parse(_ normalized: String, knownFixes: Set<String>, addressee: Addressee? = nil) -> ATCCommand? {
        parse(normalized, grounding: Grounding(fixes: knownFixes), addressee: addressee)
    }

    /// How many callsign-start words the transmission names — a cheap aircraft count. Statically bounded.
    static func boundaryCount(_ tokens: [String], starts: Set<String>) -> Int {
        guard !starts.isEmpty else { return 0 }
        let bound = min(tokens.count, maxTokens)
        var count = 0
        for i in 0..<bound where starts.contains(tokens[i]) { count += 1 }   // bounded by maxTokens
        assert(count <= maxTokens, "boundary count exceeded token cap")
        return count
    }

    /// The token range addressed to ownship: from where ownship's callsign appears to the next aircraft's
    /// callsign (or the end). nil when ownship isn't named, or is only a prefix of a longer callsign
    /// ("american 1 2 3" must not match "american 1 2 3 4"). Bounded scans.
    static func ownshipSegment(_ tokens: [String], addressee: Addressee) -> Range<Int>? {
        let own = addressee.ownshipTokens
        guard own.count >= 1, own.count <= maxCallsignTokens else { return nil }
        guard let start = subsequenceIndex(tokens, own) else { return nil }
        let afterCallsign = start + own.count
        if afterCallsign < tokens.count, digit(tokens[afterCallsign]) != nil { return nil }  // longer number
        let end = boundaryAfter(tokens, from: afterCallsign, starts: addressee.callsignStarts)
        guard start < end else { return nil }
        return start..<end
    }

    /// The first index at which `sub` occurs as a contiguous subsequence of `tokens`, or nil. Both loops
    /// are statically bounded (outer by maxTokens, inner by maxCallsignTokens).
    static func subsequenceIndex(_ tokens: [String], _ sub: [String]) -> Int? {
        guard !sub.isEmpty, sub.count <= maxCallsignTokens, sub.count <= tokens.count else { return nil }
        let last = min(tokens.count, maxTokens) - sub.count
        guard last >= 0 else { return nil }
        for i in 0...last {                                              // bounded by maxTokens
            var match = true
            for j in 0..<min(sub.count, maxCallsignTokens) {            // bounded by maxCallsignTokens
                if tokens[i + j] != sub[j] { match = false; break }
            }
            if match { return i }
        }
        return nil
    }

    /// The first index >= `from` whose token starts a callsign (another aircraft), else `tokens.count`.
    static func boundaryAfter(_ tokens: [String], from: Int, starts: Set<String>) -> Int {
        guard from >= 0 else { return tokens.count }
        let bound = min(tokens.count, maxTokens)
        var k = from
        while k < bound {                                               // bounded by maxTokens
            if starts.contains(tokens[k]) { return k }
            k += 1
        }
        return tokens.count
    }

    /// Split into at most `maxTokens` word tokens. Bounded allocation + bounded loop (rules 2, 3).
    static func tokenize(_ s: String) -> [String] {
        guard !s.isEmpty else { return [] }
        let parts = s.split(separator: " ", omittingEmptySubsequences: true)
        var out: [String] = []
        out.reserveCapacity(maxTokens)
        let bound = min(parts.count, maxTokens)
        for i in 0..<bound { out.append(String(parts[i])) }          // statically bounded by maxTokens
        assert(out.count <= maxTokens, "token cap violated")
        return out
    }

    /// "... (cleared|proceed) direct <FIX or AIRPORT> ..." → directTo. Fires ONLY when a clearance verb
    /// opens the short window before "direct" and no negator closes it, so "expect direct X" / "unable
    /// direct X" abstain. The token after the anchor must be a GROUNDED fix (in `fixes`) or a grounded
    /// 4-letter airport ICAO (in `airports`). Bounded scan.
    static func parseDirectTo(_ tokens: [String], fixes: Set<String>, airports: Set<String>) -> ATCCommand? {
        guard tokens.count >= 2, !(fixes.isEmpty && airports.isEmpty) else { return nil }
        assert(tokens.count <= maxTokens, "directTo scan over an oversized token list")
        let bound = min(tokens.count, maxTokens) - 1                 // last index has no successor
        for i in 0..<bound {                                         // statically bounded
            guard directAnchors.contains(tokens[i]), clearedBefore(tokens, index: i) else { continue }
            let candidate = tokens[i + 1].uppercased()
            if isFixShaped(candidate), fixes.contains(candidate) {
                return ATCCommand(kind: .directTo, target: candidate, qualifier: "")
            }
            if isAirportShaped(candidate), airports.contains(candidate) {
                return ATCCommand(kind: .directTo, target: candidate, qualifier: "airport")
            }
        }
        return nil
    }

    /// A 4-letter ICAO airport ident ("KPVD", "KBOS"). Distinct from a fix (rules out the 5-letter fixes).
    static func isAirportShaped(_ s: String) -> Bool {
        s.count == 4 && s.allSatisfy(\.isLetter)
    }

    /// True when a clearance verb appears in the `clearanceWindow`-token span before `index` and NO
    /// negator does — so "cleared/proceed direct" fires but "expect/unable/no longer direct" do not. A
    /// bare leading "direct" (index 0, no verb) never fires. Statically bounded (window is a constant).
    static func clearedBefore(_ tokens: [String], index: Int) -> Bool {
        guard index >= 1, index <= tokens.count else { return false }
        let low = max(0, index - clearanceWindow)
        var sawClearance = false
        for j in low..<index {                                       // bounded by clearanceWindow
            if negators.contains(tokens[j]) { return false }
            if clearanceVerbs.contains(tokens[j]) { sawClearance = true }
        }
        return sawClearance
    }

    /// "... cleared (for|the)? <ILS|RNAV|GPS|visual|localizer> ... runway <D D> (left|right|center)?"
    /// → clearedApproach. The approach TYPE must IMMEDIATELY follow a "cleared" anchor (only for/the may
    /// intervene), the anchor must not be negated ("not cleared"), so "cleared as filed … expect the ils"
    /// and "cancel approach clearance" abstain. Bounded scan.
    static func parseApproach(_ tokens: [String]) -> ATCCommand? {
        guard tokens.count >= 4 else { return nil }
        assert(tokens.count <= maxTokens, "approach scan over an oversized token list")
        let bound = min(tokens.count, maxTokens)
        for i in 0..<bound {                                         // statically bounded
            guard tokens[i] == "cleared" else { continue }
            if i >= 1, negators.contains(tokens[i - 1]) { continue } // "not/unable cleared …"
            guard let typeIndex = approachTypeIndex(tokens, after: i) else { continue }
            let type = approachTypes[tokens[typeIndex]] ?? ""
            if !type.isEmpty, let runway = runwayAfter(tokens, from: typeIndex + 1) {
                return ATCCommand(kind: .clearedApproach, target: runway, qualifier: type)
            }
        }
        return nil
    }

    /// Index of the approach-type token immediately after a "cleared" anchor at `after`, allowing only a
    /// short for/the filler gap; nil if the next meaningful token is not an approach type. Bounded window.
    static func approachTypeIndex(_ tokens: [String], after anchor: Int) -> Int? {
        guard anchor >= 0, anchor < tokens.count else { return nil }
        let limit = min(tokens.count, anchor + 1 + 3)                // ≤ 3-token gap (anchor + filler)
        var j = anchor + 1
        while j < limit {                                            // bounded by the constant window
            if approachTypes[tokens[j]] != nil { return j }
            guard approachFiller.contains(tokens[j]) else { return nil }
            j += 1
        }
        return nil
    }

    // MARK: - SID / STAR (grounded, conservative)

    /// "... climb/descend via the <NAME> <n> departure|arrival ..." → loadSID / loadStar. CONSERVATIVE:
    /// fires ONLY when a positive procedure verb opens the context, the name is NOT negated in the short
    /// window around it, the transmission carries NO retraction ("disregard"/"correction"/"cancel"), and
    /// the spoken "<NAME> <n>" resolves to exactly ONE real procedure ident (first-letter + consonant
    /// skeleton + exact version digit). If two DISTINCT procedures are named in one transmission, or any is
    /// retracted, it abstains — a wrong SID/STAR load is worse than a miss. Bounded scan.
    static func parseProcedure(_ tokens: [String], idents: [String], keyword: String, kind: ATCCommandKind) -> ATCCommand? {
        guard !idents.isEmpty, tokens.count >= 3 else { return nil }
        assert(kind == .loadSID || kind == .loadStar, "parseProcedure only loads SID/STAR")
        guard !containsRetraction(tokens) else { return nil }        // controller changed their mind → abstain
        let bound = min(tokens.count, maxTokens)
        assert(bound <= maxTokens, "procedure scan over an oversized token list")
        var resolved: String?
        for k in 2..<bound where tokens[k] == keyword {              // keyword ("departure"/"arrival")
            guard digit(tokens[k - 1]) != nil else { continue }      // version digit at k-1
            let base = tokens[k - 2]
            guard base.count >= 2, base.allSatisfy(\.isLetter) else { continue }
            guard positiveVerbBefore(tokens, index: k), cleanAround(tokens, base: k - 2, keyword: k) else { continue }
            guard let ident = uniqueProcedureIdent(base: base, version: tokens[k - 1], idents: idents) else { continue }
            if let prior = resolved, prior != ident { return nil }   // two DISTINCT procedures named → ambiguous
            resolved = ident
        }
        return resolved.map { ATCCommand(kind: kind, target: $0, qualifier: "") }
    }

    /// True when the transmission carries a retraction/self-correction word anywhere — the controller is
    /// changing or cancelling what they said, so any single procedure match is unreliable. Bounded scan.
    static func containsRetraction(_ tokens: [String]) -> Bool {
        guard !tokens.isEmpty else { return false }
        let bound = min(tokens.count, maxTokens)
        assert(bound <= maxTokens, "retraction scan over an oversized token list")
        for i in 0..<bound where retractionTokens.contains(tokens[i]) { return true }   // bounded by maxTokens
        return false
    }

    /// No clearance-negating word sits around the procedure name: a full negator in the short window just
    /// BEFORE the base ("expect the blazzer 6 departure"), or a strong negation in the short window just
    /// AFTER the keyword ("… departure is no longer in use" / "… is not authorized"). Soft anticipatory
    /// words after the keyword ("when able direct …") are allowed, so a valid load still fires. Bounded.
    static func cleanAround(_ tokens: [String], base: Int, keyword: Int) -> Bool {
        guard base >= 0, keyword > base, keyword < tokens.count else { return false }   // param check → unsafe
        let beforeLow = max(0, base - clearanceWindow)
        for i in beforeLow..<base where negators.contains(tokens[i]) { return false }   // bounded by window
        let afterHigh = min(tokens.count, keyword + 1 + clearanceWindow)
        assert(afterHigh - keyword <= clearanceWindow + 1, "after-window exceeded its constant span")
        var i = keyword + 1
        while i < afterHigh {                                                           // bounded by window
            if strongNegators.contains(tokens[i]) { return false }
            i += 1
        }
        return true
    }

    /// The single airport procedure ident whose trailing version digits equal `version`, whose FIRST
    /// letter matches the spoken base's, AND whose base's consonant skeleton equals the spoken `base`'s —
    /// or nil if none or MORE THAN ONE match (ambiguous → abstain). The first-letter check disambiguates
    /// vowel-initial twins the skeleton alone would collapse ("ASPEN" vs "ESPEN"). Duplicate copies of the
    /// same ident (one per transition) are not ambiguity. NOTE: a vowel-dropped ARINC ident cannot separate
    /// same-first-letter, same-skeleton names ("BOSTON" vs "BASTION"); single-airport grounding (where such
    /// twins essentially never co-occur) keeps that safe — vicinity-wide uniqueness is the future guard.
    static func uniqueProcedureIdent(base: String, version: String, idents: [String]) -> String? {
        let upper = base.uppercased()
        let wanted = consonantSkeleton(upper)
        guard wanted.count >= 2, let firstLetter = upper.first else { return nil }   // too short to disambiguate
        var found: String?
        for ident in idents.prefix(maxProcedures) {                  // bounded by the cap
            let split = identBaseVersion(ident)
            guard split.version == version, split.base.first == firstLetter,
                  consonantSkeleton(split.base) == wanted else { continue }
            if let f = found, f != ident { return nil }              // two DISTINCT idents → ambiguous
            found = ident
        }
        assert(found?.isEmpty != true, "a matched procedure ident must be non-empty")
        return found
    }

    /// Uppercased consonants only (vowels AEIOU removed) — matches a spoken procedure name against a
    /// vowel-dropped ARINC ident ("BLAZZER" ↔ "BLZZR"). Bounded by `maxIdentLen`.
    static func consonantSkeleton(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(maxIdentLen)
        for ch in s.uppercased().prefix(maxIdentLen) {               // bounded by the constant
            if ch.isLetter, !"AEIOU".contains(ch) { out.append(ch) }
        }
        return out
    }

    /// Split an ARINC procedure ident into (leading letters base, trailing digits version): "BLZZR6" →
    /// ("BLZZR","6"), "OOSHN5" → ("OOSHN","5"). Bounded scan from the end.
    static func identBaseVersion(_ ident: String) -> (base: String, version: String) {
        let chars = Array(ident.uppercased().prefix(maxIdentLen))
        var split = chars.count
        var i = chars.count - 1
        while i >= 0, chars[i].isNumber { split = i; i -= 1 }        // bounded by maxIdentLen
        return (String(chars[0..<split]), String(chars[split..<chars.count]))
    }

    /// True when a positive procedure verb (climb/descend/via/cleared…) appears before `index`. The verb
    /// may be far from the name (a SID is often "cleared to <apt> as filed <name> <n> departure"), so this
    /// scans the whole prefix. `index` is validated so the loop is provably in-range (bounded by
    /// tokens.count as well as the constant cap) regardless of caller (rules 2, 7).
    static func positiveVerbBefore(_ tokens: [String], index: Int) -> Bool {
        guard index >= 0, index <= tokens.count else { return false }   // param check (rule 7)
        let bound = min(index, maxTokens)
        assert(bound <= tokens.count, "verb-scan bound must not exceed tokens.count")
        for i in 0..<bound where procedureVerbs.contains(tokens[i]) { return true }   // provably in-range
        return false
    }

    // MARK: - Grounded token shapes

    /// A runway designator at/after `from`: optional "runway", a 1–2 digit heading (1…36), optional side.
    /// Returns a zero-padded "04R" / "31" or nil. All indices bound-checked before use (rule 7).
    static func runwayAfter(_ tokens: [String], from: Int) -> String? {
        guard from >= 0, from < tokens.count else { return nil }
        var i = from
        if tokens[i] == "runway" { i += 1 }
        guard i < tokens.count, let d0 = digit(tokens[i]) else { return nil }
        var number = d0
        i += 1
        if i < tokens.count, let d1 = digit(tokens[i]) { number = number * 10 + d1; i += 1 }
        guard number >= 1, number <= 36 else { return nil }          // a real runway heading
        let suffix = (i < tokens.count) ? (sides[tokens[i]] ?? "") : ""
        let numberText = number < 10 ? "0\(number)" : "\(number)"
        return numberText + suffix
    }

    /// A single decimal digit token ("4") → 0…9, else nil. Guards the length so "42" is not a digit.
    static func digit(_ token: String) -> Int? {
        guard token.count == 1, let value = Int(token), value >= 0, value <= 9 else { return nil }
        return value
    }

    /// A fix ident is `minFixLen`…`maxFixLen` letters/digits with at least one LETTER (rules out pure
    /// numbers, which are altitudes/frequencies/headings). Bounded loop over the ident length.
    static func isFixShaped(_ s: String) -> Bool {
        let length = s.count
        guard length >= minFixLen, length <= maxFixLen else { return false }
        var hasLetter = false
        for ch in s {                                                // bounded by maxFixLen (guard above)
            guard ch.isLetter || ch.isNumber else { return false }
            if ch.isLetter { hasLetter = true }
        }
        return hasLetter
    }
}
