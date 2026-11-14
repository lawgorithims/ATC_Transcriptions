import XCTest
@testable import ATCTranscribe

/// The seam compositor must let a SHALLOWER pack fill the transparent collar of a deeper pack's tile.
///
/// The sectionals stop at different depths (southern charts z12, northern z11). At a z12 request on a
/// z11/z12 join only the deeper pack holds the tile natively; serving it alone left the other chart's
/// share of the tile transparent, and the bundled z7 base showed through as a permanent blurry strip.
final class ChartSeamCompositeTests: XCTestCase {

    /// Fake BLOB store: pack index → set of "z/x/y" it holds.
    private func fetcher(_ held: [Int: Set<String>]) -> (Int, Int, Int, Int) -> Data? {
        { i, z, x, y in held[i]?.contains("\(z)/\(x)/\(y)") == true ? Data("\(i)".utf8) : nil }
    }

    func testShallowerNeighbourJoinsTheSeamBelowTheDeeperPack() {
        // Pack 0 = Chicago-like (5-11), pack 1 = St Louis-like (5-12). Request z12/1047/1546.
        let packs = [(minZoom: 5, maxZoom: 11), (minZoom: 5, maxZoom: 12)]
        let claims = MBTilesHTTPServer.seamClaims(packs: packs, z: 12, x: 1047, y: 1546,
            fetch: fetcher([0: ["11/523/773"], 1: ["12/1047/1546"]]))
        XCTAssertEqual(claims.count, 2, "the z11 pack's magnified parent is a claimant, not ignored")
        XCTAssertTrue(claims[0].isNative, "the real z12 tile is drawn on top")
        XCTAssertEqual(String(decoding: claims[0].raw, as: UTF8.self), "1")
        XCTAssertFalse(claims[1].isNative, "the magnified layer only fills what the native one leaves")
        let m = try! XCTUnwrap(claims[1].magnify)
        XCTAssertEqual(m.sub, 128); XCTAssertEqual(m.ox, 128); XCTAssertEqual(m.oy, 0)  // 1047 odd, 1546 even
    }

    func testANativeOnlyTileIsNotASeam() {
        let packs = [(minZoom: 5, maxZoom: 11), (minZoom: 5, maxZoom: 12)]
        let claims = MBTilesHTTPServer.seamClaims(packs: packs, z: 12, x: 1047, y: 1546,
            fetch: fetcher([1: ["12/1047/1546"]]))                      // Chicago does not reach here
        XCTAssertEqual(claims.count, 1, "one claimant → the single-pack fast path keeps the tile")
    }

    func testTwoShallowPacksMagnifiedAtTheSameJoinStillComposite() {
        // Omaha/Chicago (both z11) asked for at z12 because a z12 pack is mounted elsewhere.
        let packs = [(minZoom: 5, maxZoom: 11), (minZoom: 5, maxZoom: 11)]
        let claims = MBTilesHTTPServer.seamClaims(packs: packs, z: 12, x: 1000, y: 1500,
            fetch: fetcher([0: ["11/500/750"], 1: ["11/500/750"]]))
        XCTAssertEqual(claims.count, 2)
        XCTAssertTrue(claims.allSatisfy { !$0.isNative })
    }

    func testPacksBelowTheirMinZoomOrPastTheOverzoomBandDoNotClaim() {
        let packs = [(minZoom: 6, maxZoom: 12), (minZoom: 5, maxZoom: 5)]
        let claims = MBTilesHTTPServer.seamClaims(packs: packs, z: 5 + MBTilesTileOverlay.overzoomLevels + 1,
                                                  x: 0, y: 0, fetch: { _, _, _, _ in Data([1]) })
        XCTAssertEqual(claims.count, 1, "only the pack whose range covers the level claims")
    }

    func testDrawRectMagnifiesTheRightQuadrant() {
        XCTAssertEqual(MBTilesHTTPServer.seamDrawRect(nil, side: 512), CGRect(x: 0, y: 0, width: 512, height: 512))
        // Right-hand top quadrant of the parent, into a 256 output: parent drawn 512 wide, shifted left 256.
        XCTAssertEqual(MBTilesHTTPServer.seamDrawRect((sub: 128, ox: 128, oy: 0), side: 256),
                       CGRect(x: -256, y: 0, width: 512, height: 512))
        // Same quadrant into a 512 output (a 512-px native neighbour set the size).
        XCTAssertEqual(MBTilesHTTPServer.seamDrawRect((sub: 128, ox: 128, oy: 0), side: 512),
                       CGRect(x: -512, y: 0, width: 1024, height: 1024))
    }
}
