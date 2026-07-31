import XCTest
@testable import ATCTranscribe

/// The table logic, on geometry copied from the real Boston plates.
///
/// The fixtures below use the actual column centres and cell extents measured from `ILS or LOC RWY 4R`
/// and `RNAV (GPS) RWY 4R` at KBOS, so the column-assignment rules are exercised against the layout they
/// were written for rather than an idealised one.
final class PlateMinimaParserTests: XCTestCase {

    // MARK: fixtures

    private func word(_ text: String, _ x0: Double, _ x1: Double, _ y: Double, pitch: Double = 3.5) -> PlateWord {
        PlateWord(text: text, x0: x0, x1: x1, yTop: y - 2.5, yBottom: y + 2.5, pitch: pitch)
    }

    /// `CATEGORY  A  B  C  D` at the real Boston column centres.
    private var headerRow: [PlateWord] {
        [word("CATEGORY", 21.7, 52.0, 497),
         word("A", 83.5, 87.5, 497), word("B", 134.0, 138.0, 497),
         word("C", 183.0, 187.0, 497), word("D", 232.5, 236.5, 497)]
    }

    private func parse(_ rows: [[PlateWord]], prose: String = "") -> PlateMinimaParser.Result {
        PlateMinimaParser.parse(words: headerRow + rows.flatMap { $0 }, notesText: prose,
                                airport: "KBOS", approachName: "ILS or LOC RWY 4R", cycle: "2607")
    }

    // MARK: column assignment

    /// A single cell centred across the table applies to EVERY category. This is the commonest layout on
    /// a plate and the one case where horizontal overlap gives the wrong answer: the printed cell only
    /// physically covers the middle columns, so overlap alone would leave A and D with no minimum.
    func testCentredSingleCellAppliesToEveryCategory() {
        let r = parse([[word("S-ILS", 26.5, 45.0, 507), word("4R", 47.0, 54.0, 507),
                        word("218/18", 126.0, 152.0, 507), word("200(200-12)", 159.5, 196.5, 507)]])
        let row = r.minima?.rows.first
        XCTAssertEqual(row?.kind, .ils)
        XCTAssertEqual(row?.categories, [.a, .b, .c, .d])
        for c in [PlateMinima.Category.a, .b, .c, .d] {
            XCTAssertEqual(row?.values[c]?.altitudeFtMSL, 218, "category \(c.rawValue)")
        }
    }

    /// Two cells split the table: A/B take the first, C/D the second.
    func testTwoCellsSplitTheCategories() {
        let r = parse([[word("S-LOC", 26.5, 45.0, 518), word("4R", 47.0, 54.0, 518),
                        word("440/24", 76.0, 102.0, 518), word("422(500-12)", 110.0, 147.5, 518),
                        word("440/40", 175.0, 201.0, 518), word("422(500-34)", 209.0, 246.5, 518)]])
        let row = r.minima?.rows.first
        XCTAssertEqual(row?.values[.a]?.visibility, .rvrFt(2_400))
        XCTAssertEqual(row?.values[.b]?.visibility, .rvrFt(2_400))
        XCTAssertEqual(row?.values[.c]?.visibility, .rvrFt(4_000))
        XCTAssertEqual(row?.values[.d]?.visibility, .rvrFt(4_000))
    }

    /// A layout that leaves a category unclaimed is refused outright. Filling the gap from a neighbouring
    /// column would be a guess, and the guess would be a minimum altitude.
    func testARowWithAnUnclaimedCategoryIsRefused() {
        let r = parse([[word("S-LOC", 26.5, 45.0, 518), word("4R", 47.0, 54.0, 518),
                        word("440/24422(500-12)", 76.0, 100.0, 518),
                        word("560/40542(600-34)", 175.0, 199.0, 518)]])
        XCTAssertNil(r.minima)
        XCTAssertTrue(r.refusals.contains { $0.contains("did not line up") || $0.contains("no minima row") },
                      "expected a refusal, got \(r.refusals)")
    }

    // MARK: classification

    /// `LNAV/VNAV DA` is typeset as `LNAV/` over `VNAV` with `DA` beside the first line, and the sweep can
    /// return it as `LNAV/DA` on one row and `VNAV` on the next. Reading that as a plain LNAV line would
    /// label a Baro-VNAV DECISION altitude — flown through on a computed path — as a MINIMUM DESCENT
    /// altitude the aircraft is required to level at.
    func testWrappedBaroVNAVLabelIsNotReadAsPlainLNAV() {
        let r = parse([[word("LNAV/DA", 24.5, 57.0, 530),
                        word("514/50", 125.5, 152.0, 530), word("496(500-1)", 155.0, 191.0, 530)],
                       [word("VNAV", 25.0, 41.5, 536)]])
        XCTAssertEqual(r.minima?.rows.first?.kind, .baroVNAV)
        XCTAssertTrue(r.minima?.rows.first?.kind.usesDecisionAltitude == true)
        XCTAssertEqual(r.minima?.rows.first?.label, "LNAV/VNAV DA")
    }

    func testPlainLNAVIsAMinimumDescentAltitude() {
        let r = parse([[word("LNAV", 24.0, 40.0, 546), word("MDA", 44.0, 56.5, 546),
                        word("480/24", 78.0, 104.0, 546), word("462(500-12)", 113.0, 145.5, 546),
                        word("480/50", 177.0, 203.0, 546), word("462(500-1)", 208.0, 243.5, 546)]])
        XCTAssertEqual(r.minima?.rows.first?.kind, .lnav)
        XCTAssertFalse(r.minima?.rows.first?.kind.usesDecisionAltitude ?? true)
    }

    /// When the two stacked lines of `LNAV/VNAV` share one swept band their characters come back
    /// interleaved, as `LVNNAAVV/DA`. Boston's RNAV 4L prints exactly this on its second Baro-VNAV row,
    /// and dropping it would hide a published line whose minima are 88 ft lower than the one shown.
    func testInterleavedStackedLabelStillClassifies() {
        let r = parse([[word("LVNNAAVV/DA", 23.0, 53.0, 533, pitch: 3.0),
                        word("*", 56.0, 59.0, 533, pitch: 3.0),
                        word("680-178", 122.0, 148.0, 533, pitch: 3.0),
                        word("666(700-178)", 155.0, 195.0, 533, pitch: 3.0)]])
        XCTAssertEqual(r.minima?.rows.first?.kind, .baroVNAV)
        XCTAssertEqual(r.minima?.rows.first?.label, "LNAV/VNAV DA")
        XCTAssertEqual(r.minima?.rows.first?.hasInopAsterisk, true)
        XCTAssertEqual(r.minima?.rows.first?.values[.a]?.altitudeFtMSL, 680)
    }

    /// A single V cannot spell VNAV, so an ordinary LNAV line is not swept up by the subsequence rule.
    func testPlainLNAVIsNotMistakenForBaroVNAVBySubsequence() {
        XCTAssertEqual(PlateMinimaParser.classify("LNAV MDA"), .lnav)
        XCTAssertEqual(PlateMinimaParser.classify("LNAV/ MDA"), .lnav)
        XCTAssertFalse(PlateMinimaParser.containsSubsequence("LNAVMDA", "VNAV"))
    }

    /// A row with readable minima but an unreadable label must SAY so. Silently dropping it leaves the
    /// pilot with a short table and no sign that a published line is missing from it.
    func testRowWithValuesButNoRecognisableLabelIsReported() {
        let r = parse([[word("LPV DA", 22.5, 53.0, 507),
                        word("318/45", 121.0, 147.5, 507), word("304(300-78)", 157.5, 195.5, 507)],
                       [word("QQQZZ", 23.0, 53.0, 520),
                        word("680-178", 122.0, 148.0, 520), word("666(700-178)", 155.0, 195.0, 520)]])
        XCTAssertEqual(r.minima?.rows.count, 1)
        XCTAssertTrue(r.refusals.contains { $0.contains("could not be identified") },
                      "expected a refusal naming the dropped line, got \(r.refusals)")
    }

    // MARK: conditional blocks

    /// Boston's `# APPROACH MINIMA WHEN CONTROL TOWER REPORTS TALL VESSELS IN APPROACH AREA` becomes a
    /// question with an answer, instead of fine print between two tables.
    func testConditionalBlockBecomesAQuestion() {
        let prose = "#APPROACH MINIMA WHEN CONTROL TOWER REPORTS TALL VESSELS IN APPROACH AREA"
        let r = parse([[word("S-ILS", 26.5, 45.0, 507), word("4R", 47.0, 54.0, 507),
                        word("218/18", 126.0, 152.0, 507), word("200(200-12)", 159.5, 196.5, 507)],
                       [word("#APPROACHMINIMAWHENCONTROLTOWERREPORTSTALL", 54.0, 227.5, 526, pitch: 4.0)],
                       [word("VESSELSINAPPROACHAREA", 101.5, 181.5, 533)],
                       [word("S-ILS", 23.5, 42.0, 544), word("4R", 44.0, 51.0, 544),
                        word("374/40", 126.0, 152.5, 544), word("356(400-34)", 159.5, 197.0, 544)]],
                      prose: prose)
        XCTAssertEqual(r.minima?.rows.count, 1, "the base table keeps only the unconditional row")
        XCTAssertEqual(r.minima?.rows.first?.values[.a]?.altitudeFtMSL, 218)
        XCTAssertEqual(r.minima?.conditionals.count, 1)
        XCTAssertEqual(r.minima?.conditionals.first?.question,
                       "Control tower reports tall vessels in approach area?")
        XCTAssertEqual(r.minima?.conditionals.first?.rows.first?.values[.a]?.altitudeFtMSL, 374)
    }

    /// A standing annotation is not a condition. Without this, `AUTHORIZATION REQUIRED` over an RNP AR
    /// line would capture every row beneath it and hide the base minima behind a meaningless toggle.
    func testStandingAnnotationDoesNotOpenAConditionalBlock() {
        let r = parse([[word("RNP", 24.0, 36.0, 507), word("0.30", 38.0, 52.0, 507),
                        word("DA", 54.0, 62.0, 507),
                        word("5683/26", 126.0, 155.0, 507), word("326(300-12)", 159.5, 196.5, 507)],
                       [word("AUTHORIZATIONREQUIRED", 60.0, 180.0, 520)]])
        XCTAssertEqual(r.minima?.conditionals.count, 0)
        XCTAssertEqual(r.minima?.rows.count, 1)
    }

    // MARK: header

    /// The header row also carries text from the panels beside the table, some of it a bare capital
    /// letter. Only letters in strict alphabetical order at a regular spacing are columns.
    func testStrayCapitalsBesideTheTableAreNotCategories() {
        let words = headerRow + [word("P", 300.0, 305.0, 497), word("A", 340.0, 345.0, 497)]
        let header = PlateMinimaParser.findHeader(words)
        XCTAssertEqual(header?.centers.count, 4)
        XCTAssertEqual(header?.centers.last?.0, .d)
        XCTAssertLessThan(header?.bandRight ?? 999, 290, "band must not reach the panels on the right")
    }

    func testNoHeaderMeansNoMinima() {
        let r = PlateMinimaParser.parse(words: [word("LNAV", 24, 40, 546)], notesText: "",
                                        airport: "KBOS", approachName: "X", cycle: "2607")
        XCTAssertNil(r.minima)
        XCTAssertFalse(r.refusals.isEmpty)
    }

    // MARK: cell reconciliation

    /// A cell split in the middle is rejoined only because the join PARSES and the halves do not.
    func testFragmentsAreRejoinedWhenOnlyTheJoinIsAValue() {
        let header = PlateMinimaParser.findHeader(headerRow)!
        let groups = [(text: "440/24", range: 76.0...102.0), (text: "422(500-12)", range: 110.0...147.5)]
        let out = PlateMinimaParser.reconcile(groups, header: header)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.text, "440/24422(500-12)")
    }

    /// Text that parses as nothing and sits under no column is discarded, not allowed to refuse the row.
    func testOffColumnJunkIsDiscarded() {
        let header = PlateMinimaParser.findHeader(headerRow)!
        let groups = [(text: "218/18200(200-12)", range: 126.0...196.5),
                      (text: "Min:Sec", range: 259.0...282.0)]   // begins past the last column
        let out = PlateMinimaParser.reconcile(groups, header: header)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.text, "218/18200(200-12)")
    }
}
