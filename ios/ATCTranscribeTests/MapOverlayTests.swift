import XCTest
import MapKit
@testable import ATCTranscribe

/// Issue 1 (overzoom): the pure math that lets a raster chart keep drawing when you zoom in past the
/// pack's own max zoom — which ancestor tile a deeper (z,x,y) falls in, and the sub-rectangle it covers.
final class MapOverlayTests: XCTestCase {

    func testNoOverzoomAtOrBelowMaxZoom() {
        XCTAssertNil(MBTilesTileOverlay.overzoomSource(z: 10, x: 0, y: 0, maxZoom: 10))
        XCTAssertNil(MBTilesTileOverlay.overzoomSource(z: 9, x: 0, y: 0, maxZoom: 10))
    }

    func testOneLevelOverzoomPicksParentAndQuadrant() {
        // maxZoom 10, requesting z 11 tile (5,6): parent (2,3), 128-pt sub-tile, x odd → right half.
        let s = MBTilesTileOverlay.overzoomSource(z: 11, x: 5, y: 6, maxZoom: 10)
        let u = try? XCTUnwrap(s)
        XCTAssertEqual(u?.ax, 2)
        XCTAssertEqual(u?.ay, 3)
        XCTAssertEqual(u?.sub ?? 0, 128, accuracy: 1e-9)
        XCTAssertEqual(u?.ox ?? -1, 128, accuracy: 1e-9)   // x=5 is odd → 1*128
        XCTAssertEqual(u?.oy ?? -1, 0, accuracy: 1e-9)     // y=6 is even → 0
    }

    func testTwoLevelOverzoomShrinksSubTile() {
        // z 12 over maxZoom 10: dz 2, scale 4, sub 64. x=5 → ancestor 1, ox=(5%4=1)*64=64.
        let s = try? XCTUnwrap(MBTilesTileOverlay.overzoomSource(z: 12, x: 5, y: 8, maxZoom: 10))
        XCTAssertEqual(s?.ax, 1)
        XCTAssertEqual(s?.ay, 2)
        XCTAssertEqual(s?.sub ?? 0, 64, accuracy: 1e-9)
        XCTAssertEqual(s?.ox ?? -1, 64, accuracy: 1e-9)
        XCTAssertEqual(s?.oy ?? -1, 0, accuracy: 1e-9)     // y=8, 8%4=0
    }

    func testOverzoomBoundedSoItNeverUpscalesToMush() {
        // Beyond overzoomLevels+2 levels deep we stop (a 128×+ upscale is unusable) → nil.
        XCTAssertNil(MBTilesTileOverlay.overzoomSource(z: 10 + MBTilesTileOverlay.overzoomLevels + 3,
                                                       x: 0, y: 0, maxZoom: 10))
    }

    func testTileRectQuadrantsAreDisjointAndCoverTheWorld() {
        // At z=1 the four tiles tile the world into non-overlapping quadrants.
        let tl = MBTilesTileOverlay.tileRect(z: 1, x: 0, y: 0)
        let br = MBTilesTileOverlay.tileRect(z: 1, x: 1, y: 1)
        XCTAssertEqual(tl.width, MKMapSize.world.width / 2, accuracy: 1)
        XCTAssertFalse(tl.intersects(br), "diagonal quadrants must not overlap")
        XCTAssertEqual(tl.minX, 0, accuracy: 1)
        XCTAssertEqual(br.maxX, MKMapSize.world.width, accuracy: 1)
    }

    func testTileRectRejectsOutOfBoundsTile() {
        // A pack covering only the top-left quadrant must reject a tile in the bottom-right.
        let packBounds = MBTilesTileOverlay.tileRect(z: 2, x: 0, y: 0)   // far NW
        let farTile = MBTilesTileOverlay.tileRect(z: 2, x: 3, y: 3)      // far SE
        XCTAssertFalse(farTile.intersects(packBounds))
    }
}
