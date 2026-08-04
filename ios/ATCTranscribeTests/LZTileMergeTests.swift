import XCTest
@testable import ATCTranscribe

/// Merging one tile across several packs.
///
/// ⚠️ THE BUG THIS EXISTS FOR WAS VISIBLE, AND ONLY WHEN ZOOMED OUT. A pack is cut to its own
/// 1-degree cell, but a TILE is not: at z13 a tile is ~4 km and sits inside one cell, while at z10
/// it is ~40 km and straddles four. Each pack publishes its own copy of that shared tile carrying
/// only its own corner — measured over the New Mexico four-corner point, four packs held 38%, 31%,
/// 30% and 25% of ONE z10 tile.
///
/// The store returned the first pack that had the tile and stopped, so three quarters of the answer
/// was discarded and the map drew a gap several miles wide between two areas that both had data.
/// Zooming in appeared to "fix" it, because one tile fell inside one cell again. A pilot reads a
/// hole in this layer as "nothing landable here", which is the most dangerous thing it can say.
final class LZTileMergeTests: XCTestCase {

    private let n = LZPack.side * LZPack.side

    /// A tile whose surface class is known only on one side, the way a real pack looks for ground
    /// that runs off the edge of its own cell.
    private func halfTile(keepLeft: Bool, cls: UInt8 = LZPack.classCrop,
                          slope: UInt8 = 10, terrain: UInt8 = LZPack.terrainFine) -> LZTilePlanes {
        var planes = [[UInt8]](repeating: [UInt8](repeating: 0, count: n), count: LZPack.planeCount)
        for row in 0..<LZPack.side {
            for col in 0..<LZPack.side {
                let mine = keepLeft ? (col < LZPack.side / 2) : (col >= LZPack.side / 2)
                guard mine else { continue }
                let i = row * LZPack.side + col
                planes[LZPack.planeClass][i] = cls
                planes[LZPack.planeSlope][i] = slope
                planes[LZPack.planeExtent][i] = 200
            }
        }
        return LZTilePlanes(planes: planes, terrainSource: terrain)
    }

    private func knownFraction(_ t: LZTilePlanes) -> Double {
        Double(t.planes[LZPack.planeClass].filter { $0 != LZPack.classUnknown }.count) / Double(n)
    }

    // MARK: - the hole

    /// THE REGRESSION. Two packs, each holding half the tile, must merge into a whole one.
    func testTwoHalvesMakeACompleteTile() throws {
        let merged = try XCTUnwrap(LZPackStore.merge([halfTile(keepLeft: true),
                                                      halfTile(keepLeft: false)]))
        XCTAssertEqual(knownFraction(merged), 1.0, accuracy: 0.0001,
                       "the tile is still holed — this is the gap between cells")
    }

    /// And the fill is REAL DATA, not just a non-zero class: every plane must come across together,
    /// or the merged cell would carry one pack's class with another's slope.
    func testTheFillCarriesEveryPlaneTogether() throws {
        let left = halfTile(keepLeft: true, cls: LZPack.classCrop, slope: 10)
        let right = halfTile(keepLeft: false, cls: LZPack.classForest, slope: 200)
        let merged = try XCTUnwrap(LZPackStore.merge([left, right]))
        // A pixel from the left half keeps the left pack's numbers …
        XCTAssertEqual(merged.value(plane: LZPack.planeClass, x: 10, y: 5), LZPack.classCrop)
        XCTAssertEqual(merged.value(plane: LZPack.planeSlope, x: 10, y: 5), 10)
        // … and one filled from the right carries the RIGHT pack's, not a mixture.
        XCTAssertEqual(merged.value(plane: LZPack.planeClass, x: 200, y: 5), LZPack.classForest)
        XCTAssertEqual(merged.value(plane: LZPack.planeSlope, x: 200, y: 5), 200)
        XCTAssertEqual(merged.value(plane: LZPack.planeExtent, x: 200, y: 5), 200)
    }

    /// Four packs meeting at a corner — the case actually observed on the map.
    func testFourQuartersMakeACompleteTile() throws {
        func quarter(left: Bool, top: Bool) -> LZTilePlanes {
            var planes = [[UInt8]](repeating: [UInt8](repeating: 0, count: n),
                                   count: LZPack.planeCount)
            for row in 0..<LZPack.side where (row < LZPack.side / 2) == top {
                for col in 0..<LZPack.side where (col < LZPack.side / 2) == left {
                    planes[LZPack.planeClass][row * LZPack.side + col] = LZPack.classOpenFirm
                }
            }
            return LZTilePlanes(planes: planes, terrainSource: LZPack.terrainFine)
        }
        let merged = try XCTUnwrap(LZPackStore.merge([quarter(left: true, top: true),
                                                      quarter(left: false, top: true),
                                                      quarter(left: true, top: false),
                                                      quarter(left: false, top: false)]))
        XCTAssertEqual(knownFraction(merged), 1.0, accuracy: 0.0001)
    }

    // MARK: - what must NOT change

    /// Overlap is not a merge conflict to be averaged. Where two packs both measured the same
    /// ground they agree — same federal sources — so the first known value stands.
    func testOverlapKeepsTheFirstPacksValueRatherThanBlending() throws {
        let a = halfTile(keepLeft: true, cls: LZPack.classCrop, slope: 10)
        let b = halfTile(keepLeft: true, cls: LZPack.classForest, slope: 200)   // same half
        let merged = try XCTUnwrap(LZPackStore.merge([a, b]))
        XCTAssertEqual(merged.value(plane: LZPack.planeClass, x: 10, y: 5), LZPack.classCrop)
        XCTAssertEqual(merged.value(plane: LZPack.planeSlope, x: 10, y: 5), 10,
                       "values were blended — slope must be a measurement, never an average of two")
    }

    /// ⚠️ COARSE IS STICKY. The cap that stops unsurveyed ground outscoring measured ground rides on
    /// this one byte. If a fine pack is merged first and a coarse pack supplies the ground, taking
    /// the first pack's provenance would launder that cell into looking properly surveyed.
    func testCoarseProvenanceSurvivesAMergeWithAFinePack() throws {
        let fine = halfTile(keepLeft: true, terrain: LZPack.terrainFine)
        let coarse = halfTile(keepLeft: false, terrain: LZPack.terrainCoarse)
        let merged = try XCTUnwrap(LZPackStore.merge([fine, coarse]))
        XCTAssertTrue(merged.isCoarseTerrain,
                      "a coarse contributor was laundered into looking finely surveyed")
    }

    /// The converse: a coarse pack that contributes NOTHING must not downgrade the tile.
    func testAPackThatFillsNothingDoesNotChangeProvenance() throws {
        let fine = halfTile(keepLeft: true, terrain: LZPack.terrainFine)
        let coarseSameHalf = halfTile(keepLeft: true, terrain: LZPack.terrainCoarse)
        let merged = try XCTUnwrap(LZPackStore.merge([fine, coarseSameHalf]))
        XCTAssertFalse(merged.isCoarseTerrain,
                       "provenance was downgraded by a pack that supplied no ground")
    }

    // MARK: - degenerate

    func testOnePackIsReturnedUntouched() throws {
        let one = halfTile(keepLeft: true)
        let merged = try XCTUnwrap(LZPackStore.merge([one]))
        XCTAssertEqual(knownFraction(merged), 0.5, accuracy: 0.0001)
    }

    func testNoPacksYieldNothing() {
        XCTAssertNil(LZPackStore.merge([]))
    }
}
