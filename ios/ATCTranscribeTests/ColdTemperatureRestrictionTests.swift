import XCTest
@testable import ATCTranscribe

/// The snowflake (Cold Temperature Restricted Airport) figure, read off the plate, and the advisory built
/// from it. Fixtures are the laid-out lines PDFKit returned for real cycle-2611 plates (387 × 594 pt).
final class ColdTemperatureRestrictionTests: XCTestCase {

    private typealias L = ColdTemperatureRestriction.NoteLine
    private let w = 387.36, h = 594.0

    private func read(_ lines: [L]) -> Int? {
        ColdTemperatureRestriction.restrictionC(lines: lines, pageWidth: w, pageHeight: h)
    }

    // MARK: reading the figure

    /// Bozeman ILS Y 12: the figure is a line of its own in the icon column, left of the notes.
    func testBozemanSnowflakeFigureIsRead() {
        XCTAssertEqual(read([
            L(text: "T", x0: 23.2, yMid: 72),
            L(text: "Circling NA to Rwys 3-21 and 11-29. DME from BZN", x0: 53.2, yMid: 72.4),
            L(text: "VOR/DME. DME use requires simultaneous reception of", x0: 53.2, yMid: 79.6),
            L(text: "I-BZN and BZN DME. For inop ALS, increase S-LOC 12", x0: 53.2, yMid: 86.9),
            L(text: "-21°C", x0: 29.9, yMid: 89.4),
            L(text: "Cat C/D visibility to 2 SM.", x0: 53.2, yMid: 94.1),
        ]), -21)
    }

    /// Rangely RNAV 7: the figure was laid out on the same line as the prose beside it.
    func testFigureMergedWithProseIsStillRead() {
        XCTAssertEqual(read([
            L(text: "For uncompensated Baro-VNAV systems, LNAV/VNAV NA", x0: 53.6, yMid: 76.8),
            L(text: "below -28°C (-18°F) or above 54°C (130°F). Circling Rwy 25", x0: 53.6, yMid: 84.3),
            L(text: "-17°C NA at night. DME/DME RNP-0.3 NA.", x0: 30.2, yMid: 91.4),
        ]), -17)
    }

    /// Bismarck RNAV 31 is not a CTA: its `-18°C` is the Baro-VNAV window wrapping onto a new line.
    func testBaroVNAVWrapAtTheMarginIsNotASnowflake() {
        XCTAssertNil(read([
            L(text: "For uncompensated Baro-VNAV systems, LNAV/VNAV NA below", x0: 54.3, yMid: 82.7),
            L(text: "-18°C or above 54°C. Inop table does not apply to LNAV/VNAV.", x0: 54.3, yMid: 90.3),
            L(text: "*RVR 1800 authorized with use of FD or AP or HUD to DA.", x0: 54.3, yMid: 97.9),
        ]))
    }

    /// Macon RNAV 5: a Baro-VNAV wrap where an indented neighbour pulled the plain median past it.
    func testBaroVNAVWrapWithIndentedNeighbourIsNotASnowflake() {
        XCTAssertNil(read([
            L(text: "Apt Elev", x0: 86.9, yMid: 59.7),
            L(text: "For uncompensated Baro-VNAV systems, LNAV/VNAV NA below", x0: 37.7, yMid: 82.0),
            L(text: "-7°C or above 54°C.", x0: 37.7, yMid: 89.0),
            L(text: "RVR 1800 authorized with use of FD or AP or HUD to DA.", x0: 42.5, yMid: 96.0),
        ]))
    }

    /// Header-box labels (`Apt Elev` at x 88) must not count as notes prose.
    func testHeaderLabelsDoNotMoveTheMargin() {
        XCTAssertNil(read([
            L(text: "Apt Elev", x0: 88.4, yMid: 60.6),
            L(text: "For uncompensated Baro-VNAV systems, LNAV/VNAV NA below", x0: 52.6, yMid: 74.6),
            L(text: "-16°C (4°F) or above 54°C (130°F). DME/DME RNP-0.3 NA.", x0: 52.6, yMid: 81.8),
        ]))
    }

    /// Ely 00673 RNAV 30: a helicopter note to the right ends in "below" right above the figure.
    func testBelowInAnotherColumnDoesNotSuppressTheFigure() {
        XCTAssertEqual(read([
            L(text: "Circling Rwy 12 NA at night.", x0: 73.8, yMid: 83.3),
            L(text: "Rwy 30 helicopter visibility reduction below ", x0: 73.8, yMid: 92.7),
            L(text: "-18°C", x0: 32.0, yMid: 97.5),
        ]), -18)
    }

    func testTypographicMinusAndNoFigure() {
        XCTAssertEqual(ColdTemperatureRestriction.leadingTemperatureC("\u{2212}25°C"), -25)
        XCTAssertNil(ColdTemperatureRestriction.leadingTemperatureC("RVR 1800"))
        XCTAssertNil(read([L(text: "Circling NA at night.", x0: 40, yMid: 80)]))
    }

    // MARK: the plate's named source

    func testAltimeterSourceNameIsRead() {
        XCTAssertEqual(ColdTemperatureRestriction.temperatureSourceName(
            notesText: "When local altimeter setting not received, use ORE altimeter setting and increase all MDAs 60 feet"), "ORE")
        XCTAssertEqual(ColdTemperatureRestriction.temperatureSourceName(
            notesText: "Use Dane County Rgnl-Truax Fld altimeter setting."), "Dane County Rgnl-Truax Fld")
        // Interleaved missed-approach text must not be captured as a station name.
        XCTAssertNil(ColdTemperatureRestriction.temperatureSourceName(
            notesText: "use Climb to 4800 direct Allegheny County altimeter setting"))
    }

    func testSourceResolvesByIdentOrAbbreviatedName() {
        typealias S = ColdTemperatureAdvisor.Station
        let c = [S(ident: "KMSN", name: "DANE COUNTY RGNL-TRUAX FIELD", distanceNm: 22, tempC: -25),
                 S(ident: "KORE", name: "ORANGE MUNI", distanceNm: 12, tempC: -5),
                 S(ident: "KFAR", name: "HECTOR INTL", distanceNm: 200, tempC: -30)]
        XCTAssertEqual(ColdTemperatureAdvisor.resolveSource(name: "Dane County Rgnl-Truax Fld", candidates: c)?.ident, "KMSN")
        XCTAssertEqual(ColdTemperatureAdvisor.resolveSource(name: "ORE", candidates: c,
                                                            identAliases: ["KORE": ["ORE"]])?.ident, "KORE")
        XCTAssertNil(ColdTemperatureAdvisor.resolveSource(name: "Hector Intl", candidates: c), "too far away")
    }

    // MARK: the advisory

    func testFieldTemperatureAtOrBelowTheLimitAlerts() {
        let a = ColdTemperatureAdvisor.assess(restrictionC: -21, fieldIdent: "KBZN", fieldTempC: -21,
                                              plateSourceName: nil, plateSource: nil, nearby: [])
        XCTAssertEqual(a.status, .atOrBelow, "the rule applies AT the published figure, not only below it")
        XCTAssertEqual(a.observation?.source, .field)
        XCTAssertTrue(a.detail.contains("your decision"))
    }

    func testWarmerFieldDoesNotAlert() {
        let a = ColdTemperatureAdvisor.assess(restrictionC: -21, fieldIdent: "KBZN", fieldTempC: -4,
                                              plateSourceName: nil, plateSource: nil, nearby: [])
        XCTAssertEqual(a.status, .above)
    }

    /// No field report → the plate's named source is used before any nearby field.
    func testPlateSourceBeatsNearerField() {
        typealias S = ColdTemperatureAdvisor.Station
        let src = S(ident: "KMSN", name: "DANE COUNTY RGNL", distanceNm: 22, tempC: -25)
        let a = ColdTemperatureAdvisor.assess(restrictionC: -23, fieldIdent: "C29", fieldTempC: nil,
                                              plateSourceName: "Dane County Rgnl", plateSource: src,
                                              nearby: [S(ident: "KXYZ", name: "X", distanceNm: 5, tempC: -10), src])
        XCTAssertEqual(a.observation?.ident, "KMSN")
        XCTAssertEqual(a.status, .atOrBelow)
    }

    /// No field report and no plate source → nearest reporting field inside the radius, labelled as such.
    func testNearbyFallbackIsNearestInsideRadius() {
        typealias S = ColdTemperatureAdvisor.Station
        let a = ColdTemperatureAdvisor.assess(
            restrictionC: -20, fieldIdent: "KAAA", fieldTempC: nil, plateSourceName: nil, plateSource: nil,
            nearby: [S(ident: "KFAR", name: "far", distanceNm: 45, tempC: -30),
                     S(ident: "KNIL", name: "silent", distanceNm: 3, tempC: nil),
                     S(ident: "KNER", name: "near", distanceNm: 11, tempC: -22)])
        XCTAssertEqual(a.observation?.ident, "KNER")
        XCTAssertEqual(a.observation?.source, .nearby(distanceNm: 11))
        XCTAssertTrue(a.sourceLine.contains("estimate"))
    }

    func testNoTemperatureAnywhereIsUnknownNotAssumed() {
        let a = ColdTemperatureAdvisor.assess(restrictionC: -20, fieldIdent: "KAAA", fieldTempC: nil,
                                              plateSourceName: nil, plateSource: nil, nearby: [])
        XCTAssertEqual(a.status, .unknown)
        XCTAssertNil(a.observation)
    }

    // MARK: audit regressions (adversarial audit of f4f2d78)

    /// Northway VOR-A: a full-width first line `DME required.` at x 21.7 made the margin and hid -48.
    func testFullWidthFirstLineDoesNotHideTheFigure() {
        XCTAssertEqual(read([
            L(text: "DME required.", x0: 21.7, yMid: 71.5),
            L(text: "T", x0: 23.6, yMid: 81.4),
            L(text: "-48°C", x0: 30.5, yMid: 91.2),
        ]), -48)
    }

    /// Gambell RNAV 16: the figure shares a baseline with the Baro-VNAV wrap and merges into it.
    func testFigureMergedIntoBaroVNAVWrapIsReadByTheIcons() {
        XCTAssertEqual(read([
            L(text: "T", x0: 23.0, yMid: 81.1),
            L(text: "Circling NA east of Rwy 16-34. For uncompensated", x0: 56.7, yMid: 82.6),
            L(text: "A", x0: 22.2, yMid: 89.9),
            L(text: "Baro-VNAV systems, LNAV/VNAV NA below -20°C", x0: 56.7, yMid: 90.3),
            L(text: "-26°C or above 54°C .", x0: 29.5, yMid: 98.1),
        ]), -26)
    }

    /// Colstrip COPTER 24: a helicopter note ending "…reduction below" starts by the icons.
    func testHelicopterNoteByTheIconsDoesNotHideTheFigure() {
        XCTAssertEqual(read([
            L(text: "T", x0: 22.1, yMid: 72.1),
            L(text: "When local altimeter not received, use MLS altimeter setting.", x0: 58.2, yMid: 76.6),
            L(text: "A", x0: 21.2, yMid: 80.8),
            L(text: "4 Rwy 24 helicopter visibility reduction below ", x0: 34.8, yMid: 84.5),
            L(text: "-34°C", x0: 28.9, yMid: 88.8),
        ]), -34)
    }

    /// Yankton ILS 31: PDFKit lines at negative x and an asterisk note at x 27.
    func testNegativeXAndAsteriskLinesDoNotHideTheFigure() {
        XCTAssertEqual(read([
            L(text: "T", x0: 22.7, yMid: 90.7),
            L(text: "For inop ALS, DME use requires simultaneous reception of I-YKN and YKN DME.", x0: -109.0, yMid: 97.9),
            L(text: "A", x0: 21.8, yMid: 99.2),
            L(text: "d increase ZIMUK fix minimums increase S-LOC 31 Cat C/D visibility to 2 ", x0: -112.2, yMid: 105.4),
            L(text: "-30°C", x0: 29.0, yMid: 109.1),
            L(text: "* S-LOC 31 Cat C/D visibility to ", x0: 27.4, yMid: 114.0),
        ]), -30)
    }

    /// The nearest Baro-VNAV wrap to the icons in ~2,000 plates (05001R1L, 11.1 pt) stays rejected.
    func testBaroVNAVWrapNearTheIconsIsStillRejected() {
        XCTAssertNil(read([
            L(text: "T", x0: 22.0, yMid: 80.0),
            L(text: "For uncompensated Baro-VNAV systems, LNAV/VNAV NA below", x0: 33.1, yMid: 82.0),
            L(text: "A", x0: 22.0, yMid: 89.0),
            L(text: "-25°C (-13°F) or above 54°C (130°F).", x0: 33.1, yMid: 89.5),
        ]))
    }

    /// The rule applies to the REPORTED whole degree. Juneau, limit +1 °C, body `01/M02`, feed 1.4.
    func testReportedWholeDegreeNotTenthsDecidesTheStatus() {
        XCTAssertEqual(ColdTemperatureAdvisor.reportedC(raw: "PAJN 141953Z 10003KT 10SM OVC040 01/M02 A2990", tenths: 1.4), 1)
        XCTAssertEqual(ColdTemperatureAdvisor.reportedC(raw: "KBZN 141953Z 00000KT 10SM CLR M21/M24 A3030", tenths: -20.6), -21)
        XCTAssertEqual(ColdTemperatureAdvisor.reportedC(raw: nil, tenths: -20.6), -21)
        let a = ColdTemperatureAdvisor.assess(restrictionC: 1, fieldIdent: "PAJN",
                                              fieldTempC: ColdTemperatureAdvisor.reportedC(raw: "PAJN 141953Z 01/M02 A2990", tenths: 1.4),
                                              plateSourceName: nil, plateSource: nil, nearby: [])
        XCTAssertEqual(a.status, .atOrBelow)
    }

    private func metar(_ json: String) throws -> Metar {
        try JSONDecoder().decode(Metar.self, from: Data(json.utf8))
    }

    /// A station that stopped reporting at +3 °C must not stand in for tonight's temperature.
    func testStaleObservationIsNotTheReportedTemperature() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = try metar(#"{"icaoId":"KAAA","temp":3,"rawOb":"KAAA 03/M01 A3000","obsTime":\#(1_800_000_000 - 3 * 3600)}"#)
        let fresh = try metar(#"{"icaoId":"KAAA","temp":-22,"rawOb":"KAAA M22/M25 A3000","obsTime":\#(1_800_000_000 - 50 * 60)}"#)
        XCTAssertNil(ColdTemperatureAdvisor.current(old, now: now))
        let c = try XCTUnwrap(ColdTemperatureAdvisor.current(fresh, now: now))
        XCTAssertEqual(c.tempC, -22)
        let a = ColdTemperatureAdvisor.assess(restrictionC: -20, fieldIdent: "KAAA", fieldTempC: c.tempC,
                                              fieldAge: c.age, plateSourceName: nil, plateSource: nil, nearby: [])
        XCTAssertTrue(a.sourceLine.contains("50 min ago"), a.sourceLine)
    }

    /// Lower-48 fields with no ICAO in NASR file their METAR under K + ident (M46 → KM46); Alaska does not.
    func testWeatherIdentForFieldsWithoutICAO() {
        func apt(_ id: String, _ icao: String, _ lat: Double, _ lon: Double) -> AirportData.Airport {
            AirportData.Airport(ident: id, icao: icao, name: "", coord: Coord(lat: lat, lon: lon), elevationFt: nil,
                                ownership: "", use: "", status: "O", tower: "", fuel: "", siteType: "A", far139: "")
        }
        XCTAssertEqual(ColdTemperatureStore.weatherIdent(apt("M46", "", 45.85, -106.7)), "KM46")
        XCTAssertEqual(ColdTemperatureStore.weatherIdent(apt("BZN", "KBZN", 45.78, -111.15)), "KBZN")
        XCTAssertNil(ColdTemperatureStore.weatherIdent(apt("ENA", "", 60.57, -151.24)), "no K convention in Alaska")
    }

    /// A failed fetch is reported as a failure, not as "nobody reports".
    func testFailedFetchSaysSo() {
        let a = ColdTemperatureAdvisor.assess(restrictionC: -20, fieldIdent: "KAAA", fieldTempC: nil,
                                              plateSourceName: nil, plateSource: nil, nearby: [], fetchFailed: true)
        XCTAssertEqual(a.status, .unknown)
        XCTAssertTrue(a.sourceLine.contains("could not be fetched"), a.sourceLine)
    }

    func testSourceResolutionAuditCases() {
        typealias S = ColdTemperatureAdvisor.Station
        let c = [S(ident: "POOH", name: "HOONAH", distanceNm: 1, tempC: nil),
                 S(ident: "PAOH", name: "HOONAH", distanceNm: 2, tempC: nil),
                 S(ident: "KBTM", name: "BERT MOONEY", distanceNm: 20, tempC: nil, city: "BUTTE"),
                 S(ident: "PAQH", name: "QUINHAGAK", distanceNm: 5, tempC: nil),
                 S(ident: "PAWN", name: "NOATAK", distanceNm: 30, tempC: nil)]
        let aliases = ["PAOH": ["HNH"], "KBTM": ["BTM"], "PAWN": ["WTK"]]
        XCTAssertEqual(ColdTemperatureAdvisor.resolveSource(name: "HNH/PAOH", candidates: c, identAliases: aliases)?.ident, "PAOH")
        XCTAssertEqual(ColdTemperatureAdvisor.resolveSource(name: "Butte", candidates: c, identAliases: aliases)?.ident, "KBTM")
        XCTAssertEqual(ColdTemperatureAdvisor.resolveSource(name: "Butte NA", candidates: c, identAliases: aliases)?.ident, "KBTM")
        XCTAssertEqual(ColdTemperatureAdvisor.resolveSource(name: "A Noatak", candidates: c, identAliases: aliases)?.ident, "PAWN")
    }
}
