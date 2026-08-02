import Foundation

/// Matches a DEPARTURE or ARRIVAL plate title to its coded CIFP procedure.
///
/// ⚠️ THE TWO SIDES SPELL THE SAME PROCEDURE DIFFERENTLY, AND SUBSTRING MATCHING FINDS NOTHING. The FAA
/// chart is titled "LUCIT THREE (RNAV)"; CIFP idents it `LUCIT3`. Measured over every bundled terminal
/// chart that has a coded procedure at the same field: a plain `plate.contains(ident)` matched
/// **0 of 6,015**. That is why the Vector button never appeared on a SID or STAR — the gate is
/// `vectorChart != nil`, so the failure was silent and looked like "this procedure has no geometry".
///
/// The rule reads the CIFP side into the chart's own spelling rather than the reverse, because the ident
/// is the constrained form: `<BASE><revision digit>[<suffix>]`. Measured on the same 6,015:
///
/// | rule | matched | ambiguous |
/// |---|---|---|
/// | spoken revision ("LUCIT3" → "LUCIT THREE") | 5,120 (85%) | 0 |
/// | + base-is-a-prefix, same revision ("GARL6" ← "GARLAND SIX") | 5,410 (**89%**) | 0 |
///
/// The remaining 11% title the procedure by a place the ident CONTRACTS to a navaid or an initialism —
/// "MELBOURNE THREE" is `MLB3`, "WILKES-BARRE FIVE" is `LVZ5`, "JOE POOL EIGHT" is `JPOOL8`. There is no
/// rule that recovers those without guessing, so they match NOTHING and no chart is offered. An
/// ambiguous match is never returned either: drawing a different departure than the one on screen is
/// worse than drawing none.
enum TerminalChartMatch {

    /// Revision numbers are spelled out on the chart and printed as a digit in the ident. One through
    /// nine covers every published revision — the FAA rolls back to ONE rather than reaching TEN.
    static let revisionWords = ["ONE", "TWO", "THREE", "FOUR", "FIVE", "SIX", "SEVEN", "EIGHT", "NINE"]

    /// `("LUCIT3")` → `(base: "LUCIT", revision: 3)`; nil when the ident is not of that shape.
    static func split(ident: String) -> (base: String, revision: Int)? {
        let u = ident.uppercased()
        guard let r = u.range(of: "[A-Z]+[1-9][A-Z]?$", options: .regularExpression),
              r.lowerBound == u.startIndex, r.upperBound == u.endIndex else { return nil }
        var digitIndex: String.Index?
        for i in u.indices where u[i].isNumber { digitIndex = i; break }   // bounded (rule 2)
        guard let d = digitIndex, let n = u[d].wholeNumberValue, n >= 1, n <= 9 else { return nil }
        let base = String(u[u.startIndex..<d])
        guard !base.isEmpty else { return nil }
        return (base, n)
    }

    /// The revision a plate title spells out, e.g. "LUCIT THREE (RNAV)" → 3.
    static func revision(inPlate plateName: String) -> Int? {
        let u = plateName.uppercased()
        for (i, w) in revisionWords.enumerated() {                          // bounded (rule 2)
            if u.range(of: "\\b\(w)\\b", options: .regularExpression) != nil { return i + 1 }
        }
        return nil
    }

    /// The single coded procedure this plate is for, or nil.
    ///
    /// Returns nil for BOTH "nothing matched" and "several matched" on purpose — see the type comment.
    static func match(plateName: String, idents: [String]) -> String? {
        let plate = plateName.uppercased()
        assert(idents.count <= 4096, "TerminalChartMatch: candidate list out of range")
        let unique = Array(Set(idents.map { $0.uppercased() })).sorted()

        // 1. The chart's own spelling of the ident.
        var hits = unique.prefix(4096).filter { id in                       // bounded (rule 2)
            guard let s = split(ident: id) else { return plate.contains(id) }
            return plate.contains("\(s.base) \(revisionWords[s.revision - 1])") || plate.contains(id)
        }
        if hits.count == 1 { return hits.first }
        if hits.count > 1 { return nil }

        // 2. The ident's base is a CONTRACTION of the charted name, and the revision agrees. Guarded by
        //    the revision so "GARL6" cannot be claimed by "GARLAND SIX"'s neighbour "GARLAND TWO".
        guard let rev = revision(inPlate: plate) else { return nil }
        let firstWord = plate.split(whereSeparator: { !$0.isLetter }).first.map(String.init) ?? ""
        guard !firstWord.isEmpty else { return nil }
        hits = unique.prefix(4096).filter { id in                           // bounded (rule 2)
            guard let s = split(ident: id), s.revision == rev else { return false }
            return firstWord.hasPrefix(s.base)
        }
        return hits.count == 1 ? hits.first : nil
    }
}
