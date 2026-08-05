import XCTest
@testable import ATCTranscribe

/// Landing distance in the murphy factor, and the borrowed-speed bug it replaced.
///
/// WHAT THIS DIMENSION MAY AND MAY NOT CLAIM. A 10 m fact cell does not know how LONG a field is,
/// so "will it fit" is not answerable at pixel level — that is the site finder's question. What
/// landing distance legitimately says here is how much MARGINAL ground an aeroplane can use at all:
/// one needing 2,600 ft over a 50 ft obstacle cannot treat brush the way one needing 900 ft can.
/// These tests pin that boundary in both directions — the scaling happens, and it does not leak
/// into the hazard term or move the top of the scale.
final class LZLandingDistanceTests: XCTestCase {

    private var document: Data!

    override func setUpWithError() throws {
        document = try XCTUnwrap(LZRulesetCompiler.loadDocument(),
                                 "the shipped ruleset must be in the test bundle")
    }

    private func compiled(_ aircraft: AircraftProfile?) throws -> LZCompiledRuleset {
        try XCTUnwrap(LZRulesetCompiler.compile(document: document, aircraft: aircraft,
                                                themeKey: "day", packStamp: "test"))
    }

    private func plane(vref: Int? = nil, over50: Double? = nil,
                       glide: Double? = 9, vbg: Int? = 70) -> AircraftProfile {
        var a = AircraftProfile()
        a.callsign = "N0LZ"
        a.glideRatio = glide
        a.bestGlideKts = vbg
        a.vRefKts = vref
        a.landingOver50Ft = over50
        return a
    }

    /// Utility of a surface class, 0...255 out of the compiled LUT.
    private func utility(_ r: LZCompiledRuleset, _ code: UInt8) -> Int { Int(r.surfaceLUT[Int(code)]) }

    // MARK: - the borrowed speed

    /// ⚠️ THE BUG THIS REPLACED. The compiler read `bestGlideKts` AS Vref. They are different
    /// speeds — best glide is flown well above approach speed — so an aeroplane that glides at 90
    /// and crosses the fence at 55 was scored as though it touched down at 90.
    ///
    /// It erred SAFE (a faster assumed touchdown tolerates less surface and slope), which is exactly
    /// why nobody noticed: nothing on screen looked wrong. This asserts the two fields now have
    /// visibly different effects, so the borrowing cannot come back unseen.
    func testVrefIsReadFromVrefAndNotFromBestGlide() throws {
        // Same aeroplane, same Vref; only the best-glide speed differs. Best glide does not enter
        // the score at all, so nothing may move.
        let slowGlide = try compiled(plane(vref: 55, over50: 1600, vbg: 65))
        let fastGlide = try compiled(plane(vref: 55, over50: 1600, vbg: 110))
        XCTAssertEqual(slowGlide.signature, fastGlide.signature,
                       "best-glide speed changed the score — it is being read as Vref again")

        // Now hold best glide and change Vref. This MUST move.
        let slowApproach = try compiled(plane(vref: 45, over50: 1600, vbg: 80))
        let fastApproach = try compiled(plane(vref: 95, over50: 1600, vbg: 80))
        XCTAssertNotEqual(slowApproach.signature, fastApproach.signature,
                          "approach speed had no effect on the score")
    }

    // MARK: - what distance scales

    /// A long-landing aeroplane gets LESS out of marginal ground. Brush is the clearest case: it is
    /// usable at all only when you can afford the roll.
    func testALongLandingAeroplaneGetsLessFromMarginalGround() throws {
        let cub = try compiled(plane(vref: 45, over50: 500))
        let twin = try compiled(plane(vref: 90, over50: 3400))

        for surface in [LZPack.classBrush, LZPack.classOpenSoft, LZPack.classBarrenRough] {
            XCTAssertGreaterThan(utility(cub, surface), utility(twin, surface),
                                 "\(LZPack.className(surface)): the long-landing aeroplane was not "
                                 + "penalised on marginal ground")
        }
    }

    /// ...but the TOP of the scale does not move. Firm open ground is the best ground there is for
    /// everything that flies, and if it slid around per aeroplane the pilot would have no fixed
    /// reference for what "good" means.
    func testTheBestGroundIsTheSameForEveryAeroplane() throws {
        let cub = try compiled(plane(vref: 45, over50: 500))
        let twin = try compiled(plane(vref: 90, over50: 3400))
        XCTAssertEqual(utility(cub, LZPack.classOpenFirm), utility(twin, LZPack.classOpenFirm),
                       "firm open ground moved when the aeroplane changed")
    }

    /// Distance must NOT touch the hazard term. A tower is equally lethal to a Cub and a Malibu, and
    /// letting aircraft performance discount an obstacle is the one direction this must never go.
    func testDistanceNeverDiscountsHazard() throws {
        let cub = try compiled(plane(vref: 45, over50: 500))
        let twin = try compiled(plane(vref: 90, over50: 3400))
        XCTAssertEqual(cub.hazardLUT, twin.hazardLUT,
                       "landing distance leaked into the hazard curve")
        // And unlandable stays unlandable regardless.
        for surface in [LZPack.classWater, LZPack.classForest, LZPack.classDevelopedDense] {
            XCTAssertEqual(utility(cub, surface), 0)
            XCTAssertEqual(utility(twin, surface), 0)
        }
    }

    /// An aeroplane at the reference distance must score exactly as the default table does, or the
    /// model has quietly re-baselined every published weight.
    func testTheReferenceAeroplaneIsUnchanged() throws {
        let atReference = try compiled(plane(vref: 65, over50: 1600))
        let noProfile = try compiled(nil)
        XCTAssertEqual(atReference.surfaceLUT, noProfile.surfaceLUT,
                       "an aeroplane at the reference numbers is not the default aeroplane")
    }

    // MARK: - bounds and identity

    /// A ground roll typed in metres, a zero, a negative — none may invent an aeroplane that lands
    /// anywhere or one that cannot land at all.
    func testAbsurdDistancesAreClamped() throws {
        for bad in [0.0, -1.0, 5.0, 1_000_000.0, .infinity, .nan] {
            let r = try compiled(plane(vref: 65, over50: bad))
            for code in 0...255 {
                XCTAssertLessThanOrEqual(Int(r.surfaceLUT[code]), 255)
            }
            XCTAssertEqual(utility(r, LZPack.classWater), 0, "water became landable at \(bad) ft")
        }
    }

    /// The signature must move with landing distance. Without it the compiler builds a different LUT
    /// and the map serves the PREVIOUS aeroplane's cached tiles under the same URL — the same class
    /// of staleness the pack fingerprint exists to prevent.
    func testTheSignatureFollowsLandingDistance() throws {
        let short = try compiled(plane(vref: 65, over50: 900))
        let long = try compiled(plane(vref: 65, over50: 3400))
        XCTAssertNotEqual(short.signature, long.signature,
                          "changing landing distance did not change the tile signature")
        XCTAssertEqual(short.signature.count, 16)
        XCTAssertEqual(short.signature, short.signature.lowercased(),
                       "the signature rides a URL path — hex must stay lowercase")
    }

    /// A profile that predates these fields still compiles, on the same rule as the glide fields.
    func testAProfileWithoutTheNewFieldsStillCompiles() throws {
        var old = AircraftProfile()
        old.callsign = "N123"
        old.glideRatio = 9
        old.bestGlideKts = 68            // no vRefKts, no landingOver50Ft
        let r = try compiled(old)
        XCTAssertEqual(r.surfaceLUT.count, 256)
        XCTAssertGreaterThan(utility(r, LZPack.classOpenFirm), 0)
    }

    /// The ruleset must still be internally coherent after gaining the model.
    func testTheShippedRulesetStillPartitionsUnity() throws {
        let r = try compiled(nil)
        let total = r.wSurface + r.wSlope + r.wRough + r.wHazard
        XCTAssertEqual(total, 255, accuracy: 2, "weights no longer sum to one")
    }

    // MARK: - rotorcraft

    private func helicopter() -> AircraftProfile {
        var a = AircraftProfile()
        a.callsign = "N44RH"
        a.glideRatio = 4.0                  // autorotation, roughly 4:1
        a.bestGlideKts = 70
        a.vRefKts = 60
        a.landingOver50Ft = nil             // the catalogue publishes none, by design
        a.isRotorcraft = true
        return a
    }

    /// ⚠️ THE DEFECT THIS PINS. The catalogue withholds a landing distance for helicopters and says
    /// in as many words that a fixed-wing figure would be misleading; the sheet tells the pilot the
    /// field is "not used for rotorcraft". Every consumer then read the nil and substituted the
    /// 1,600 ft fixed-wing default, so an R44 was asked for 731 m of open ground — about five times
    /// an autorotation's needs — and the extent veto blacked out ground it could use easily.
    ///
    /// Nothing on screen said so. The layer simply went dark for helicopters, which reads exactly
    /// like "nowhere here is landable": the most dangerous sentence this layer can speak.
    func testAHelicopterIsNotAskedForARunwaysWorthOfGround() {
        let heli = LZSiteFinder.requiredRunMetres(for: helicopter())
        let fixed = LZSiteFinder.requiredRunMetres(for: plane(vref: 60, over50: nil))
        XCTAssertLessThan(heli, fixed / 3.0,
                          "a rotorcraft is still inheriting the fixed-wing landing distance")
        // …but it is still a REQUIREMENT. "A helicopter can land anywhere" is a claim this layer
        // must never make: a 137 m clear run is the floor the model can express, not zero.
        XCTAssertGreaterThan(heli, 100.0, "a rotorcraft was let off any room requirement at all")
    }

    /// The list and the shading must decide it identically — they read the same nil and drew
    /// opposite conclusions before, which is what routing both through one helper fixes.
    func testTheShadingAndTheListAgreeOnWhatAHelicopterNeeds() throws {
        let heli = helicopter()
        let compiledFt = LZSiteFinder.bookLandingDistanceFt(for: heli)
        XCTAssertEqual(compiledFt, LZSiteFinder.rotorcraftBookFt)
        // The compiled ruleset must be a DIFFERENT one from the same airframe read as fixed-wing,
        // or the map is still painting the aeroplane's answer under the helicopter's name.
        var asFixedWing = heli
        asFixedWing.isRotorcraft = nil
        XCTAssertNotEqual(try compiled(heli).signature, try compiled(asFixedWing).signature,
                          "marking the profile as a rotorcraft changed nothing the map draws")
    }

    /// ⚠️ THE HALF THAT ERRED THE UNSAFE WAY. Slope tolerance stretches with a slower Vref — a
    /// fixed-wing argument, since a slower touchdown leaves more margin on sloping ground. Skid gear
    /// does not work that way: slope is a rollover limit, not an energy one. A helicopter's low Vref
    /// was therefore widening the very curve it should tighten, and unlike the distance defect this
    /// one made the map MORE permissive.
    func testAHelicopterIsNeverMoreSlopeTolerantThanTheReference() throws {
        let heli = try compiled(helicopter())
        let reference = try compiled(nil)                  // the ruleset's own conservative curve
        for raw in 0...255 {
            XCTAssertLessThanOrEqual(Int(heli.slopeLUT[raw]), Int(reference.slopeLUT[raw]),
                                     "a rotorcraft scored slope \(raw) better than the reference "
                                     + "fixed-wing curve — the stretch is back")
        }
        // And it must not have been flattened to nothing either: level ground still scores.
        XCTAssertGreaterThan(Int(heli.slopeLUT[0]), 200, "level ground stopped being landable")
    }
}
