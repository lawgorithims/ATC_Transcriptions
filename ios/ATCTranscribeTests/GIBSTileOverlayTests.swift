import XCTest
import MapKit
@testable import ATCTranscribe

/// NASA GIBS smoke overlay: the three things that silently break satellite tiles — the prior-UTC-day
/// date (today's tiles are half-empty), the `{z}/{y}/{x}` row-before-column path order, and requesting
/// past the matrix set's native zoom (GIBS 404s there, so we clamp + overzoom instead).
final class GIBSTileOverlayTests: XCTestCase {

    private func utcDate(_ y: Int, _ mo: Int, _ d: Int, _ h: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h))!
    }

    func testPriorUTCDay() {
        XCTAssertEqual(GIBSTileOverlay.priorUTCDay(from: utcDate(2026, 7, 13, 12)), "2026-07-12")
        XCTAssertEqual(GIBSTileOverlay.priorUTCDay(from: utcDate(2026, 7, 1, 0)), "2026-06-30")   // month rollover
        XCTAssertEqual(GIBSTileOverlay.priorUTCDay(from: utcDate(2026, 1, 1, 2)), "2025-12-31")   // year rollover
        XCTAssertEqual(GIBSTileOverlay.priorUTCDay(from: utcDate(2024, 3, 1, 6)), "2024-02-29")   // leap day
    }

    func testTileURLIsRowBeforeColumn() {
        let o = GIBSTileOverlay(layer: .smoke, now: { self.utcDate(2026, 7, 13, 12) })
        let url = o.url(forTilePath: MKTileOverlayPath(x: 8, y: 12, z: 5, contentScaleFactor: 1))
        XCTAssertEqual(url.absoluteString,
            "https://gibs.earthdata.nasa.gov/wmts/epsg3857/best/MODIS_Terra_CorrectedReflectance_TrueColor/default/2026-07-12/GoogleMapsCompatible_Level9/5/12/8.jpg")
        // Guard the ordering explicitly: row (y=12) must precede column (x=8).
        XCTAssertTrue(url.absoluteString.hasSuffix("/5/12/8.jpg"), "GIBS path is z/y/x, not z/x/y")
    }

    /// Live date: the URL must reflect the CURRENT prior-UTC-day, not one frozen at construction —
    /// so a session that crosses UTC midnight never keeps serving a stale date.
    func testDateIsComputedLivePerRequest() {
        var clock = self.utcDate(2026, 7, 13, 12)
        let o = GIBSTileOverlay(layer: .smoke, now: { clock })
        let before = o.url(forTilePath: MKTileOverlayPath(x: 1, y: 1, z: 3, contentScaleFactor: 1))
        XCTAssertTrue(before.absoluteString.contains("/2026-07-12/"))
        clock = self.utcDate(2026, 7, 14, 0)                  // cross UTC midnight
        let after = o.url(forTilePath: MKTileOverlayPath(x: 1, y: 1, z: 3, contentScaleFactor: 1))
        XCTAssertTrue(after.absoluteString.contains("/2026-07-13/"), "date follows the clock, not construction")
    }

    /// Past native zoom GIBS has no tiles, so `url` clamps z to the native max (loadTile then crops the
    /// ancestor up). A deep request must never ask GIBS for a non-existent z.
    func testDeepZoomClampsToNativeInURL() {
        let o = GIBSTileOverlay(layer: .smoke, now: { self.utcDate(2026, 7, 13, 12) })
        let url = o.url(forTilePath: MKTileOverlayPath(x: 100, y: 200, z: 12, contentScaleFactor: 1))
        XCTAssertTrue(url.absoluteString.contains("/GoogleMapsCompatible_Level9/9/"),
                      "zoom past native must clamp to \(GIBSLayer.smoke.maxZ)")
    }

    func testOverlayConfig() {
        let o = GIBSTileOverlay(layer: .smoke, now: { self.utcDate(2026, 7, 13, 12) })
        XCTAssertEqual(o.minimumZ, 1)
        XCTAssertEqual(o.maximumZ, min(GIBSLayer.smoke.maxZ + GIBSTileOverlay.overzoomLevels, 22))  // requests past native, then overzooms
        XCTAssertGreaterThan(o.maximumZ, GIBSLayer.smoke.maxZ, "must request past native so the layer doesn't vanish")
        XCTAssertFalse(o.canReplaceMapContent)               // draws OVER the chart, never replaces it
        XCTAssertEqual(o.tileSize, CGSize(width: 256, height: 256))
        XCTAssertGreaterThan(GIBSLayer.smoke.alpha, 0)
        XCTAssertLessThan(GIBSLayer.smoke.alpha, 1)          // translucent so the chart shows through
    }
}
