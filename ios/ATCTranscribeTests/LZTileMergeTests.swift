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

    // MARK: - cost

    /// ⚠️ A REGRESSION GUARD ON THE RENDER PATH, WRITTEN AS A SCALING TEST ON PURPOSE.
    ///
    /// The first early-out rescanned all 65 536 pixels across every tile found so far, once per
    /// tile — O(n²) — and at low zoom over a contiguous block the tile can never complete, so it
    /// paid that in full and still decoded everything.
    ///
    /// Asserting milliseconds would pin a DEBUG number that says nothing about the shipped build
    /// and would flake on a loaded machine. Asserting the SHAPE of the cost does not: quadratic
    /// growth shows as 16x when the input quadruples, linear as 4x, whatever the absolute speed.
    func testMergeCostGrowsLinearlyWithPackCount() {
        func stripes(_ k: Int) -> [LZTilePlanes] {
            (0..<k).map { j in
                var planes = [[UInt8]](repeating: [UInt8](repeating: 0, count: n),
                                       count: LZPack.planeCount)
                for row in 0..<LZPack.side {
                    planes[LZPack.planeClass][row * LZPack.side + j] = LZPack.classCrop
                }
                return LZTilePlanes(planes: planes, terrainSource: LZPack.terrainFine)
            }
        }
        // Never completes, so no early-out can mask the growth.
        let small = stripes(8), large = stripes(32)
        _ = LZPackStore.merge(small); _ = LZPackStore.merge(large)      // warm
        func time(_ t: [LZTilePlanes]) -> Double {
            let t0 = CFAbsoluteTimeGetCurrent()
            for _ in 0..<3 { _ = LZPackStore.merge(t) }
            return CFAbsoluteTimeGetCurrent() - t0
        }
        let ratio = time(large) / max(time(small), 1e-9)
        // 4x the packs. Linear ≈ 4, quadratic ≈ 16. 8 leaves generous headroom for noise while
        // still failing loudly on a reintroduced rescan.
        XCTAssertLessThan(ratio, 8.0,
                          String(format: "4x the packs cost %.1fx the time — that is quadratic, "
                                 + "and it runs with a frame waiting", ratio))
    }

    /// The early-out must still fire: a first tile that already covers everything ends it.
    func testACompleteFirstTileStopsImmediately() throws {
        var full = [[UInt8]](repeating: [UInt8](repeating: LZPack.classCrop, count: n),
                             count: LZPack.planeCount)
        full[LZPack.planeSlope] = [UInt8](repeating: 12, count: n)
        let a = LZTilePlanes(planes: full, terrainSource: LZPack.terrainFine)
        // A coarse second tile must NOT change provenance, because it fills nothing.
        let b = halfTile(keepLeft: false, terrain: LZPack.terrainCoarse)
        let merged = try XCTUnwrap(LZPackStore.merge([a, b]))
        XCTAssertFalse(merged.isCoarseTerrain)
        XCTAssertEqual(merged.value(plane: LZPack.planeSlope, x: 200, y: 5), 12,
                       "a tile that was already complete was overwritten")
    }

    // MARK: - mixed schemas

    /// ⚠️ A PLANE THE CONTRIBUTOR NEVER CARRIED MUST NOT BECOME A MEASUREMENT OF ZERO.
    ///
    /// A pilot who downloaded cells before the extent plane existed and cells after it has both on
    /// disk, and at low zoom one tile is assembled from both. The fill copies only the planes the
    /// source HAS, so a schema-1 contributor used to leave the accumulator's own extent bytes —
    /// zeros, because that ground lay outside its cell — standing over the ground it supplied.
    ///
    /// Zero extent is not "unmeasured". It is "no open run at all": the cap table maps it to 0 and
    /// the cell scores as unusable terrain. `LZTilePlanes.extentRaw` says outright that a pack
    /// which predates the plane must fall back to the pre-extent score, never to a tiny field.
    func testASchemaOneContributorDropsTheExtentPlaneRatherThanReportingZeroRoom() throws {
        let modern = halfTile(keepLeft: true)                       // 7 planes, extent 200
        var oldPlanes = halfTile(keepLeft: false).planes
        oldPlanes.removeLast()                                      // schema 1: no extent plane
        let legacy = LZTilePlanes(planes: oldPlanes, terrainSource: LZPack.terrainFine)
        XCTAssertEqual(legacy.planes.count, LZPack.planeExtent)

        let merged = try XCTUnwrap(LZPackStore.merge([modern, legacy]))
        XCTAssertEqual(knownFraction(merged), 1.0, accuracy: 0.0001, "the tile is holed again")
        XCTAssertNil(merged.extentRaw(x: 200, y: 5),
                     "ground supplied by a pack with no extent plane is being reported as ZERO "
                     + "room — the cap table scores that as unusable terrain")
        XCTAssertNil(merged.extentRaw(x: 10, y: 5),
                     "presence is a property of the TILE, not of one cell")
    }

    /// The converse must NOT throw the measurement away: a legacy pack that supplies nothing has
    /// contributed nothing to doubt, so the modern tile keeps its extent.
    func testALegacyPackThatFillsNothingDoesNotCostTheExtentPlane() throws {
        let modern = halfTile(keepLeft: true)
        var sameHalf = halfTile(keepLeft: true).planes
        sameHalf.removeLast()
        let legacy = LZTilePlanes(planes: sameHalf, terrainSource: LZPack.terrainFine)
        let merged = try XCTUnwrap(LZPackStore.merge([modern, legacy]))
        XCTAssertEqual(merged.extentRaw(x: 10, y: 5), 200,
                       "a pack that supplied no ground still cost the tile its extent measurement")
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
