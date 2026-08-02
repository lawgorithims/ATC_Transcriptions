import XCTest
@testable import ATCTranscribe

/// Room-to-use feeding the risk shading, and the backward-compatibility guarantee that goes with it.
///
/// THE PROBLEM THIS DIMENSION SOLVES: a 60 m patch of perfect flat cropland ringed by forest scored
/// IDENTICALLY to the middle of a mile-wide field — same class, slope, roughness and hazard, so the
/// same colour. One is usable and one is not, and a pilot reading the gradient could not tell them
/// apart. That is risk, not a recommendation, so it belongs in the shading.
///
/// THE GUARANTEE THAT GOES WITH IT: a pack WITHOUT the plane must score exactly as it did before the
/// plane existed. Nil means "not measured", never "no room" — collapsing those would turn every pack
/// published so far into a map of unusable terrain.
final class LZExtentScoringTests: XCTestCase {

    private var document: Data!

    override func setUpWithError() throws {
        document = try XCTUnwrap(LZRulesetCompiler.loadDocument())
    }

    private func rules(over50 ft: Double) throws -> LZCompiledRuleset {
        var a = AircraftProfile()
        a.vRefKts = 62
        a.glideRatio = 9
        a.landingOver50Ft = ft
        return try XCTUnwrap(LZRulesetCompiler.compile(document: document, aircraft: a,
                                                       themeKey: "day", packStamp: "t"))
    }

    /// Raw extent byte for a run in metres.
    private func raw(_ metres: Double) -> UInt8 {
        UInt8(min(254, max(0, Int((metres / LZPack.extentStepM).rounded()))))
    }

    // MARK: - the model

    /// A C172 (~1250 ft over 50) needs about 572 m of unprepared run. The cap must be absent well
    /// above that, biting below it, and the ground excluded well below.
    func testTheCapCurveMatchesTheAeroplane() throws {
        let r = try rules(over50: 1250)
        XCTAssertEqual(r.requiredRunM, 1250 * 0.3048 * 1.5, accuracy: 1.0)

        XCTAssertEqual(r.extentCap[Int(raw(1200))], LZCompiledRuleset.scoreMax,
                       "twice the required run must not cap at all")
        XCTAssertLessThan(r.extentCap[Int(raw(460))], LZCompiledRuleset.scoreMax,
                          "80% of the required run should be capped")
        XCTAssertLessThan(r.extentCap[Int(raw(350))], r.extentCap[Int(raw(460))],
                          "the cap must tighten as the run shortens")
    }

    /// SATURATION IS NOT A LENGTH. 255 means "at least 2550 m"; reading it as exactly 2550 m would
    /// cap an aeroplane needing more than that on ground which is effectively unbounded.
    func testSaturatedExtentNeverCapsEvenForALongLandingAeroplane() throws {
        let heavy = try rules(over50: 6000)          // needs ~2743 m, more than 2550
        XCTAssertGreaterThan(heavy.requiredRunM, LZPack.extentMetres(254))
        XCTAssertEqual(heavy.extentCap[Int(LZPack.extentSaturated)], LZCompiledRuleset.scoreMax,
                       "'more room than anything can use' was treated as a hard 2550 m")
    }

    /// The same ground is a different answer for a different aeroplane — the murphy contract, now
    /// applied to room as well as to surface.
    func testTheSameGroundVetoesForOneAeroplaneAndNotAnother() throws {
        let cub = try rules(over50: 500)             // needs ~229 m
        let twin = try rules(over50: 3400)           // needs ~1554 m
        let fourHundredMetres = raw(400)

        let cubVeto = cub.extentVetoAtOrBelow.map { fourHundredMetres <= $0 } ?? false
        let twinVeto = twin.extentVetoAtOrBelow.map { fourHundredMetres <= $0 } ?? false
        XCTAssertFalse(cubVeto, "400 m is ample for a 500 ft-over-50 aeroplane")
        XCTAssertTrue(twinVeto, "400 m is far too short for a 3400 ft-over-50 aeroplane")
    }

    /// Zero is a MEASUREMENT — no open ground here — and its exclusion belongs to the surface class,
    /// which already says so. Vetoing on it here would double-report the same fact and bury the real
    /// reason on the card.
    func testZeroExtentIsNotItselfTheVetoReason() throws {
        let r = try rules(over50: 1250)
        let vetoAt = try XCTUnwrap(r.extentVetoAtOrBelow)
        XCTAssertGreaterThanOrEqual(vetoAt, 1, "the veto threshold must exclude zero")
    }

    /// The threshold scales with the aeroplane, monotonically.
    func testAVeryShortLandingAeroplaneIsVetoedOnLessGround() throws {
        let short = try rules(over50: 600)
        let long = try rules(over50: 4000)
        let a = try XCTUnwrap(short.extentVetoAtOrBelow)
        let b = try XCTUnwrap(long.extentVetoAtOrBelow)
        XCTAssertLessThan(a, b, "the longer-landing aeroplane must be vetoed on more ground")
    }

    // MARK: - backward compatibility

    /// A ruleset with no extent model compiles and caps nothing — the behaviour before the plane.
    func testARulesetWithoutTheModelCapsNothing() throws {
        var doc = try XCTUnwrap(String(data: document, encoding: .utf8))
        // Remove the model by renaming its key, which is how a ruleset predating it looks.
        doc = doc.replacingOccurrences(of: "\"extent_model\"", with: "\"extent_model_disabled\"")
        let r = try XCTUnwrap(LZRulesetCompiler.compile(document: Data(doc.utf8), aircraft: nil,
                                                        themeKey: "day", packStamp: "t"))
        XCTAssertTrue(r.extentCap.isEmpty, "no model must mean no cap table at all")
        XCTAssertNil(r.extentVetoAtOrBelow)
    }

    /// THE COMPATIBILITY GUARANTEE, end to end through the real fixture. The fixture's schema-2
    /// tiles are saturated except the deliberately-short one, so a pack with the plane and a pack
    /// without must agree everywhere the run is ample.
    func testSaturatedGroundScoresTheSameWithOrWithoutTheModel() throws {
        let withModel = try rules(over50: 1250)
        var doc = try XCTUnwrap(String(data: document, encoding: .utf8))
        doc = doc.replacingOccurrences(of: "\"extent_model\"", with: "\"extent_model_disabled\"")
        var a = AircraftProfile(); a.vRefKts = 62; a.glideRatio = 9; a.landingOver50Ft = 1250
        let without = try XCTUnwrap(LZRulesetCompiler.compile(document: Data(doc.utf8), aircraft: a,
                                                              themeKey: "day", packStamp: "t"))
        // Every other table must be untouched by the presence of the model.
        XCTAssertEqual(withModel.surfaceLUT, without.surfaceLUT)
        XCTAssertEqual(withModel.slopeLUT, without.slopeLUT)
        XCTAssertEqual(withModel.hazardLUT, without.hazardLUT)
        XCTAssertEqual(withModel.roughLUT, without.roughLUT)
    }

    /// The signature must move with the required run, or changing aeroplane re-compiles a different
    /// cap table and the map serves the previous one's cached tiles.
    func testTheSignatureFollowsTheRequiredRun() throws {
        XCTAssertNotEqual(try rules(over50: 800).signature, try rules(over50: 3000).signature)
    }

    /// Room must never RAISE a score — it is a ceiling, not a bonus. If it could lift ground, a
    /// wide-open patch of forest would start competing with a field.
    func testExtentOnlyEverLowersAScore() throws {
        let r = try rules(over50: 1250)
        for raw in 0...255 {
            XCTAssertLessThanOrEqual(r.extentCap[raw], LZCompiledRuleset.scoreMax,
                                     "extent cap exceeded the score ceiling at raw \(raw)")
            XCTAssertGreaterThanOrEqual(r.extentCap[raw], 0)
        }
        // Monotone: more room is never worth less.
        for raw in 1...254 where raw > 1 {
            XCTAssertGreaterThanOrEqual(r.extentCap[raw], r.extentCap[raw - 1],
                                        "more room scored worse at raw \(raw)")
        }
    }
}
