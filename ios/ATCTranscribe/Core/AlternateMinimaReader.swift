import Foundation
#if canImport(PDFKit)
import PDFKit
#endif

/// Turns an IFR ALTERNATE MINIMUMS booklet into the line-ordered text `AlternateMinimaParser` reads.
///
/// ⚠️ THE BOOKLET IS TWO COLUMNS AND PDFKIT DOES NOT KNOW IT. `selectionsByLine()` returns lines in
/// y-then-x order, so the columns INTERLEAVE: on the real NE1 booklet, "AUBURN/LEWISTON, ME" in the left
/// column is immediately followed by "BAR HARBOR, ME" from the right column at the same height. Every
/// block would therefore end at its own first line — `isBlockBoundary` sees a city header and stops —
/// and the parser would return nil for essentially every airport. Splitting the page into columns and
/// reading each in full is not a refinement here; without it the feature returns nothing.
///
/// Full-width lines (the page's prose preamble) stay in the left stream at their own height, which keeps
/// them ahead of the first airport block where they belong.
enum AlternateMinimaReader {

    /// Cap on pages swept (rule 2). The largest booklet in the cycle is well under this.
    static let maxPages = 24

    /// A line's box need only carry x, width and y for the column decision.
    struct Placed: Equatable {
        let x: Double
        let width: Double
        let y: Double
        let text: String
    }

    /// A line wider than this fraction of the page spans both columns and is not column content.
    static let fullWidthFraction = 0.55

    /// Order `lines` into single-column reading order: everything left of the gutter top-to-bottom,
    /// then everything right of it.
    ///
    /// Pure and page-shaped so the ordering can be tested without a PDF.
    static func ordered(_ lines: [Placed], pageWidth: Double) -> [String] {
        assert(pageWidth > 0, "AlternateMinimaReader: non-positive page width")
        guard pageWidth > 0 else { return lines.map(\.text) }
        var left: [Placed] = [], right: [Placed] = []
        for l in lines.prefix(4096) {                                    // bounded (rule 2)
            if l.width > pageWidth * fullWidthFraction { left.append(l) }
            else if l.x > pageWidth * 0.5 { right.append(l) }
            else { left.append(l) }
        }
        let byY: (Placed, Placed) -> Bool = { $0.y < $1.y }
        return left.sorted(by: byY).map(\.text) + right.sorted(by: byY).map(\.text)
    }

    #if canImport(PDFKit)
    /// The booklet's text in reading order, or nil when the file cannot be opened.
    ///
    /// Returns nil rather than empty text so a caller can tell "not readable" from "read, no match" —
    /// the second is the normal answer for an airport with standard alternate minima.
    static func text(pdfAt url: URL) -> String? {
        guard let doc = PDFDocument(url: url), doc.pageCount > 0 else { return nil }
        var out: [String] = []
        for i in 0..<min(doc.pageCount, maxPages) {                      // bounded (rule 2)
            guard let page = doc.page(at: i) else { continue }
            let media = page.bounds(for: .mediaBox)
            guard let all = page.selection(for: media) else { continue }
            var placed: [Placed] = []
            for sel in all.selectionsByLine().prefix(2048) {             // bounded (rule 2)
                guard let t = sel.string, !t.isEmpty else { continue }
                let b = sel.bounds(for: page)
                placed.append(Placed(x: Double(b.minX - media.minX), width: Double(b.width),
                                     y: Double(media.maxY - b.maxY), text: t))
            }
            out += ordered(placed, pageWidth: Double(media.width))
        }
        assert(out.count < 100_000, "AlternateMinimaReader: implausible line count")
        return out.isEmpty ? nil : out.joined(separator: "\n")
    }
    #endif
}
