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
}
