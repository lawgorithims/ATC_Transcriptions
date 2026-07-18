// EXPERIMENTAL — branch experimental/maplibre-migration. DO NOT MERGE.
//
// Pure classification of a navaid's FAA type string → the MapLibre nav-symbol layer's per-feature icon
// name. This is the extracted, deterministic core of Coordinator.glyphName (no NavMeta/DB dependency), so
// the FAA symbology mapping is statically pinned. Gated on MapLibre so a MapLibre-excluded build (the
// shipping config per the build-62 note) simply compiles this out.
#if canImport(MapLibre)
import XCTest
@testable import ATCTranscribe

final class MapLibreNavGlyphTests: XCTestCase {
    private func glyph(_ t: String) -> String { MapLibreChartView.Coordinator.navGlyph(forType: t) }

    func testPlainVOR()  { XCTAssertEqual(glyph("VOR"), "nav-vor") }
    func testVORTAC()    { XCTAssertEqual(glyph("VORTAC"), "nav-vortac") }
    func testVORDME()    { XCTAssertEqual(glyph("VOR/DME"), "nav-vordme"); XCTAssertEqual(glyph("VOR-DME"), "nav-vordme") }
    func testNDB()       { XCTAssertEqual(glyph("NDB"), "nav-ndb") }
    func testNDBDME()    { XCTAssertEqual(glyph("NDB/DME"), "nav-ndbdme") }

    /// SAFETY of the classification ORDER: a TACAN and a bare DME must NOT be drawn with the VOR glyph
    /// (they carry no VOR service). This pins the exact regression the FAA-symbology work fixed.
    func testTACANIsNotVOR() {
        XCTAssertEqual(glyph("TACAN"), "nav-tacan")
        XCTAssertNotEqual(glyph("TACAN"), "nav-vor")
    }
    func testBareDMEIsNotVOR() {
        XCTAssertEqual(glyph("DME"), "nav-dme")
        XCTAssertNotEqual(glyph("DME"), "nav-vordme")   // bare DME, not the VOR-DME combo
    }

    func testCaseInsensitive()        { XCTAssertEqual(glyph("vortac"), "nav-vortac") }
    func testUnknownFallsBackToVOR()  { XCTAssertEqual(glyph("WHATSIT"), "nav-vor") }
    func testEveryGlyphIsRegistered() {
        // Every name this classifier can emit must be one the layer registered (registerNavImages).
        let registered: Set<String> = ["nav-airport", "nav-fix", "nav-vor", "nav-vortac", "nav-vordme",
                                       "nav-ndb", "nav-ndbdme", "nav-tacan", "nav-dme"]
        for t in ["VOR", "VORTAC", "VOR/DME", "NDB", "NDB/DME", "TACAN", "DME", "WHATSIT", ""] {
            XCTAssertTrue(registered.contains(glyph(t)), "\(t) → \(glyph(t)) is not a registered glyph")
        }
    }
}
#endif
