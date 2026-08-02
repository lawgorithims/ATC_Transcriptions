import XCTest
import MapKit
@testable import ATCTranscribe

/// `LZPackLibrary` — install state, the coverage-offer selection, and the two policies that make it
/// deliberately unlike `ChartLibrary`.
///
/// Everything here runs against a temporary pack directory, so nothing touches the pilot's installed
/// kit. Network paths are not exercised: the request shape is proven end-to-end by `lz/publish.py`'s
/// own verification pass, which fetches every published pack anonymously the way the app does.
@MainActor
final class LZPackLibraryTests: XCTestCase {

    private var dir: URL!
    private var lib: LZPackLibrary!
    private var packURL: URL!

    override func setUpWithError() throws {
        packURL = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "lz_fixture",
                                                           withExtension: "lzpack"))
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lzlib-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        lib = LZPackLibrary(directory: dir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func cell(_ id: String, bytes: Int = 89_317_376,
                      bounds: [Double] = [-107, 32, -106, 33]) -> LZPackCatalog.Cell {
        let json = """
        {"id":"\(id)","path":"cells/\(id).lzpack","bytes":\(bytes),
         "bounds":\(bounds),"built_at":"2026-08-02T00:36:00Z","coarse_terrain_tiles":20}
        """
        return try! JSONDecoder().decode(LZPackCatalog.Cell.self, from: Data(json.utf8))
    }

    private func installFixture(as id: String) throws {
        try FileManager.default.copyItem(at: packURL,
                                         to: dir.appendingPathComponent("\(id).lzpack"))
        lib.refreshInstalled()
    }

    // MARK: - install state

    func testAnEmptyDirectoryHasNothingInstalled() {
        XCTAssertTrue(lib.installedIDs.isEmpty)
        XCTAssertEqual(lib.installedBytes, 0)
        XCTAssertEqual(lib.state("n33w107"), .notDownloaded)
    }

    func testAnInstalledPackIsSeenWithItsBytes() throws {
        try installFixture(as: "n33w107")
        XCTAssertEqual(lib.installedIDs, ["n33w107"])
        XCTAssertGreaterThan(lib.installedBytes, 0)
        XCTAssertEqual(lib.state("n33w107"), .ready)
        XCTAssertTrue(lib.isInstalled("n33w107"))
    }

    /// The catalog cache lives in the same directory and must not be counted as a pack.
    func testNonPackFilesAreIgnored() throws {
        try Data("{}".utf8).write(to: dir.appendingPathComponent("catalog.json"))
        try Data("x".utf8).write(to: dir.appendingPathComponent("notes.txt"))
        lib.refreshInstalled()
        XCTAssertTrue(lib.installedIDs.isEmpty, "a stray file was counted as an installed pack")
    }

    func testRemainingBytesExcludesWhatIsAlreadyInstalled() throws {
        let a = cell("n33w107", bytes: 100), b = cell("n34w108", bytes: 250)
        XCTAssertEqual(lib.remainingBytes([a, b]), 350)
        try installFixture(as: "n33w107")
        XCTAssertEqual(lib.remainingBytes([a, b]), 250, "an installed cell still counted as remaining")
    }

    // MARK: - the local file identity

    /// A pack lands under its cell id and nothing else. The chart side has to encode an FAA cycle in
    /// the filename and strip it back off; there is no cycle here, and adding one later would break
    /// the identity this whole class assumes.
    func testAPackLandsUnderItsCellId() {
        let c = cell("n33w107")
        XCTAssertEqual(lib.localURL(c).lastPathComponent, "n33w107.lzpack")
        XCTAssertEqual(LZPackLibrary.packID(lib.localURL(c).lastPathComponent), c.id)
    }

    // MARK: - coverage offers

    /// The offer selection is a rect test against what is NOT installed. This is what the route and
    /// the map pill are both built on.
    func testMissingCellsFindsPublishedCoverageThatIsNotInstalled() throws {
        let catalog = try XCTUnwrap(LZPackCatalog.decode(Data("""
        {"schema":1,"regions":[],"cells":[
          {"id":"n33w107","path":"cells/n33w107.lzpack","bytes":1,"bounds":[-107,32,-106,33]},
          {"id":"n40w105","path":"cells/n40w105.lzpack","bytes":1,"bounds":[-105,39,-104,40]}]}
        """.utf8)))
        lib.adoptForTesting(catalog)

        // Over Las Cruces: one cell covers it, and it is not installed.
        let overKLRU = ChartGeo.rect(around: Coord(lat: 32.29, lon: -106.92), radiusNM: 20)
        XCTAssertEqual(lib.missingCells(covering: [overKLRU]).map(\.id), ["n33w107"])

        // Install it and the offer goes away — there is nothing left to offer.
        try installFixture(as: "n33w107")
        XCTAssertTrue(lib.missingCells(covering: [overKLRU]).isEmpty,
                      "an installed cell was still offered for download")

        // Somewhere with no published coverage at all offers nothing — a DIFFERENT state from
        // "published but not downloaded", and the map pill says so differently.
        let overKansas = ChartGeo.rect(around: Coord(lat: 38.5, lon: -98.0), radiusNM: 20)
        XCTAssertTrue(lib.missingCells(covering: [overKansas]).isEmpty)
    }

    func testNoCatalogMeansNoOffers() {
        XCTAssertTrue(lib.missingCells(around: Coord(lat: 32.29, lon: -106.92)).isEmpty,
                      "offers must not be invented before the catalog is known")
    }

    /// A route offer is the same selection over per-leg rects.
    func testRouteCoverageUsesTheSameSelection() throws {
        let catalog = try XCTUnwrap(LZPackCatalog.decode(Data("""
        {"schema":1,"regions":[],"cells":[
          {"id":"n33w107","path":"cells/n33w107.lzpack","bytes":1,"bounds":[-107,32,-106,33]}]}
        """.utf8)))
        lib.adoptForTesting(catalog)
        let rects = [ChartGeo.rect(around: Coord(lat: 32.5, lon: -106.5), radiusNM: 5)]
        XCTAssertEqual(lib.missingCells(covering: rects).map(\.id), ["n33w107"])
    }

    // MARK: - policy

    /// PIN-ONLY. There is no eviction path at all, by design — nothing here may delete a pack the
    /// pilot downloaded. If an LRU is ever added, this test is the argument it has to beat.
    func testNothingEvictsAPackExceptThePilot() throws {
        try installFixture(as: "n33w107")
        let before = lib.installedIDs

        // Every state-changing entry point, short of an explicit remove.
        lib.refreshInstalled()
        _ = lib.remainingBytes([cell("n33w107")])
        _ = lib.missingCells(around: Coord(lat: 32.29, lon: -106.92))
        lib.cancel("n33w107")

        XCTAssertEqual(lib.installedIDs, before, "something evicted a pinned pack")

        // ...and an explicit remove does remove it.
        lib.remove(cell("n33w107"))
        XCTAssertTrue(lib.installedIDs.isEmpty)
        XCTAssertEqual(lib.installedBytes, 0)
    }

    /// Cancelling a transfer that never started must not leave a phantom state behind.
    func testCancellingAnIdleCellIsHarmless() {
        lib.cancel("n33w107")
        XCTAssertEqual(lib.state("n33w107"), .notDownloaded)
    }
}
