import XCTest
import UIKit
@testable import ATCTranscribe

/// Renders every airport-symbol variant to a labelled contact sheet so the FAA distinctions can be
/// CONFIRMED by eye, and asserts that each variant is actually visually DIFFERENT from the others.
///
/// The pixel-difference assertion is the real test: a rendering bug that silently drew two FAA classes
/// the same (a heliport indistinguishable from a private field, say) is exactly the kind of fault a
/// unit test on the classification alone would miss.
final class AirportGlyphSheetTests: XCTestCase {

    private struct Sample { let label: String; let spec: AirportSymbol.Spec }

    private func spec(_ kind: AirportSymbol.Kind, _ shape: AirportSymbol.Shape,
                      towered: Bool = false, fuel: Bool = false, beacon: Bool = false,
                      axes: [Int] = [40], cat: AirportSymbol.Category? = nil) -> AirportSymbol.Spec {
        AirportSymbol.Spec(kind: kind, shape: shape, towered: towered, fuel: fuel, beacon: beacon,
                           runwayAxesDeg: axes, category: cat)
    }

    private var samples: [Sample] {
        [
            // The ordinary airport family — the three FAA shapes.
            Sample(label: "Towered\nhard 1.5–8k", spec: spec(.airport, .filledCircleWithRunways, towered: true, axes: [40, 130])),
            Sample(label: "Non-towered\nhard 1.5–8k", spec: spec(.airport, .filledCircleWithRunways, axes: [40, 130])),
            Sample(label: "Soft / <1500ft\nopen circle", spec: spec(.airport, .openCircle)),
            Sample(label: "Runway >8069ft\nno circle", spec: spec(.airport, .runwaysOnly, towered: true, axes: [35, 90])),
            Sample(label: "Multi-runway\nno circle", spec: spec(.airport, .runwaysOnly, towered: true, axes: [10, 65, 110, 155])),
            // Modifiers.
            Sample(label: "+ Fuel\n(tick marks)", spec: spec(.airport, .filledCircleWithRunways, towered: true, fuel: true, axes: [40, 130])),
            Sample(label: "+ Beacon\n(star)", spec: spec(.airport, .filledCircleWithRunways, towered: true, beacon: true, axes: [40, 130])),
            Sample(label: "+ Fuel + Beacon", spec: spec(.airport, .filledCircleWithRunways, towered: true, fuel: true, beacon: true, axes: [40, 130])),
            // The distinct FAA classes.
            Sample(label: "Military\n(double ring)", spec: spec(.military, .runwaysOnly, towered: true, axes: [5, 110])),
            Sample(label: "Heliport (H)", spec: spec(.heliport, .openCircle)),
            Sample(label: "Seaplane\n(anchor)", spec: spec(.seaplane, .openCircle)),
            Sample(label: "Ultralight (F)", spec: spec(.ultralight, .openCircle)),
            Sample(label: "Private (R)", spec: spec(.privateUse, .openCircle)),
            Sample(label: "Unverified (U)", spec: spec(.unverified, .openCircle)),
            Sample(label: "Abandoned (X)", spec: spec(.abandoned, .openCircle)),
            // Flight-category rings — drawn AROUND the FAA symbol, which keeps its tower colour.
            Sample(label: "VFR ring", spec: spec(.airport, .filledCircleWithRunways, towered: true, axes: [40, 130], cat: .vfr)),
            Sample(label: "MVFR ring", spec: spec(.airport, .filledCircleWithRunways, towered: true, axes: [40, 130], cat: .mvfr)),
            Sample(label: "IFR ring", spec: spec(.airport, .filledCircleWithRunways, towered: true, axes: [40, 130], cat: .ifr)),
            Sample(label: "LIFR ring", spec: spec(.airport, .filledCircleWithRunways, towered: true, axes: [40, 130], cat: .lifr)),
            // The case the first cut lost: same weather, different tower status.
            Sample(label: "Non-towered\nVFR ring", spec: spec(.airport, .filledCircleWithRunways, axes: [40, 130], cat: .vfr)),
            Sample(label: "Runways only\nIFR ring", spec: spec(.airport, .runwaysOnly, towered: true, axes: [35, 90], cat: .ifr)),
            // Runway orientation must actually rotate.
            Sample(label: "Rwy 09/27", spec: spec(.airport, .runwaysOnly, towered: true, axes: [90])),
            Sample(label: "Rwy 18/36", spec: spec(.airport, .runwaysOnly, towered: true, axes: [0])),
            Sample(label: "Rwy 04/22", spec: spec(.airport, .runwaysOnly, towered: true, axes: [40])),
        ]
    }

    /// Write the labelled contact sheet for visual confirmation.
    func testRenderLabelledGlyphSheet() throws {
        let all = samples
        let cols = 6
        let cell = CGSize(width: 122, height: 122)
        let rows = (all.count + cols - 1) / cols
        let size = CGSize(width: cell.width * CGFloat(cols), height: cell.height * CGFloat(rows))

        let img = UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor(white: 0.09, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            for (i, s) in all.enumerated() {
                let ox = CGFloat(i % cols) * cell.width, oy = CGFloat(i / cols) * cell.height
                let glyph = AirportSymbolRenderer.image(for: s.spec)
                glyph.draw(at: CGPoint(x: ox + (cell.width - glyph.size.width) / 2, y: oy + 8))
                let para = NSMutableParagraphStyle(); para.alignment = .center
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 9, weight: .medium),
                    .foregroundColor: UIColor(white: 0.85, alpha: 1),
                    .paragraphStyle: para]
                NSAttributedString(string: s.label, attributes: attrs)
                    .draw(in: CGRect(x: ox + 3, y: oy + 60, width: cell.width - 6, height: 50))
            }
        }
        let out = URL(fileURLWithPath: "/tmp/glyph_sheet.png")
        try img.pngData()!.write(to: out)
        print("GLYPHSHEET \(out.path) variants=\(all.count)")
        XCTAssertGreaterThan(all.count, 20)
    }

    /// Every variant must render DISTINCTLY. Two FAA classes that look identical would be a real
    /// hazard — a pilot reading a private field as a public one, or a heliport as an airport.
    func testEveryVariantIsVisuallyDistinct() {
        var seen: [String: String] = [:]                      // pixel hash → label
        for s in samples {
            let img = AirportSymbolRenderer.image(for: s.spec)
            guard let data = img.pngData() else { XCTFail("\(s.label) failed to render"); continue }
            // A cheap content hash: the PNG bytes of a deterministically-rendered glyph.
            let hash = "\(data.count)-\(data.prefix(512).reduce(0) { $0 &+ Int($1) })-\(data.suffix(512).reduce(0) { $0 &+ Int($1) })"
            if let clash = seen[hash] {
                XCTFail("'\(s.label)' renders identically to '\(clash)' — the distinction is invisible")
            }
            seen[hash] = s.label
        }
        XCTAssertEqual(seen.count, samples.count, "every variant must be visually distinct")
    }

    /// The FAA tower colour must survive a weather report. The first cut tinted the whole symbol by
    /// flight category, which made a towered and a non-towered field identical wherever a METAR existed —
    /// confirmed on the chart over the LA basin, where every field drew as the same green dot.
    func testTowerStatusIsStillReadableWhenTheFieldReportsWeather() {
        let towered = spec(.airport, .filledCircleWithRunways, towered: true, axes: [40], cat: .vfr)
        let non = spec(.airport, .filledCircleWithRunways, axes: [40], cat: .vfr)
        XCTAssertEqual(AirportSymbolRenderer.tint(towered), AirportSymbolRenderer.towerBlue)
        XCTAssertEqual(AirportSymbolRenderer.tint(non), AirportSymbolRenderer.nonTowerMag)
        XCTAssertNotEqual(AirportSymbolRenderer.image(for: towered).pngData(),
                          AirportSymbolRenderer.image(for: non).pngData())
    }

    /// The category rides in its own channel: same airport, different weather → same symbol, different ring.
    func testTheFlightCategoryIsCarriedByTheRingNotTheSymbolColour() {
        let vfr = spec(.airport, .filledCircleWithRunways, towered: true, axes: [40], cat: .vfr)
        let ifr = spec(.airport, .filledCircleWithRunways, towered: true, axes: [40], cat: .ifr)
        XCTAssertEqual(AirportSymbolRenderer.tint(vfr), AirportSymbolRenderer.tint(ifr),
                       "the FAA symbol colour must not move with the weather")
        XCTAssertEqual(AirportSymbolRenderer.ringColor(vfr), AirportSymbolRenderer.vfrGreen)
        XCTAssertEqual(AirportSymbolRenderer.ringColor(ifr), AirportSymbolRenderer.ifrRed)
        XCTAssertNotEqual(AirportSymbolRenderer.image(for: vfr).pngData(),
                          AirportSymbolRenderer.image(for: ifr).pngData())
    }

    /// A field that isn't reporting gets NO ring — absence of information is never drawn as a condition.
    func testANonReportingFieldDrawsNoRing() {
        XCTAssertNil(AirportSymbolRenderer.ringColor(spec(.airport, .openCircle)))
    }

    /// The renderer must actually rotate with the runway — an airport's symbol shows its layout.
    func testRunwayOrientationChangesTheRendering() {
        let ns = AirportSymbolRenderer.image(for: spec(.airport, .runwaysOnly, towered: true, axes: [0]))
        let ew = AirportSymbolRenderer.image(for: spec(.airport, .runwaysOnly, towered: true, axes: [90]))
        XCTAssertNotEqual(ns.pngData(), ew.pngData(), "a N/S runway must not draw the same as an E/W one")
    }

    /// Real airports from the bundled dataset classify into the expected FAA families.
    func testRealAirportsClassifyAsExpected() throws {
        try XCTSkipUnless(AirportSymbolData.isAvailable, "bundled airport_symbols.json missing")
        // KBOS: towered, fuel, beacon, hard-surfaced, 10,006 ft → no circle.
        let bos = AirportSymbolData.spec("KBOS", category: .vfr)
        XCTAssertEqual(bos.kind, .airport)
        XCTAssertTrue(bos.towered, "KBOS is towered")
        XCTAssertEqual(bos.shape, .runwaysOnly, "KBOS's 10,006 ft runway drops the circle")
        XCTAssertFalse(bos.runwayAxesDeg.isEmpty, "KBOS must draw its runway layout")

        // KTCS: NOT towered — the magenta case.
        XCTAssertFalse(AirportSymbolData.spec("KTCS").towered, "KTCS has no control tower")

        // KNZY: a Naval Air Station → the military glyph.
        XCTAssertEqual(AirportSymbolData.spec("KNZY").kind, .military, "KNZY is a Naval Air Station")
    }
}
