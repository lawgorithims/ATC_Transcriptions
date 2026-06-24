import Foundation

/// A faithful port of Python `difflib.SequenceMatcher.ratio()` (Ratcliff/Obershelp
/// "gestalt" similarity), used by the deterministic corrector to score how close a
/// transcript token is to an airport-vocabulary term — the same algorithm
/// `atc_corrector.py` relies on via `difflib`.
///
/// difflib's *autojunk* heuristic (drop characters of `b` that appear in more than
/// 1% of a sequence ≥ 200 chars long) only triggers for long sequences. ATC vocab
/// terms and tokens are short, so we omit autojunk and the result matches CPython
/// for these inputs.
struct SequenceMatcher {
    private let a: [Character]
    private let b: [Character]
    private let b2j: [Character: [Int]]

    init(_ a: String, _ b: String) {
        let ac = Array(a), bc = Array(b)
        self.a = ac
        self.b = bc
        var map: [Character: [Int]] = [:]
        for (j, ch) in bc.enumerated() { map[ch, default: []].append(j) }
        self.b2j = map
    }

    /// Longest matching block within a[alo..<ahi] / b[blo..<bhi]. Direct port of
    /// difflib's `find_longest_match` (without junk handling).
    private func findLongestMatch(_ alo: Int, _ ahi: Int, _ blo: Int, _ bhi: Int) -> (i: Int, j: Int, size: Int) {
        var besti = alo, bestj = blo, bestsize = 0
        var j2len: [Int: Int] = [:]
        for i in alo..<ahi {
            var newj2len: [Int: Int] = [:]
            for j in b2j[a[i]] ?? [] {
                if j < blo { continue }
                if j >= bhi { break }
                let k = (j2len[j - 1] ?? 0) + 1
                newj2len[j] = k
                if k > bestsize {
                    besti = i - k + 1
                    bestj = j - k + 1
                    bestsize = k
                }
            }
            j2len = newj2len
        }
        return (besti, bestj, bestsize)
    }

    /// Total size of all matching blocks (recursive, like difflib's
    /// `get_matching_blocks`), summed for the ratio.
    private func totalMatches() -> Int {
        var total = 0
        var queue: [(Int, Int, Int, Int)] = [(0, a.count, 0, b.count)]
        while let (alo, ahi, blo, bhi) = queue.popLast() {
            let m = findLongestMatch(alo, ahi, blo, bhi)
            if m.size > 0 {
                total += m.size
                queue.append((alo, m.i, blo, m.j))
                queue.append((m.i + m.size, ahi, m.j + m.size, bhi))
            }
        }
        return total
    }

    /// Similarity in [0, 1]: `2*M / T`, where M is total matched characters and T is
    /// the combined length. Matches `difflib.SequenceMatcher.ratio()`; returns 1.0
    /// when both strings are empty.
    func ratio() -> Double {
        let t = a.count + b.count
        guard t > 0 else { return 1.0 }
        return 2.0 * Double(totalMatches()) / Double(t)
    }
}

/// Single best vocab match for `word` at or above `cutoff` by
/// `SequenceMatcher.ratio()`, or `nil`. Equivalent to
/// `difflib.get_close_matches(word, vocab, n: 1, cutoff: cutoff)` plus the ratio.
///
/// difflib selects with `heapq.nlargest(1, [(ratio, term), ...])`, which compares the
/// whole `(ratio, term)` tuple — so on a ratio tie the lexicographically-LARGER term
/// wins, independent of `vocab` order. We replicate that tie-break here (Swift's
/// `Dictionary.keys` order is not even insertion-stable, so without it the chosen
/// correction would be both wrong-vs-Python and nondeterministic).
func closestMatch(_ word: String, in vocab: [String], cutoff: Double) -> (term: String, ratio: Double)? {
    var best: (term: String, ratio: Double)?
    for term in vocab {
        let r = SequenceMatcher(word, term).ratio()
        guard r >= cutoff else { continue }
        if best == nil || r > best!.ratio || (r == best!.ratio && term > best!.term) {
            best = (term, r)
        }
    }
    return best
}
