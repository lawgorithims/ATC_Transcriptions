import Foundation

/// Canonical normalization for US ATC transcripts — Swift port of
/// `python-legacy/atc_normalize.py`.
///
/// Canonicalizes EQUIVALENT spoken/written forms of numbers and runway designators
/// so "4R" == "4 right" == "four right". On the US human-verified gold set this removes
/// pure-format mismatches that a naive comparison counts as errors, cutting WER ~8–9
/// points (whisper-small-us 32.3% → 22.8%, turbo 28.9% → 20.2%). It only unifies
/// equivalent forms — it never changes meaning, so it is safe to apply unconditionally.
enum ATCNormalize {
    static let units: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "tree": 3, "four": 4, "fower": 4,
        "five": 5, "fife": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "niner": 9,
    ]
    static let teens: [String: Int] = [
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
        "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fourty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]
    static let rlc: [Character: String] = ["r": "right", "l": "left", "c": "center"]

    /// Lowercase, replace punctuation with spaces, split into tokens.
    static func strip(_ text: String) -> [String] {
        var s = ""
        for ch in text.lowercased() {
            s.append((ch.isLetter || ch.isNumber || ch == " ") ? ch : " ")
        }
        return s.split(separator: " ").map(String.init)
    }

    /// Collapse runs of spoken number words into digit strings; a tens word grabs a
    /// following unit ("nine seventy five" -> "975").
    static func wordsToDigits(_ tokens: [String]) -> [String] {
        var out: [String] = []
        var i = 0
        while i < tokens.count {
            var run: [Int] = []
            var j = i
            while j < tokens.count {
                let w = tokens[j]
                if let u = units[w] { run.append(u) }
                else if let t = teens[w] { run.append(t) }
                else if let t = tens[w] { run.append(t) }
                else { break }
                j += 1
            }
            if run.isEmpty {
                out.append(tokens[i]); i += 1
            } else {
                var parts: [String] = []
                var k = 0
                while k < run.count {
                    if run[k] >= 20, run[k] % 10 == 0, k + 1 < run.count, run[k + 1] < 10 {
                        parts.append(String(run[k] + run[k + 1])); k += 2   // seventy + five -> 75
                    } else {
                        parts.append(String(run[k])); k += 1
                    }
                }
                out.append(parts.joined()); i = j
            }
        }
        return out
    }

    /// Explode each maximal digit run into single spaced digits ("125" -> "1 2 5").
    static func explodeDigits(_ w: String) -> String {
        var out = ""
        var run = ""
        for ch in w {
            if ch.isNumber { run.append(ch) }
            else {
                if !run.isEmpty { out += run.map(String.init).joined(separator: " "); run = "" }
                out.append(ch)
            }
        }
        if !run.isEmpty { out += run.map(String.init).joined(separator: " ") }
        return out
    }

    /// Canonical form: spoken numbers -> digits, multi-digit numbers exploded to single
    /// spaced digits, and runway designators unified ("4r"/"4R"/"four right" -> "4 right").
    static func normalize(_ text: String) -> String {
        var out: [String] = []
        for w in wordsToDigits(strip(text)) {
            if w.count >= 2, let last = w.last, let side = rlc[last],
               w.dropLast().allSatisfy({ $0.isNumber }) {
                out.append(String(w.dropLast()).map(String.init).joined(separator: " "))
                out.append(side)
            } else {
                out.append(explodeDigits(w))
            }
        }
        return out.joined(separator: " ").split(separator: " ").map(String.init).joined(separator: " ")
    }
}
