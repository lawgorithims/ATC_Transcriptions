import XCTest
import SQLite3
#if canImport(MapLibre)
import MapLibre
#endif
@testable import ATCTranscribe

#if canImport(MapLibre)
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// MapLibre's ambient cache is OFF (see `MapLibreAmbientCache`). The test host IS the app, so `App.init`
/// has applied the real configuration before any of this runs.
///
/// The probe is MapLibre's own "insert into the ambient cache" entry point, `preload(_:for:…)`. It runs
/// `DatabaseFileSource::forward` → `OfflineDatabase::put`, the call every fetched tile makes (and the top
/// of the heaviest stack in every disk-writes report), so a probe that is not stored means a tile is not
/// stored either.
final class MapLibreAmbientCacheTests: XCTestCase {

    func testTheAppSwitchesTheCacheOffAtLaunch() {
        XCTAssertTrue(MapLibreAmbientCache.didDisable,
                      "App.init must switch the ambient cache off before any map exists")
        XCTAssertEqual(MapLibreAmbientCache.disabledSize, 0,
                       "zero is MapLibre's off switch — any other cap still writes every tile")
    }

    func testAResponseHandedToTheCacheIsNotStored() throws {
        let probe = try Self.probeURL()
        preload(probe)
        XCTAssertEqual(storedCount(probe), 0, "MapLibre stored a response with the ambient cache off")
    }

    /// The control for the test above: with a cap, the SAME probe IS stored — so a zero there means "not
    /// stored", not "looked in the wrong place".
    func testTheProbeIsStoredWhenTheCacheIsOn() throws {
        addTeardownBlock { _ = Self.restoreDisabled() }                // runs even after a failed assert
        XCTAssertTrue(Self.setCap(50 * 1024 * 1024), "could not switch the cache on for the control")
        let probe = try Self.probeURL()
        preload(probe)
        XCTAssertEqual(storedCount(probe), 1, "the probe cannot see the cache, so the zero above proves nothing")
        XCTAssertTrue(Self.restoreDisabled(), "could not switch the cache back off")
        XCTAssertEqual(storedCount(probe), 0, "clearing must remove what the cap let in")
    }

    // MARK: helpers

    /// A loopback URL like every tile the map draws, on the discard port so nothing could ever answer it.
    private static func probeURL() throws -> URL {
        try XCTUnwrap(URL(string: "http://127.0.0.1:9/ambient-cache-probe/\(UUID().uuidString).json"))
    }

    private func preload(_ url: URL) {
        let done = expectation(description: "MapLibre handled the preload")
        MLNOfflineStorage.shared.preload(Data("{}".utf8), for: url, modificationDate: nil,
                                         expirationDate: nil, eTag: nil, mustRevalidate: false) { _, error in
            XCTAssertNil(error)
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
    }

    /// Cap the cache, waiting for MapLibre to confirm. The confirmation arrives by `dispatch_sync` to main,
    /// which the waiter's run-loop spin services.
    @discardableResult
    private static func setCap(_ bytes: UInt) -> Bool {
        let done = XCTestExpectation(description: "cap applied")
        var failure: Error?
        MLNOfflineStorage.shared.setMaximumAmbientCacheSize(bytes) { error in
            failure = error
            done.fulfill()
        }
        return XCTWaiter().wait(for: [done], timeout: 10) == .completed && failure == nil
    }

    /// The app's own configuration again: cap zero, then empty whatever the control let in.
    @discardableResult
    private static func restoreDisabled() -> Bool {
        let capped = setCap(MapLibreAmbientCache.disabledSize)
        let done = XCTestExpectation(description: "cache cleared")
        var failure: Error?
        MLNOfflineStorage.shared.clearAmbientCache { error in
            failure = error
            done.fulfill()
        }
        return capped && XCTWaiter().wait(for: [done], timeout: 10) == .completed && failure == nil
    }

    /// Rows MapLibre holds for `url`, read straight from its database file. No file stores nothing.
    private func storedCount(_ url: URL) -> Int {
        let path = MLNOfflineStorage.shared.databaseURL.path
        guard FileManager.default.fileExists(atPath: path) else { return 0 }
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil), SQLITE_OK, "cannot open \(path)")
        var st: OpaquePointer?
        defer { sqlite3_finalize(st) }
        let sql = "SELECT count(*) FROM resources WHERE url = ?1"
        XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &st, nil), SQLITE_OK, "unexpected cache schema")
        XCTAssertEqual(sqlite3_bind_text(st, 1, url.absoluteString, -1, SQLITE_TRANSIENT), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(st), SQLITE_ROW)
        return Int(sqlite3_column_int64(st, 0))
    }
}
#endif
