import XCTest
@testable import ATCTranscribe

/// Regressions an adversarial pass found in this session's own fixes. Every one of these was
/// self-inflicted by a fix, which is why they are pinned here rather than in the file they touch.
final class FixVerificationTests: XCTestCase {

    private func k(_ desc: String, _ alt: String, _ alt2: String = "", speed: Int? = nil) -> LegConstraint {
        LegConstraint(altDesc: desc, alt: alt, alt2: alt2, speedLimitKt: speed,
                      verticalAngleDeg: nil, rnpNm: nil)
    }
    private func leg(_ ident: String, _ c: LegConstraint?) -> ResolvedLeg {
        ResolvedLeg(ident: ident, kind: .waypoint, coord: Coord(lat: 35, lon: -106), constraint: c)
    }

    // MARK: - a blank coding must not erase a real one

    func testABlankCodingDoesNotWipeThePublishedAltitude() {
        // `CIFPLeg.constraint` is non-optional, so a leg with no altitude still arrives as a full
        // LegConstraint whose alt is nil. Treating that as "permits everything" destroyed a published
        // crossing altitude on 1,006 legs — 925 of them on STARs, undoing the fix that put the common
        // segment's restrictions back into constraintRoute.
        XCTAssertEqual(k("+", "04000").unioned(with: k("", "")).alt, .atOrAbove(4_000))
        XCTAssertEqual(k("", "").unioned(with: k("+", "04000")).alt, .atOrAbove(4_000),
                       "order must not matter")
    }

    func testABlankCodingDoesNotWipeThePublishedSpeedLimit() {
        XCTAssertEqual(k("", "", speed: 210).unioned(with: k("", "")).speedLimitKt, 210)
        XCTAssertEqual(k("", "").unioned(with: k("", "", speed: 210)).speedLimitKt, 210)
    }

    func testTwoRealRulesStillUnionToWhatBothPermit() {
        // The original behaviour this must not undo.
        XCTAssertEqual(k("+", "13000").unioned(with: k("+", "08600")).alt, .atOrAbove(8_600))
    }

    func testACollapsedPairKeepsTheOnlyPublishedAltitude() {
        var out: [ResolvedLeg] = []
        ProcedureRoute.appendDeduped(leg("GIGGY", k("+", "04000")), to: &out)
        ProcedureRoute.appendDeduped(leg("GIGGY", k("", "")), to: &out)
        XCTAssertEqual(out.first?.constraint?.alt, .atOrAbove(4_000),
                       "the blank second crossing must not erase the first's published altitude")
    }

    // MARK: - NASR codes must be translated, not passed through

    func testAClosedAirportIsClassifiedClosed() {
        // pure value mapping — no database needed
        // Closure lives in `status` (CI/CP), NOT in site_type — the first version never read it, so 254
        // closed fields drew as usable airports, which is worse than the circled U they had before.
        let closed = AirportData.Airport(ident: "TST", icao: "", name: "T", coord: Coord(lat: 0, lon: 0),
                                         elevationFt: nil, ownership: "PR", use: "PR", status: "CI",
                                         tower: "NON-ATCT", fuel: "", siteType: "A", far139: "")
        XCTAssertEqual(AirportSymbolData.curatedTypeCode(closed), "CLS")
    }

    func testNonAirplaneFacilitiesKeepTheirOwnGlyph() {
        for (site, want) in [("H", "HEL"), ("C", "SPB"), ("U", "ULT")] {
            let a = AirportData.Airport(ident: "T", icao: "", name: "T", coord: Coord(lat: 0, lon: 0),
                                        elevationFt: nil, ownership: "PU", use: "PU", status: "O",
                                        tower: "NON-ATCT", fuel: "", siteType: site, far139: "")
            XCTAssertEqual(AirportSymbolData.curatedTypeCode(a), want)
        }
    }

    func testAPlainAirportClaimsNoTypeCode() {
        let a = AirportData.Airport(ident: "T", icao: "", name: "T", coord: Coord(lat: 0, lon: 0),
                                    elevationFt: nil, ownership: "PU", use: "PU", status: "O",
                                    tower: "ATCT", fuel: "100LL", siteType: "A", far139: "")
        XCTAssertNil(AirportSymbolData.curatedTypeCode(a),
                     "an ordinary airport must let shape and owner classify it, not force a code")
    }

    func testMilitaryOwnershipMapsToTheLetterTheClassifierTests() {
        for o in ["MA", "MN", "MR"] { XCTAssertEqual(AirportSymbolData.curatedOwner(o), "M") }
        XCTAssertEqual(AirportSymbolData.curatedOwner("PR"), "PR")
        XCTAssertNil(AirportSymbolData.curatedOwner(""))
    }

    // MARK: - the geometry guard must actually be able to fire

    func testTheFieldResolvesForAnAirportTheGuardWasWrittenFor() throws {
        try XCTSkipUnless(CIFP.available, "cifp.sqlite not present")
        // The guard originally resolved the field through a 78-airport table that contains NONE of the
        // ten airports it exists for, so it could never fire.
        for apt in ["KSJT", "KRUQ", "KBRD", "KABI", "KJNX"] {
            XCTAssertNotNil(ProcedureRoute.fieldPosition(apt), "\(apt) must resolve to a position")
        }
    }

    func testTheBoundAdmitsTheLongestLegitimateApproachLeg() {
        // Measured on the rebuilt cycle: the longest legitimate leg is 171.7 NM and p99.9 is 59.8.
        XCTAssertGreaterThan(ProcedureRoute.maxApproachLegNm, 171.7)
    }

    func testTheAirwayExpansionCannotConsumeTheRouteBudget() {
        // Enroute is appended BEFORE the arrival, approach and destination, so unbounded expansion
        // would truncate the safety-critical tail. Six long airways filed end to end is 631 points.
        XCTAssertLessThan(RouteResolver.maxAirwayExpansion, ProcedureRoute.maxLegs / 2,
                          "the tail must keep most of the budget")
    }

    // MARK: - no approach leg is misplaced any more

    func testNoApproachLegSitsImplausiblyFarFromItsField() throws {
        try XCTSkipUnless(CIFP.available, "cifp.sqlite not present")
        // The end state of the whole misplaced-fix investigation. Sampled across the airports that were
        // affected plus a spread of ordinary ones; every leg must now be within the bound of its own
        // field. The single largest distance in the cycle is 172 NM at PMDY (Midway Atoll), a genuinely
        // remote Pacific approach — which is why the bound is 250 and not 150.
        var worst = 0.0, worstAt = ""
        for apt in ["KBRD", "KSJT", "KRUQ", "KABI", "KBRO", "KHQU", "KJNX", "KMFD", "KPKB", "KSLN",
                    "KBOS", "KDEN", "KSEA"] {
            guard let field = ProcedureRoute.fieldPosition(apt) else { continue }
            for p in CIFP.procedures(airport: apt) where p.kind == "IAP" {
                for leg in CIFP.legs(procedureID: p.id).prefix(80) {
                    guard let c = leg.coord else { continue }
                    let d = Geo.nmBetween(field, c)
                    if d > worst { worst = d; worstAt = "\(apt) \(p.ident) \(leg.fix)" }
                    XCTAssertTrue(ProcedureRoute.isPlausibleApproachLeg(c, field: field),
                                  "\(apt) \(p.ident) fix \(leg.fix) is \(Int(d)) NM from its field")
                }
            }
        }
        XCTAssertLessThan(worst, 100.0, "worst sampled leg was \(worstAt) at \(Int(worst)) NM")
    }

    func testBrainerdsTerminalNDBResolvesToBrainerd() throws {
        try XCTSkipUnless(CIFP.available, "cifp.sqlite not present")
        // Three airports publish a terminal NDB called "BR" and TWO of them are in region K3, so the
        // region alone does not disambiguate — it picked Burlington's, 369 NM away. The leg declares
        // the fix is TERMINAL (section P), which makes the airport the more specific key.
        let field = try XCTUnwrap(ProcedureRoute.fieldPosition("KBRD"))
        var found = false
        for p in CIFP.procedures(airport: "KBRD") where p.kind == "IAP" {
            for leg in CIFP.legs(procedureID: p.id) where leg.fix == "BR" {
                let c = try XCTUnwrap(leg.coord)
                found = true
                XCTAssertLessThan(Geo.nmBetween(field, c), 15.0,
                                  "KBRD's own NDB must be at Brainerd, not Burlington")
            }
        }
        XCTAssertTrue(found, "KBRD publishes approaches using the BR NDB")
    }

    // MARK: - a shared plate must not answer for the wrong approach

    func testALocalizerApproachDoesNotReadTheILSLine() {
        // THE bug silent extraction would have activated. "ILS OR LOC RWY 06" is ONE plate carrying an
        // S-ILS decision altitude AND an S-LOC minimum descent altitude, and matchPlate correctly pairs
        // the LOC-only coded procedure with it. Measured: 1,259 LOC-only approaches match a plate and
        // 1,101 (87.5%) would have reported a decision altitude on an approach with no glideslope.
        XCTAssertFalse(AppModel.minimaKindApplies(.ils, toApproachNamed: "LOC RWY 06"))
        XCTAssertTrue(AppModel.minimaKindApplies(.localizer, toApproachNamed: "LOC RWY 06"))
        XCTAssertTrue(AppModel.minimaKindApplies(.ils, toApproachNamed: "ILS OR LOC RWY 06"))
    }

    func testEachApproachFamilyReadsItsOwnLine() {
        XCTAssertTrue(AppModel.minimaKindApplies(.lpv, toApproachNamed: "RNAV (GPS) RWY 17"))
        XCTAssertFalse(AppModel.minimaKindApplies(.lpv, toApproachNamed: "VOR RWY 17"))
        XCTAssertTrue(AppModel.minimaKindApplies(.vor, toApproachNamed: "VOR RWY 17"))
        XCTAssertTrue(AppModel.minimaKindApplies(.rnpAR, toApproachNamed: "RNAV (RNP) Z RWY 27"))
        XCTAssertTrue(AppModel.minimaKindApplies(.ndb, toApproachNamed: "NDB RWY 03"))
        XCTAssertFalse(AppModel.minimaKindApplies(.ils, toApproachNamed: "NDB RWY 03"))
    }

    func testCirclingAndSidestepAreNeverTheStraightInAnswer() {
        for name in ["ILS OR LOC RWY 06", "RNAV (GPS) RWY 17", "VOR-A"] {
            XCTAssertFalse(AppModel.minimaKindApplies(.circling, toApproachNamed: name))
            XCTAssertFalse(AppModel.minimaKindApplies(.sidestep, toApproachNamed: name))
            XCTAssertFalse(AppModel.minimaKindApplies(.other, toApproachNamed: name))
        }
    }

    func testAnUnrecognisedNameMatchesNothingAndFallsBack() {
        // No row applies → the caller returns nil → the conservative title test stands. Never a guess.
        for k in [PlateMinima.Kind.ils, .lpv, .localizer, .vor, .ndb, .rnpAR] {
            XCTAssertFalse(AppModel.minimaKindApplies(k, toApproachNamed: "SOMETHING UNRECOGNISED"))
        }
    }
}
