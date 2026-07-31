import XCTest
@testable import ATCTranscribe

/// The bundled terrain-relief pack is the app's first genuinely SPARSE pack: it carries its deepest
/// level only where there is terrain worth the bytes (3,875 of 12,042 land tiles at z10 — 51% of land
/// left to the parent), and flat country is magnified from a shallower level, where for flat country
/// the result is indistinguishable.
///
/// That makes the ancestor fallback load-bearing rather than a nicety. Without it a missing deep tile
/// is a HOLE in the map over the plains, not a smooth parent — and the pack could only ever be dense,
/// which is what the 4× resolution increase was traded against.
final class SparseTerrainPackTests: XCTestCase {

    // MARK: - the ancestor address arithmetic

    func testOneStepUpHalvesTheAddressAndPicksTheRightQuadrant() {
        // z10/206,415 is a real dropped tile: the flat Mesilla valley south-west of Las Cruces. Its
        // parent z9/103,207 exists and covers it.
        let a = MBTilesTileOverlay.ancestorSource(z: 10, x: 206, y: 415, step: 1)
        XCTAssertEqual(a?.ax, 103)
        XCTAssertEqual(a?.ay, 207)
        XCTAssertEqual(a?.ox, 0, "206 is even → left half of the parent")
        XCTAssertEqual(a?.oy, 1, "415 is odd → bottom half of the parent")
    }

    func testAllFourChildrenMapToTheSameParentAndDistinctQuadrants() {
        var quadrants = Set<String>()
        for dx in 0...1 {
            for dy in 0...1 {
                guard let a = MBTilesTileOverlay.ancestorSource(z: 10, x: 206 + dx, y: 414 + dy, step: 1) else {
                    return XCTFail("no ancestor for a valid tile")
                }
                XCTAssertEqual(a.ax, 103); XCTAssertEqual(a.ay, 207)
                quadrants.insert("\(a.ox),\(a.oy)")
            }
        }
        XCTAssertEqual(quadrants.count, 4, "the four children must land on four different quadrants")
    }

    func testTwoStepsUpWalksFourTilesPerEdge() {
        let a = MBTilesTileOverlay.ancestorSource(z: 10, x: 206, y: 415, step: 2)
        XCTAssertEqual(a?.ax, 51); XCTAssertEqual(a?.ay, 103)
        XCTAssertEqual(a?.ox, 2); XCTAssertEqual(a?.oy, 3)
    }

    func testWalkingPastTheRootIsRefusedRatherThanWrapped() {
        // A negative zoom would index a tile that does not exist; the guard must refuse, not compute.
        XCTAssertNil(MBTilesTileOverlay.ancestorSource(z: 1, x: 1, y: 1, step: 2))
        XCTAssertNil(MBTilesTileOverlay.ancestorSource(z: 0, x: 0, y: 0, step: 1))
    }

    func testADegenerateStepIsRefused() {
        XCTAssertNil(MBTilesTileOverlay.ancestorSource(z: 10, x: 206, y: 415, step: 0))
        XCTAssertNil(MBTilesTileOverlay.ancestorSource(z: 10, x: 206, y: 415, step: 9))
    }

    // MARK: - the shipped pack

    /// Resolved exactly as the app resolves it (MapLibreChartView.bundledTerrainBase), so the test
    /// exercises the same lookup that would fail in production.
    private var pack: MBTilesReader? {
        Bundle.main.url(forResource: "terrain_base", withExtension: "mbtiles", subdirectory: "basemap")
            .flatMap { MBTilesReader(path: $0.path) }
    }

    func testThePackDeclaresTheDepthItWasBuiltAt() throws {
        let r = try XCTUnwrap(pack, "bundled terrain pack missing")
        XCTAssertEqual(r.maxZoom, 10, "the source zoom and the declared maxzoom must agree — reading a "
                     + "rebuilt pack at the old depth is how a resolution GAIN gets misread as a loss")
        XCTAssertEqual(r.minZoom, 0)
    }

    func testEveryDroppedDeepTileHasAnAncestorThatExists() throws {
        // The invariant that makes sparsity safe. Sampled across the pack's own deep level rather than
        // asserted in the abstract: for any z10 address in bounds, walking up must reach a real tile.
        let r = try XCTUnwrap(pack, "bundled terrain pack missing")
        var checked = 0, holes: [String] = []
        // A spread over CONUS: mountains, plains, coast.
        for (x, y) in [(206, 415), (207, 415), (215, 390), (170, 380), (300, 400), (250, 370)] {
            guard r.tileData(z: 10, x: x, y: y) == nil else { continue }   // present natively → not a hole
            checked += 1
            var found = false
            for step in 1...4 {                                            // bounded (rule 2)
                guard let a = MBTilesTileOverlay.ancestorSource(z: 10, x: x, y: y, step: step) else { break }
                if r.tileData(z: 10 - step, x: a.ax, y: a.ay) != nil { found = true; break }
            }
            if !found { holes.append("z10/\(x),\(y)") }
        }
        XCTAssertTrue(holes.isEmpty, "dropped deep tiles with no ancestor — these render as holes: \(holes)")
        XCTAssertGreaterThan(checked, 0, "the sample found no dropped tiles; it is not testing sparsity")
    }

    func testTheShallowLevelsAreDenseSoTheFallbackAlwaysLands() throws {
        // Sparsity is allowed ONLY at the deepest level. If z9 were sparse too, a dropped z10 tile could
        // walk up into another hole — which is the bug that made the first sparse bake produce a pyramid
        // with 12 tiles at z9 where a dense bake gives 3,125.
        let r = try XCTUnwrap(pack, "bundled terrain pack missing")
        XCTAssertGreaterThan(r.tileCount(z: 9), 3_000,
                             "z9 must be DENSE — a sparse parent turns the deep-level fallback into a hole")
    }
}
