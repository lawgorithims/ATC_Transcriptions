import XCTest
@testable import ATCTranscribe

/// The notes that change the numbers, on the exact wording the FAA uses.
final class PlateNoteParserTests: XCTestCase {

    func testAltimeterPenaltyIsReadWithItsSourceAndItsAmount() {
        let text = "When local altimeter setting not received, use Providence altimeter setting and " +
                   "increase all MDA 80 feet."
        guard case .altimeterPenalty(let add, let source)? = PlateNoteParser.notes(inText: text).first?.effect else {
            return XCTFail("no altimeter penalty parsed")
        }
        XCTAssertEqual(add, 80)
        XCTAssertEqual(source, "Providence")
    }

    /// The temperature limit differs plate to plate — Boston's RNAV 4R publishes −16 °C where the
    /// familiar figure is −15 — so it is read rather than assumed.
    func testBaroVNAVTemperatureWindowIsReadFromThePlate() {
        let text = "For uncompensated Baro-VNAV systems, LNAV/VNAV NA below -16°C or above 54°C."
        guard case .baroVNAVTemperatureLimit(let lo, let hi)? = PlateNoteParser.notes(inText: text).first?.effect else {
            return XCTFail("no temperature limit parsed")
        }
        XCTAssertEqual(lo, -16)
        XCTAssertEqual(hi, 54)
    }

    /// The FAA typesets the minus with U+2212, not a hyphen.
    func testTypographicMinusSign() {
        let text = "For uncompensated Baro-VNAV systems, LNAV/VNAV NA below \u{2212}20\u{00B0}C."
        guard case .baroVNAVTemperatureLimit(let lo, _)? = PlateNoteParser.notes(inText: text).first?.effect else {
            return XCTFail("no temperature limit parsed")
        }
        XCTAssertEqual(lo, -20)
    }

    func testNightRestrictionsAreCollectedWithoutDuplicates() {
        let text = "Circling NA at night. Circling NA at night. Procedure NA at night."
        let night = PlateNoteParser.notes(inText: text).filter {
            if case .nightRestriction = $0.effect { return true } else { return false }
        }
        XCTAssertEqual(night.count, 2)
    }

    /// A restriction on circling does not bear on a straight-in line, and vice versa.
    func testNightRestrictionScope() {
        XCTAssertTrue(MinimaSolver.applies("Circling NA at night", to: .circling))
        XCTAssertFalse(MinimaSolver.applies("Circling NA at night", to: .ils))
        XCTAssertTrue(MinimaSolver.applies("Procedure NA at night", to: .ils))
    }

    func testProseWithNoAdjustmentsProducesNoNotes() {
        XCTAssertTrue(PlateNoteParser.notes(inText: "Use of MALSR required. RADAR required.").isEmpty)
    }

    /// A penalty whose amount cannot be found is dropped rather than defaulted — a default here would be
    /// an invented minimum.
    func testIncompleteAltimeterNoteIsDropped() {
        let text = "When local altimeter setting not received, use Providence altimeter setting."
        XCTAssertTrue(PlateNoteParser.notes(inText: text).isEmpty)
    }

    // MARK: METAR temperature, which drives the Baro-VNAV limit

    func testTemperatureFromRawObservation() {
        XCTAssertEqual(Metar.temperatureFromRaw("KBOS 011854Z 04012KT 10SM BKN035 M05/M12 A2992"), -5)
        XCTAssertEqual(Metar.temperatureFromRaw("KBOS 011854Z 04012KT 10SM BKN035 22/14 A2992"), 22)
        XCTAssertNil(Metar.temperatureFromRaw("KBOS 011854Z 04012KT 10SM BKN035 A2992"))
        XCTAssertNil(Metar.temperatureFromRaw(nil))
    }

    /// A runway or visibility group elsewhere in the observation must not be read as a temperature.
    func testRunwayVisualRangeGroupIsNotATemperature() {
        XCTAssertEqual(Metar.temperatureFromRaw("KORD 011854Z 04012KT 1/2SM R10L/2000FT FG 03/02 A2992"), 3)
    }
}
