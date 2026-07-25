import XCTest
@testable import ATCTranscribe

/// Parsing the FAA's published crossing restrictions, and — the part that matters more — deciding when
/// the app has no business drawing a conclusion from them.
final class LegConstraintTests: XCTestCase {

    private func c(_ desc: String, _ alt: String, _ alt2: String = "",
                   speed: Int? = nil) -> LegConstraint {
        LegConstraint(altDesc: desc, alt: alt, alt2: alt2, speedLimitKt: speed,
                      verticalAngleDeg: nil, rnpNm: nil)
    }

    // MARK: the four modelled qualifiers

    func testTheModelledAltitudeQualifiers() {
        XCTAssertEqual(c("", "02000").alt, .at(2000))
        XCTAssertEqual(c("+", "02000").alt, .atOrAbove(2000))
        XCTAssertEqual(c("-", "02000").alt, .atOrBelow(2000))
        XCTAssertEqual(c("B", "05000", "03000").alt, .between(high: 5000, low: 3000))
    }

    func testBetweenOrdersItsPairWhicheverWayTheSourceWroteThem() {
        XCTAssertEqual(c("B", "03000", "05000").alt, .between(high: 5000, low: 3000))
    }

    func testFlightLevelsParse() {
        XCTAssertEqual(LegConstraint.feet("FL180"), 18000)
        XCTAssertEqual(LegConstraint.feet("02000"), 2000)
        XCTAssertNil(LegConstraint.feet(""))
        XCTAssertNil(LegConstraint.feet("   "))
        XCTAssertNil(LegConstraint.feet("ABOVE"))
    }

    /// The whole safety argument for this feature: ARINC's step-down and glidepath qualifiers mean
    /// different things depending on the leg's role and on a second altitude. We do not model them, so
    /// they must produce silence — not a guess at a restriction the chart does not state.
    func testUnmodelledQualifiersAreSilentRatherThanGuessed() {
        for desc in ["V", "H", "J", "I", "G", "X", "?"] {
            let k = c(desc, "02000", "03000")
            XCTAssertNil(k.alt, "\(desc) must not be turned into a rule")
            XCTAssertTrue(k.altUnmodelled, "\(desc) must be flagged unmodelled")
        }
    }

    func testBetweenWithOnlyOneAltitudeIsUnusable() {
        let k = c("B", "05000")
        XCTAssertNil(k.alt)
        XCTAssertTrue(k.altUnmodelled)
    }

    func testNoPublishedAltitudeIsNotAnUnmodelledOne() {
        let k = c("", "")
        XCTAssertNil(k.alt)
        XCTAssertFalse(k.altUnmodelled, "absent is absent — that is different from 'do not conclude'")
    }

    // MARK: deviation

    func testDeviationRespectsEachRule() {
        XCTAssertNil(c("+", "02000").altitudeDeviation(2500), "above an at-or-above complies")
        XCTAssertEqual(c("+", "02000").altitudeDeviation(1500), -500)
        XCTAssertNil(c("-", "02000").altitudeDeviation(1500), "below an at-or-below complies")
        XCTAssertEqual(c("-", "02000").altitudeDeviation(2500), 500)
        XCTAssertNil(c("B", "05000", "03000").altitudeDeviation(4000))
        XCTAssertEqual(c("B", "05000", "03000").altitudeDeviation(5600), 600)
        XCTAssertEqual(c("B", "05000", "03000").altitudeDeviation(2400), -600)
    }

    func testAltTextReadsLikeTheChart() {
        XCTAssertEqual(c("+", "02000").altText, "at or above 2000 ft")
        XCTAssertEqual(c("B", "05000", "03000").altText, "between 3000 ft and 5000 ft")
        XCTAssertEqual(c("", "FL180").altText, "at FL180")
    }
}

/// When the app is entitled to warn at all. Every nil here is a case where warning would be dishonest.
final class LegConstraintCheckTests: XCTestCase {

    private let atOrAbove2000 = LegConstraint(altDesc: "+", alt: "02000", alt2: "",
                                              speedLimitKt: 210, verticalAngleDeg: nil, rnpNm: nil)

    private func check(alt: Int? = 1000, xtk: Double? = 0.5, vacc: Double? = 10,
                       integrity: Bool = true,
                       constraint: LegConstraint? = nil) -> LegConstraintCheck.Warning? {
        LegConstraintCheck.evaluate(constraint: constraint ?? atOrAbove2000, fix: "SHUSH",
                                    altitudeFtMSL: alt, crossTrackNm: xtk,
                                    verticalAccuracyM: vacc, integrityOK: integrity)
    }

    func testWarnsWhenClearlyBelowAPublishedMinimum() {
        let w = check(alt: 1000)
        XCTAssertEqual(w?.sense, .below)
        XCTAssertEqual(w?.deviationFt, -1000)
        XCTAssertEqual(w?.limitText, "at or above 2000 ft")
        XCTAssertEqual(w?.headline, "1000 ft low at SHUSH")
    }

    /// GPS altitude is geometric and charted altitudes are barometric; they disagree by a few hundred
    /// feet with pressure and temperature. A warning inside that spread is a datum artefact, and one
    /// that cries wolf teaches the pilot to ignore the one that matters.
    func testStaysQuietInsideTheGpsBarometricSpread() {
        XCTAssertNil(check(alt: 2000 - LegConstraintCheck.toleranceFt + 50))
        XCTAssertNotNil(check(alt: 2000 - LegConstraintCheck.toleranceFt - 50))
    }

    func testStaysQuietWhenTheFixIsNotTrustworthy() {
        XCTAssertNil(check(integrity: false), "degraded or spoofed GPS")
        XCTAssertNil(check(vacc: 120), "vertical solution too loose to mean anything")
        XCTAssertNil(check(vacc: nil), "unknown accuracy is not good accuracy")
        XCTAssertNil(check(alt: nil), "no altitude at all")
    }

    func testStaysQuietWhenNotEstablishedOnTheLeg() {
        XCTAssertNil(check(xtk: 40), "40 NM off the leg is not flying it")
        XCTAssertNil(check(xtk: nil), "no cross-track means the nearest-waypoint fallback, at any range")
    }

    func testStaysQuietOnAnUnmodelledQualifier() {
        let stepDown = LegConstraint(altDesc: "V", alt: "02000", alt2: "03000",
                                     speedLimitKt: nil, verticalAngleDeg: nil, rnpNm: nil)
        XCTAssertNil(check(alt: 100, constraint: stepDown))
    }

    func testStaysQuietWhenNothingIsPublished() {
        let none = LegConstraint(altDesc: "", alt: "", alt2: "",
                                 speedLimitKt: 210, verticalAngleDeg: nil, rnpNm: nil)
        XCTAssertNil(check(alt: 100, constraint: none))
    }

    /// Speed is carried for display but never judged: ground speed is not indicated airspeed, and no
    /// margin makes that comparison honest.
    func testSpeedIsNeverWarnedOn() {
        let fast = LegConstraint(altDesc: "", alt: "", alt2: "", speedLimitKt: 210,
                                 verticalAngleDeg: nil, rnpNm: nil)
        XCTAssertEqual(fast.speedLimitKt, 210)
        XCTAssertNil(check(alt: 100, constraint: fast), "a speed limit alone never produces a warning")
    }
}
