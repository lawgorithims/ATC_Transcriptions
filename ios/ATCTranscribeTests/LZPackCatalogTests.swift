import XCTest
import MapKit
@testable import ATCTranscribe

/// The catalog contract, tested against the JSON `lz/publish.py` actually emits.
///
/// The literal below is the shape published to
/// `huggingface.co/datasets/SingularityUS/commsight-lz/index.json`, trimmed of the vintages block
/// the app does not decode. If the publisher's output and this drift apart, the layer's whole
/// discovery path breaks at exactly the moment a pilot tries to download coverage — so this is a
/// cross-language contract test, the same reason `LZPackTests` reads a Python-generated fixture
/// rather than a Swift-generated one.
final class LZPackCatalogTests: XCTestCase {

    private let published = """
    {
      "schema": 1,
      "regions": [
        { "id": "southern-nm", "title": "Southern New Mexico",
          "note": "Las Cruces, the Mesilla Valley, the Organ and San Andres ranges.",
          "cells": ["n32w106","n32w107","n32w108",
                    "n33w106","n33w107","n33w108",
                    "n34w106","n34w107","n34w108"] }
      ],
      "cells": [
        { "id": "n33w107", "path": "cells/n33w107.lzpack", "bytes": 89317376,
          "sha256": "727563ad216145ee70447439f442f229c72bf44c4cca1e8dd7f8d3beac7bb69e",
          "bounds": [-107.0, 32.0, -106.0, 33.0],
          "minzoom": 6, "maxzoom": 13,
          "built_at": "2026-08-02T00:36:00Z", "coarse_terrain_tiles": 20,
          "attribution": "Terrain/land cover: USGS, USDA, USFWS (public domain)." }
      ]
    }
    """.data(using: .utf8)!

    private func catalog() throws -> LZPackCatalog {
        try XCTUnwrap(LZPackCatalog.decode(published), "the published catalog shape no longer decodes")
    }

    // MARK: - decoding

    func testTheRealPublishedCatalogDecodes() throws {
        let c = try catalog()
        XCTAssertEqual(c.schema, 1)
        XCTAssertEqual(c.cells.count, 1)
        let cell = try XCTUnwrap(c.cell(id: "n33w107"))
        XCTAssertEqual(cell.bytes, 89_317_376)
        XCTAssertEqual(cell.path, "cells/n33w107.lzpack")
        XCTAssertEqual(cell.coarseTerrainTiles, 20)
        XCTAssertEqual(cell.builtAt, "2026-08-02T00:36:00Z")
        XCTAssertEqual(cell.sha256?.count, 64)
    }

    /// A catalog from a newer publisher is REFUSED whole, not half-read. Offering coverage we only
    /// partly understand is worse than offering none.
    func testANewerSchemaIsRefused() throws {
        let newer = String(data: published, encoding: .utf8)!
            .replacingOccurrences(of: "\"schema\": 1", with: "\"schema\": 2")
        XCTAssertNil(LZPackCatalog.decode(newer.data(using: .utf8)!))
    }

    func testGarbageDecodesToNilRatherThanThrowing() {
        XCTAssertNil(LZPackCatalog.decode(Data("not json".utf8)))
        XCTAssertNil(LZPackCatalog.decode(Data()))
        XCTAssertNil(LZPackCatalog.decode(Data("{\"schema\":1}".utf8)))   // no cells/regions keys
    }

    /// Unknown keys must be ignorable — the publisher already emits `vintages` and `attribution`
    /// that this build does not read, and adding a field must never require an app update.
    func testUnknownFieldsAreIgnored() throws {
        let c = try catalog()
        XCTAssertEqual(c.cells.first?.id, "n33w107")   // decoded despite minzoom/attribution present
    }

    // MARK: - geography

    /// The footprint must be the cell the id names. `n33w107` is the USGS cell whose NORTH-WEST
    /// corner is 33N 107W, so it spans lat 32-33 and lon -107..-106 — Las Cruces is inside it.
    func testTheFootprintIsWhereTheCellIdSays() throws {
        let cell = try XCTUnwrap(try catalog().cell(id: "n33w107"))
        let rect = try XCTUnwrap(cell.mapRect, "a cell that cannot say where it is must not be offered")

        let klru = MKMapPoint(CLLocationCoordinate2D(latitude: 32.2894, longitude: -106.9219))
        XCTAssertTrue(rect.contains(klru), "Las Cruces is not inside its own cell")

        // Denver is a long way outside it.
        let denver = MKMapPoint(CLLocationCoordinate2D(latitude: 39.74, longitude: -104.99))
        XCTAssertFalse(rect.contains(denver))
    }

    func testUnusableBoundsYieldNoFootprintRatherThanAGuess() {
        for bad in ["[]", "[1,2,3]", "[-107,33,-106,32]", "[0,0,0,0]"] {
            let json = """
            {"schema":1,"regions":[],"cells":[{"id":"x","path":"cells/x.lzpack","bytes":1,
             "bounds":\(bad)}]}
            """
            let c = LZPackCatalog.decode(Data(json.utf8))
            XCTAssertNil(c?.cells.first?.mapRect, "bounds \(bad) should not produce a footprint")
        }
    }

    /// Rect selection is what the route and viewport offers are built on.
    func testCellsIntersectingSelectsByFootprint() throws {
        let c = try catalog()
        let overCell = ChartGeo.rect(around: Coord(lat: 32.29, lon: -106.92), radiusNM: 10)
        XCTAssertEqual(c.cells(intersecting: [overCell]).map(\.id), ["n33w107"])

        let overDenver = ChartGeo.rect(around: Coord(lat: 39.74, lon: -104.99), radiusNM: 10)
        XCTAssertTrue(c.cells(intersecting: [overDenver]).isEmpty)
        XCTAssertTrue(c.cells(intersecting: []).isEmpty)
    }

    // MARK: - regions

    /// A region may name cells that are not published yet — coverage grows one build at a time, and
    /// listing nine while one exists must offer one, not crash and not invent eight.
    func testARegionOnlyOffersCellsThatActuallyExist() throws {
        let c = try catalog()
        let region = try XCTUnwrap(c.regions.first)
        XCTAssertEqual(region.cells.count, 9, "the region names the whole 3x3 ring")
        XCTAssertEqual(c.cells(in: region).map(\.id), ["n33w107"], "only the built cell is offerable")
    }

    func testTotalBytesCountsOnlyPublishedCells() throws {
        XCTAssertEqual(try catalog().totalBytes, 89_317_376)
    }

    // MARK: - addressing

    func testRemoteURLIsTheAnonymousResolvePath() throws {
        let cell = try XCTUnwrap(try catalog().cell(id: "n33w107"))
        let url = try XCTUnwrap(cell.remote(base: LZPackLibrary.base))
        XCTAssertEqual(url.absoluteString,
            "https://huggingface.co/datasets/SingularityUS/commsight-lz/resolve/main/cells/n33w107.lzpack")
    }

    /// A path that tries to escape the repo root, or is absolute, must not produce a URL at all.
    func testHostilePathsProduceNoURL() {
        for bad in ["../../etc/passwd", "/etc/passwd", ""] {
            let json = """
            {"schema":1,"regions":[],"cells":[{"id":"x","path":"\(bad)","bytes":1,
             "bounds":[-1,-1,1,1]}]}
            """
            let cell = LZPackCatalog.decode(Data(json.utf8))?.cells.first
            XCTAssertNil(cell?.remote(base: LZPackLibrary.base), "path \(bad) should be refused")
        }
    }

    /// The local filename is the id and nothing else. This is the whole reason the id derivation is
    /// a `dropLast` rather than the shape-stripping `ChartLibrary.packID` has to do — keep it so.
    func testLocalFilenameRoundTripsThroughPackID() throws {
        let cell = try XCTUnwrap(try catalog().cell(id: "n33w107"))
        XCTAssertEqual(cell.localFilename, "n33w107.lzpack")
        XCTAssertEqual(LZPackLibrary.packID(cell.localFilename), "n33w107")
    }

    func testPackIDRejectsAnythingThatIsNotAPack() {
        XCTAssertNil(LZPackLibrary.packID("New_York_SEC-05-14-2026.mbtiles"))
        XCTAssertNil(LZPackLibrary.packID("catalog.json"))
        XCTAssertNil(LZPackLibrary.packID(".lzpack"))
        XCTAssertNil(LZPackLibrary.packID(".hidden.lzpack"))
        XCTAssertEqual(LZPackLibrary.packID("n33w107.lzpack"), "n33w107")
    }
}
