import XCTest
@testable import ATCTranscribe

/// Where a missing tile's ancestor lives, and which piece of it to magnify.
///
/// The terrain relief is a SPARSE pack: it carries its deepest level only where the terrain warrants
/// the bytes, and the loopback server fills the gaps by magnifying a parent. An off-by-one in this
/// arithmetic does not fail loudly — it draws the wrong quadrant of the wrong parent, which reads as
/// terrain in a place there is none. So the index maths is pure and pinned here.
final class SparseTileAncestorTests: XCTestCase {

    /// One step up halves the index, and the low bit says which quadrant.
    func testOneStepUpPicksTheCorrectQuadrant() {
        let cases: [(x: Int, y: Int, ax: Int, ay: Int, ox: Int, oy: Int)] = [
            (10, 20, 5, 10, 0, 0),
            (11, 20, 5, 10, 1, 0),
            (10, 21, 5, 10, 0, 1),
            (11, 21, 5, 10, 1, 1),
        ]
        for c in cases {
            let s = MBTilesTileOverlay.ancestorSource(z: 10, x: c.x, y: c.y, step: 1)
            XCTAssertEqual(s?.ax, c.ax); XCTAssertEqual(s?.ay, c.ay)
            XCTAssertEqual(s?.ox, c.ox); XCTAssertEqual(s?.oy, c.oy)
        }
    }

    /// Two steps up is a quarter of the parent's edge, so the offset runs 0...3.
    func testTwoStepsUpAddressesAFourByFourGrid() {
        for dx in 0..<4 {                                            // bounded (rule 2)
            for dy in 0..<4 {                                        // bounded (rule 2)
                let x = 40 + dx, y = 84 + dy
                let s = MBTilesTileOverlay.ancestorSource(z: 10, x: x, y: y, step: 2)
                XCTAssertEqual(s?.ax, 10, "x \(x) has ancestor 40>>2")
                XCTAssertEqual(s?.ay, 21, "y \(y) has ancestor 84>>2")
                XCTAssertEqual(s?.ox, dx); XCTAssertEqual(s?.oy, dy)
            }
        }
    }

    /// The quadrant offsets must TILE the parent exactly — every child maps to a distinct piece, and
    /// together they cover all of it. This is the property an off-by-one breaks.
    func testChildrenTileTheParentExactlyOnce() {
        let step = 3, scale = 1 << step
        var seen = Set<String>()
        for dx in 0..<scale {                                        // bounded (rule 2)
            for dy in 0..<scale {                                    // bounded (rule 2)
                guard let s = MBTilesTileOverlay.ancestorSource(z: 12, x: 8 * scale + dx,
                                                                y: 5 * scale + dy, step: step) else {
                    return XCTFail("no ancestor for a valid child")
                }
                XCTAssertEqual(s.ax, 8); XCTAssertEqual(s.ay, 5)
                XCTAssertTrue(seen.insert("\(s.ox),\(s.oy)").inserted, "two children claim one quadrant")
            }
        }
        XCTAssertEqual(seen.count, scale * scale, "the children must cover the whole parent")
    }

    /// Refusals: a step that would run off the top of the pyramid, or no step at all.
    func testItRefusesImpossibleSteps() {
        XCTAssertNil(MBTilesTileOverlay.ancestorSource(z: 2, x: 1, y: 1, step: 3))
        XCTAssertNil(MBTilesTileOverlay.ancestorSource(z: 10, x: 1, y: 1, step: 0))
        XCTAssertNil(MBTilesTileOverlay.ancestorSource(z: 10, x: 1, y: 1, step: 99))
    }

    /// The server may not climb forever: past a few levels the parent carries so little of the
    /// requested area that serving nothing is honester than serving a smear.
    func testTheClimbIsBounded() {
        XCTAssertLessThanOrEqual(MBTilesHTTPServer.maxAncestorSteps, 4)
        XCTAssertGreaterThan(MBTilesHTTPServer.maxAncestorSteps, 0)
    }
}
