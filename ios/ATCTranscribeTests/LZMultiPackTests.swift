import XCTest
import MapKit
import SQLite3
@testable import ATCTranscribe

/// The three things that broke the moment a SECOND pack could exist.
///
/// Every one of these was written when exactly one `.lzpack` could be installed — side-loaded by
/// hand into one simulator — and all three are invisible in that world. They become wrong as soon
/// as a pilot can download a region, which is the whole point of the catalog, so they are pinned
/// here rather than discovered in the air:
///
///   1. `planes(z:x:y:)` asked EVERY pack for EVERY tile and let SQLite say "no such row".
///   2. The render signature keyed on the pack COUNT, so swapping one cell for another served
///      cached tiles composited from a pack that is no longer mounted.
///   3. A pack landing while the map was open was never picked up.
///
/// The fixture is one cell. Where a second is needed these tests synthesise one by copying it and
/// rewriting the copy's `bounds`/`lz_cell`/`built_at` — enough to exercise identity and the bounds
/// index without a second 88 MB build.
final class LZMultiPackTests: XCTestCase {

    private var packURL: URL!
    private var dirs: [URL] = []

    override func setUpWithError() throws {
        packURL = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "lz_fixture",
                                                           withExtension: "lzpack"),
                                "lz_fixture.lzpack missing from the test bundle")
    }

    override func tearDownWithError() throws {
        for d in dirs { try? FileManager.default.removeItem(at: d) }
        dirs.removeAll()
    }

    private func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lzmulti-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dirs.append(dir)
        return dir
    }

    /// Copy the fixture in, optionally rewriting the metadata that gives a pack its identity and
    /// its footprint.
    @discardableResult
    private func install(_ dir: URL, as name: String,
                         bounds: String? = nil, cell: String? = nil,
                         builtAt: String? = nil) throws -> URL {
        let dst = dir.appendingPathComponent("\(name).lzpack")
        try FileManager.default.copyItem(at: packURL, to: dst)
        guard bounds != nil || cell != nil || builtAt != nil else { return dst }

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dst.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        func set(_ k: String, _ v: String) {
            let sql = "INSERT OR REPLACE INTO metadata(name,value) VALUES('\(k)','\(v)')"
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, "could not set \(k)")
        }
        if let b = bounds { set("bounds", b) }
        if let c = cell { set("lz_cell", c) }
        if let t = builtAt { set("built_at", t) }
        return dst
    }

    // MARK: - 1. the bounds index

    /// `MKMapRect` IS the Web Mercator square, so a tile's rect is exact arithmetic with no
    /// trigonometry. If this drifts, the bounds index starts rejecting tiles that ARE in a pack —
    /// which renders as holes in the layer, not as an error.
    func testTileRectTilesTheWorldExactly() {
        XCTAssertEqual(LZPackStore.tileRect(z: 0, x: 0, y: 0).size.width,
                       MKMapSize.world.width, accuracy: 0.5)

        // The four z1 quadrants must tile the world without gap or overlap.
        let q = (0..<2).flatMap { x in (0..<2).map { y in LZPackStore.tileRect(z: 1, x: x, y: y) } }
        XCTAssertEqual(q.reduce(0) { $0 + $1.size.width * $1.size.height },
                       MKMapSize.world.width * MKMapSize.world.height,
                       accuracy: MKMapSize.world.width)      // exact to rounding
        for a in 0..<q.count {
            for b in (a + 1)..<q.count {
                XCTAssertFalse(q[a].intersects(q[b]), "z1 quadrants \(a) and \(b) overlap")
            }
        }
        // A child sits inside its parent.
        XCTAssertTrue(LZPackStore.tileRect(z: 0, x: 0, y: 0)
            .contains(LZPackStore.tileRect(z: 5, x: 9, y: 12).origin))
    }

    /// A tile inside the pack's declared bounds still resolves — the index must not be so eager it
    /// rejects real data.
    func testATileInsideTheBoundsStillDecodes() throws {
        let dir = try makeDir()
        try install(dir, as: "fixture")
        let store = LZPackStore(directory: dir)
        XCTAssertTrue(store.isAvailable)
        XCTAssertNotNil(store.planes(z: 13, x: 1000, y: 2000),
                        "the bounds index rejected a tile the pack actually holds")
    }

    /// A tile outside the pack's real extent must be rejected — that rejection is the whole point
    /// of the index. The fixture holds a 2x2 block at (1000,2000); its neighbours are far outside.
    func testATileOutsideTheRealExtentIsRejected() throws {
        let dir = try makeDir()
        try install(dir, as: "fixture")
        let store = LZPackStore(directory: dir)
        XCTAssertTrue(store.isAvailable)
        XCTAssertNil(store.planes(z: 13, x: 4000, y: 6000),
                     "a tile far outside the pack's extent must not resolve")
        // ...and the covered rect is genuinely a small part of the world, not a give-up fallback.
        let covered = LZPackStore.coveredRect(try XCTUnwrap(store.readers.first))
        XCTAssertLessThan(covered.size.width, MKMapSize.world.width / 100,
                          "the index fell back to world coverage instead of reading the extent")
    }

    /// THE REASON THE INDEX READS TILE ADDRESSES AND NOT `bounds`. A pack whose declared bounds
    /// disagree with the tiles it stores must still serve them: metadata is a claim, the stored
    /// addresses are the fact. Both of these packs claim somewhere they do not cover.
    func testAPackWhoseDeclaredBoundsAreWrongStillServesItsTiles() throws {
        for (name, bounds) in [("degenerate", "0,0,0,0"), ("mislabelled", "10.0,10.0,11.0,11.0")] {
            let dir = try makeDir()
            try install(dir, as: name, bounds: bounds)
            XCTAssertNotNil(LZPackStore(directory: dir).planes(z: 13, x: 1000, y: 2000),
                            "\(name): bounds metadata overrode the tiles actually present")
        }
    }

    // MARK: - 2. the mounted-set fingerprint

    /// THE STALE-TILE BUG. Swapping one pack for another keeps the COUNT identical; if that is what
    /// the signature is built from, every cached tile keeps being served from a pack that is gone.
    func testSwappingOnePackForAnotherChangesTheFingerprint() throws {
        let a = try makeDir()
        try install(a, as: "cellA", cell: "n33w107", builtAt: "2026-08-01T00:00:00Z")
        let one = LZPackStore(directory: a).packFingerprint

        let b = try makeDir()
        try install(b, as: "cellB", cell: "n34w108", builtAt: "2026-08-01T00:00:00Z")
        let two = LZPackStore(directory: b).packFingerprint

        XCTAssertEqual(LZPackStore(directory: a).readers.count,
                       LZPackStore(directory: b).readers.count,
                       "precondition: the counts are equal, which is why a count cannot tell them apart")
        XCTAssertNotEqual(one, two, "swapping packs left the fingerprint unchanged — stale tiles")
    }

    /// Rebuilding a pack under the SAME filename must also invalidate. The id alone cannot see this;
    /// the build stamp is why it is in the fingerprint.
    func testRebuildingAPackUnderTheSameNameChangesTheFingerprint() throws {
        let a = try makeDir()
        try install(a, as: "n33w107", builtAt: "2026-08-01T00:00:00Z")
        let before = LZPackStore(directory: a).packFingerprint

        let b = try makeDir()
        try install(b, as: "n33w107", builtAt: "2026-09-15T12:00:00Z")
        let after = LZPackStore(directory: b).packFingerprint

        XCTAssertNotEqual(before, after, "a rebuilt pack was served from the old pack's cache")
    }

    /// Order on disk must not matter — the same set is the same signature, or every relaunch
    /// needlessly discards a warm tile cache.
    func testFingerprintIsOrderIndependent() throws {
        let a = try makeDir()
        try install(a, as: "aaa", cell: "n33w107", builtAt: "t1")
        try install(a, as: "zzz", cell: "n34w108", builtAt: "t2")

        let b = try makeDir()
        try install(b, as: "zzz", cell: "n34w108", builtAt: "t2")
        try install(b, as: "aaa", cell: "n33w107", builtAt: "t1")

        XCTAssertEqual(LZPackStore(directory: a).packFingerprint,
                       LZPackStore(directory: b).packFingerprint)
    }

    func testEmptyStoreHasAStableEmptyFingerprint() throws {
        let dir = try makeDir()
        let store = LZPackStore(directory: dir)
        XCTAssertFalse(store.isAvailable)
        XCTAssertEqual(store.packFingerprint, "")
    }

    // MARK: - 3. picking up a pack that lands at runtime

    /// A pack arriving while the app is running must become visible without a relaunch or a toggle.
    /// Downloading 88 MB and watching the map not change is indistinguishable from a broken layer.
    @MainActor
    func testAPackThatLandsAfterMountIsPickedUp() throws {
        let dir = try makeDir()
        let store = LZPackStore(directory: dir)
        XCTAssertFalse(store.isAvailable, "precondition: nothing installed yet")

        try install(dir, as: "arrived-later")
        store.reload()

        XCTAssertTrue(store.isAvailable, "a pack that landed after mount was never seen")
        XCTAssertNotNil(store.planes(z: 13, x: 1000, y: 2000))
        XCTAssertFalse(store.packFingerprint.isEmpty)
    }

    /// ...and removing one is seen too, so a pilot reclaiming space does not leave the map drawing
    /// from a file that no longer exists.
    @MainActor
    func testRemovingAPackIsSeenOnReload() throws {
        let dir = try makeDir()
        let url = try install(dir, as: "temporary")
        let store = LZPackStore(directory: dir)
        XCTAssertTrue(store.isAvailable)

        try FileManager.default.removeItem(at: url)
        store.reload()

        XCTAssertFalse(store.isAvailable)
        XCTAssertEqual(store.packFingerprint, "")
        XCTAssertNil(store.planes(z: 13, x: 1000, y: 2000))
    }
}
