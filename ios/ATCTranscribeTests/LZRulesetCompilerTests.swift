import XCTest
@testable import ATCTranscribe

/// Tests for the compiled ruleset — the layer where all judgment lives.
///
/// The properties worth defending here are not "does it produce a number" but the invariants the
/// safety story rests on: every veto and cap can name itself, a cap really is a ceiling, the
/// coarse-DEM rule fires, and the signature changes exactly when the rendered pixels would.
final class LZRulesetCompilerTests: XCTestCase {

    private var document: Data!

    override func setUpWithError() throws {
        // The shipped ruleset, from the app bundle — not a hand-written stub, so these tests fail
        // if the real document drifts out of contract.
        document = try XCTUnwrap(LZRulesetCompiler.loadDocument(bundle: Bundle(for: LZPackTests.self))
                                 ?? LZRulesetCompiler.loadDocument(bundle: .main),
                                 "lz_ruleset_v1.json missing from the bundle")
    }

    private func compiled(aircraft: AircraftProfile? = nil,
                          theme: String = "day",
                          pack: String = "test") -> LZCompiledRuleset? {
        LZRulesetCompiler.compile(document: document, aircraft: aircraft,
                                  themeKey: theme, packStamp: pack)
    }

    // MARK: - shape

    func testShippedRulesetCompiles() throws {
        let r = try XCTUnwrap(compiled(), "the shipped ruleset must compile")
        XCTAssertEqual(r.rulesetID, "fw_ambient")
        XCTAssertFalse(r.rulesetVersion.isEmpty)
        XCTAssertEqual(r.slopeLUT.count, 256)
        XCTAssertEqual(r.roughLUT.count, 256)
        XCTAssertEqual(r.hazardLUT.count, 256)
        XCTAssertEqual(r.surfaceLUT.count, 256)
    }

    func testWeightsFormAPartitionOfUnity() throws {
        let r = try XCTUnwrap(compiled())
        let sum = r.wSurface + r.wSlope + r.wRough + r.wHazard
        // Pre-scaled to 255 for integer per-pixel maths; allow one unit of rounding.
        XCTAssertEqual(sum, 255, accuracy: 1)
    }

    /// Invariant: every veto and every cap carries human text. A rule that cannot name itself
    /// could decide a cell with no way to explain why, which is exactly what this layer must not do.
    func testEveryVetoAndCapNamesItself() throws {
        let r = try XCTUnwrap(compiled())
        XCTAssertFalse(r.vetoText.isEmpty)
        XCTAssertFalse(r.capText.isEmpty)
        for (id, text) in r.vetoText {
            XCTAssertFalse(text.isEmpty, "veto \(id) has no card text")
        }
        for (id, text) in r.capText {
            XCTAssertFalse(text.isEmpty, "cap \(id) has no card text")
        }
    }

    // MARK: - utilities

    func testPiecewiseInterpolationMatchesHandComputedPoints() {
        let pts: [[Double]] = [[0, 1.0], [2.0, 1.0], [5.0, 0.45], [9.0, 0.1], [12.0, 0.0]]
        XCTAssertEqual(LZRulesetCompiler.interpolate(pts, at: 0), 1.0, accuracy: 1e-9)
        XCTAssertEqual(LZRulesetCompiler.interpolate(pts, at: 2.0), 1.0, accuracy: 1e-9)
        // midpoint of the 2 -> 5 segment
        XCTAssertEqual(LZRulesetCompiler.interpolate(pts, at: 3.5), 0.725, accuracy: 1e-9)
        XCTAssertEqual(LZRulesetCompiler.interpolate(pts, at: 12.0), 0.0, accuracy: 1e-9)
        // Clamped, not extrapolated — off the end of the table must not produce a negative utility.
        XCTAssertEqual(LZRulesetCompiler.interpolate(pts, at: -5), 1.0, accuracy: 1e-9)
        XCTAssertEqual(LZRulesetCompiler.interpolate(pts, at: 99), 0.0, accuracy: 1e-9)
    }

    func testSlopeLUTIsMonotonicallyNonIncreasing() throws {
        let r = try XCTUnwrap(compiled())
        // Steeper ground can never score better than gentler ground.
        for raw in 1...254 {
            XCTAssertLessThanOrEqual(r.slopeLUT[raw], r.slopeLUT[raw - 1],
                                     "slope utility rose at raw \(raw)")
        }
    }

    func testHazardLUTIsMonotonicallyNonIncreasing() throws {
        let r = try XCTUnwrap(compiled())
        for raw in 1...255 {
            XCTAssertLessThanOrEqual(r.hazardLUT[raw], r.hazardLUT[raw - 1],
                                     "hazard utility rose at raw \(raw)")
        }
    }

    /// Nodata must score zero, not "very steep but survivable". A hole in the DEM is an absence of
    /// knowledge; scoring it as a real value would paint unknown ground as merely poor.
    func testNoDataSlopeAndRoughScoreZero() throws {
        let r = try XCTUnwrap(compiled())
        XCTAssertEqual(r.slopeLUT[Int(LZPack.slopeNoData)], 0)
        XCTAssertEqual(r.roughLUT[Int(LZPack.roughNoData)], 0)
    }

    func testSurfaceUtilityRanksClassesSensibly() throws {
        let r = try XCTUnwrap(compiled())
        let firm = r.surfaceLUT[Int(LZPack.classOpenFirm)]
        let crop = r.surfaceLUT[Int(LZPack.classCrop)]
        let brush = r.surfaceLUT[Int(LZPack.classBrush)]
        XCTAssertGreaterThan(firm, crop)
        XCTAssertGreaterThan(crop, brush)
        XCTAssertEqual(r.surfaceLUT[Int(LZPack.classWater)], 0)
        XCTAssertEqual(r.surfaceLUT[Int(LZPack.classForest)], 0)
        XCTAssertEqual(r.surfaceLUT[Int(LZPack.classUnknown)], 0)
    }

    // MARK: - vetoes and caps

    func testVetoClassesAreExactlyTheDeclaredOnes() throws {
        let r = try XCTUnwrap(compiled())
        XCTAssertTrue(r.vetoClass[Int(LZPack.classWater)])
        XCTAssertTrue(r.vetoClass[Int(LZPack.classDevelopedDense)])
        XCTAssertTrue(r.vetoClass[Int(LZPack.classForest)])
        XCTAssertFalse(r.vetoClass[Int(LZPack.classOpenFirm)])
        XCTAssertFalse(r.vetoClass[Int(LZPack.classCrop)])
        XCTAssertFalse(r.vetoClass[Int(LZPack.classBrush)])
    }

    /// The rule that keeps un-vetoable coarse terrain from outscoring lidar-covered ground.
    /// Nothing in the shipping pack exercises it (3DEP 1 m covers 100% of the pilot cell), so this
    /// test and the fixture's synthetic coarse tile are the only things standing behind it.
    func testCoarseTerrainCapIsBelowFullScore() throws {
        let r = try XCTUnwrap(compiled())
        XCTAssertLessThan(r.capCoarseTerrain, LZCompiledRuleset.scoreMax)
        XCTAssertGreaterThan(r.capCoarseTerrain, 0)
        XCTAssertNotNil(r.capText["coarse_terrain"])
    }

    func testWireCorridorCapIsTighterThanTheAssumedRoadCap() throws {
        let r = try XCTUnwrap(compiled())
        let charted = try XCTUnwrap(r.capFlag[LZPack.flagTXCorridor])
        let assumed = try XCTUnwrap(r.capFlag[LZPack.flagRoadBuffer])
        // A charted powerline is known; an assumed road corridor is a heuristic. The known hazard
        // must bite harder, or the confidence tiers mean nothing.
        XCTAssertLessThan(charted, assumed)
    }

    func testSlopeVetoThresholdMatchesTheDocument() throws {
        let r = try XCTUnwrap(compiled())
        let deg = try XCTUnwrap(LZPack.slopeDegrees(r.slopeVetoAbove))
        XCTAssertEqual(deg, 12.0, accuracy: LZPack.slopeStepDeg)
    }

    // MARK: - aircraft dependence

    /// The murphy contract: aircraft changes the CURVE, not a scalar. A slower aeroplane must see
    /// at least as much slope tolerance as a faster one, everywhere.
    ///
    /// ⚠️ These used to be distinguished by `bestGlideKts`, back when the compiler read best glide
    /// AS the approach speed. They are different speeds, so this test was quietly asserting the bug
    /// — and it broke the moment the compiler started reading `vRefKts`, which is what a test
    /// encoding a defect should do.
    func testSlowerAircraftNeverSeesLessSlopeToleranceThanFaster() throws {
        var slow = AircraftProfile(); slow.vRefKts = 45; slow.glideRatio = 9
        var fast = AircraftProfile(); fast.vRefKts = 110; fast.glideRatio = 12
        let s = try XCTUnwrap(compiled(aircraft: slow))
        let f = try XCTUnwrap(compiled(aircraft: fast))
        for raw in 0...254 {
            XCTAssertGreaterThanOrEqual(s.slopeLUT[raw], f.slopeLUT[raw],
                                        "faster aircraft tolerated more slope at raw \(raw)")
        }
        XCTAssertNotEqual(s.slopeLUT, f.slopeLUT, "aircraft made no difference at all")
    }

    /// The energy modifier is bounded so it can reorder marginal surfaces but never lift one above
    /// genuinely good ground. Invariant 1: a bonus never beats a better class.
    func testEnergyModifierNeverLiftsMarginalAboveOpenField() throws {
        for kts in [40, 55, 65, 90, 130] {
            var p = AircraftProfile(); p.vRefKts = kts
            let r = try XCTUnwrap(compiled(aircraft: p))
            XCTAssertGreaterThan(r.surfaceLUT[Int(LZPack.classOpenFirm)],
                                 r.surfaceLUT[Int(LZPack.classBrush)],
                                 "brush caught open field at \(kts) kt")
            XCTAssertLessThanOrEqual(r.surfaceLUT[Int(LZPack.classBrush)], 255)
        }
    }

    func testHazardUtilityIsIdenticalAcrossAircraft() throws {
        // Must vary inputs the compiler READS. Distinguishing these by bestGlideKts would make
        // them identical aeroplanes and the assertion below would hold vacuously.
        var slow = AircraftProfile(); slow.vRefKts = 40; slow.landingOver50Ft = 700
        var fast = AircraftProfile(); fast.vRefKts = 140; fast.landingOver50Ft = 4200
        let s = try XCTUnwrap(compiled(aircraft: slow))
        let f = try XCTUnwrap(compiled(aircraft: fast))
        // A wire does not care what you fly. The energy model must never touch the hazard term.
        XCTAssertEqual(s.hazardLUT, f.hazardLUT)
    }

    // MARK: - signature

    func testSignatureIsLowercaseHexOnly() throws {
        let r = try XCTUnwrap(compiled())
        let allowed = CharacterSet(charactersIn: "0123456789abcdef")
        XCTAssertTrue(r.signature.unicodeScalars.allSatisfy { allowed.contains($0) },
                      "signature '\(r.signature)' is not lowercase hex — the tile server's path "
                      + "parser splits on '/' and '.' and would truncate it")
        XCTAssertFalse(r.signature.isEmpty)
    }

    func testSignatureIsStableForIdenticalInputs() throws {
        let a = try XCTUnwrap(compiled())
        let b = try XCTUnwrap(compiled())
        XCTAssertEqual(a.signature, b.signature)
    }

    func testSignatureChangesWithAircraftThemeAndPack() throws {
        var p = AircraftProfile(); p.glideRatio = 11; p.vRefKts = 70
        let base = try XCTUnwrap(compiled())
        let byAircraft = try XCTUnwrap(compiled(aircraft: p))
        let byTheme = try XCTUnwrap(compiled(theme: "night"))
        let byPack = try XCTUnwrap(compiled(pack: "other"))
        XCTAssertNotEqual(base.signature, byAircraft.signature, "aircraft must re-key the cache")
        XCTAssertNotEqual(base.signature, byTheme.signature, "theme must re-key the cache")
        XCTAssertNotEqual(base.signature, byPack.signature, "a new pack must re-key the cache")
    }

    // MARK: - malformation

    func testMalformedDocumentsCompileToNil() {
        XCTAssertNil(LZRulesetCompiler.compile(document: Data("not json".utf8), aircraft: nil,
                                               themeKey: "day", packStamp: "p"))
        XCTAssertNil(LZRulesetCompiler.compile(document: Data("{}".utf8), aircraft: nil,
                                               themeKey: "day", packStamp: "p"))
    }

    func testWeightsThatDoNotSumToOneAreRefused() throws {
        var obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: document) as? [String: Any])
        obj["weights"] = ["surface": 0.9, "slope": 0.9, "rough": 0.9, "hazard": 0.9]
        let bad = try JSONSerialization.data(withJSONObject: obj)
        XCTAssertNil(LZRulesetCompiler.compile(document: bad, aircraft: nil,
                                               themeKey: "day", packStamp: "p"),
                     "weights that do not partition unity put the score off the caps' scale")
    }

    /// A ruleset written against a different fact schema must be refused outright — the plane
    /// order it assumes may no longer be the one in the pack.
    func testMismatchedFactSchemaIsRefused() throws {
        var obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: document) as? [String: Any])
        obj["requires_facts_schema"] = LZPack.schema + 1
        let bad = try JSONSerialization.data(withJSONObject: obj)
        XCTAssertNil(LZRulesetCompiler.compile(document: bad, aircraft: nil,
                                               themeKey: "day", packStamp: "p"))
    }
}
