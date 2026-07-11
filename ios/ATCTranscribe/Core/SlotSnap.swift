import Foundation

/// SlotSnap — context-grounded correction of runway and frequency slots against the airport's
/// real runways and published airband frequencies (`AirportContextStore`). Swift port of
/// `python-legacy/slot_snap.py`, validated byte-identical via `snap_fixtures.json`.
///
/// Policies (deliberately conservative — this stage must never flip semantics):
///  * runway: exact designator → verified; unique digit-edit-1 candidate with the SAME suffix →
///    snap. The L/C/R suffix is NEVER added, removed, or changed. Ambiguity → abstain.
///  * frequency: candidates are the airport's published airband (118–136.975) frequencies.
///    Exact → verified; unique digit-edit-1 → snap; unmatched off-raster → "invalid" (kept as
///    heard). Frequency matches require a nearby anchor word (contact/tower/…) so stray digits
///    in chatter are never edited. Point-less radio speech ("tower one two six five five") is
///    recognized.
/// Text is rewritten only on a confident snap, in `ATCNormalize` canonical per-digit space.
enum SlotSnap {

    struct Edit: Sendable, Equatable {
        let slot: String        // "runway" | "frequency"
        let verdict: String     // verified | snapped | unverified | invalid
        let original: String
        var snapped: String?
        var applied = false
    }

    static let freqAnchors: Set<String> = ["contact", "monitor", "frequency", "tower", "ground",
                                           "approach", "departure", "center", "radio",
                                           "clearance", "atis", "localizer", "ils", "tune"]
    static let airband = 118.0...136.975
    static let navBand = 108.0...117.975     // VOR/ILS/localizer band, where CIFP publishes ILS freqs

    // Fix slot: ground a misheard fix ident against the airport's coded-procedure fixes (CIFP). Fires only
    // after a STRONG clearance anchor that is reliably followed by a fix name. "over" and "cross" are
    // deliberately NOT anchors: they precede position/landmark ("over the river") and cross-runway /
    // cross-traffic phrases far more often than fixes, and a busy airport almost always has one 5-letter
    // fix at edit-distance 1 from a plain word — so those anchors caused real false snaps (river→RIVET,
    // outer→OUTTR). The stoplist below is the second line of defense against the same collision class.
    private static let fixRx = try! NSRegularExpression(
        pattern: #"\b((?:direct|hold(?:ing)?|intercept|join)(?: (?:to|at|the|for))?) ([a-z]{4,7})\b"#)
    static let fixStopwords: Set<String> = [
        // pattern / taxi / clearance jargon
        "traffic", "final", "short", "runway", "runways", "tower", "left", "right", "center",
        "downwind", "base", "line", "position", "hold", "clear", "climb", "descend", "maintain",
        "heading", "turn", "join", "intercept", "ground", "airport", "gate", "wind",
        // filler / function words
        "with", "into", "onto", "your", "that", "this", "then", "them", "when", "there",
        "will", "have", "just", "past", "next", "point",
        // geographic / position / ILS-phraseology nouns that legitimately follow these anchors
        "river", "field", "water", "ridge", "shore", "fence", "bridge", "marker", "outer",
        "inner", "middle", "coast", "beach", "numbers", "pattern", "present", "radial", "course",
    ]

    // The suffix must not be a direction word belonging to the NEXT phrase ("runway 4,
    // right traffic" / "right turn") — capturing it would invent an L/R designator.
    private static let runwayRx = try! NSRegularExpression(
        pattern: #"\brunway((?: \d){1,2})( (?:left|right|center)(?! (?:traffic|turn|downwind|base|closed)))?\b"#)
    private static let freqRx = try! NSRegularExpression(
        pattern: #"\b(\d \d \d) point (\d(?: \d){0,2})\b"#)
    // radio speech often omits "point": "contact tower one two six five five"
    private static let freqNoPointRx = try! NSRegularExpression(
        pattern: #"\b(1 \d \d) (\d(?: \d)?)\b(?! point)(?! \d)"#)

    /// Apply the stage. Returns (canonical-space text, edits). No context → canonicalize only.
    /// `telephony` guards the frequency patterns against callsign flight numbers ("center
    /// american 1786" is a callsign, not frequency 178.6 — the dominant false-positive class
    /// measured on the collected corpus). `conservativeFrequencies` (H3): when true, a heard
    /// value that is already a valid airband channel is never snapped — see `snapFrequency`.
    /// Defaulted false so the byte-parity fixtures (which pass two args) replay unchanged.
    static func apply(_ text: String, context: AirportContextData?,
                      telephony: Set<String> = CallsignSnap.telephonyWords(nil),
                      conservativeFrequencies: Bool = false) -> (text: String, edits: [Edit]) {
        var out = ATCNormalize.normalize(text)
        guard let context else { return (out, []) }
        var edits: [Edit] = []

        out = substitute(runwayRx, in: out) { groups, _, _, _ in
            let num = groups[0].replacingOccurrences(of: " ", with: "").drop(while: { $0 == "0" })
            let numStr = num.isEmpty ? "0" : String(num)
            let suffixWord = groups[1].trimmingCharacters(in: .whitespaces)   // "" | left | right | center
            let (verdict, snapped) = snapRunway(numStr, suffixWord: suffixWord, context: context)
            let heard = numStr + (suffixWord.isEmpty ? "" : " " + suffixWord)
            if let snapped {
                edits.append(Edit(slot: "runway", verdict: "snapped", original: heard,
                                  snapped: snapped + (suffixWord.isEmpty ? "" : " " + suffixWord),
                                  applied: true))
                return "runway " + snapped.map(String.init).joined(separator: " ")
                    + (groups[1].isEmpty ? "" : groups[1])
            }
            edits.append(Edit(slot: "runway", verdict: verdict, original: heard))
            return nil
        }

        for rx in [freqRx, freqNoPointRx] {
            out = substitute(rx, in: out) { groups, prefix, full, matchRange in
                let prefixToks = prefix.split(separator: " ").suffix(4).map(String.init)
                guard !freqAnchors.isDisjoint(with: prefixToks) else { return nil }
                // the POINT-LESS pattern requires the anchor IMMEDIATELY before the
                // digits ("contact tower 126 55" yes; "tower cessna 1265" no)
                let matched = full.substring(with: matchRange)
                if !matched.contains("point"),
                   prefixToks.last.map({ freqAnchors.contains($0) }) != true {
                    return nil
                }
                // never read a callsign's digits as a frequency (airline flight
                // numbers AND GA tails — both measured failure classes)
                if let cs = callsignRange(in: full as String, telephony: telephony),
                   NSIntersectionRange(cs, matchRange).length > 0 {
                    return nil
                }
                let heardStr = groups[0].replacingOccurrences(of: " ", with: "") + "."
                    + groups[1].replacingOccurrences(of: " ", with: "")
                guard let heard = Double(heardStr) else { return nil }
                let (verdict, snapped) = snapFrequency(heard, context: context,
                                                       conservative: conservativeFrequencies)
                if let snapped {
                    edits.append(Edit(slot: "frequency", verdict: "snapped", original: heardStr,
                                      snapped: trimFreq(snapped), applied: true))
                    return renderFrequency(snapped)
                }
                edits.append(Edit(slot: "frequency", verdict: verdict, original: heardStr))
                return nil
            }
        }

        // fix slot — snap a misheard fix ident (right after a clearance anchor) onto the airport's coded
        // procedure fixes. Conservative: exact → verified; a unique edit-1 candidate for a ≥5-char
        // non-stopword token → snap; ambiguous / no candidates → abstain. Never invents or lengthens.
        if !context.fixes.isEmpty {
            out = substitute(fixRx, in: out) { groups, _, _, _ in
                let anchorPhrase = groups[0]         // "direct" | "hold at" | "cross the" | …
                let heard = groups[1]
                guard !fixStopwords.contains(heard) else { return nil }
                let (verdict, snapped) = snapFix(heard, context: context)
                if let snapped {
                    edits.append(Edit(slot: "fix", verdict: "snapped", original: heard, snapped: snapped, applied: true))
                    return anchorPhrase + " " + snapped
                }
                edits.append(Edit(slot: "fix", verdict: verdict, original: heard))
                return nil
            }
        }
        return (out, edits)
    }

    // MARK: fix

    /// Snap a heard token onto the airport's coded-procedure fixes. Exact (case-insensitive) → verified;
    /// a single edit-1 candidate when the heard token is ≥5 letters → snapped; otherwise abstain. The
    /// ≥5-letter floor plus the caller's stoplist keep short common words from snapping onto a look-alike.
    private static func snapFix(_ heard: String, context: AirportContextData) -> (verdict: String, snapped: String?) {
        let up = heard.uppercased()
        let cands = Set(context.fixes.map { $0.uppercased() }.filter { $0.count >= 4 && $0.allSatisfy(\.isLetter) })
        if cands.contains(up) { return ("verified", nil) }
        guard heard.count >= 5 else { return ("unverified", nil) }
        let near = cands.filter { CallsignSnap.levenshtein($0, up) == 1 }.sorted()
        return near.count == 1 ? ("snapped", near[0].lowercased()) : ("unverified", nil)
    }

    // MARK: runway

    /// "17C" → ("17", "C"); "22" → ("22", ""). Tolerates a leading zero ("02C" → ("2", "C")).
    static func parseDesignator(_ d: String) -> (num: String, suffix: String) {
        var s = d.trimmingCharacters(in: .whitespaces).uppercased()
        var suffix = ""
        if let last = s.last, "LRC".contains(last) { suffix = String(last); s.removeLast() }
        if s.first == "0" { s.removeFirst() }
        guard !s.isEmpty, s.count <= 2, s.allSatisfy(\.isNumber) else { return ("", "") }
        return (s, suffix)
    }

    private static func snapRunway(_ num: String, suffixWord: String,
                                   context: AirportContextData) -> (verdict: String, snapped: String?) {
        let suffix = ["left": "L", "right": "R", "center": "C"][suffixWord] ?? ""
        let cands = context.runways.map(parseDesignator).filter { !$0.num.isEmpty }
        if !suffix.isEmpty {
            let pool = cands.filter { $0.suffix == suffix }.map(\.num)
            if pool.contains(num) { return ("verified", nil) }
            let near = Set(pool.filter { CallsignSnap.levenshtein($0, num) == 1 }).sorted()
            return near.count == 1 ? ("snapped", near[0]) : ("unverified", nil)
        }
        let families = Set(cands.map(\.num)).sorted()
        if families.contains(num) { return ("verified", nil) }
        let near = families.filter { CallsignSnap.levenshtein($0, num) == 1 }
        return near.count == 1 ? ("snapped", near[0]) : ("unverified", nil)
    }

    // MARK: frequency

    static func freqDigits(_ mhz: Double) -> String {
        // Fixed width (6 digits, no stripping) — stripping collapsed integer-MHz
        // values across the decimal (120.0 -> "12") and broke the edit<=1 policy.
        String(format: "%.3f", mhz).replacingOccurrences(of: ".", with: "")
    }

    static func onRaster(_ mhz: Double) -> Bool {
        // A frequency is a real channel if it sits on the 25 kHz grid, OR if it is the universal
        // 2-decimal shorthand for an .xx5 channel — controllers drop the trailing 5 ("124.67" =
        // 124.675). Mirror of python-legacy/slot_snap.py::_on_raster (live FP#4 fix, 2026-07-08 —
        // the Swift port lagged the second arm; H3 remediation restores it). Genuinely mangled
        // values (118.41) still fail both arms. Fixed 2-iteration loop (rule 2).
        for cand in [mhz, mhz + 0.005] {
            let k = ((cand - 118.0) / 0.025).rounded()
            if abs(118.0 + k * 0.025 - cand) < 1e-6 { return true }
        }
        return false
    }

    private static func snapFrequency(_ heard: Double, context: AirportContextData,
                                      conservative: Bool) -> (verdict: String, snapped: Double?) {
        let comms = context.frequencyValues.filter { airband.contains($0) }
        let nav = context.navFrequencies.filter { navBand.contains($0) }        // published ILS/LOC freqs
        // Snap ONLY within the heard value's own band — never let an airband comms freq be rewritten to a
        // nav/ILS freq or vice-versa (an edit-1 across the 118 boundary is a real cross-band corruption).
        let cands = navBand.contains(heard) ? nav : comms
        if cands.contains(where: { abs($0 - heard) < 1e-6 }) { return ("verified", nil) }
        // PRODUCT POLICY (H3, Swift-only, 2026-07-11; python-legacy deliberately NOT updated — the
        // same fixture-absent gating pattern as the nav-band branch below): a heard value that is
        // already a plausible airband channel (in-band + on-raster) is NEVER rewritten — it is most
        // likely a handoff to a facility outside this airport's published table, and a
        // Levenshtein-1 "correction" would silently corrupt a valid frequency (the worst kind of
        // error: official-looking and wrong). Only a garbled/impossible value may snap. The parity
        // fixtures never pass `conservative`, so the Python-validated behavior stays byte-identical.
        if conservative, airband.contains(heard), onRaster(heard) { return ("unverified", nil) }
        let hd = freqDigits(heard)
        let near = Set(cands.filter { CallsignSnap.levenshtein(freqDigits($0), hd) == 1 }).sorted()
        if near.count == 1 { return ("snapped", near[0]) }
        // A nav-band freq heard where the airport publishes ILS freqs abstains when it doesn't match — it
        // must NOT fall into the airband's off-raster "invalid" verdict. With no nav freqs (all existing
        // python-validated fixtures) this guard is skipped, so the airband policy below is byte-identical.
        if navBand.contains(heard), !nav.isEmpty { return ("unverified", nil) }
        if !airband.contains(heard) || !onRaster(heard) { return ("invalid", nil) }
        return ("unverified", nil)
    }

    static func renderFrequency(_ mhz: Double) -> String {
        let parts = String(format: "%.3f", mhz).split(separator: ".")
        var frac = String(parts[1])
        while frac.count > 1, frac.hasSuffix("0") { frac.removeLast() }
        return parts[0].map(String.init).joined(separator: " ") + " point "
            + frac.map(String.init).joined(separator: " ")
    }

    private static func trimFreq(_ mhz: Double) -> String {
        var s = String(format: "%.3f", mhz)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    // MARK: regex plumbing

    /// GA type/model words that anchor a spoken callsign — used ONLY to protect the digits
    /// from the frequency patterns, never for snapping (mirror of `GA_CALLSIGN_WORDS`).
    static let gaCallsignWords: Set<String> = [
        "cessna", "piper", "skyhawk", "skylane", "cherokee", "warrior", "archer",
        "bonanza", "baron", "citation", "mooney", "beech", "beechcraft", "cirrus",
        "diamond", "grumman", "lancair", "malibu", "saratoga", "seminole", "seneca",
        "husky", "cub", "champ", "stinson", "maule", "aztec", "navajo", "caravan",
        "kingair", "king", "experimental", "helicopter", "gyroplane",
    ]

    /// Char range of the extracted callsign span in the pass-input text, or nil. Canonical
    /// text is ASCII, so character offsets == NSRange UTF-16 offsets.
    private static func callsignRange(in text: String, telephony: Set<String>) -> NSRange? {
        var span = CallsignSnap.extractCallsign(text, telephony: telephony)
        if span == nil {
            let tokens = text.split(separator: " ").map(String.init)
            for i in 0..<max(0, tokens.count - 1)
            where gaCallsignWords.contains(tokens[i]) && tokens[i + 1].allSatisfy(\.isNumber) {
                var j = i + 1
                while j < tokens.count, tokens[j].allSatisfy(\.isNumber), !tokens[j].isEmpty { j += 1 }
                span = tokens[i..<j].joined(separator: " ")
                break
            }
        }
        guard let span else { return nil }
        let padded = " " + text + " "
        guard let r = padded.range(of: " " + span + " ") else { return nil }
        let start = padded.distance(from: padded.startIndex, to: r.lowerBound)
        return NSRange(location: start, length: span.count)
    }

    /// re.sub with a callback: `body` gets the capture groups (empty string for a missed
    /// optional group), the text BEFORE the match, the full pass-input string, and the match
    /// range (for span-overlap guards); returning nil keeps the match unchanged.
    /// Non-overlapping, left-to-right, single pass — identical semantics to Python `re.sub`.
    private static func substitute(_ rx: NSRegularExpression, in text: String,
                                   _ body: ([String], String, NSString, NSRange) -> String?) -> String {
        let ns = text as NSString
        var result = ""
        var cursor = 0
        for m in rx.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            var groups: [String] = []
            for gi in 1..<m.numberOfRanges {
                let r = m.range(at: gi)
                groups.append(r.location == NSNotFound ? "" : ns.substring(with: r))
            }
            let replacement = body(groups, ns.substring(to: m.range.location), ns, m.range)
            result += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            result += replacement ?? ns.substring(with: m.range)
            cursor = m.range.location + m.range.length
        }
        result += ns.substring(from: cursor)
        return result
    }
}
