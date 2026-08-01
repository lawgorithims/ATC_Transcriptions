import XCTest
@testable import ATCTranscribe

/// ITEM 28 — IFR alternate minimums.
///
/// A different chart and a different question from the approach minima: these say whether the field may
/// be FILED as an alternate hours earlier, not how low you may descend once there. The booklets are
/// shared — 27 of them cover 2,052 airports, median 71 each — so the parse is always "find this airport
/// inside a large document".
final class AlternateMinimaTests: XCTestCase {

    /// The real KLEW block, exactly as the extractor emits it (superscripts on their own lines).
    private let lewText = """
    AUBURN/LEWISTON, ME

    AUBURN/LEWISTON
    MUNI (LEW).………..………….ILS or LOC Rwy 413
    RNAV (GPS) Rwy 42
    RNAV (GPS) Rwy 223
    1
    LOC Cat C 800-2½, Cat D 900-2¾.
    2
    Cat C 800-2¼, Cat D 900-2¾,
    3
    NA when local weather not available.
    """

    // MARK: the runway / footnote split

    func testTheFootnoteMarkersDoNotBecomePartOfTheRunway() {
        // ⚠️ THE CENTRAL AMBIGUITY. "413" is Rwy 4 with footnotes 1 and 3 at an airport with a runway 4,
        // and Rwy 41 with footnote 3 at one with a runway 41. The characters do not carry the boundary;
        // the airport's published runways do.
        let (rw, marks) = AlternateMinimaParser.split("413", publishedRunways: ["4", "22"])
        XCTAssertEqual(rw, "4")
        XCTAssertEqual(marks, [1, 3])
    }

    func testTheLongestPublishedRunwayWins() {
        // At an airport with both 2 and 22, "223" must read as Rwy 22 footnote 3 — not Rwy 2, footnotes
        // 2 and 3.
        let (rw, marks) = AlternateMinimaParser.split("223", publishedRunways: ["2", "22"])
        XCTAssertEqual(rw, "22")
        XCTAssertEqual(marks, [3])
    }

    func testASidedRunwayIsMatchedWhole() {
        let (rw, marks) = AlternateMinimaParser.split("04R2", publishedRunways: ["04R", "04L"])
        XCTAssertEqual(rw, "04R")
        XCTAssertEqual(marks, [2])
    }

    func testARunwayWithNoFootnotesYieldsNoMarkers() {
        let (rw, marks) = AlternateMinimaParser.split("17", publishedRunways: ["17", "35"])
        XCTAssertEqual(rw, "17")
        XCTAssertTrue(marks.isEmpty)
    }

    func testAnUnpublishedRunwayStillParses() {
        // A runway withdrawn since the booklet was printed still has a published entry.
        let (rw, _) = AlternateMinimaParser.split("31", publishedRunways: ["9", "27"])
        XCTAssertEqual(rw, "31")
    }

    // MARK: the block

    func testTheRealLewistonBlockParses() throws {
        let m = try XCTUnwrap(AlternateMinimaParser.parse(text: lewText, ident: "LEW",
                                                          publishedRunways: ["4", "22"]))
        XCTAssertEqual(m.entries.count, 3)
        XCTAssertEqual(m.entries[0].runway, "4")
        XCTAssertEqual(m.entries[0].footnoteIDs, [1, 3])
        XCTAssertEqual(m.entries[2].runway, "22")
        XCTAssertEqual(m.footnotes[3], "NA when local weather not available.")
    }

    func testAnAirportNotListedMeansStandard() {
        // Absence is an ANSWER here — the booklet prints only exceptions, so an unlisted field uses the
        // standard 600-2 / 800-2. It must not read as a parse failure.
        XCTAssertNil(AlternateMinimaParser.parse(text: lewText, ident: "BOS", publishedRunways: ["4L"]))
    }

    func testTheBookletIsKeyedByBareFAACode() {
        // Entries read "(LEW)", never "(KLEW)" — the same namespace split as everywhere else.
        XCTAssertNotNil(AlternateMinimaParser.parse(text: lewText, ident: "KLEW",
                                                    publishedRunways: ["4", "22"]))
    }

    // MARK: precision, and what it means HERE

    func testRNAVIsNonPrecisionForAlternatePlanning() {
        // ⚠️ The booklet's own header defines this: precision is ILS, PAR and GLS only; RNAV (GPS) and
        // RNAV (RNP) are NON-precision. That is the opposite of how the same words read on the approach
        // chart, and getting it backwards understates the required ceiling by 200 ft.
        let rnav = AlternateMinima.Entry(name: "RNAV (GPS) Rwy 4", runway: "4", footnoteIDs: [])
        XCTAssertFalse(rnav.isPrecision)
        XCTAssertEqual(rnav.standardCeilingFt, 800)
    }

    func testILSIsPrecisionButLocaliserAloneIsNot() {
        XCTAssertTrue(AlternateMinima.Entry(name: "ILS or LOC Rwy 4", runway: "4", footnoteIDs: []).isPrecision)
        let loc = AlternateMinima.Entry(name: "LOC Rwy 4", runway: "4", footnoteIDs: [])
        XCTAssertFalse(loc.isPrecision)
        XCTAssertEqual(loc.standardCeilingFt, 800)
    }

    // MARK: the conditions and the two toggles

    func testTheWeatherConditionIsRecognised() {
        XCTAssertEqual(AlternateMinima.Condition.classify("NA when local weather not available."),
                       .naWithoutLocalWeather)
    }

    func testTheTowerConditionIsRecognised() {
        XCTAssertEqual(AlternateMinima.Condition.classify("NA when control tower closed."),
                       .naWhenTowerClosed)
    }

    func testCategoryMinimaAreRecognised() {
        guard case .categoryMinima = AlternateMinima.Condition.classify("Cat C 800-2¼, Cat D 900-2¾.")
        else { return XCTFail("a category line was not recognised") }
    }

    func testAnUnclassifiableFootnoteIsKeptVerbatim() {
        // ⚠️ NOT a failure. The footnotes carry a long tail of one-off restrictions, and a condition the
        // app cannot classify is still one the pilot must read — dropping it would be the worst outcome.
        guard case .other(let t) = AlternateMinima.Condition.classify("Procedure NA for arrivals at DUMZU.")
        else { return XCTFail("an unclassified footnote was dropped") }
        XCTAssertTrue(t.contains("DUMZU"))
    }

    func testUsabilityFailsTowardUnusableAndSaysWhy() throws {
        let m = try XCTUnwrap(AlternateMinimaParser.parse(text: lewText, ident: "LEW",
                                                          publishedRunways: ["4", "22"]))
        let ils = m.entries[0]                                    // carries footnote 3 (weather)
        XCTAssertEqual(m.usability(ils, localWeatherAvailable: false, towerOpen: true),
                       .notAuthorised("local weather not available"))
        XCTAssertTrue(m.usability(ils, localWeatherAvailable: true, towerOpen: true).isAuthorised)
    }

    func testTheTowerToggleIsPilotSetBecauseNoScheduleExists() throws {
        // apt.sqlite's `tower` column carries a facility TYPE ("ATCT"/"NON-ATCT") and no hours — nothing
        // in the bundle says when a tower is open, so the app must ask rather than assume.
        let text = """
        SOMEWHERE, ST

        SOMEWHERE MUNI (XYZ).……ILS or LOC Rwy 91
        1
        NA when control tower closed.
        """
        let m = try XCTUnwrap(AlternateMinimaParser.parse(text: text, ident: "XYZ",
                                                          publishedRunways: ["9", "27"]))
        XCTAssertEqual(m.usability(m.entries[0], localWeatherAvailable: true, towerOpen: false),
                       .notAuthorised("control tower closed"))
        XCTAssertTrue(m.usability(m.entries[0], localWeatherAvailable: true, towerOpen: true).isAuthorised)
    }
}
