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

    // MARK: what the REAL booklets look like (all 27 in the 2607 cycle were measured)

    /// The booklet is two columns and PDFKit reads them y-then-x, so the raw line order interleaves
    /// them. Left-in-full then right-in-full is the only order in which a block is contiguous.
    func testTheTwoColumnsAreReadOneAtATime() {
        let lines = [
            AlternateMinimaReader.Placed(x: 21, width: 95, y: 271, text: "AUBURN/LEWISTON, ME"),
            AlternateMinimaReader.Placed(x: 200, width: 71, y: 271, text: "BAR HARBOR, ME"),
            AlternateMinimaReader.Placed(x: 26, width: 156, y: 286, text: "MUNI (LEW)....ILS or LOC Rwy 4"),
            AlternateMinimaReader.Placed(x: 208, width: 153, y: 286, text: "BAR HARBOR (BHB)....ILS Rwy 22"),
        ]
        let out = AlternateMinimaReader.ordered(lines, pageWidth: 387)
        XCTAssertEqual(out, ["AUBURN/LEWISTON, ME", "MUNI (LEW)....ILS or LOC Rwy 4",
                             "BAR HARBOR, ME", "BAR HARBOR (BHB)....ILS Rwy 22"],
                       "interleaved columns end every block at its own first line")
    }

    /// A full-width line spans both columns and belongs where it sits, ahead of the airport blocks.
    func testAFullWidthPreambleLineStaysAhead() {
        let lines = [
            AlternateMinimaReader.Placed(x: 200, width: 71, y: 271, text: "RIGHT COLUMN"),
            AlternateMinimaReader.Placed(x: 25, width: 335, y: 60, text: "Pilots must review the notes."),
        ]
        XCTAssertEqual(AlternateMinimaReader.ordered(lines, pageWidth: 387).first,
                       "Pilots must review the notes.")
    }

    /// ⚠️ THE REGRESSION THAT MOTIVATED THE ORDERING FIX. A city block holds several airports, and the
    /// next one's first line is BOTH a boundary and a valid entry.
    func testACityBlockWithTwoAirportsDoesNotBleed() throws {
        let text = """
        DETROIT, MI
        COLEMAN A YOUNG
        MUNI (DET)......ILS or LOC Rwy 151
        RNAV (GPS) Rwy 332
        1LOC Cat D 900-2.
        WILLOW RUN (YIP).......ILS or LOC Rwy 51
        RNAV (GPS) Rwy 92
        """
        let m = try XCTUnwrap(AlternateMinimaParser.parse(text: text, ident: "DET",
                                                          publishedRunways: ["15", "33"]))
        XCTAssertEqual(m.entries.count, 2, "Willow Run's approaches are not Coleman A Young's")
        XCTAssertEqual(m.entries.map(\.runway), ["15", "33"])
    }

    /// The boundary line usually names an approach type too, so a blanket "contains (GPS)" test never
    /// fired on it.
    func testABoundaryLineMayAlsoNameAnApproachType() {
        XCTAssertTrue(AlternateMinimaParser.isBlockBoundary("FLD (ANJ).....RNAV (GPS) Rwy 14",
                                                            ident: "CIU"))
        XCTAssertFalse(AlternateMinimaParser.isBlockBoundary("RNAV (GPS) Rwy 14", ident: "CIU"))
    }

    /// The block's OWN opening line carries its own parenthetical and must not end it.
    func testTheBlocksOwnIdentIsNotABoundary() {
        XCTAssertFalse(AlternateMinimaParser.isBlockBoundary("MUNI (DET)......ILS Rwy 15", ident: "DET"))
        XCTAssertFalse(AlternateMinimaParser.isBlockBoundary("MUNI (DET)......ILS Rwy 15", ident: "KDET"),
                       "the booklet prints the bare FAA code; the app may hold the ICAO one")
    }

    /// PDFKit keeps a superscript on its text's baseline, so the marker arrives glued to the front.
    func testAnInlineFootnoteMarkerIsRead() throws {
        let f = try XCTUnwrap(AlternateMinimaParser.inlineFootnote("1LOC Cat C 800-2, Cat D 900-2."))
        XCTAssertEqual(f.id, 1)
        XCTAssertEqual(f.text, "LOC Cat C 800-2, Cat D 900-2.")
    }

    /// ⚠️ An identifier begins digit-then-letter too. Only footnote PROSE is accepted.
    func testAnIdentifierIsNotMistakenForAFootnote() {
        XCTAssertNil(AlternateMinimaParser.inlineFootnote("9G3 SOMEWHERE MUNI"))
        XCTAssertNil(AlternateMinimaParser.inlineFootnote("1000 PALMS, CA"))
    }

    /// North Adams publishes ONLY circling approaches, each with a marker glued to the letter. Failing
    /// to read them made the airport look unlisted, which means the opposite of what the booklet says.
    func testACirclingOnlyAirportWithGluedMarkersParses() throws {
        let text = """
        NORTH ADAMS, MA
        HARRIMAN-AND-
        WEST (AQW)..........RNAV (GPS)-A1
        RNAV (GPS)-B2
        1Cat A, B 2100-2, Cat C 2200-3.
        """
        let m = try XCTUnwrap(AlternateMinimaParser.parse(text: text, ident: "AQW",
                                                          publishedRunways: ["11", "29"]))
        XCTAssertEqual(m.entries.count, 2)
        XCTAssertEqual(m.entries[0].name, "RNAV (GPS)-A")
        XCTAssertEqual(m.entries[0].footnoteIDs, [1])
        XCTAssertTrue(m.entries.allSatisfy { $0.runway.isEmpty }, "a circling approach serves no runway")
    }

    /// Youngstown publishes only RADAR-1, which names a number rather than a runway or a letter.
    func testARadarOnlyAirportParses() throws {
        let text = """
        YOUNGSTOWN/WARREN, OH
        RGNL (YNG)............RADAR-1
        NA when local weather not available.
        """
        let m = try XCTUnwrap(AlternateMinimaParser.parse(text: text, ident: "YNG",
                                                          publishedRunways: ["14", "32"]))
        XCTAssertEqual(m.entries.count, 1)
        XCTAssertEqual(m.entries[0].name, "RADAR-1")
    }

    /// ⚠️ The preamble names "RNAV (RNP)" and Owosso's identifier IS RNP, so the first match was prose.
    func testThePreambleDoesNotStealAnIdentifier() throws {
        let text = """
        Non-Precision approach operations include: NDB, VOR, LOC, TACAN, LDA, SDF, ASR, RNAV
        (GPS) and RNAV (RNP).
        OWOSSO, MI
        OWOSSO COMMUNITY (RNP).......RNAV (GPS) Rwy 11
        """
        let m = try XCTUnwrap(AlternateMinimaParser.parse(text: text, ident: "RNP",
                                                          publishedRunways: ["11", "29"]))
        XCTAssertEqual(m.entries.count, 1)
        XCTAssertEqual(m.entries[0].runway, "11")
    }
}
