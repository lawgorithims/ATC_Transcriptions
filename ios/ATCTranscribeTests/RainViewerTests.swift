import XCTest
@testable import ATCTranscribe

/// The pure parse of RainViewer's weather-maps.json → the newest radar frame's {z}/{x}/{y} tile template.
final class RainViewerTests: XCTestCase {

    func testLatestRadarTemplatePrefersNowcastTip() {
        let json = """
        { "host": "https://tilecache.rainviewer.com",
          "radar": { "past": [ {"time": 1, "path": "/v2/radar/aaa"}, {"time": 2, "path": "/v2/radar/bbb"} ],
                     "nowcast": [ {"time": 3, "path": "/v2/radar/ccc"} ] } }
        """.data(using: .utf8)!
        let t = RainViewerService.latestRadarTemplate(from: json)
        XCTAssertEqual(t, "https://tilecache.rainviewer.com/v2/radar/ccc/256/{z}/{x}/{y}/2/1_1.png")
    }

    func testFallsBackToLatestPastWhenNoNowcast() {
        let json = """
        { "host": "https://h", "radar": { "past": [ {"time": 1, "path": "/p/1"}, {"time": 2, "path": "/p/2"} ] } }
        """.data(using: .utf8)!
        let t = RainViewerService.latestRadarTemplate(from: json)
        XCTAssertEqual(t, "https://h/p/2/256/{z}/{x}/{y}/2/1_1.png")   // newest past frame, and a real {z}/{x}/{y}
        XCTAssertTrue(t!.contains("{z}/{x}/{y}"))
    }

    func testNilOnEmptyOrMalformed() {
        XCTAssertNil(RainViewerService.latestRadarTemplate(from: Data("{}".utf8)))
        XCTAssertNil(RainViewerService.latestRadarTemplate(from: Data(#"{"host":"h","radar":{"past":[]}}"#.utf8)))
        XCTAssertNil(RainViewerService.latestRadarTemplate(from: Data("not json".utf8)))
    }

    func testRadarFramesAreOrderedPastThenForecastWithTimes() {
        let json = """
        { "host": "https://h",
          "radar": { "past": [ {"time": 100, "path": "/p/1"}, {"time": 200, "path": "/p/2"} ],
                     "nowcast": [ {"time": 300, "path": "/n/1"} ] } }
        """.data(using: .utf8)!
        let frames = RainViewerService.radarFrames(from: json)
        XCTAssertEqual(frames.count, 3)
        XCTAssertEqual(frames.map(\.isForecast), [false, false, true])   // observed first, forecast last
        XCTAssertEqual(frames.first?.time, Date(timeIntervalSince1970: 100))
        XCTAssertTrue(frames.last!.template.contains("/n/1/256/{z}/{x}/{y}"))
    }

    func testRadarFramesEmptyOnMalformed() {
        XCTAssertTrue(RainViewerService.radarFrames(from: Data("nope".utf8)).isEmpty)
    }

    func testRepresentativeTileMapsCenterToSlippyCoords() {
        // No center → a CONUS overview at z4, in-range.
        let conus = RainViewerService.representativeTile(center: nil)
        XCTAssertEqual(conus.z, 4)
        XCTAssertTrue((0..<16).contains(conus.x) && (0..<16).contains(conus.y))
        // A center → z6, in-range, and a westerly center yields a smaller x tile than an easterly one.
        let bos = RainViewerService.representativeTile(center: (42.36, -71.06))
        let sf = RainViewerService.representativeTile(center: (37.77, -122.42))
        XCTAssertEqual(bos.z, 6)
        XCTAssertTrue((0..<64).contains(bos.x) && (0..<64).contains(bos.y))
        XCTAssertLessThan(sf.x, bos.x, "San Francisco is west of Boston → smaller tile x")
        XCTAssertLessThan(bos.y, sf.y, "Boston is north of SF → smaller tile y")
    }

    // MARK: viewport tile cover — the radar the pilot is LOOKING AT is warmed first

    private func region(_ lat: Double, _ lon: Double, _ latSpan: Double, _ lonSpan: Double) -> RadarRegion {
        RadarRegion(centerLat: lat, centerLon: lon, latSpan: latSpan, lonSpan: lonSpan)
    }

    func testViewportCoverStaysWithinBudgetAndNeverExceedsRadarMaxZoom() {
        // Span from a tight terminal view to a continental one — every cover must fit the budget and
        // never request past z7 (RainViewer serves a placeholder image beyond it).
        for span in [0.05, 0.2, 0.8, 2.0, 6.0, 20.0, 60.0] {
            let tiles = RainViewerService.viewportTiles(region(39.0, -77.0, span, span * 1.4))
            XCTAssertFalse(tiles.isEmpty, "span \(span) produced no tiles")
            XCTAssertLessThanOrEqual(tiles.count, 9, "span \(span) blew the tile budget")
            for t in tiles {
                XCTAssertLessThanOrEqual(t.z, RainViewerService.maxRadarZoom, "span \(span) exceeded z7")
                XCTAssertGreaterThanOrEqual(t.z, 0)
                let cap = 1 << t.z
                XCTAssertTrue((0..<cap).contains(t.x) && (0..<cap).contains(t.y), "tile off the pyramid: \(t)")
            }
            XCTAssertEqual(Set(tiles).count, tiles.count, "span \(span) produced duplicate tiles")
        }
    }

    func testViewportCoverIsOrderedFromTheCenterOutward() {
        // The tile under the middle of the screen must be fetched FIRST — that is the whole point of
        // prioritising the visible area.
        let r = region(39.0, -77.0, 3.0, 4.0)
        let tiles = RainViewerService.viewportTiles(r)
        XCTAssertGreaterThan(tiles.count, 1, "this span should need more than one tile")
        let c = RainViewerService.tile(lat: 39.0, lon: -77.0, z: tiles[0].z)
        XCTAssertEqual(tiles[0].x, c.x); XCTAssertEqual(tiles[0].y, c.y)
        // Non-decreasing Manhattan distance from the center tile.
        let d = tiles.map { abs($0.x - c.x) + abs($0.y - c.y) }
        XCTAssertEqual(d, d.sorted(), "cover must be ordered nearest-to-center first")
    }

    func testViewportCoverActuallyContainsTheViewedCorners() {
        // A cover that misses the corners would leave the screen edges blank — assert both corners are in.
        let r = region(39.0, -77.0, 2.0, 2.0)
        let tiles = Set(RainViewerService.viewportTiles(r))
        let z = tiles.first!.z
        for (lat, lon) in [(39.0 - 0.99, -77.0 - 0.99), (39.0 + 0.99, -77.0 + 0.99)] {
            let t = RainViewerService.tile(lat: lat, lon: lon, z: z)
            XCTAssertTrue(tiles.contains(RadarRegion.Tile(z: t.z, x: t.x, y: t.y)),
                          "corner (\(lat), \(lon)) is outside the warmed cover")
        }
    }

    func testViewportCoverHandlesDegenerateAndPolarRegions() {
        // A zero span (a camera that has not settled) must still yield one usable tile, not a crash.
        let zero = RainViewerService.viewportTiles(region(39.0, -77.0, 0, 0))
        XCTAssertEqual(zero.count, 1)
        // Near the pole, Mercator's tan() blows up — latitude is clamped, so the tile stays on the pyramid.
        let polar = RainViewerService.viewportTiles(region(89.9, 10.0, 1.0, 1.0))
        XCTAssertFalse(polar.isEmpty)
        for t in polar {
            let cap = 1 << t.z
            XCTAssertTrue((0..<cap).contains(t.y), "polar tile off the pyramid: \(t)")
        }
    }

    func testViewportCoverSpanningTheAntimeridianStaysOnThePyramid() {
        // A view straddling ±180° must not produce negative or out-of-range x.
        let tiles = RainViewerService.viewportTiles(region(20.0, 179.5, 2.0, 3.0))
        XCTAssertFalse(tiles.isEmpty)
        for t in tiles {
            let cap = 1 << t.z
            XCTAssertTrue((0..<cap).contains(t.x), "antimeridian tile off the pyramid: \(t)")
        }
    }

    func testRegionMoveThresholdSuppressesJitterButCatchesRealPans() {
        let base = region(39.0, -77.0, 2.0, 2.0)
        // A nudge well inside a third of the span is not worth re-warming for.
        XCTAssertFalse(region(39.1, -77.05, 2.0, 2.0).differsMeaningfully(from: base))
        // A pan of more than a third of the span is.
        XCTAssertTrue(region(40.0, -77.0, 2.0, 2.0).differsMeaningfully(from: base))
        XCTAssertTrue(region(39.0, -75.0, 2.0, 2.0).differsMeaningfully(from: base))
        // So is a real zoom change, even with the center pinned.
        XCTAssertTrue(region(39.0, -77.0, 0.5, 0.5).differsMeaningfully(from: base))
        XCTAssertTrue(region(39.0, -77.0, 8.0, 8.0).differsMeaningfully(from: base))
        XCTAssertFalse(region(39.0, -77.0, 2.2, 2.2).differsMeaningfully(from: base), "a 10% zoom is jitter")
    }

    func testParseLastModifiedHeader() {
        let d = WXImageCache.parseLastModified("Sun, 19 Jul 2026 23:45:59 GMT")
        XCTAssertNotNil(d)
        // Round-trips to the same GMT wall clock.
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "GMT")!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: d!)
        XCTAssertEqual(c.year, 2026); XCTAssertEqual(c.month, 7); XCTAssertEqual(c.day, 19)
        XCTAssertEqual(c.hour, 23); XCTAssertEqual(c.minute, 45)
        XCTAssertNil(WXImageCache.parseLastModified(nil))
        XCTAssertNil(WXImageCache.parseLastModified("garbage"))
    }
}
