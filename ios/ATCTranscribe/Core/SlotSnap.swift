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
                                           "clearance", "atis"]
    static let airband = 118.0...136.975

    private static let runwayRx = try! NSRegularExpression(
        pattern: #"\brunway((?: \d){1,2})( left| right| center)?\b"#)
    private static let freqRx = try! NSRegularExpression(
        pattern: #"\b(\d \d \d) point (\d(?: \d){0,2})\b"#)
    // radio speech often omits "point": "contact tower one two six five five"
    private static let freqNoPointRx = try! NSRegularExpression(
        pattern: #"\b(1 \d \d) (\d(?: \d)?)\b(?! point)(?! \d)"#)

    /// Apply the stage. Returns (canonical-space text, edits). No context → canonicalize only.
    static func apply(_ text: String, context: AirportContextData?) -> (text: String, edits: [Edit]) {
        var out = ATCNormalize.normalize(text)
        guard let context else { return (out, []) }
        var edits: [Edit] = []

        out = substitute(runwayRx, in: out) { groups, _ in
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
            out = substitute(rx, in: out) { groups, prefix in
                let prefixToks = prefix.split(separator: " ").suffix(4).map(String.init)
                guard !freqAnchors.isDisjoint(with: prefixToks) else { return nil }
                let heardStr = groups[0].replacingOccurrences(of: " ", with: "") + "."
                    + groups[1].replacingOccurrences(of: " ", with: "")
                guard let heard = Double(heardStr) else { return nil }
                let (verdict, snapped) = snapFrequency(heard, context: context)
                if let snapped {
                    edits.append(Edit(slot: "frequency", verdict: "snapped", original: heardStr,
                                      snapped: trimFreq(snapped), applied: true))
                    return renderFrequency(snapped)
                }
                edits.append(Edit(slot: "frequency", verdict: verdict, original: heardStr))
                return nil
            }
        }
        return (out, edits)
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
        var s = String(format: "%.3f", mhz).replacingOccurrences(of: ".", with: "")
        while s.count > 1, s.hasSuffix("0") { s.removeLast() }
        return s
    }

    static func onRaster(_ mhz: Double) -> Bool {
        let k = ((mhz - 118.0) / 0.025).rounded()
        return abs(118.0 + k * 0.025 - mhz) < 1e-6
    }

    private static func snapFrequency(_ heard: Double,
                                      context: AirportContextData) -> (verdict: String, snapped: Double?) {
        let cands = context.frequencyValues.filter { airband.contains($0) }
        if cands.contains(where: { abs($0 - heard) < 1e-6 }) { return ("verified", nil) }
        let hd = freqDigits(heard)
        let near = Set(cands.filter { CallsignSnap.levenshtein(freqDigits($0), hd) == 1 }).sorted()
        if near.count == 1 { return ("snapped", near[0]) }
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

    /// re.sub with a callback: `body` gets the capture groups (empty string for a missed
    /// optional group) and the text BEFORE the match in the pass-input string (for anchor
    /// checks); returning nil keeps the match unchanged. Non-overlapping, left-to-right, single
    /// pass — identical semantics to Python `re.sub`.
    private static func substitute(_ rx: NSRegularExpression, in text: String,
                                   _ body: ([String], String) -> String?) -> String {
        let ns = text as NSString
        var result = ""
        var cursor = 0
        for m in rx.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            var groups: [String] = []
            for gi in 1..<m.numberOfRanges {
                let r = m.range(at: gi)
                groups.append(r.location == NSNotFound ? "" : ns.substring(with: r))
            }
            let replacement = body(groups, ns.substring(to: m.range.location))
            result += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            result += replacement ?? ns.substring(with: m.range)
            cursor = m.range.location + m.range.length
        }
        result += ns.substring(from: cursor)
        return result
    }
}
