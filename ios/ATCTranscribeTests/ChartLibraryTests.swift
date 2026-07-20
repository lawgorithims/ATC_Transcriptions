import XCTest
import MapKit
@testable import ATCTranscribe

/// Pure coverage for the chart cache's geometry + catalog decoding — the pieces that select which packs
/// a route or a position needs, with no network or disk. The `ChartLibrary` download/warm paths are
/// integration-only (network) and exercised by the app, not here.
final class ChartLibraryTests: XCTestCase {

    // MARK: ChartGeo.routeRects

    private func leg(_ ident: String, _ lat: Double, _ lon: Double) -> ResolvedLeg {
        ResolvedLeg(ident: ident, kind: .waypoint, coord: Coord(lat: lat, lon: lon))
    }

    func testRouteRectsEmptyForNoPoints() {
        XCTAssertTrue(ChartGeo.routeRects([]).isEmpty)
    }

    func testRouteRectsSinglePointGivesOneNonEmptyRect() {
        let rects = ChartGeo.routeRects([leg("BOS", 42.36, -71.0)])
        XCTAssertEqual(rects.count, 1)
        XCTAssertGreaterThan(rects[0].size.width, 0, "a single fix still gets some area so intersects() works")
        XCTAssertTrue(rects[0].contains(MKMapPoint(CLLocationCoordinate2D(latitude: 42.36, longitude: -71.0))),
                      "the rect surrounds the fix")
    }

    func testRouteRectsHasOneRectPerLeg() {
        let pts = [leg("A", 42, -71), leg("B", 41, -73), leg("C", 40, -75)]
        XCTAssertEqual(ChartGeo.routeRects(pts).count, pts.count - 1, "N points → N-1 leg rects")
    }

    func testRouteRectCoversItsLegEndpoints() {
        let a = CLLocationCoordinate2D(latitude: 42, longitude: -71)
        let b = CLLocationCoordinate2D(latitude: 40, longitude: -74)
        let rect = ChartGeo.routeRects([leg("A", a.latitude, a.longitude), leg("B", b.latitude, b.longitude)])[0]
        XCTAssertTrue(rect.contains(MKMapPoint(a)) && rect.contains(MKMapPoint(b)),
                      "the leg rect spans both endpoints")
    }

    // MARK: ChartGeo.rect(around:)

    func testRectAroundContainsCenterAndNearby() {
        let c = Coord(lat: 39.0, lon: -104.0)
        let rect = ChartGeo.rect(around: c, radiusNM: 60)
        XCTAssertTrue(rect.contains(MKMapPoint(CLLocationCoordinate2D(latitude: c.lat, longitude: c.lon))))
        // ~30 NM north (0.5° lat) stays inside a 60 NM radius; ~180 NM north (3°) falls outside.
        XCTAssertTrue(rect.contains(MKMapPoint(CLLocationCoordinate2D(latitude: 39.5, longitude: -104.0))))
        XCTAssertFalse(rect.contains(MKMapPoint(CLLocationCoordinate2D(latitude: 42.0, longitude: -104.0))))
    }

    // MARK: ChartCatalog decoding + pack selection (the core of packsCovering)

    private let fixture = """
    {
      "cycle": "2506",
      "sectional": [
        { "id": "New_York_SEC", "bounds": [-77.0, 40.0, -71.0, 45.0], "bytes": 1048576, "path": "sectional/New_York_SEC.mbtiles" },
        { "id": "Los_Angeles_SEC", "bounds": [-121.0, 32.0, -114.0, 36.0], "bytes": 2097152, "path": "sectional/Los_Angeles_SEC.mbtiles" }
      ],
      "ifrLow": []
    }
    """.data(using: .utf8)!

    func testCatalogDecodes() throws {
        let cat = try JSONDecoder().decode(ChartCatalog.self, from: fixture)
        XCTAssertEqual(cat.cycle, "2506")
        XCTAssertEqual(cat.sectional.count, 2)
        XCTAssertTrue(cat.ifrLow.isEmpty)
        let ny = try XCTUnwrap(cat.sectional.first { $0.id == "New_York_SEC" })
        XCTAssertEqual(ny.bytes, 1_048_576)
        XCTAssertEqual(ny.path, "sectional/New_York_SEC.mbtiles")
        let remote = try XCTUnwrap(ny.remote)   // L13: remote is now optional
        XCTAssertTrue(remote.absoluteString.hasSuffix("/sectional/New_York_SEC.mbtiles"))
    }

    func testCatalogEntryWithSpacesPercentEncodesRatherThanNil() throws {
        // L13: a path with a space is not a valid URL as-is — the fallback percent-encodes it so a
        // real (if unusual) catalog entry still resolves to a non-nil URL instead of crashing.
        let json = """
        { "cycle": "2506", "sectional": [
          { "id": "spacey", "bounds": [-74, 40, -73, 41], "bytes": 1, "path": "sectional/New York SEC.mbtiles" }
        ], "ifrLow": [] }
        """.data(using: .utf8)!
        let cat = try JSONDecoder().decode(ChartCatalog.self, from: json)
        let e = try XCTUnwrap(cat.sectional.first)
        let remote = try XCTUnwrap(e.remote, "a space-bearing path must percent-encode, not return nil")
        XCTAssertTrue(remote.absoluteString.contains("New%20York") || remote.absoluteString.contains("New York"))
    }

    func testEntryMapRectSelectsPacksARouteCrosses() throws {
        let cat = try JSONDecoder().decode(ChartCatalog.self, from: fixture)
        let ny = try XCTUnwrap(cat.sectional.first { $0.id == "New_York_SEC" })
        let la = try XCTUnwrap(cat.sectional.first { $0.id == "Los_Angeles_SEC" })
        // A short NY-area route selects the NY pack but not the LA one — the same intersect test
        // `ChartLibrary.packsCovering` and `ChartStore.load` use.
        let route = ChartGeo.routeRects([leg("A", 42.0, -73.0), leg("B", 41.5, -72.0)])
        XCTAssertTrue(route.contains { ny.mapRect.intersects($0) }, "NY route crosses the New York sectional")
        XCTAssertFalse(route.contains { la.mapRect.intersects($0) }, "…and not the Los Angeles sectional")
    }
    func testPackIDParsesFilenameForPinProtection() {
        // The pin-protection prune reads the pack id from the on-disk filename; ids may contain dashes,
        // so the split must be at the LAST dash (before the cycle) — a wrong split would strip pin
        // protection and let a rollover wipe the pilot's downloads.
        XCTAssertEqual(ChartLibrary.packID("New_York_SEC-2508.mbtiles"), "New_York_SEC")
        XCTAssertEqual(ChartLibrary.packID("vfr-sec-den-2508.mbtiles"), "vfr-sec-den")   // dashed id
        XCTAssertNil(ChartLibrary.packID("index.json"))
        XCTAssertNil(ChartLibrary.packID("nodash.mbtiles"))
    }
}
