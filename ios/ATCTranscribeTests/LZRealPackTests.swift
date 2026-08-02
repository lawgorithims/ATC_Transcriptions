import XCTest
@testable import ATCTranscribe

/// End-to-end tests against the REAL shipped pack (`lz/out/n33w107.lzpack`, ~86 MB), not the
/// synthetic fixture.
///
/// The fixture proves the format contract; this proves the PRODUCT. Real data is where the
/// interesting failures live: a pyramid level that aggregates itself into nothing, a ruleset whose
/// thresholds happen to veto an entire region, a ramp whose bottom stop swallows every score the
/// data actually produces. All of those pass every fixture test and still ship a blank map.
///
/// The pack is too large to bundle into the test target, so this reads it from the repo by absolute
/// path (simulator processes can read host paths) and SKIPS when it is absent — a checkout without
/// a built pack must not fail the suite.
final class LZRealPackTests: XCTestCase {

    private static let packPath =
        "/Users/bsusl/CommSight/ATC_Transcriptions/lz/out/n33w107.lzpack"

    private var store: LZPackStore!
    private var comp: LZTileCompositor!

    // Las Cruces, inside the pilot cell.
    private let klru = (lon: -106.9219, lat: 32.2894)
    private let mesillaValley = (lon: -106.80, lat: 32.26)
    private let organCrest = (lon: -106.5610, lat: 32.3600)

    override func setUpWithError() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.packPath),
                          "no built pack at \(Self.packPath) — run lz/package.py --build")
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lzreal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Symlink rather than copy: 86 MB per test case is gratuitous.
        try FileManager.default.createSymbolicLink(
            at: dir.appendingPathComponent("n33w107.lzpack"),
            withDestinationURL: URL(fileURLWithPath: Self.packPath))
        store = LZPackStore(directory: dir)
        let doc = try XCTUnwrap(LZRulesetCompiler.loadDocument(bundle: Bundle(for: Self.self))
                                ?? LZRulesetCompiler.loadDocument(bundle: .main))
        let rules = try XCTUnwrap(LZRulesetCompiler.compile(document: doc, aircraft: nil,
                                                            themeKey: "day", packStamp: "real"))
        comp = LZTileCompositor(store: store, rules: rules, night: false)
    }

    func testRealPackMounts() {
        XCTAssertTrue(store.isAvailable, "pack did not mount: \(store.rejected)")
        XCTAssertEqual(store.minZoom, 6)
        XCTAssertEqual(store.maxZoom, 13)
    }

    /// The layer must actually PAINT over the cell at the zooms a pilot flies. This is the test the
    /// simulator run was trying to be: without it, "the tiles are being requested" proves only that
    /// the plumbing works, not that anything comes back.
    func testTilesRenderAtOperationalZooms() throws {
        var rendered = [Int: Int]()
        for z in 9...13 {
            let (tx, ty, _, _) = try XCTUnwrap(
                LZTileCompositor.tilePixel(lon: klru.lon, lat: klru.lat, z: z))
            if let png = comp.tilePNG(signature: comp.signature, z: z, x: tx, y: ty) {
                rendered[z] = png.count
            }
        }
        XCTAssertFalse(rendered.isEmpty,
                       "no tile rendered at any operational zoom — the layer would be invisible")
        // z12 and z13 are where the cell fills a useful part of the view; those must paint.
        XCTAssertNotNil(rendered[13], "z13 over KLRU rendered nothing")
        XCTAssertNotNil(rendered[12], "z12 over KLRU rendered nothing")
    }

    /// A z6 tile is ~99% outside a single 1x1 degree cell, so it is legitimately almost all
    /// `unknown` and paints little or nothing. That is correct — but it is also why the layer looks
    /// absent when the map is zoomed out, so it is pinned here rather than rediscovered as a bug.
    func testLowZoomIsMostlyUnknownByConstruction() throws {
        let (tx, ty, _, _) = try XCTUnwrap(
            LZTileCompositor.tilePixel(lon: klru.lon, lat: klru.lat, z: 6))
        let tile = try XCTUnwrap(store.planes(z: 6, x: tx, y: ty), "z6 tile missing")
        let cls = tile.planes[LZPack.planeClass]
        let unknown = cls.reduce(0) { $0 + ($1 == LZPack.classUnknown ? 1 : 0) }
        XCTAssertGreaterThan(Double(unknown) / Double(cls.count), 0.9,
                             "a z6 tile should be dominated by out-of-cell 'unknown'")
    }

    // MARK: - the ground truth, read back through the whole stack

    func testMesillaValleyScoresAboveTheOrganMountains() throws {
        let valley = try XCTUnwrap(comp.sample(lon: mesillaValley.lon, lat: mesillaValley.lat))
        let crest = try XCTUnwrap(comp.sample(lon: organCrest.lon, lat: organCrest.lat))
        XCTAssertGreaterThan(valley.score, crest.score,
                             "irrigated valley floor must outscore a mountain crest")
    }

    /// THE regression test for the pilot-reported bug: the Organ Mountains must PAINT.
    ///
    /// They sit immediately east of Las Cruces at 29-50 degrees under forest — the most obviously
    /// unlandable ground in the cell — and the first version of the compositor rendered them as
    /// nothing at all, because a veto returned nil and the renderer skipped the pixel. A blank
    /// mountain is indistinguishable from a mountain we have no data for.
    func testOrganMountainsRenderAsExcludedNotBlank() throws {
        let (tx, ty, _, _) = try XCTUnwrap(
            LZTileCompositor.tilePixel(lon: organCrest.lon, lat: organCrest.lat, z: 13))
        let png = try XCTUnwrap(comp.tilePNG(signature: comp.signature, z: 13, x: tx, y: ty),
                                "the Organ Mountains rendered NOTHING — the veto is invisible again")
        XCTAssertGreaterThan(png.count, 200)

        let s = try XCTUnwrap(comp.sample(lon: organCrest.lon, lat: organCrest.lat))
        XCTAssertTrue(s.vetoed, "a 40-degree forested crest must be an active exclusion")
        XCTAssertFalse(s.rules.filter { $0.kind == .veto }.isEmpty,
                       "the exclusion must name itself on the card")
    }

    /// The whole visible area must not be one flat colour: a heatmap that cannot separate the
    /// valley floor from the mountainside is not telling the pilot anything.
    func testValleyAndMountainRenderDifferently() throws {
        let valley = try XCTUnwrap(comp.sample(lon: mesillaValley.lon, lat: mesillaValley.lat))
        let crest = try XCTUnwrap(comp.sample(lon: organCrest.lon, lat: organCrest.lat))
        XCTAssertFalse(valley.vetoed, "the irrigated valley floor must not be excluded")
        XCTAssertTrue(crest.vetoed)
        XCTAssertGreaterThan(valley.score, 0)
    }

    func testOrganCrestIsSteepAndUnusable() throws {
        let s = try XCTUnwrap(comp.sample(lon: organCrest.lon, lat: organCrest.lat))
        let slope = try XCTUnwrap(s.slopeDeg, "no slope on the crest — DEM hole?")
        XCTAssertGreaterThan(slope, 10.0, "Organ Mountains crest read as gentle ground")
    }

    /// Every scored cell in the real pack carries the standing unmapped-wires caveat, and any cell
    /// that was capped or vetoed names the rule that did it. Explainability has to survive contact
    /// with real data, not just the fixture.
    func testRealCellsExplainThemselves() throws {
        for (lon, lat) in [klru, mesillaValley, organCrest] {
            let s = try XCTUnwrap(comp.sample(lon: lon, lat: lat))
            XCTAssertTrue(s.rules.contains { $0.id == "unmapped_wires" },
                          "lost the unmapped-wires caveat at \(lon),\(lat)")
            for r in s.rules where r.kind != .flag {
                XCTAssertFalse(r.text.isEmpty, "rule \(r.id) fired with no explanation")
            }
        }
    }

    /// The pack's provenance must reach the device, or the card cannot say how old the data is.
    func testVintagesSurviveIntoTheApp() throws {
        let v = store.vintages
        XCTAssertFalse(v.isEmpty, "no vintages recorded in the pack metadata")
        let blob = try XCTUnwrap(v.values.first)
        for source in ["dem_3dep", "nlcd", "canopy", "dof"] {
            XCTAssertTrue(blob.contains(source), "provenance lost \(source)")
        }
    }

    /// Rendering budget. The compositor runs on the tile server's queue alongside chart decoding
    /// during a pan, so a slow tile is felt directly. Generous bound — this is a smoke alarm for an
    /// accidental per-pixel allocation, not a benchmark.
    func testTileRenderStaysWithinBudget() throws {
        let (tx, ty, _, _) = try XCTUnwrap(
            LZTileCompositor.tilePixel(lon: klru.lon, lat: klru.lat, z: 13))
        // Warm the pack's page cache; we are timing the composite, not the first disk read.
        _ = comp.tilePNG(signature: comp.signature, z: 13, x: tx, y: ty)
        let fresh = LZTileCompositor(store: store,
                                     rules: try XCTUnwrap(LZRulesetCompiler.compile(
                                        document: try XCTUnwrap(
                                            LZRulesetCompiler.loadDocument(bundle: Bundle(for: Self.self))
                                            ?? LZRulesetCompiler.loadDocument(bundle: .main)),
                                        aircraft: nil, themeKey: "day", packStamp: "perf")),
                                     night: false)
        let t0 = CFAbsoluteTimeGetCurrent()
        _ = fresh.tilePNG(signature: fresh.signature, z: 13, x: tx, y: ty)
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        XCTAssertLessThan(ms, 120, "a single tile composite took \(Int(ms)) ms")
    }
}
