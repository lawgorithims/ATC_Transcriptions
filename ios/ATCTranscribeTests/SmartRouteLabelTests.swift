import XCTest
@testable import ATCTranscribe

/// Pins the crossing-restriction map labels for the decluttered night base (`ChartLayer.smartDark`).
///
/// These labels ASSERT A LIMIT to a pilot in flight, so the tests here care about two things above
/// prettiness: an unmodelled qualifier must produce NOTHING rather than a guess, and the
/// at-or-above / at-or-below sense must never invert.
final class SmartRouteLabelTests: XCTestCase {

    /// Build a constraint the way CIFP.swift does — through the real ARINC-field initializer, so these
    /// tests exercise the same parse the app runs rather than a hand-made value.
    private func constraint(altDesc: String = "", alt: String = "", alt2: String = "",
                            speed: Int? = nil) -> LegConstraint {
        LegConstraint(altDesc: altDesc, alt: alt, alt2: alt2,
                      speedLimitKt: speed, verticalAngleDeg: nil, rnpNm: nil)
    }

    // MARK: altitude

    func testCrossAtAltitude() {
        XCTAssertEqual(SmartRouteLabel.altText(constraint(altDesc: "", alt: "05000")), "5000")
    }

    func testAtOrAboveTakesASuffix() {
        XCTAssertEqual(SmartRouteLabel.altText(constraint(altDesc: "+", alt: "05000")), "5000A")
    }

    func testAtOrBelowTakesBSuffix() {
        XCTAssertEqual(SmartRouteLabel.altText(constraint(altDesc: "-", alt: "05000")), "5000B")
    }

    /// A window prints the ceiling first then the floor — the order a pilot reads a block altitude in,
    /// and the order the chart stacks them.
    func testWindowPrintsCeilingThenFloor() {
        XCTAssertEqual(SmartRouteLabel.altText(constraint(altDesc: "B", alt: "07000", alt2: "05000")),
                       "7000B 5000A")
    }

    /// The published values can arrive either way round; `LegConstraint` normalizes, and the label must
    /// follow it rather than echoing the source order.
    func testWindowNormalizesReversedInput() {
        XCTAssertEqual(SmartRouteLabel.altText(constraint(altDesc: "B", alt: "05000", alt2: "07000")),
                       "7000B 5000A")
    }

    func testFlightLevelsAboveTransition() {
        XCTAssertEqual(SmartRouteLabel.altText(constraint(altDesc: "", alt: "FL230")), "FL230")
        XCTAssertEqual(SmartRouteLabel.altText(constraint(altDesc: "+", alt: "18000")), "FL180A")
        // Just below the threshold stays in feet.
        XCTAssertEqual(SmartRouteLabel.altText(constraint(altDesc: "", alt: "17900")), "17900")
    }

    // MARK: the never-guess rule

    /// THE governing rule, inherited from LegConstraint: a qualifier this app does not model prints
    /// nothing. Drawing a limit the chart does not state is worse than drawing no limit at all.
    func testUnmodelledQualifierPrintsNothing() {
        for desc in ["V", "H", "J", "I", "G", "X"] {
            let c = constraint(altDesc: desc, alt: "05000")
            XCTAssertTrue(c.altUnmodelled, "\(desc) should be unmodelled")
            XCTAssertNil(SmartRouteLabel.altText(c), "unmodelled qualifier \(desc) must not label")
        }
    }

    /// "Between" without both values is not a usable window — and must not degrade into a single limit.
    func testIncompleteWindowPrintsNothing() {
        XCTAssertNil(SmartRouteLabel.altText(constraint(altDesc: "B", alt: "05000")))
    }

    func testNoConstraintPrintsNothing() {
        XCTAssertNil(SmartRouteLabel.altText(nil))
        XCTAssertNil(SmartRouteLabel.altText(constraint()))
        XCTAssertNil(SmartRouteLabel.speedText(nil))
        XCTAssertNil(SmartRouteLabel.speedText(constraint()))
    }

    // MARK: speed

    func testSpeedLimit() {
        XCTAssertEqual(SmartRouteLabel.speedText(constraint(speed: 210)), "210K")
    }

    /// Bad source data is not a restriction to draw.
    func testNonsenseSpeedIsDropped() {
        XCTAssertNil(SmartRouteLabel.speedText(constraint(speed: 0)))
        XCTAssertNil(SmartRouteLabel.speedText(constraint(speed: -50)))
        XCTAssertNil(SmartRouteLabel.speedText(constraint(speed: 5000)))
    }

    // MARK: layout budget

    /// The map label layers assume a bounded string; the widest real label is a flight-level window.
    func testLongestLabelStaysWithinCap() {
        let widest = SmartRouteLabel.altText(constraint(altDesc: "B", alt: "FL230", alt2: "FL180"))
        XCTAssertEqual(widest, "FL230B FL180A")
        XCTAssertLessThanOrEqual(widest?.count ?? 0, SmartRouteLabel.maxLabelChars)
    }

    /// A leg can carry BOTH — which is exactly why the altitude and speed are drawn by two separate
    /// symbol layers (one textColor each) rather than one combined string.
    func testAltitudeAndSpeedCoexist() {
        let c = constraint(altDesc: "+", alt: "06500", speed: 210)
        XCTAssertEqual(SmartRouteLabel.altText(c), "6500A")
        XCTAssertEqual(SmartRouteLabel.speedText(c), "210K")
    }
}
