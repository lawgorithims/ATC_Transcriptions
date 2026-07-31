import XCTest
@testable import ATCTranscribe

/// ARINC's VERTICAL-PATH altitude qualifiers — `G`, `H`, `I`, `J`, `V`.
///
/// These pair an ordinary procedural crossing altitude in the FIRST field with a computed glideslope /
/// glidepath / intercept altitude in the SECOND. They used to fall through to "unmodelled", which threw
/// away the first altitude as well — so on the shipped cycle **5,856 legs across 4,576 approaches drew
/// no altitude on the map and were skipped by `LegConstraintCheck` entirely, including the FAF itself on
/// 1,187 approaches**. PABE's ILS 19R-Y publishes its final approach fix KAYSE at 1,800 ft and the app
/// rendered it blank.
///
/// The at vs at-or-above split is ARINC 424 and is corroborated by the shipped data, not taken on trust:
/// see `testTheDataItselfSupportsTheDirectionOfEachQualifier`.
final class LegConstraintVerticalPathTests: XCTestCase {

    private func c(_ desc: String, _ alt: String, _ alt2: String = "") -> LegConstraint {
        LegConstraint(altDesc: desc, alt: alt, alt2: alt2,
                      speedLimitKt: nil, verticalAngleDeg: nil, rnpNm: nil)
    }

    // MARK: - the crossing restriction survives

    func testGlideslopeQualifierAtTheFAFNoLongerLosesItsAltitude() {
        // PABE I19R-Y, FAF KAYSE, coded H / 01800 / 01800.
        let k = c("H", "01800", "01800")
        XCTAssertFalse(k.altUnmodelled, "the FAF crossing altitude must not be discarded")
        XCTAssertEqual(k.alt, .atOrAbove(1_800))
        XCTAssertEqual(SmartRouteLabel.altText(k), "1800A", "the FAF must draw its altitude on the map")
    }

    func testEveryVerticalPathQualifierKeepsTheFirstAltitude() {
        for desc in ["G", "H", "I", "J", "V"] {
            let k = c(desc, "02500", "02400")
            XCTAssertFalse(k.altUnmodelled, "\(desc) still discards its crossing altitude")
            XCTAssertNotNil(k.alt, "\(desc) produced no rule")
            XCTAssertNotNil(SmartRouteLabel.altText(k), "\(desc) draws no label")
        }
    }

    func testAtVersusAtOrAboveFollowsTheQualifier() {
        // G and I state an AT altitude; H, J and V state a MINIMUM. Reading a minimum as a mandatory
        // altitude would over-constrain, and reading an 'at' as a minimum would under-state it.
        XCTAssertEqual(c("G", "02500", "02400").alt, .at(2_500))
        XCTAssertEqual(c("I", "02500", "02400").alt, .at(2_500))
        XCTAssertEqual(c("H", "02500", "02400").alt, .atOrAbove(2_500))
        XCTAssertEqual(c("J", "02500", "02400").alt, .atOrAbove(2_500))
        XCTAssertEqual(c("V", "00960", "00973").alt, .atOrAbove(960))
    }

    func testTheStepDownMinimumIsWhatIsLabelled_NotThePath() {
        // PABE R01R, step-down DISVE: minimum 960, VNAV path 973. The label must be the MINIMUM — the
        // path is where the aeroplane will be, not where it is required to be.
        let k = c("V", "00960", "00973")
        XCTAssertEqual(SmartRouteLabel.altText(k), "960A")
        XCTAssertEqual(k.glidepathAltFt, 973, "the coded path altitude should still be carried")
    }

    func testThePathAltitudeIsCarriedButIsNotAConstraint() {
        let k = c("H", "01800", "01750")
        XCTAssertEqual(k.glidepathAltFt, 1_750)
        XCTAssertEqual(k.alt, .atOrAbove(1_800), "the requirement is field one, never field two")
        XCTAssertFalse(SmartRouteLabel.altText(k)!.contains("1750"),
                       "the path altitude must never be labelled as a restriction")
    }

    func testOrdinaryQualifiersCarryNoPathAltitude() {
        for desc in ["", "+", "-", "B"] {
            XCTAssertNil(c(desc, "05000", "04000").glidepathAltFt, "\(desc) invented a path altitude")
        }
    }

    func testAnUnknownQualifierIsStillRefused() {
        // `X` appears once in the shipped cycle and its meaning is not established, so it must keep
        // failing closed. Silence is correct; a guess is not.
        let k = c("X", "02500", "02400")
        XCTAssertTrue(k.altUnmodelled)
        XCTAssertNil(k.alt)
        XCTAssertNil(SmartRouteLabel.altText(k))
        XCTAssertNil(k.glidepathAltFt)
    }

    func testAVerticalPathQualifierWithNoAltitudeStaysEmptyRatherThanUnmodelled() {
        let k = c("V", "", "00973")
        XCTAssertNil(k.alt, "no first altitude means no restriction to state")
        XCTAssertFalse(k.altUnmodelled, "the qualifier IS understood; it simply carries no altitude")
    }

    // MARK: - against the shipped cycle

    func testTheDataItselfSupportsTheDirectionOfEachQualifier() throws {
        try XCTSkipUnless(CIFP.available, "cifp.sqlite not present")
        // The evidence behind the at-or-above reading of `V`: on a step-down the coded path must CLEAR
        // the published minimum, so field two is at or above field one. If a future cycle inverted that
        // relationship, the reading here would be wrong and this test is how it gets caught.
        var vChecked = 0, vPathBelowMinimum = 0
        var hijChecked = 0, hijPathAboveCrossing = 0
        for (apt, ident) in [("PABE", "R01R"), ("PAQT", "R23"), ("PABE", "I19RY"), ("PABR", "I08")] {
            guard let proper = CIFP.approachProper(airport: apt, ident: ident) else { continue }
            for leg in CIFP.legs(procedureID: proper.id).prefix(64) {          // bounded (rule 2)
                let k = leg.constraint
                guard let path = k.glidepathAltFt, let rule = k.alt else { continue }
                switch rule {
                case .atOrAbove(let floor) where leg.altDesc.uppercased() == "V":
                    vChecked += 1
                    if path < floor { vPathBelowMinimum += 1 }
                case .atOrAbove(let floor):
                    hijChecked += 1
                    if path > floor { hijPathAboveCrossing += 1 }
                case .at(let exact):
                    hijChecked += 1
                    if path > exact { hijPathAboveCrossing += 1 }
                default: break
                }
            }
        }
        XCTAssertGreaterThan(vChecked + hijChecked, 0, "the sample found no vertical-path legs at all")
        XCTAssertEqual(vPathBelowMinimum, 0,
                       "a coded VNAV path fell BELOW its step-down minimum — the V reading is inverted")
        XCTAssertEqual(hijPathAboveCrossing, 0,
                       "a glideslope altitude sat above its crossing altitude — the H/I/J reading is inverted")
    }

    func testTheFAFOfAKnownApproachNowCarriesItsPublishedAltitude() throws {
        try XCTSkipUnless(CIFP.available, "cifp.sqlite not present")
        let proper = try XCTUnwrap(CIFP.approachProper(airport: "PABE", ident: "I19RY"),
                                   "PABE I19R-Y not in this cycle")
        let faf = CIFP.legs(procedureID: proper.id).first { $0.role == .finalApproachFix }
        let k = try XCTUnwrap(faf?.constraint, "no FAF on PABE I19R-Y")
        XCTAssertFalse(k.altUnmodelled)
        XCTAssertEqual(SmartRouteLabel.altText(k), "1800A", "KAYSE publishes 1,800 ft and must show it")
    }
}
