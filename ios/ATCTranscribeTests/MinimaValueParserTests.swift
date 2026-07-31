import XCTest
@testable import ATCTranscribe

/// The cell grammar. Every case here is a string a real plate produced through the sweep.
///
/// The bias under test is one-directional: a cell must parse EXACTLY or not at all. Several of these
/// assert a refusal, and those matter more than the successes — a refused row shows the pilot a gap and
/// sends them to the chart, while a mis-parsed one shows them a number.
final class MinimaValueParserTests: XCTestCase {

    // MARK: straight-in

    func testILSCellWithRVRAndParenthetical() {
        let v = MinimaValueParser.parse("218/18 200(200-12)")
        XCTAssertEqual(v?.altitudeFtMSL, 218)
        XCTAssertEqual(v?.visibility, .rvrFt(1_800))
        XCTAssertEqual(v?.heightAboveFt, 200)
        XCTAssertEqual(v?.ceilingFt, 200)
    }

    /// The sweep cannot always tell a typeset space from a wide character, so the same cell arrives with
    /// no spaces at all and with spaces inside a number. Both must give the same answer.
    func testSpacingDoesNotChangeTheAnswer() {
        let forms = ["440/24 422(500-12)", "440/24422(500-12)", "4 4 0/24 422 (500-12 )"]
        for f in forms {
            let v = MinimaValueParser.parse(f)
            XCTAssertEqual(v?.altitudeFtMSL, 440, "form: \(f)")
            XCTAssertEqual(v?.visibility, .rvrFt(2_400), "form: \(f)")
            XCTAssertEqual(v?.heightAboveFt, 422, "form: \(f)")
        }
    }

    /// `18200` after the solidus is RVR 1800 then a 200 ft height — never a one-mile visibility and an
    /// 8,200 ft height, which is arithmetically available and physically absurd.
    func testRunTogetherRVRAndHeightResolveToTheRVRReading() {
        let v = MinimaValueParser.parse("218/18200(200-12)")
        XCTAssertEqual(v?.visibility, .rvrFt(1_800))
        XCTAssertEqual(v?.heightAboveFt, 200)
    }

    func testStatuteMileVisibilityInParentheses() {
        XCTAssertEqual(MinimaValueParser.parse("514/50 496(500-1)")?.visibility, .rvrFt(5_000))
        XCTAssertEqual(MinimaValueParser.parse("514/50 496(500-1)")?.ceilingFt, 500)
    }

    // MARK: fractions

    func testFractionDigitsDecodeAsPublishedVisibilities() {
        XCTAssertEqual(MinimaValueParser.statuteSixteenths("12"), 8)     // ½
        XCTAssertEqual(MinimaValueParser.statuteSixteenths("34"), 12)    // ¾
        XCTAssertEqual(MinimaValueParser.statuteSixteenths("78"), 14)    // ⅞
        XCTAssertEqual(MinimaValueParser.statuteSixteenths("114"), 20)   // 1¼
        XCTAssertEqual(MinimaValueParser.statuteSixteenths("134"), 28)   // 1¾
        XCTAssertEqual(MinimaValueParser.statuteSixteenths("1"), 16)     // 1 SM
    }

    /// A digit pair the FAA does not publish is refused rather than rounded to something nearby.
    func testUnpublishedVisibilityIsRefused() {
        XCTAssertNil(MinimaValueParser.statuteSixteenths("17"))
        XCTAssertNil(MinimaValueParser.statuteSixteenths("99"))
        XCTAssertNil(MinimaValueParser.statuteSixteenths("1234"))
    }

    /// Some plates set the denominator left of the numerator, so the sweep returns `141` for 1¼.
    func testReversedFractionDigitsAreRecovered() {
        XCTAssertEqual(MinimaValueParser.statuteSixteenths("141"), 20)   // 1¼
        XCTAssertEqual(MinimaValueParser.parse("500/60 484(500-141)")?.ceilingFt, 500)
    }

    func testUnicodeFractionGlyphs() {
        XCTAssertEqual(MinimaValueParser.statuteSixteenths("½"), 8)
        XCTAssertEqual(MinimaValueParser.statuteSixteenths("1½"), 24)
        XCTAssertEqual(MinimaValueParser.statuteSixteenths("¾"), 12)
    }

    // MARK: parenthetical repair

    /// `(300-1½)` sweeps as `3001-2` because the raised numerator anchors left of the hyphen. Published
    /// ceilings are whole hundreds, so the stray digit can only belong to the visibility.
    func testCeilingGivesBackADigitThatCannotBeItsOwn() {
        let fixed = MinimaValueParser.repairParenthetical(ceiling: "3001", visibility: "2")
        XCTAssertEqual(fixed?.ceiling, 300)
        XCTAssertEqual(fixed?.visibility, "12")
        XCTAssertEqual(MinimaValueParser.parse("273/24 257(3001-2)")?.altitudeFtMSL, 273)
    }

    func testWholeHundredCeilingIsLeftAlone() {
        let same = MinimaValueParser.repairParenthetical(ceiling: "500", visibility: "34")
        XCTAssertEqual(same?.ceiling, 500)
        XCTAssertEqual(same?.visibility, "34")
    }

    // MARK: circling

    func testCirclingCellUsesStatuteMiles() {
        let v = MinimaValueParser.parse("640-134 623(700-134)")
        XCTAssertEqual(v?.altitudeFtMSL, 640)
        XCTAssertEqual(v?.visibility, .statuteSixteenths(28))            // 1¾
        XCTAssertEqual(v?.heightAboveFt, 623)
        XCTAssertEqual(v?.ceilingFt, 700)
    }

    /// `12500` can be read as ½ then a 500 ft height, or as 1 mile then a 2,500 ft height — both are
    /// arithmetically available. The plate settles it by repeating the visibility in the parentheses;
    /// with nothing to settle it the cell is refused rather than picked.
    func testAnAmbiguousCirclingSplitIsResolvedOnlyByTheRepeatedVisibility() {
        XCTAssertNil(MinimaValueParser.splitVisibilityAndHeight("12500", afterSolidus: false,
                                                                parenSixteenths: nil))
        let resolved = MinimaValueParser.splitVisibilityAndHeight("12500", afterSolidus: false,
                                                                  parenSixteenths: 8)
        XCTAssertEqual(resolved?.0, .statuteSixteenths(8))
        XCTAssertEqual(resolved?.1, 500)
    }

    /// An unambiguous run needs no help: only one split of `134623` is a published visibility followed
    /// by a plausible height.
    func testAnUnambiguousCirclingSplitNeedsNoParenthetical() {
        let v = MinimaValueParser.splitVisibilityAndHeight("134623", afterSolidus: false, parenSixteenths: nil)
        XCTAssertEqual(v?.0, .statuteSixteenths(28))
        XCTAssertEqual(v?.1, 623)
    }

    // MARK: CAT II

    /// `RA 116/12 100 DA 116` — the leading figure is a RADIO height and the decision altitude is last.
    /// Reading the first number as the DA is right only at sea level.
    func testCatIITakesTheDecisionAltitudeNotTheRadioHeight() {
        let v = MinimaValueParser.parse("CAT II RA 108/12 100 DA 5427")
        XCTAssertEqual(v?.altitudeFtMSL, 5_427)
        XCTAssertEqual(v?.visibility, .rvrFt(1_200))
        XCTAssertEqual(v?.heightAboveFt, 100)
    }

    /// `RA` is printed hard against the row label and is often swept into it.
    func testCatIIWithoutItsRAPrefix() {
        XCTAssertEqual(MinimaValueParser.parse("179/14 150 DA 5504")?.altitudeFtMSL, 5_504)
    }

    // MARK: refusals

    func testNotAuthorised() {
        XCTAssertEqual(MinimaValueParser.parse("NA")?.isNA, true)
        XCTAssertNil(MinimaValueParser.parse("NA")?.altitudeFtMSL)
    }

    func testTextFromTheSurroundingPanelsIsRefused() {
        for junk in ["Min:Sec", "MIRLRwy15L-33R", "HIRL all Rwys", "Knots", ""] {
            XCTAssertNil(MinimaValueParser.parse(junk), "should refuse: \(junk)")
        }
    }

    func testImplausibleFiguresAreRefused() {
        XCTAssertNil(MinimaValueParser.parse("99999/24 100(200-12)"))     // altitude out of range
        XCTAssertNil(MinimaValueParser.parse("440/99 422(500-12)"))       // no such RVR
    }

    /// An eighth of a mile is not a published landing minimum, so `18200` in a statute-mile slot has no
    /// reading at all — the alternative, one mile over an 8,200 ft height, is bounded out.
    func testEighthOfAMileIsNotAPublishedVisibility() {
        XCTAssertNil(MinimaValueParser.statuteSixteenths("18"))
        XCTAssertNil(MinimaValueParser.splitVisibilityAndHeight("18200", afterSolidus: false,
                                                                parenSixteenths: nil))
        XCTAssertEqual(MinimaValueParser.statuteSixteenths("118"), 18, "mixed eighths ARE published")
    }
}
