import XCTest
@testable import ATCTranscribe

final class TafTests: XCTestCase {

    private let sample = """
    [{"icaoId":"KBOS","rawTAF":"TAF KBOS 162320Z 1700/1806 29011G22KT 6SM FU SCT060 BKN200 FM170100 32006KT P6SM SCT070",
      "issueTime":"2026-07-16T23:20:00.000Z",
      "fcsts":[
        {"timeFrom":1784246400,"timeTo":1784250000,"wdir":290,"wspd":11,"wgst":22,"visib":6,"wxString":"FU",
         "clouds":[{"cover":"SCT","base":6000},{"cover":"BKN","base":20000}]},
        {"timeFrom":1784250000,"timeTo":1784304000,"fcstChange":"FM","wdir":320,"wspd":6,"visib":"6+",
         "clouds":[{"cover":"SCT","base":7000}]}
      ]}]
    """

    func testParsesRawIssuedAndPeriods() throws {
        let taf = try XCTUnwrap(Taf.parse(Data(sample.utf8)))
        XCTAssertEqual(taf.icaoId, "KBOS")
        XCTAssertTrue(taf.rawText?.contains("TAF KBOS") == true)
        XCTAssertNotNil(taf.issued)
        XCTAssertEqual(taf.periods.count, 2)
    }

    func testDecodesIntoPlainEnglish() throws {
        let taf = try XCTUnwrap(Taf.parse(Data(sample.utf8)))
        let first = taf.periods[0].summary
        XCTAssertTrue(first.hasPrefix("Wind from 290°"), "sentence-case plain English: \(first)")
        XCTAssertTrue(first.contains("at 11 kt"), "wind speed in words: \(first)")
        XCTAssertTrue(first.contains("gusting 22"), "gust in words: \(first)")
        XCTAssertTrue(first.contains("smoke"), "FU decoded to 'smoke': \(first)")
        XCTAssertTrue(first.contains("scattered clouds at 6,000 ft"), "sky in feet + words: \(first)")
        XCTAssertTrue(first.contains("broken clouds at 20,000 ft"), "second layer: \(first)")
        // The FM period header is plain English now (no raw "FM"), with its own decoded body. Header is
        // built with the airport coordinate so it carries Zulu + the local clock.
        let hdr = taf.periods[1].header(lat: 42.36, lon: -71.01)   // Boston → Eastern
        XCTAssertTrue(hdr.hasPrefix("From "), "header: \(hdr)")
        XCTAssertTrue(hdr.contains("Z"), "Zulu retained: \(hdr)")
        XCTAssertTrue(hdr.contains("EDT") || hdr.contains("EST"), "local time appended: \(hdr)")
        XCTAssertTrue(taf.periods[1].summary.contains("from 320°"), "wind: \(taf.periods[1].summary)")
        XCTAssertTrue(taf.periods[1].summary.contains("visibility 6+ SM"), "6+ vis: \(taf.periods[1].summary)")
    }

    func testWeatherCodeDecoding() {
        XCTAssertEqual(Taf.wxText("BR"), "mist")
        XCTAssertEqual(Taf.wxText("-RA"), "light rain")
        XCTAssertEqual(Taf.wxText("+SN"), "heavy snow")
        XCTAssertEqual(Taf.wxText("TSRA"), "thunderstorm with rain")
        XCTAssertEqual(Taf.wxText("VCTS"), "thunderstorm in the vicinity")
        XCTAssertEqual(Taf.wxText("FZRA"), "freezing rain")
        XCTAssertEqual(Taf.wxText("-SHRA"), "light showers of rain")
        XCTAssertEqual(Taf.wxText("-SHRA BR"), "light showers of rain, mist")   // multiple groups
    }

    func testCalmAndVariableWind() throws {
        let calm = """
        [{"icaoId":"KXYZ","rawTAF":"TAF KXYZ 1700/1806 00000KT P6SM SKC",
          "fcsts":[{"timeFrom":1784250000,"wdir":"VRB","wspd":0,"visib":"6+","clouds":[{"cover":"SKC"}]}]}]
        """
        let taf = try XCTUnwrap(Taf.parse(Data(calm.utf8)))
        XCTAssertTrue(taf.periods[0].summary.contains("wind calm") || taf.periods[0].summary.hasPrefix("Wind calm"),
                      "0 kt → calm: \(taf.periods[0].summary)")
        XCTAssertTrue(taf.periods[0].summary.contains("sky clear"))
    }

    func testEmptyPayloadIsNil() {
        XCTAssertNil(Taf.parse(Data("[]".utf8)))
        XCTAssertNil(Taf.parse(Data("garbage".utf8)))
    }
}
