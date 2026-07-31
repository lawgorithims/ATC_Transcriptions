import XCTest
@testable import ATCTranscribe

/// The raster level-selection contract.
///
/// The whole "chart goes soft too early when zooming out" fix is one integer's worth of arithmetic
/// against a formula that lives in vendored C++ (`src/mbgl/util/tile_cover.cpp`, `coveringZoomLevel`).
/// Nothing in Swift enforces it, so these tests are the tripwire: an upstream rebase that changes the
/// rounding, or an accidental revert of the declared tileSize to 256, fails here rather than silently
/// un-fixing the chart in a way only a pilot would notice.
final class RasterTileZoomTests: XCTestCase {

    private typealias C = MapLibreChartView.Coordinator

    /// At the conventional 256 the rule is `round(Z + 1)` — the level steps at the HALF zoom, which is
    /// the behaviour being fixed.
    func testConventionalTileSizeStepsAtTheHalfZoom() {
        let cases: [(Double, Int)] = [
            (6.0, 7), (6.4, 7), (6.49, 7),      // still on level 7 through the lower half
            (6.5, 8), (6.6, 8), (7.0, 8), (7.49, 8),
            (7.5, 9), (8.0, 9),
        ]
        for (zoom, expected) in cases {
            XCTAssertEqual(C.rasterTileZ(mapZoom: zoom, tileSize: 256, maxZoom: 22), expected,
                           "map zoom \(zoom)")
        }
    }

    /// The bias moves the step to the integer: the deeper level is held across the whole octave.
    /// This is the user-visible property — the chart stops going soft half an octave early.
    func testBiasedTileSizeStepsAtTheIntegerZoom() {
        let cases: [(Double, Int)] = [
            (6.0, 8), (6.4, 8), (6.9, 8), (6.99, 8),     // level 8 held across the whole octave
            (7.0, 9), (7.4, 9), (7.99, 9),
            (8.0, 10),
        ]
        for (zoom, expected) in cases {
            XCTAssertEqual(C.rasterTileZ(mapZoom: zoom, tileSize: C.rasterTileSize, maxZoom: 22), expected,
                           "map zoom \(zoom)")
        }
    }

    /// 181 and not 182. The app parks its camera on INTEGER zooms, and a 182 bias (1.4922) still picks
    /// the same level 256 does at exactly those zooms — it would have cost tiles everywhere and changed
    /// nothing at the commonest position on screen. This is the test that catches that mistake.
    func testTheBiasActuallyChangesTheLevelAtIntegerZooms() {
        for k in [5, 6, 7, 8, 9] {                                  // bounded (rule 2)
            let z = Double(k)
            let conventional = C.rasterTileZ(mapZoom: z, tileSize: 256, maxZoom: 22)
            let biased = C.rasterTileZ(mapZoom: z, tileSize: C.rasterTileSize, maxZoom: 22)
            XCTAssertEqual(biased, conventional + 1,
                           "at integer zoom \(k) the bias must pick one level DEEPER, not the same one")
            XCTAssertEqual(C.rasterTileZ(mapZoom: z - 0.01, tileSize: C.rasterTileSize, maxZoom: 22), k + 1,
                           "just below integer \(k) must still be on the shallower level")
        }
    }

    /// The chart must never be drawn MAGNIFIED within an octave. Chart pixels per screen point is
    /// `256 / (512 * 2^(Z - z))`; at 256 the worst case is 0.707 (a 1.41x blow-up), at 182 it is ~0.995.
    func testTheChartIsNeverMagnifiedWithinAnOctave() {
        func chartPixelsPerPoint(_ zoom: Double, _ tileSize: Int) -> Double {
            let z = C.rasterTileZ(mapZoom: zoom, tileSize: tileSize, maxZoom: 22)
            return 256.0 / (512.0 * pow(2.0, zoom - Double(z)))
        }
        var worstConventional = Double.greatestFiniteMagnitude
        var worstBiased = Double.greatestFiniteMagnitude
        for step in 0...100 {                                        // bounded (rule 2)
            let zoom = 6.0 + Double(step) / 100.0                    // one full octave
            worstConventional = min(worstConventional, chartPixelsPerPoint(zoom, 256))
            worstBiased = min(worstBiased, chartPixelsPerPoint(zoom, C.rasterTileSize))
        }
        XCTAssertLessThan(worstConventional, 0.72, "the old rule magnified by ~1.41x at its worst")
        XCTAssertGreaterThan(worstBiased, 0.98, "the biased rule must never magnify inside an octave")
    }

    /// The pack's real depth still caps the request — a source that declares its true maxzoom lets the
    /// GPU magnify for free instead of sending the loopback server down the CPU re-encode path.
    func testTheRequestIsClampedToThePacksRealDepth() {
        XCTAssertEqual(C.rasterTileZ(mapZoom: 12.0, tileSize: C.rasterTileSize, maxZoom: 11), 11)
        XCTAssertEqual(C.rasterTileZ(mapZoom: 20.0, tileSize: C.rasterTileSize, maxZoom: 7), 7)
        XCTAssertEqual(C.rasterTileZ(mapZoom: 0.5, tileSize: C.rasterTileSize, maxZoom: 11, minZoom: 5), 5)
    }
}
