import XCTest
@testable import ATCTranscribe

/// The arithmetic between the published table and the number the pilot flies to.
final class MinimaSolverTests: XCTestCase {

    // MARK: fixtures

    private func value(_ alt: Int, _ vis: PlateMinima.Visibility, hat: Int? = nil, raw: String = "x") -> PlateMinima.Value {
        PlateMinima.Value(altitudeFtMSL: alt, visibility: vis, heightAboveFt: hat,
                          ceilingFt: nil, isNA: false, rawText: raw)
    }

    private func row(_ label: String, _ kind: PlateMinima.Kind,
                     _ v: PlateMinima.Value, y: Double = 500) -> PlateMinima.Row {
        PlateMinima.Row(label: label, kind: kind,
                        values: Dictionary(uniqueKeysWithValues: PlateMinima.Category.allCases.prefix(4).map { ($0, v) }),
                        hasInopAsterisk: false, pageY: y)
    }

    private func minima(rows: [PlateMinima.Row],
                        conditionals: [PlateMinima.ConditionalBlock] = [],
                        notes: [PlateNote] = []) -> PlateMinima {
        PlateMinima(airport: "KBOS", approachName: "ILS or LOC RWY 4R", rows: rows,
                    conditionals: conditionals, notes: notes, amendment: "Amdt 11C 12JUN25", cycle: "2607")
    }

    // MARK: baseline

    func testPublishedValuePassesThroughUnchanged() {
        let m = minima(rows: [row("S-ILS 4R", .ils, value(218, .rvrFt(1_800), hat: 200))])
        let s = MinimaSolver.solve(m, request: .init(category: .a, kind: .ils))
        XCTAssertEqual(s?.altitudeFtMSL, 218)
        XCTAssertEqual(s?.visibility, .rvrFt(1_800))
        XCTAssertTrue(s?.steps.isEmpty ?? false)
        XCTAssertEqual(s?.altitudeKind, "DA")
    }

    /// A decision altitude and a minimum descent altitude are not the same instruction, and the label is
    /// half the meaning of the figure.
    func testLocalizerLineIsAMinimumDescentAltitude() {
        let m = minima(rows: [row("S-LOC 4R", .localizer, value(440, .rvrFt(2_400)))])
        XCTAssertEqual(MinimaSolver.solve(m, request: .init(kind: .localizer))?.altitudeKind, "MDA")
    }

    // MARK: inoperative components

    /// On an ILS published at RVR 1800, losing the approach lights takes the visibility to RVR 4000 —
    /// and never touches the altitude.
    func testApproachLightsInopOnALowVisibilityILS() {
        let m = minima(rows: [row("S-ILS 4R", .ils, value(218, .rvrFt(1_800)))])
        var r = MinimaSolver.Request(kind: .ils)
        r.inoperative = [.approachLights]
        let s = MinimaSolver.solve(m, request: r)
        XCTAssertEqual(s?.visibility, .rvrFt(4_000))
        XCTAssertEqual(s?.altitudeFtMSL, 218, "the table raises visibility only")
        XCTAssertEqual(s?.steps.count, 1)
    }

    /// On a localizer the same failure adds half a mile to whatever is published — a different rule in
    /// the same table, for a different kind of approach.
    func testApproachLightsInopOnALocalizerAddsHalfAMile() {
        let m = minima(rows: [row("S-LOC 4R", .localizer, value(440, .statuteSixteenths(8)))])
        var r = MinimaSolver.Request(kind: .localizer)
        r.inoperative = [.approachLights]
        XCTAssertEqual(MinimaSolver.solve(m, request: r)?.visibility, .statuteSixteenths(16))   // ½ → 1
    }

    /// LPV and LNAV/VNAV are not covered by the table. The plate carries its own note, so the figure is
    /// left alone and the pilot is sent to read it rather than shown a rule meant for an ILS.
    func testSatelliteLinesAreNotAdjustedByTheGroundBasedTable() {
        let m = minima(rows: [row("LPV DA", .lpv, value(218, .rvrFt(1_800)))])
        var r = MinimaSolver.Request(kind: .lpv)
        r.inoperative = [.approachLights]
        let s = MinimaSolver.solve(m, request: r)
        XCTAssertEqual(s?.visibility, .rvrFt(1_800), "must not apply the ILS rule to an LPV line")
        XCTAssertFalse(s?.advisories.isEmpty ?? true, "must say so rather than silently do nothing")
    }

    func testRVRReadoutInopConvertsToStatuteMiles() {
        let m = minima(rows: [row("S-ILS 4R", .ils, value(218, .rvrFt(2_400)))])
        var r = MinimaSolver.Request(kind: .ils)
        r.inoperative = [.rvrReadout]
        XCTAssertEqual(MinimaSolver.solve(m, request: r)?.visibility, .statuteSixteenths(8))    // ½
    }

    // MARK: altimeter

    func testRemoteAltimeterRaisesTheAltitudeByThePublishedAmount() {
        let note = PlateNote(text: "…increase all MDA 80 feet.",
                             effect: .altimeterPenalty(addFt: 80, source: "Providence"))
        let m = minima(rows: [row("S-LOC 4R", .localizer, value(440, .rvrFt(2_400)))], notes: [note])
        var r = MinimaSolver.Request(kind: .localizer)
        r.remoteAltimeter = true
        let s = MinimaSolver.solve(m, request: r)
        XCTAssertEqual(s?.altitudeFtMSL, 520)
        XCTAssertEqual(s?.base.altitudeFtMSL, 440, "the published value stays visible for checking")
        XCTAssertTrue(s?.steps.first?.text.contains("+80 ft") ?? false)
    }

    func testNoPenaltyIsAppliedWhenThePlateDoesNotPublishOne() {
        let m = minima(rows: [row("S-LOC 4R", .localizer, value(440, .rvrFt(2_400)))])
        var r = MinimaSolver.Request(kind: .localizer)
        r.remoteAltimeter = true
        XCTAssertEqual(MinimaSolver.solve(m, request: r)?.altitudeFtMSL, 440)
    }

    // MARK: temperature

    /// The limit is read from the plate, not assumed: Boston's RNAV 4R publishes −16 °C, not the −15 °C
    /// that a hardcoded rule would have used.
    func testBaroVNAVIsNotAuthorisedBelowThePublishedTemperature() {
        let note = PlateNote(text: "…LNAV/VNAV NA below -16°C or above 54°C.",
                             effect: .baroVNAVTemperatureLimit(minC: -16, maxC: 54))
        let m = minima(rows: [row("LNAV/VNAV DA", .baroVNAV, value(514, .rvrFt(5_000)))], notes: [note])
        var r = MinimaSolver.Request(kind: .baroVNAV)
        r.temperatureC = -17
        let s = MinimaSolver.solve(m, request: r)
        XCTAssertNotNil(s?.notAuthorised)
        XCTAssertNil(s?.altitudeFtMSL, "an unavailable line must not still show a number")

        r.temperatureC = -15
        XCTAssertNil(MinimaSolver.solve(m, request: r)?.notAuthorised)
        XCTAssertEqual(MinimaSolver.solve(m, request: r)?.altitudeFtMSL, 514)
    }

    func testUnknownTemperatureIsReportedAsUnknownNotAssumedSafe() {
        let note = PlateNote(text: "…NA below -16°C.", effect: .baroVNAVTemperatureLimit(minC: -16, maxC: nil))
        let m = minima(rows: [row("LNAV/VNAV DA", .baroVNAV, value(514, .rvrFt(5_000)))], notes: [note])
        let s = MinimaSolver.solve(m, request: .init(kind: .baroVNAV))
        XCTAssertNil(s?.notAuthorised)
        XCTAssertTrue(s?.advisories.contains { $0.contains("unknown") } ?? false)
    }

    func testTemperatureLimitDoesNotTouchOtherLines() {
        let note = PlateNote(text: "…NA below -16°C.", effect: .baroVNAVTemperatureLimit(minC: -16, maxC: nil))
        let m = minima(rows: [row("LNAV MDA", .lnav, value(480, .rvrFt(2_400)))], notes: [note])
        var r = MinimaSolver.Request(kind: .lnav)
        r.temperatureC = -30
        XCTAssertNil(MinimaSolver.solve(m, request: r)?.notAuthorised)
    }

    // MARK: conditional blocks

    func testAnsweringAConditionSwapsInThatBlocksRow() {
        let base = row("S-ILS 4R", .ils, value(218, .rvrFt(1_800)))
        let raised = row("S-ILS 4R", .ils, value(374, .rvrFt(4_000)), y: 540)
        let block = PlateMinima.ConditionalBlock(
            heading: "APPROACH MINIMA WHEN CONTROL TOWER REPORTS TALL VESSELS IN APPROACH AREA",
            question: "Control tower reports tall vessels in approach area?",
            rows: [raised])
        let m = minima(rows: [base], conditionals: [block])

        XCTAssertEqual(MinimaSolver.solve(m, request: .init(kind: .ils))?.altitudeFtMSL, 218)

        var r = MinimaSolver.Request(kind: .ils)
        r.conditionals = [block.heading]
        let s = MinimaSolver.solve(m, request: r)
        XCTAssertEqual(s?.altitudeFtMSL, 374)
        XCTAssertEqual(s?.visibility, .rvrFt(4_000))
        XCTAssertTrue(s?.steps.first?.text.contains("tall vessels") ?? false)
    }

    // MARK: categories

    /// A category the plate does not publish has no answer, and the panel blacks it out rather than
    /// borrowing the neighbouring column's figure.
    func testUnpublishedCategoryHasNoSolution() {
        let m = minima(rows: [row("S-ILS 4R", .ils, value(218, .rvrFt(1_800)))])
        XCTAssertNil(MinimaSolver.solve(m, request: .init(category: .e, kind: .ils)))
        XCTAssertFalse(m.publishedCategories.contains(.e))
    }

    func testExplicitNAIsReportedAsNotAuthorised() {
        let na = PlateMinima.Value.na("NA")
        let r = PlateMinima.Row(label: "CIRCLING", kind: .circling, values: [.a: na, .b: na],
                                hasInopAsterisk: false, pageY: 500)
        let s = MinimaSolver.solve(minima(rows: [r]), request: .init(category: .a, kind: .circling))
        XCTAssertNotNil(s?.notAuthorised)
        XCTAssertNil(s?.altitudeFtMSL)
    }

    // MARK: more than one row of a kind

    /// Boston's RNAV 4L prints two `LNAV/VNAV DA` lines — the second, starred, nearly a hundred feet
    /// lower. Exposing only the first would hide a published line, so every printed row is reachable.
    func testBothRowsOfTheSameKindAreReachable() {
        let plain = row("LNAV/VNAV DA", .baroVNAV, value(768, .statuteSixteenths(32)), y: 500)
        let starred = PlateMinima.Row(label: "LNAV/VNAV DA", kind: .baroVNAV,
                                      values: [.a: value(680, .statuteSixteenths(30))],
                                      hasInopAsterisk: true, pageY: 512)
        let m = minima(rows: [plain, starred])

        XCTAssertEqual(MinimaSolver.availableLines(m).count, 2)
        XCTAssertEqual(MinimaSolver.solve(m, request: .init(kind: .baroVNAV, lineIndex: 0))?.altitudeFtMSL, 768)
        XCTAssertEqual(MinimaSolver.solve(m, request: .init(kind: .baroVNAV, lineIndex: 1))?.altitudeFtMSL, 680)
    }

    /// An index past the last row of that kind clamps rather than returning nothing — the pilot keeps a
    /// published number instead of an empty panel.
    func testLineIndexBeyondTheLastRowClamps() {
        let m = minima(rows: [row("LPV DA", .lpv, value(318, .rvrFt(4_500)))])
        XCTAssertEqual(MinimaSolver.solve(m, request: .init(kind: .lpv, lineIndex: 7))?.altitudeFtMSL, 318)
    }

    // MARK: visibility ordering

    /// Ordering exists so a raised visibility never silently LOWERS the requirement.
    func testVisibilityOrderingFollowsTheComparableValuesTable() {
        XCTAssertLessThan(PlateMinima.Visibility.rvrFt(1_800), .rvrFt(2_400))
        XCTAssertLessThan(PlateMinima.Visibility.statuteSixteenths(8), .statuteSixteenths(16))
        XCTAssertEqual(InopTable.statuteEquivalent(.rvrFt(2_400)), .statuteSixteenths(8))
        XCTAssertEqual(InopTable.statuteEquivalent(.rvrFt(5_000)), .statuteSixteenths(16))
    }
}
