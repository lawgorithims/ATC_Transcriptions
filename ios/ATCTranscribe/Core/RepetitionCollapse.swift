import Foundation

/// Deterministic repetition collapser — a cheap, safe stage for the **fast inline tier**
/// that removes the immediate token/phrase repeats Whisper's degeneracy guard
/// (`compressionRatioThreshold: 2.4`) lets through. "runway three runway three runway three"
/// -> "runway three"; "the the the the" -> "the". Instant, no model, recorded as a `repeat`
/// edit so it stays transparent.
///
/// Conservative by design — collapsing legitimate ATC readbacks would corrupt the feed:
///   * a **single** token must repeat **3+** times to collapse (so a real digit readback like
///     "three three" for 33 is left alone);
///   * a **multi-word** phrase (2–4 tokens) collapses at **2+** repeats (an exact phrase echo
///     is almost always a decode artifact).
/// Only *immediate, consecutive* exact repeats are touched — the shape Whisper loops produce.
struct RepetitionCollapse: Corrector {
    var maxPhrase = 4

    func correct(_ text: String, history: [String]) async -> Correction {
        if text.trimmingCharacters(in: .whitespaces).isEmpty {
            return .unchanged(text, backend: "deterministic")
        }
        let tokens = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let (out, edits) = Self.collapse(tokens, maxPhrase: maxPhrase)
        let corrected = out.joined(separator: " ")
        if edits.isEmpty || corrected == text {
            return .unchanged(text, backend: "deterministic")
        }
        return Correction(raw: text, corrected: corrected, changed: true, edits: edits, backend: "deterministic")
    }

    /// Greedy left-to-right collapse, preferring the longest repeating block at each position
    /// so "A B A B" collapses as a 2-gram rather than two stray 1-grams.
    static func collapse(_ tokens: [String], maxPhrase: Int) -> (out: [String], edits: [CorrectionEdit]) {
        var out: [String] = []
        var edits: [CorrectionEdit] = []
        let n = tokens.count
        var i = 0
        while i < n {
            var collapsed = false
            for w in stride(from: min(maxPhrase, (n - i) / 2), through: 1, by: -1) where w >= 1 {
                let block = normJoin(tokens, i, i + w)
                var reps = 1
                var j = i + w
                while j + w <= n, normJoin(tokens, j, j + w) == block { reps += 1; j += w }
                let need = (w == 1) ? 3 : 2
                if reps >= need {
                    out.append(contentsOf: tokens[i..<(i + w)])
                    let from = tokens[i..<j].joined(separator: " ")
                    let to = tokens[i..<(i + w)].joined(separator: " ")
                    edits.append(CorrectionEdit(from: from, to: to, reason: "repeat", backend: "deterministic"))
                    i = j
                    collapsed = true
                    break
                }
            }
            if !collapsed { out.append(tokens[i]); i += 1 }
        }
        return (out, edits)
    }

    private static func normJoin(_ tokens: [String], _ lo: Int, _ hi: Int) -> String {
        tokens[lo..<hi].map { String($0.lowercased().filter { ("a"..."z").contains($0) || ("0"..."9").contains($0) }) }
            .joined(separator: " ")
    }
}
