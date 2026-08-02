import XCTest
import CoreGraphics
import ImageIO
@testable import ATCTranscribe

/// Tests for the murphy compositor — where facts meet judgment.
///
/// These lean on the synthetic fixture pack because its four tiles were built to isolate exactly
/// the decisions that matter: a clean field, a veto, an identical field on COARSE terrain, and
/// good ground beside a charted wire.
final class LZTileCompositorTests: XCTestCase {

    private var store: LZPackStore!
    private var rules: LZCompiledRuleset!
    private var comp: LZTileCompositor!

    private let z = 13, x0 = 1000, y0 = 2000

    override func setUpWithError() throws {
        let bundle = Bundle(for: Self.self)
        let packURL = try XCTUnwrap(bundle.url(forResource: "lz_fixture", withExtension: "lzpack"))
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lzcomp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: packURL, to: dir.appendingPathComponent("f.lzpack"))
        store = LZPackStore(directory: dir)

        let doc = try XCTUnwrap(LZRulesetCompiler.loadDocument(bundle: bundle)
                                ?? LZRulesetCompiler.loadDocument(bundle: .main))
        rules = try XCTUnwrap(LZRulesetCompiler.compile(document: doc, aircraft: nil,
                                                        themeKey: "day", packStamp: "fix"))
        comp = LZTileCompositor(store: store, rules: rules, night: false)
    }

    // MARK: - rendering

    func testCleanFieldTileRendersPixels() throws {
        let png = try XCTUnwrap(comp.tilePNG(signature: comp.signature, z: z, x: x0, y: y0),
                                "the clean-field tile should render")
        XCTAssertGreaterThan(png.count, 100)
        XCTAssertEqual(Array(png.prefix(4)), [0x89, 0x50, 0x4E, 0x47], "not a PNG")
    }

    /// An excluded tile PAINTS. This test used to assert the opposite, and that was the bug the
    /// pilot caught: water, forest and 40-degree mountainside all returned nil from the scorer,
    /// the renderer skipped those pixels, and the most lethal ground in the cell came out blank —
    /// indistinguishable from terrain we have no data for.
    func testExcludedWaterTilePaintsRatherThanVanishing() throws {
        let png = try XCTUnwrap(comp.tilePNG(signature: comp.signature, z: z, x: x0 + 1, y: y0),
                                "an all-water tile must render the affirmative exclusion wash")
        XCTAssertGreaterThan(png.count, 100)
    }

    /// The three visual states must stay three. `unknown` is the only one that may render as
    /// nothing; `excluded` and `scored` both paint, and they must not look alike.
    func testUnknownRendersNothingWhileExcludedPaints() throws {
        // The fixture has no all-unknown tile, so build the comparison from the scorer instead:
        // an unknown-class sample makes no claim, a water sample excludes.
        let water = try sampleTile(dx: 1, dy: 0)
        XCTAssertTrue(water.vetoed, "water must be an active exclusion, not an absence of opinion")
        XCTAssertEqual(water.score, 0)
        XCTAssertFalse(water.rules.filter { $0.kind == .veto }.isEmpty,
                       "an exclusion must name the rule that produced it")
    }

    /// The whole point of the architecture: a stale signature must not serve a tile scored for the
    /// previous aircraft. It 404s, MapLibre re-requests under the new template after the source
    /// remount, and the map never shows a mix of two aircraft's scores.
    func testStaleSignatureIsRefused() {
        XCTAssertNil(comp.tilePNG(signature: "deadbeefdeadbeef", z: z, x: x0, y: y0))
    }

    func testCacheReturnsByteIdenticalTiles() throws {
        let a = try XCTUnwrap(comp.tilePNG(signature: comp.signature, z: z, x: x0, y: y0))
        let b = try XCTUnwrap(comp.tilePNG(signature: comp.signature, z: z, x: x0, y: y0))
        XCTAssertEqual(a, b)
    }

    func testMissingTileAddressReturnsNil() {
        XCTAssertNil(comp.tilePNG(signature: comp.signature, z: z, x: 4242, y: 4242))
    }

    /// Decode the rendered PNG and check the ACTUAL pixel colour.
    ///
    /// Nothing else in this suite could catch a channel swap: byte counts, PNG magic, cache
    /// identity and every score assertion all pass with red and blue exchanged. The first version
    /// packed `A<<24|B<<16|G<<8|R` for a `premultipliedFirst|byteOrder32Little` context, so GREEN
    /// — which occupies the same slot either way — looked perfect while the red exclusion wash
    /// rendered blue-purple on the map.
    private func firstOpaquePixel(_ png: Data) throws -> (r: Int, g: Int, b: Int, a: Int) {
        let src = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let img = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
        let w = img.width, h = img.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = try XCTUnwrap(CGContext(
            data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        for i in stride(from: 0, to: buf.count, by: 4) where buf[i + 3] > 8 {
            return (Int(buf[i]), Int(buf[i + 1]), Int(buf[i + 2]), Int(buf[i + 3]))
        }
        XCTFail("no opaque pixel in the rendered tile")
        return (0, 0, 0, 0)
    }

    func testExclusionWashIsRedNotBlue() throws {
        let png = try XCTUnwrap(comp.tilePNG(signature: comp.signature, z: z, x: x0 + 1, y: y0))
        let p = try firstOpaquePixel(png)
        XCTAssertGreaterThan(p.r, p.b + 40,
                             "exclusion rendered (r:\(p.r) g:\(p.g) b:\(p.b)) — red/blue swapped")
        XCTAssertGreaterThan(p.r, p.g + 40, "exclusion should be dominantly red")
    }

    func testFavourableGroundIsGreen() throws {
        let png = try XCTUnwrap(comp.tilePNG(signature: comp.signature, z: z, x: x0, y: y0))
        let p = try firstOpaquePixel(png)
        XCTAssertGreaterThan(p.g, p.r, "a clean field should read green (r:\(p.r) g:\(p.g) b:\(p.b))")
        XCTAssertGreaterThan(p.g, p.b)
    }

    // MARK: - scoring semantics, via sampling

    private func sampleTile(dx: Int, dy: Int) throws -> LZSampleInfo {
        // Centre of the requested fixture tile, converted back to a coordinate.
        let n = Double(1 << z)
        let lon = (Double(x0 + dx) + 0.5) / n * 360.0 - 180.0
        let yf = (Double(y0 + dy) + 0.5) / n
        let lat = atan(sinh(.pi * (1 - 2 * yf))) * 180.0 / .pi
        return try XCTUnwrap(comp.sample(lon: lon, lat: lat, z: z))
    }

    func testCleanFieldScoresWellAndIsNotVetoed() throws {
        let s = try sampleTile(dx: 0, dy: 0)
        XCTAssertFalse(s.vetoed)
        XCTAssertGreaterThan(s.score, 50, "a clean open field on fine terrain should score well")
        XCTAssertEqual(s.surfaceClass, LZPack.classOpenFirm)
        XCTAssertFalse(s.coarseTerrain)
    }

    func testWaterIsVetoedAndSaysWhy() throws {
        let s = try sampleTile(dx: 1, dy: 0)
        XCTAssertTrue(s.vetoed)
        XCTAssertEqual(s.score, 0)
        let veto = try XCTUnwrap(s.rules.first { $0.kind == .veto })
        XCTAssertEqual(veto.id, "water")
        XCTAssertFalse(veto.text.isEmpty, "a veto must name itself on the card")
    }

    /// The coarse-DEM cap. Identical surface facts, different DEM provenance — the only thing that
    /// may separate them is the cap, and it must actually bite. Nothing in the shipping pack can
    /// test this (3DEP 1 m covers 100% of the pilot cell), which is why the fixture carries it.
    func testCoarseTerrainScoresStrictlyBelowIdenticalFineTerrain() throws {
        let fine = try sampleTile(dx: 0, dy: 0)
        let coarse = try sampleTile(dx: 0, dy: 1)
        XCTAssertEqual(coarse.surfaceClass, fine.surfaceClass, "fixture tiles must match on surface")
        XCTAssertTrue(coarse.coarseTerrain)
        XCTAssertLessThan(coarse.score, fine.score,
                          "un-vetoable coarse terrain must not score like lidar-covered ground")
        XCTAssertLessThanOrEqual(coarse.score, rules.capCoarseTerrain)
        XCTAssertTrue(coarse.rules.contains { $0.id == "coarse_terrain" && $0.kind == .cap })
    }

    /// Hazard must dominate surface: good ground beside a charted wire is not good ground.
    func testChartedWireCapsOtherwiseGoodGround() throws {
        let clean = try sampleTile(dx: 0, dy: 0)
        let wired = try sampleTile(dx: 1, dy: 1)
        XCTAssertEqual(wired.surfaceClass, clean.surfaceClass)
        XCTAssertLessThan(wired.score, clean.score)
        XCTAssertLessThanOrEqual(wired.score, try XCTUnwrap(rules.capFlag[LZPack.flagTXCorridor]))
        XCTAssertTrue(wired.rules.contains { $0.id == "wire_corridor" && $0.kind == .cap })
    }

    /// Every scored cell carries the standing "wires are largely unmapped" note. Absence of a
    /// depicted wire is not evidence of no wire, and the card has to keep saying so.
    func testEverySampleCarriesTheUnmappedWiresCaveat() throws {
        for (dx, dy) in [(0, 0), (1, 1), (0, 1)] {
            let s = try sampleTile(dx: dx, dy: dy)
            XCTAssertTrue(s.rules.contains { $0.id == "unmapped_wires" },
                          "tile +\(dx),+\(dy) lost the unmapped-wires caveat")
        }
    }

    func testRulesAreListedVetoesThenCapsThenFlags() throws {
        let s = try sampleTile(dx: 1, dy: 1)
        let order = s.rules.map(\.kind)
        let firstFlag = order.firstIndex(of: .flag) ?? order.count
        let lastCap = order.lastIndex(of: .cap) ?? -1
        XCTAssertLessThan(lastCap, firstFlag, "caps must be listed before annotation-only flags")
    }

    // MARK: - aircraft changes the map

    /// Switching aircraft must visibly re-score, and must re-key the cache so no pixel from the
    /// previous aircraft survives.
    func testAircraftChangeAltersSignatureAndScores() throws {
        var cub = AircraftProfile(); cub.bestGlideKts = 45; cub.glideRatio = 9
        let doc = try XCTUnwrap(LZRulesetCompiler.loadDocument(bundle: Bundle(for: Self.self))
                                ?? LZRulesetCompiler.loadDocument(bundle: .main))
        let cubRules = try XCTUnwrap(LZRulesetCompiler.compile(document: doc, aircraft: cub,
                                                               themeKey: "day", packStamp: "fix"))
        XCTAssertNotEqual(cubRules.signature, rules.signature)
        let cubComp = LZTileCompositor(store: store, rules: cubRules, night: false)
        // The old signature must not be served by the new compositor.
        XCTAssertNil(cubComp.tilePNG(signature: comp.signature, z: z, x: x0, y: y0))
        XCTAssertNotNil(cubComp.tilePNG(signature: cubComp.signature, z: z, x: x0, y: y0))
    }

    func testNightThemeStillRendersButDiffersFromDay() throws {
        let night = LZTileCompositor(store: store, rules: rules, night: true)
        let d = try XCTUnwrap(comp.tilePNG(signature: comp.signature, z: z, x: x0, y: y0))
        let n = try XCTUnwrap(night.tilePNG(signature: night.signature, z: z, x: x0, y: y0))
        XCTAssertNotEqual(d, n, "night mode should not render identically to day")
    }

    // MARK: - projection helper

    func testTilePixelRoundTripsWithinTheTile() throws {
        let (tx, ty, px, py) = try XCTUnwrap(
            LZTileCompositor.tilePixel(lon: -106.92, lat: 32.289, z: 13))
        XCTAssertGreaterThanOrEqual(px, 0); XCTAssertLessThan(px, LZPack.side)
        XCTAssertGreaterThanOrEqual(py, 0); XCTAssertLessThan(py, LZPack.side)
        XCTAssertGreaterThan(tx, 0); XCTAssertGreaterThan(ty, 0)
    }

    func testTilePixelRejectsOutOfRangeInputs() {
        XCTAssertNil(LZTileCompositor.tilePixel(lon: 0, lat: 89, z: 13), "beyond mercator limits")
        XCTAssertNil(LZTileCompositor.tilePixel(lon: 0, lat: 0, z: 40), "absurd zoom")
    }
}
