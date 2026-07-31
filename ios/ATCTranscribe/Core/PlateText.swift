import Foundation
import CoreGraphics
#if canImport(PDFKit)
import PDFKit
#endif

/// One positioned run of text on a plate page.
///
/// Coordinates are **y-DOWN from the top of the page**, so `yTop` sorts in reading order. PDF page space
/// is y-up; the extractor flips once, so nothing downstream has to remember which way is which.
struct PlateWord: Equatable {
    let text: String
    let x0: Double
    let x1: Double
    let yTop: Double
    let yBottom: Double
    /// Median character advance in this run's row — the natural unit for "is this gap a space, a new
    /// cell, or nothing at all?". A minima row mixes two type sizes, so a threshold taken from the row's
    /// box height would be wrong for half of it.
    let pitch: Double

    var xMid: Double { (x0 + x1) / 2 }
    var yMid: Double { (yTop + yBottom) / 2 }
    var height: Double { max(yBottom - yTop, 0.01) }
    var width: Double { max(x1 - x0, 0.0) }

    init(text: String, x0: Double, x1: Double, yTop: Double, yBottom: Double, pitch: Double = 3.5) {
        self.text = text
        self.x0 = x0
        self.x1 = x1
        self.yTop = yTop
        self.yBottom = yBottom
        self.pitch = max(pitch, 0.5)
    }
}

/// Turns a plate page into positioned runs.
///
/// WHY NOT `characterBounds(at:)`. The obvious API is wrong in a way that is very hard to see: its index
/// space is the page's glyphs, while `page.string`'s index space includes the separators PDFKit inserts
/// between laid-out lines, and the two drift apart as the page goes on. Near the bottom of a plate — which
/// is exactly where the minima block sits — the boxes it returns are attached to the wrong characters, with
/// impossible widths and overlaps, and `numberOfCharacters` reports the string's length so nothing flags it.
/// A minima parser built on it produces confident, wrong numbers.
///
/// WHAT IS USED INSTEAD. `selection(for: rect)` is the query PDFView itself uses for text selection, and it
/// is exact: it returns the characters anchored inside a rectangle. Probing a narrow column at a time walks
/// the page in true VISUAL order — which matters, because the string PDFKit hands back for a line carrying
/// a typeset fraction relocates the numerator and denominator to the end of it, turning `(200-½)` into
/// `(200- ) 12`.
enum PlateText {

    /// Probe width. 0.5 pt resolves individual characters (advances on a plate run 3–5 pt) while keeping a
    /// full minima band under ten thousand queries — about 30 ms.
    static let scanStep = 0.5
    /// A gap wider than this multiple of the local advance separates two runs.
    static let runBreakFactor = 1.55
    /// …and never less than this many points, so a single wide letter cannot split a word.
    static let runBreakFloor = 2.0
    /// A gap wider than this multiple of the local advance separates two printed CELLS.
    static let cellBreakFactor = 3.5
    /// Hard scan bounds (rule 2).
    static let maxSamples = 4_000
    static let maxRows = 400

    // MARK: pure helpers

    /// Split runs into rows by vertical proximity, each row ordered left → right.
    static func rows(_ words: [PlateWord], tolerance: Double) -> [[PlateWord]] {
        assert(tolerance > 0, "PlateText.rows: non-positive tolerance")
        guard !words.isEmpty else { return [] }
        let sorted = words.sorted { $0.yMid < $1.yMid }
        var out: [[PlateWord]] = []
        var current: [PlateWord] = []
        var anchor = sorted[0].yMid
        for w in sorted.prefix(maxRows * 8) {                     // bounded (rule 2)
            if !current.isEmpty && abs(w.yMid - anchor) > tolerance {
                out.append(current.sorted { $0.x0 < $1.x0 })
                current = []
            }
            if current.isEmpty { anchor = w.yMid }
            current.append(w)
        }
        if !current.isEmpty { out.append(current.sorted { $0.x0 < $1.x0 }) }
        return out
    }

    /// Join a row into a plain string, inserting a space wherever the horizontal gap suggests one.
    static func line(_ row: [PlateWord]) -> String {
        var s = ""
        var cursor = -Double.greatestFiniteMagnitude
        for w in row.prefix(1_000) {                              // bounded (rule 2)
            if !s.isEmpty && w.x0 - cursor > w.pitch * 0.6 { s += " " }
            s += w.text
            cursor = max(cursor, w.x1)
        }
        return s
    }

    /// Median of a sorted-able list, or `fallback` when empty.
    static func median(_ values: [Double], fallback: Double) -> Double {
        guard !values.isEmpty else { return fallback }
        let s = values.sorted()
        return s[s.count / 2]
    }

    #if canImport(PDFKit)

    // MARK: PDFKit surface

    /// A laid-out line: its text and its box, y-DOWN. Good enough for prose (notes), where only the
    /// words matter; NOT used for the minima table, where the character order is what matters.
    struct Line { let text: String; let rect: CGRect }

    static func lines(page: PDFPage) -> [Line] {
        let media = page.bounds(for: .mediaBox)
        guard let all = page.selection(for: media) else { return [] }
        let height = Double(media.maxY)
        var out: [Line] = []
        for sel in all.selectionsByLine().prefix(maxRows) {        // bounded (rule 2)
            let b = sel.bounds(for: page)
            guard let t = sel.string, !t.isEmpty else { continue }
            out.append(Line(text: t,
                            rect: CGRect(x: b.minX - media.minX, y: height - Double(b.maxY),
                                         width: b.width, height: b.height)))
        }
        return out
    }

    /// Every character anchored in `rect` (page space, y-UP), in visual order, grouped into runs.
    ///
    /// Two passes: a vertical sweep finds the rows that actually carry text, then each row is swept
    /// horizontally. Sweeping only the occupied rows is what keeps this cheap — a whole minima band costs
    /// a few thousand queries rather than the hundreds of thousands a full raster of the page would.
    static func scan(page: PDFPage, in rect: CGRect, step: Double = scanStep) -> [PlateWord] {
        assert(step > 0.05, "PlateText.scan: degenerate step")
        guard rect.width > 0, rect.height > 0 else { return [] }
        let media = page.bounds(for: .mediaBox)
        let pageHeight = Double(media.maxY)
        var out: [PlateWord] = []

        for band in occupiedBands(page: page, in: rect, step: step).prefix(maxRows) {   // bounded (rule 2)
            let probe = CGRect(x: rect.minX, y: band.lo - step, width: rect.width, height: band.hi - band.lo + 2 * step)
            let samples = sweep(page: page, band: probe, step: step)
            guard !samples.isEmpty else { continue }
            let advances = zip(samples.dropFirst(), samples).map { $0.0.x - $0.1.x }
            let pitch = median(advances.filter { $0 > 0.6 }, fallback: 3.5)
            let brk = max(pitch * runBreakFactor, runBreakFloor)
            // y-DOWN box for the whole band; individual characters share it.
            let yTop = pageHeight - Double(probe.maxY)
            let yBottom = pageHeight - Double(probe.minY)

            var text = ""
            var x0 = 0.0, x1 = 0.0
            func flush() {
                guard !text.isEmpty else { return }
                out.append(PlateWord(text: text, x0: x0, x1: x1, yTop: yTop, yBottom: yBottom, pitch: pitch))
                text = ""
            }
            var cursor = -Double.greatestFiniteMagnitude
            for s in samples.prefix(maxSamples) {                 // bounded (rule 2)
                if !text.isEmpty && s.x - cursor > brk { flush() }
                if text.isEmpty { x0 = s.x - Double(media.minX) }
                text += s.text
                cursor = s.x
                x1 = s.x - Double(media.minX) + pitch
            }
            flush()
        }
        return out
    }

    /// Vertical extents inside `rect` that carry text, y-UP, merged when they are closer than one line.
    private static func occupiedBands(page: PDFPage, in rect: CGRect, step: Double) -> [(lo: Double, hi: Double)] {
        var marks: [Double] = []
        var y = rect.minY
        var guardCount = 0
        while y < rect.maxY && guardCount < maxSamples {          // bounded (rule 2)
            guardCount += 1
            let strip = CGRect(x: rect.minX, y: y, width: rect.width, height: step)
            if let s = page.selection(for: strip)?.string,
               !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { marks.append(y) }
            y += step
        }
        guard !marks.isEmpty else { return [] }
        // A raised fraction numerator anchors ~1.5 pt above its row, so bands closer than 2.5 pt are the
        // same visual row and must not be split apart.
        var out: [(lo: Double, hi: Double)] = []
        var lo = marks[0], hi = marks[0]
        for m in marks.dropFirst().prefix(maxSamples) {           // bounded (rule 2)
            if m - hi > 2.5 { out.append((lo, hi)); lo = m }
            hi = m
        }
        out.append((lo, hi))
        return out
    }

    /// Characters anchored in `band`, left to right.
    private static func sweep(page: PDFPage, band: CGRect, step: Double) -> [(x: Double, text: String)] {
        var out: [(x: Double, text: String)] = []
        var x = band.minX
        var guardCount = 0
        while x < band.maxX && guardCount < maxSamples {          // bounded (rule 2)
            guardCount += 1
            let probe = CGRect(x: x, y: band.minY, width: step, height: band.height)
            if let s = page.selection(for: probe)?.string {
                // A probe that lands on a typeset fraction returns its numerator and denominator with a
                // line break between them. They are one visibility, so every space inside a sample is
                // dropped — not just the ones at the ends.
                let t = s.filter { !$0.isWhitespace }
                if !t.isEmpty { out.append((x: Double(x), text: t)) }
            }
            x += step
        }
        return out
    }
    #endif
}
