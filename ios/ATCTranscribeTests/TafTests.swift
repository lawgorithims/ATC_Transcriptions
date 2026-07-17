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

    func testDecodesWindVisSkyIntoSummary() throws {
        let taf = try XCTUnwrap(Taf.parse(Data(sample.utf8)))
        let first = taf.periods[0].summary
        XCTAssertTrue(first.contains("290°"), "wind direction decoded: \(first)")
        XCTAssertTrue(first.contains("11G22 kt"), "wind + gust decoded: \(first)")
        XCTAssertTrue(first.contains("SCT60"), "sky decoded in hundreds of feet: \(first)")
        // An FM period is tagged in its header, with its own decoded wind/vis.
        XCTAssertTrue(taf.periods[1].header.contains("FM"))
        XCTAssertTrue(taf.periods[1].summary.contains("320°"))
        XCTAssertTrue(taf.periods[1].summary.contains("6+"), "string visibility passes through: \(taf.periods[1].summary)")
    }

    func testEmptyPayloadIsNil() {
        XCTAssertNil(Taf.parse(Data("[]".utf8)))
        XCTAssertNil(Taf.parse(Data("garbage".utf8)))
    }
}
