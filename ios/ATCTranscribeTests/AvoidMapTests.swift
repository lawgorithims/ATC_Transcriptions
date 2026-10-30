import XCTest
import Compression
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

    /// A one-tile avoid map at z12 around KLRU, with `byte` painted at KLRU's pixel.
    private func makeMap(_ name: String, byte: UInt8, builtAt: String = "2026-10-30T00:00:00Z") throws -> URL {
        let url = dir.appendingPathComponent(name)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let ddl = """
        CREATE TABLE metadata (name TEXT, value TEXT);
        CREATE TABLE tiles (zoom_level INTEGER, tile_column INTEGER, tile_row INTEGER, tile_data BLOB);
        INSERT INTO metadata VALUES ('format','avoid1'), ('avoid_schema','1'), ('minzoom','8'), ('maxzoom','12'),
          ('built_at','\(builtAt)'), ('slope_threshold_deg','10'), ('attribution','test'), ('caveat','test'),
          ('bounds','-125,24,-66,50');
        """
        XCTAssertEqual(sqlite3_exec(db, ddl, nil, nil, nil), SQLITE_OK)
        let t = try XCTUnwrap(AvoidMap.tilePixel(lon: klru.lon, lat: klru.lat, z: 12))
        var mask = [UInt8](repeating: 0, count: 65_536)
        mask[t.py * 256 + t.px] = byte
        let data = blob(mask)
        var st: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "INSERT INTO tiles VALUES (12, ?, ?, ?)", -1, &st, nil), SQLITE_OK)
        sqlite3_bind_int(st, 1, Int32(t.x))
        sqlite3_bind_int(st, 2, Int32((1 << 12) - 1 - t.y))                       // TMS row
        _ = data.withUnsafeBytes { sqlite3_bind_blob(st, 3, $0.baseAddress, Int32(data.count), nil) }
        XCTAssertEqual(sqlite3_step(st), SQLITE_DONE)
        sqlite3_finalize(st)
        return url
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

    func testTheServerRouteParsesSignedPaths() {
        let p = MBTilesHTTPServer.signedPath("/avoid/9f3a/12/794/1655.png", root: "avoid")
        XCTAssertEqual(p?.0, "9f3a")
        XCTAssertEqual(p?.1, 12)
        XCTAssertNil(MBTilesHTTPServer.signedPath("/avoid/ZZ/12/794/1655", root: "avoid"), "uppercase signature refused")
        XCTAssertNil(MBTilesHTTPServer.signedPath("/lz/9f3a/12/794/1655", root: "avoid"), "another route's path")
    }
}
