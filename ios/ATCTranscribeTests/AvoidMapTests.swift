import XCTest
import Compression
import CoreGraphics
import ImageIO
import SQLite3
@testable import ATCTranscribe

/// The "where not to go" map: its tile format, its colour rules and its file handling.
final class AvoidMapTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("avoid-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: helpers

    /// "AVD1" + raw DEFLATE, exactly as lz/avoid/common.py packs a tile.
    private func blob(_ mask: [UInt8]) -> Data {
        var out = [UInt8](repeating: 0, count: 70_000)
        let n = mask.withUnsafeBufferPointer { src in
            compression_encode_buffer(&out, out.count, src.baseAddress!, src.count, nil, COMPRESSION_ZLIB)
        }
        precondition(n > 0)
        return Data("AVD1".utf8) + Data(out.prefix(n))
    }

    /// An avoid map holding exactly `tiles` (XYZ rows), as `lz/avoid/merge.py` writes one. With `band`, it
    /// is one longitude band as `lz/avoid/shard.py` writes it; without, a map of everything.
    private func writeMap(_ name: String, tiles: [(z: Int, x: Int, y: Int, mask: [UInt8])],
                          builtAt: String = "2026-10-30T00:00:00Z", schema: String = AvoidMap.schema,
                          band: (id: String, columns: ClosedRange<Int>)? = nil) throws -> URL {
        let url = dir.appendingPathComponent(name)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let bandRows = band.map { ", ('shard','\($0.id)'), ('shard_x8','\($0.columns.lowerBound),\($0.columns.upperBound)')" } ?? ""
        let ddl = """
        CREATE TABLE metadata (name TEXT, value TEXT);
        CREATE TABLE tiles (zoom_level INTEGER, tile_column INTEGER, tile_row INTEGER, tile_data BLOB);
        INSERT INTO metadata VALUES ('format','avoid1'), ('avoid_schema','\(schema)'), ('minzoom','8'), ('maxzoom','12'),
          ('built_at','\(builtAt)'), ('slope_threshold_deg','6'), ('attribution','test'), ('caveat','test'),
          ('bounds','-125,24,-66,50')\(bandRows);
        """
        XCTAssertEqual(sqlite3_exec(db, ddl, nil, nil, nil), SQLITE_OK)
        for t in tiles {
            let data = blob(t.mask)
            var st: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(db, "INSERT INTO tiles VALUES (?, ?, ?, ?)", -1, &st, nil), SQLITE_OK)
            sqlite3_bind_int(st, 1, Int32(t.z))
            sqlite3_bind_int(st, 2, Int32(t.x))
            sqlite3_bind_int(st, 3, Int32((1 << t.z) - 1 - t.y))                   // TMS row
            _ = data.withUnsafeBytes { sqlite3_bind_blob(st, 4, $0.baseAddress, Int32(data.count), nil) }
            XCTAssertEqual(sqlite3_step(st), SQLITE_DONE)
            sqlite3_finalize(st)
        }
        return url
    }

    /// A one-tile avoid map at z12, with `byte` painted at one point's pixel (KLRU unless told).
    private func makeMap(_ name: String, byte: UInt8, builtAt: String = "2026-10-30T00:00:00Z",
                         at point: (lat: Double, lon: Double)? = nil,
                         band: (id: String, columns: ClosedRange<Int>)? = nil) throws -> URL {
        let at = point ?? klru
        let t = try XCTUnwrap(AvoidMap.tilePixel(lon: at.lon, lat: at.lat, z: 12))
        var mask = [UInt8](repeating: 0, count: 65_536)
        mask[t.py * 256 + t.px] = byte
        return try writeMap(name, tiles: [(12, t.x, t.y, mask)], builtAt: builtAt, band: band)
    }

    /// Pixels a rendered tile paints (alpha above zero).
    private func paintedPixels(_ png: Data) throws -> Int {
        let src = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
        var rgba = [UInt8](repeating: 0, count: 256 * 256 * 4)
        let ctx = try XCTUnwrap(CGContext(data: &rgba, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 1024,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 256, height: 256))
        return stride(from: 3, to: rgba.count, by: 4).filter { rgba[$0] > 0 }.count
    }

    private let klru = (lat: 32.2894, lon: -106.9219)

    // MARK: format

    func testATileRoundTripsAndAnythingElseIsRefused() {
        var mask = [UInt8](repeating: 0, count: 65_536)
        mask[0] = AvoidReason.wires.rawValue
        mask[65_535] = AvoidReason.trees.rawValue | AvoidReason.steep.rawValue
        XCTAssertEqual(AvoidMap.decode(blob(mask)), mask)
        XCTAssertNil(AvoidMap.decode(Data("LZP1".utf8) + blob(mask).dropFirst(4)), "wrong magic")
        XCTAssertNil(AvoidMap.decode(Data("AVD1".utf8)), "no payload")
        XCTAssertNil(AvoidMap.decode(blob([UInt8](repeating: 1, count: 1000))), "short payload is not a tile")
    }

    func testReasonsNameEveryBit() {
        XCTAssertEqual(AvoidReason.reasons(in: 0), [])
        XCTAssertEqual(AvoidReason.reasons(in: 0xFF).count, 8)
        XCTAssertEqual(AvoidReason.reasons(in: 64 | 4), [.trees, .wires])
        XCTAssertTrue(AvoidReason.wires.isHazard)
        XCTAssertFalse(AvoidReason.steep.isHazard)
    }

    // MARK: colours

    /// Nothing on this map may read as an invitation: no pixel, in any theme or setting, is green-led.
    func testNoColourIsGreen() {
        for theme in AppTheme.allCases {
            for cover in [true, false] {
                for b in 0..<256 {
                    guard let c = AvoidTileRenderer.colour(forByte: UInt8(b), theme: theme, showCover: cover) else { continue }
                    XCTAssertLessThanOrEqual(c.1, max(c.0, c.2) + 1e-9, "byte \(b) in \(theme) is green-led")
                }
            }
        }
    }

    func testHiddenHazardsWinAndCoverIsOptionalButSteepIsNot() {
        let wires = AvoidTileRenderer.colour(.wires, theme: .cockpit)
        let mixed = AvoidTileRenderer.colour(forByte: AvoidReason.wires.rawValue | AvoidReason.solar.rawValue
                                             | AvoidReason.trees.rawValue, theme: .cockpit, showCover: true)
        XCTAssertEqual(mixed?.0, wires.0)
        XCTAssertEqual(mixed?.3, wires.3, "a power line over a forest draws as the power line")
        XCTAssertNil(AvoidTileRenderer.colour(forByte: AvoidReason.trees.rawValue, theme: .cockpit, showCover: false))
        XCTAssertNotNil(AvoidTileRenderer.colour(forByte: AvoidReason.trees.rawValue, theme: .cockpit, showCover: true))
        XCTAssertNotNil(AvoidTileRenderer.colour(forByte: AvoidReason.steep.rawValue, theme: .cockpit, showCover: false),
                        "steep ground is drawn even with cover off")
        XCTAssertNil(AvoidTileRenderer.colour(forByte: 0, theme: .cockpit, showCover: true), "clear ground stays clear")
    }

    // MARK: the installed file

    func testAnInstalledMapAnswersForAPointAndAnEmptyDirectoryDoesNot() throws {
        let store = AvoidMapStore(directory: dir)
        store.reload()
        XCTAssertNil(store.reasons(lon: klru.lon, lat: klru.lat), "no map: no answer, not an all-clear")
        _ = try makeMap("avoid_conus-a.mbtiles", byte: AvoidReason.wires.rawValue | AvoidReason.steep.rawValue)
        store.reload()
        XCTAssertTrue(store.isInstalled)
        XCTAssertEqual(store.reasons(lon: klru.lon, lat: klru.lat), [.steep, .wires])
        XCTAssertEqual(store.reasons(lon: klru.lon + 0.2, lat: klru.lat), [], "mapped, no tile: nothing to report")
    }

    func testAnUpdateIsSwappedInWithoutDeletingTheFileInUse() throws {
        let first = try makeMap("avoid_conus-a.mbtiles", byte: AvoidReason.wires.rawValue)
        let store = AvoidMapStore(directory: dir)
        store.reload()
        let incoming = try makeMap("incoming.mbtiles", byte: AvoidReason.solar.rawValue, builtAt: "2026-11-01T00:00:00Z")
        try store.install(incoming)
        XCTAssertEqual(store.reasons(lon: klru.lon, lat: klru.lat), [.solar], "the new map is served at once")
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path),
                      "the superseded file must outlive this session: a reader may still hold it open")
        store.reload()                                              // the next launch
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path), "and go at the next launch")
        XCTAssertEqual(store.reasons(lon: klru.lon, lat: klru.lat), [.solar])
    }

    func testRemovalStopsServingNowAndDeletesAtTheNextLaunch() throws {
        let file = try makeMap("avoid_conus-a.mbtiles", byte: AvoidReason.wires.rawValue)
        let store = AvoidMapStore(directory: dir)
        store.reload()
        store.uninstallKeepingFilesUntilRelaunch()
        XCTAssertFalse(store.isInstalled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        store.reload()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(store.isInstalled)
    }

    func testTheRendererPaintsOnlyWhatIsThereAndItsSignatureFollowsTheSettings() throws {
        _ = try makeMap("avoid_conus-a.mbtiles", byte: AvoidReason.wires.rawValue)
        let store = AvoidMapStore(directory: dir)
        store.reload()
        let r = AvoidTileRenderer(store: store)
        let sig = try XCTUnwrap(r.signature(theme: .cockpit, showCover: false))
        XCTAssertNotEqual(sig, r.signature(theme: .night, showCover: false))
        XCTAssertNotEqual(sig, r.signature(theme: .cockpit, showCover: true))
        let t = try XCTUnwrap(AvoidMap.tilePixel(lon: klru.lon, lat: klru.lat, z: 12))
        XCTAssertNotNil(r.tilePNG(signature: sig, theme: .cockpit, showCover: false, z: 12, x: t.x, y: t.y))
        XCTAssertNil(r.tilePNG(signature: "0", theme: .cockpit, showCover: false, z: 12, x: t.x, y: t.y),
                     "a stale signature is refused")
        XCTAssertNil(r.tilePNG(signature: sig, theme: .cockpit, showCover: false, z: 7, x: 0, y: 0),
                     "below the map's minimum zoom there is nothing to draw")
    }

    // MARK: land cover (schema 2: stored no finer than z11)

    /// Each z11 pixel covers the 2×2 below it, from the parent's quadrant over the child. All four children
    /// are checked against every parent bit, so a wrong offset, a swapped axis or a copied hazard fails.
    func testAZ12TileTakesItsLandCoverFromItsZ11ParentsQuadrant() throws {
        let t = try XCTUnwrap(AvoidMap.tilePixel(lon: klru.lon, lat: klru.lat, z: 12))
        let (x0, y0) = (t.x & ~1, t.y & ~1)                                 // the parent's NW child
        let parent = (0..<65_536).map { UInt8(truncatingIfNeeded: ($0 &* 2_654_435_761) >> 13) }
        var own = [UInt8](repeating: 0, count: 65_536)
        own[0] = AvoidReason.wires.rawValue
        own[65_535] = AvoidReason.steep.rawValue
        _ = try writeMap("avoid_conus-a.mbtiles", tiles: [(11, x0 >> 1, y0 >> 1, parent), (12, x0 + 1, y0, own)])
        let store = AvoidMapStore(directory: dir)
        store.reload()
        for (dx, dy) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
            let m = try XCTUnwrap(store.maskWithLandCover(z: 12, x: x0 + dx, y: y0 + dy), "child \(dx),\(dy)")
            let stored = (dx, dy) == (1, 0) ? own : [UInt8](repeating: 0, count: 65_536)
            let wrong = (0..<65_536).first { i in
                let p = parent[(dy * 128 + i / 256 / 2) * 256 + dx * 128 + (i % 256) / 2]
                return m[i] != stored[i] | (p & AvoidMap.landCover)
            }
            XCTAssertNil(wrong, "child \(dx),\(dy): first wrong pixel \(wrong ?? -1)")
        }
        XCTAssertNil(store.mask(z: 12, x: x0, y: y0), "a child with no tile of its own stores nothing")
        XCTAssertEqual(store.maskWithLandCover(z: 11, x: x0 >> 1, y: y0 >> 1), parent, "z11 is drawn as stored")
    }

    func testAPointsReasonsTakeLandCoverFromZ11ButNotItsHazards() throws {
        let t12 = try XCTUnwrap(AvoidMap.tilePixel(lon: klru.lon, lat: klru.lat, z: 12))
        let t11 = try XCTUnwrap(AvoidMap.tilePixel(lon: klru.lon, lat: klru.lat, z: 11))
        XCTAssertEqual([t11.x, t11.y], [t12.x >> 1, t12.y >> 1], "the same point at z11 is in the parent")
        // A point in the sibling tile, which has no z12 tile of its own.
        let sibling = (lat: klru.lat, lon: (Double(t12.x ^ 1) + 0.5) / 4096 * 360 - 180)
        let s11 = try XCTUnwrap(AvoidMap.tilePixel(lon: sibling.lon, lat: sibling.lat, z: 11))
        XCTAssertEqual([s11.x, s11.y], [t11.x, t11.y])
        var own = [UInt8](repeating: 0, count: 65_536)
        own[t12.py * 256 + t12.px] = AvoidReason.steep.rawValue
        var parent = [UInt8](repeating: 0, count: 65_536)
        // The wires at z11 came from a neighbouring z12 pixel (an overview ORs them up): not this point's.
        parent[t11.py * 256 + t11.px] = AvoidReason.trees.rawValue | AvoidReason.wires.rawValue
        parent[s11.py * 256 + s11.px] = AvoidReason.water.rawValue
        _ = try writeMap("avoid_conus-a.mbtiles", tiles: [(11, t11.x, t11.y, parent), (12, t12.x, t12.y, own)])
        let store = AvoidMapStore(directory: dir)
        store.reload()
        XCTAssertEqual(store.reasons(lon: klru.lon, lat: klru.lat), [.trees, .steep])
        XCTAssertEqual(store.reasons(lon: sibling.lon, lat: sibling.lat), [.water], "no z12 tile, still its land cover")
    }

    func testTheRendererDrawsZ11LandCoverOnZ12OnlyWhenCoverIsShown() throws {
        let t = try XCTUnwrap(AvoidMap.tilePixel(lon: klru.lon, lat: klru.lat, z: 12))
        let trees = [UInt8](repeating: AvoidReason.trees.rawValue, count: 65_536)
        var own = [UInt8](repeating: 0, count: 65_536)
        own[t.py * 256 + t.px] = AvoidReason.wires.rawValue
        _ = try writeMap("avoid_conus-a.mbtiles", tiles: [(11, t.x >> 1, t.y >> 1, trees), (12, t.x, t.y, own)])
        let store = AvoidMapStore(directory: dir)
        store.reload()
        let r = AvoidTileRenderer(store: store)
        let off = try XCTUnwrap(r.signature(theme: .cockpit, showCover: false))
        let on = try XCTUnwrap(r.signature(theme: .cockpit, showCover: true))
        let hazardOnly = try XCTUnwrap(r.tilePNG(signature: off, theme: .cockpit, showCover: false, z: 12, x: t.x, y: t.y))
        let withCover = try XCTUnwrap(r.tilePNG(signature: on, theme: .cockpit, showCover: true, z: 12, x: t.x, y: t.y))
        XCTAssertEqual(try paintedPixels(hazardOnly), 1, "cover off: the one power-line pixel")
        XCTAssertEqual(try paintedPixels(withCover), 65_536, "cover on: the parent's trees under the line")
        let bare = (x: t.x ^ 1, y: t.y)                                      // its sibling: no z12 tile at all
        XCTAssertNil(r.tilePNG(signature: off, theme: .cockpit, showCover: false, z: 12, x: bare.x, y: bare.y))
        let sibling = try XCTUnwrap(r.tilePNG(signature: on, theme: .cockpit, showCover: true, z: 12, x: bare.x, y: bare.y),
                                    "land cover alone must still draw at z12")
        XCTAssertEqual(try paintedPixels(sibling), 65_536)
    }

    /// Schema 1's z12 tiles carry their own land cover: this build would draw it twice, coarse over fine,
    /// and a schema-1 build would read schema 2's z12 as having none. Each refuses the other's files.
    func testAMapOfAnotherSchemaIsRefusedAndCleanedUp() throws {
        let old = try writeMap("avoid_conus-a.mbtiles", tiles: [], schema: "1")
        let store = AvoidMapStore(directory: dir)
        store.reload()
        XCTAssertFalse(store.isInstalled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path), "a file this build cannot read is not kept")
        XCTAssertNil(AvoidMapStore.open(try writeMap("incoming.mbtiles", tiles: [], schema: "3")))
    }

    // MARK: bands

    /// KLRU is in z8 column 51; this point is in column 53, and one in column 60 is in no band here.
    private let east = (lat: 32.29, lon: -104.70)
    private let unmapped = (lat: 35.0, lon: -95.5)

    func testEachBandAnswersOnlyForItsOwnColumns() throws {
        XCTAssertEqual(AvoidMap.tilePixel(lon: klru.lon, lat: klru.lat, z: 8)?.x, 51)
        XCTAssertEqual(AvoidMap.tilePixel(lon: east.lon, lat: east.lat, z: 8)?.x, 53)
        _ = try makeMap("avoid_w108-w104-a.mbtiles", byte: AvoidReason.wires.rawValue, band: ("w108-w104", 50...52))
        _ = try makeMap("avoid_w104-w100-a.mbtiles", byte: AvoidReason.solar.rawValue, at: east,
                        band: ("w104-w100", 53...55))
        let store = AvoidMapStore(directory: dir)
        store.reload()
        XCTAssertEqual(store.installed.map(\.shardID), ["w108-w104", "w104-w100"], "west to east")
        XCTAssertEqual(store.reasons(lon: klru.lon, lat: klru.lat), [.wires])
        XCTAssertEqual(store.reasons(lon: east.lon, lat: east.lat), [.solar], "read from ITS band, not the first")
        XCTAssertNil(store.reasons(lon: unmapped.lon, lat: unmapped.lat), "a band not installed: no answer")
        XCTAssertTrue(store.covers(z: 10, x: 51 << 2), "every zoom under a band's column is that band's")
        XCTAssertFalse(store.covers(z: 10, x: 60 << 2))
    }

    func testInstallingABandReplacesThatBandAndNothingElse() throws {
        let old = try makeMap("avoid_w108-w104-a.mbtiles", byte: AvoidReason.wires.rawValue, band: ("w108-w104", 50...52))
        _ = try makeMap("avoid_w104-w100-a.mbtiles", byte: AvoidReason.solar.rawValue, at: east,
                        band: ("w104-w100", 53...55))
        let store = AvoidMapStore(directory: dir)
        store.reload()
        let incoming = try makeMap("incoming.mbtiles", byte: AvoidReason.steep.rawValue,
                                   builtAt: "2026-11-01T00:00:00Z", band: ("w108-w104", 50...52))
        try store.install(incoming)
        XCTAssertEqual(store.reasons(lon: klru.lon, lat: klru.lat), [.steep], "the new band is served at once")
        XCTAssertEqual(store.reasons(lon: east.lon, lat: east.lat), [.solar], "its neighbour is untouched")
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path), "the replaced file outlives this session")
        store.reload()                                              // the next launch
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path), "and goes at the next launch, as the older copy")
        XCTAssertEqual(store.installed.count, 2)
        XCTAssertEqual(store.builtAt, "2026-10-30T00:00:00Z", "the map is as current as its OLDEST band")
    }

    /// Remove, then download only SOME bands, then relaunch: the removed bands must stay gone. When a
    /// fresh install simply cleared the removal marker, every band not re-downloaded came back.
    func testARemovedBandStaysRemovedWhenOnlySomeAreDownloadedAgain() throws {
        let west = try makeMap("avoid_w108-w104-a.mbtiles", byte: AvoidReason.wires.rawValue, band: ("w108-w104", 50...52))
        let eastFile = try makeMap("avoid_w104-w100-a.mbtiles", byte: AvoidReason.solar.rawValue, at: east,
                                   band: ("w104-w100", 53...55))
        let store = AvoidMapStore(directory: dir)
        store.reload()
        store.uninstallKeepingFilesUntilRelaunch()
        let incoming = try makeMap("incoming.mbtiles", byte: AvoidReason.steep.rawValue,
                                   builtAt: "2026-11-01T00:00:00Z", band: ("w108-w104", 50...52))
        try store.install(incoming)
        XCTAssertEqual(store.installed.map(\.shardID), ["w108-w104"], "only what was downloaded since the removal")
        store.reload()                                              // the next launch
        XCTAssertFalse(FileManager.default.fileExists(atPath: west.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: eastFile.path), "a removed band came back")
        XCTAssertEqual(store.installed.map(\.shardID), ["w108-w104"])
        XCTAssertNil(store.reasons(lon: east.lon, lat: east.lat))
        XCTAssertFalse(AvoidMapStore.isMapFileName("../avoid_x.mbtiles"), "the removal list stays in its directory")
    }

    func testAMalformedBandRangeRefusesTheFile() {
        XCTAssertEqual(AvoidMapStore.columns(nil), 0...255, "no band metadata: a map of everything")
        XCTAssertEqual(AvoidMapStore.columns("50,52"), 50...52)
        XCTAssertNil(AvoidMapStore.columns("52,50"))
        XCTAssertNil(AvoidMapStore.columns("50"))
        XCTAssertNil(AvoidMapStore.columns("50,999"))
    }

    @MainActor
    func testTheLibraryFetchesOnlyMissingOrOlderBandsAndRemembersTheCatalog() throws {
        _ = try makeMap("avoid_w108-w104-a.mbtiles", byte: AvoidReason.wires.rawValue, band: ("w108-w104", 50...52))
        let store = AvoidMapStore(directory: dir)
        store.reload()
        func catalog(_ builtAt: String, schema: Int = 3) -> Data {
            Data("""
            {"schema": \(schema), "built_at": "\(builtAt)", "shards": [
              {"id": "w108-w104", "path": "map/avoid_w108-w104.mbtiles", "bytes": 90000000, "sha256": "aa"},
              {"id": "w104-w100", "path": "map/avoid_w104-w100.mbtiles", "bytes": 60000000, "sha256": "bb"}]}
            """.utf8)
        }
        let lib = AvoidMapLibrary(store: store)
        XCTAssertTrue(lib.adopt(catalogData: catalog("2026-10-30T00:00:00Z")))
        XCTAssertEqual(lib.missing.map(\.id), ["w104-w100"], "the band already installed at this build is not fetched again")
        XCTAssertEqual(lib.bytesToDownload, 60_000_000)
        XCTAssertTrue(lib.updateAvailable, "part of the map is installed and part is not")
        XCTAssertEqual(lib.installedOfTotal?.0, 1)
        XCTAssertEqual(lib.installedOfTotal?.1, 2)
        XCTAssertTrue(lib.adopt(catalogData: catalog("2026-11-01T00:00:00Z")))
        XCTAssertEqual(lib.missing.map(\.id), ["w108-w104", "w104-w100"], "a newer build supersedes every band")
        XCTAssertFalse(lib.adopt(catalogData: Data(#"{"schema": 1, "map": {}}"#.utf8)), "an old-schema catalog is refused")
        XCTAssertFalse(lib.adopt(catalogData: catalog("2026-11-02T00:00:00Z", schema: 2)),
                       "catalog 2 lists bands whose z12 tiles hold their own land cover")
        XCTAssertEqual(AvoidMapLibrary.catalogPath, "index-v3.json",
                       "lz/avoid/publish.py writes catalog 3 here; builds that read catalog 2 read index.json")
        XCTAssertEqual(AvoidMapLibrary(store: store).catalog?.built_at, "2026-11-01T00:00:00Z",
                       "the catalog survives a relaunch, so an offline pilot still learns the install is partial")
    }

    func testTheServerRouteParsesSignedPaths() {
        let p = MBTilesHTTPServer.signedPath("/avoid/9f3a/12/794/1655.png", root: "avoid")
        XCTAssertEqual(p?.0, "9f3a")
        XCTAssertEqual(p?.1, 12)
        XCTAssertNil(MBTilesHTTPServer.signedPath("/avoid/ZZ/12/794/1655", root: "avoid"), "uppercase signature refused")
        XCTAssertNil(MBTilesHTTPServer.signedPath("/lz/9f3a/12/794/1655", root: "avoid"), "another route's path")
    }
}
