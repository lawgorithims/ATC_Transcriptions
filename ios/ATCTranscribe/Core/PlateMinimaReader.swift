import Foundation
import CoreGraphics
#if canImport(PDFKit)
import PDFKit
#endif

/// Gets the two things the minima parser needs out of a plate PDF: the positioned text of the minima
/// band, and the prose of the notes.
///
/// They are read differently on purpose. The notes only need words, so the laid-out line strings are
/// enough and are cheap. The table needs to know what is printed WHERE — which column a value sits under
/// decides which aircraft category it applies to — so the band is swept character by character. Sweeping
/// the whole page that way would be wasteful, hence the two-phase approach: find the `CATEGORY` header
/// first, then sweep only what is under it.
enum PlateMinimaReader {

    /// How far below the header the table can run, in points. FAA minima blocks are about 60 pt deep.
    static let bandDepth = 84.0
    /// How far left of the header word the row labels can start.
    static let labelMargin = 6.0

    struct Extract {
        var bandWords: [PlateWord] = []
        var notesText: String = ""
        /// Set when the page carries no extractable text at all — a scanned raster plate. That is a
        /// different answer from "parsed and found nothing", and the UI says so differently.
        var isRaster = false
        /// Set when the file could not be opened as a PDF at all. Distinct from every other empty result:
        /// a missing or corrupt file is a cache problem the pilot can fix by re-downloading, and reporting
        /// it as "this chart has no readable minima" sends them looking in the wrong place.
        var isUnreadable = false
    }

    #if canImport(PDFKit)
    static func extract(pdfAt url: URL) -> Extract {
        guard let doc = PDFDocument(url: url), let page = doc.page(at: 0) else {
            var out = Extract()
            out.isUnreadable = true
            return out
        }
        return extract(page: page)
    }

    static func extract(page: PDFPage) -> Extract {
        var out = Extract()
        let lines = PlateText.lines(page: page)
        guard !lines.isEmpty else { out.isRaster = true; return out }

        var prose = ""
        for l in lines.prefix(PlateText.maxRows) { prose += l.text + " " }   // bounded (rule 2)
        out.notesText = prose

        let media = page.bounds(for: .mediaBox)
        guard let header = lines.first(where: { $0.text.uppercased().contains("CATEGORY") }) else { return out }

        // `rect` is y-UP page space; the header rect is y-DOWN, so the band lies BELOW it in reading
        // order, which is below it in decreasing y-up terms.
        let headerTopY = Double(media.maxY) - Double(header.rect.minY)      // y-up of the header's top
        let bandTop = headerTopY + 1.0
        let bandBottom = headerTopY - bandDepth
        let scanRect = CGRect(x: Double(media.minX), y: max(bandBottom, Double(media.minY)),
                              width: Double(media.width), height: bandTop - max(bandBottom, Double(media.minY)))
        guard scanRect.height > 4 else { return out }

        let swept = PlateText.scan(page: page, in: scanRect)
        // Trim to the table: everything left of the label column start, and right of the last category
        // column, belongs to the panels around the table.
        guard let cat = swept.first(where: { $0.text.uppercased().hasPrefix("CATEGORY") }) else {
            out.bandWords = swept
            return out
        }
        out.bandWords = swept.filter { $0.x1 > cat.x0 - labelMargin }
        return out
    }
    #endif
}
