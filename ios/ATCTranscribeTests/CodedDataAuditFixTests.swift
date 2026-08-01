import XCTest
@testable import ATCTranscribe

/// Fixes from the coded-data audit: places where data that IS in the bundled databases went missing or
/// was misread on the way to the pilot.
final class CodedDataAuditFixTests: XCTestCase {

    private func k(_ desc: String, _ alt: String, _ alt2: String = "", speed: Int? = nil) -> LegConstraint {
        LegConstraint(altDesc: desc, alt: alt, alt2: alt2,
                      speedLimitKt: speed, verticalAngleDeg: nil, rnpNm: nil)
    }
    private func leg(_ ident: String, _ c: LegConstraint?, role: LegRole = .none) -> ResolvedLeg {
        ResolvedLeg(ident: ident, kind: .waypoint, coord: Coord(lat: 35, lon: -106),
                    constraint: c, role: role)
    }

    // MARK: - below-sea-level airports

    func testNegativeAltitudesAreRealAndAccepted() {
        // Six legs in the shipped cycle sit below sea level, every one at a field that is itself below
        // sea level. Rejecting them blanked the missed-approach point on four approaches and killed the
        // whole vertical profile on the two where the rejected leg anchors it.
        XCTAssertEqual(LegConstraint.feet("-00086"), -86, "KTRM RWY 30 threshold")
        XCTAssertEqual(LegConstraint.feet("-00145"), -145, "KCLR RWY 08 threshold")
        XCTAssertEqual(LegConstraint.feet("-00054"), -54)
    }

    func testAnImplausibleNegativeIsStillRejected() {
        // The bound is plausibility, not sign: the lowest land on earth is about -1,400 ft.
        XCTAssertNil(LegConstraint.feet("-99999"))
        XCTAssertNil(LegConstraint.feet("-5000"))
    }

    func testOrdinaryAltitudesAreUnaffected() {
        XCTAssertEqual(LegConstraint.feet("02500"), 2_500)
        XCTAssertEqual(LegConstraint.feet("FL230"), 23_000)
        XCTAssertNil(LegConstraint.feet(""))
        XCTAssertNil(LegConstraint.feet("ABOVE"))
    }

    // MARK: - a fix crossed twice keeps both published rules

    func testCollapsingARevisitedFixKeepsWhatBothCrossingsPermit() {
        // KAEG RNAV RWY 22: the transition crosses EYIPE at 13,000, the hold in lieu at 8,600. The app
        // cannot tell which crossing the aircraft is on, so it must not warn against only one of them.
        var out: [ResolvedLeg] = []
        ProcedureRoute.appendDeduped(leg("EYIPE", k("+", "13000")), to: &out)
        ProcedureRoute.appendDeduped(leg("EYIPE", k("+", "08600")), to: &out)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.constraint?.alt, .atOrAbove(8_600),
                       "the union must permit the lower published altitude")
    }

    func testTheUnionNeverInventsATighterLimitThanEitherSide() {
        let a = k("+", "13000"), b = k("-", "08600")
        let u = a.unioned(with: b)
        // at-or-above 13,000 unioned with at-or-below 8,600: neither end is closed on both sides, so
        // there is nothing both crossings jointly forbid.
        XCTAssertNil(u.alt, "a union with no common bound must state no rule")
        XCTAssertFalse(u.altUnmodelled, "both sides were understood — this is 'no limit', not 'unknown'")
    }

    func testAWindowUnionWidensToCoverBoth() {
        let u = k("B", "10000", "08000").unioned(with: k("B", "07000", "05000"))
        XCTAssertEqual(u.alt, .between(high: 10_000, low: 5_000))
    }

    func testTwoIdenticalRulesAreUnchangedByTheUnion() {
        let u = k("+", "05000").unioned(with: k("+", "05000"))
        XCTAssertEqual(u.alt, .atOrAbove(5_000))
    }

    func testAUnionWithAnUnreadableQualifierStatesNothing() {
        // Never-guess still governs: a union with an unknown is not knowable.
        let u = k("+", "05000").unioned(with: k("X", "09000"))
        XCTAssertNil(u.alt)
        XCTAssertTrue(u.altUnmodelled)
    }

    func testSpeedLimitsUnionToTheMorePermissive() {
        // A speed limit is a ceiling, so what both crossings permit is the higher of the two.
        let u = k("", "05000", speed: 210).unioned(with: k("", "05000", speed: 250))
        XCTAssertEqual(u.speedLimitKt, 250)
    }

    func testRolePromotionStillSurvivesTheCollapse() {
        // The previously-fixed behaviour must not regress while the constraint merge is added.
        var out: [ResolvedLeg] = []
        ProcedureRoute.appendDeduped(leg("CRLTN", nil, role: .none), to: &out)
        ProcedureRoute.appendDeduped(leg("CRLTN", k("+", "01800"), role: .finalApproachFix), to: &out)
        XCTAssertEqual(out.first?.role, .finalApproachFix)
        XCTAssertEqual(out.first?.constraint?.alt, .atOrAbove(1_800),
                       "a first leg with NO constraint must adopt the incoming one")
    }

    // MARK: - vertical guidance is not inferred from the title

    func testAnRNAVTitleNoLongerClaimsADecisionAltitude() {
        // The name is identical whether the chart publishes an LPV line or an LNAV MDA and nothing
        // else. Cross-checked against OCR'd plates, 1,335 straight-in RNAV approaches publish an MDA
        // and no vertically-guided line, and the app drew a glidepath to a decision altitude on each.
        for name in ["RNAV (GPS) RWY 17", "RNAV (RNP) Z RWY 27", "GPS RWY 04"] {
            XCTAssertFalse(ApproachProfile.impliesVerticalGuidance(name, codedRunway: "17"),
                           "\(name) must not imply a decision altitude from its title alone")
        }
    }

    func testATrueGlideslopeTitleStillDoes() {
        // ILS/GLS/JPALS name the guidance in the title unambiguously; those keep it.
        XCTAssertTrue(ApproachProfile.impliesVerticalGuidance("ILS OR LOC RWY 04R", codedRunway: "04R"))
        XCTAssertTrue(ApproachProfile.impliesVerticalGuidance("GLS RWY 16R", codedRunway: "16R"))
    }

    func testLocaliserOnlyAndCirclingAreStillRefused() {
        XCTAssertFalse(ApproachProfile.impliesVerticalGuidance("LOC RWY 26", codedRunway: "26"))
        XCTAssertFalse(ApproachProfile.impliesVerticalGuidance("RNAV (GPS)-A", codedRunway: ""))
    }
}
