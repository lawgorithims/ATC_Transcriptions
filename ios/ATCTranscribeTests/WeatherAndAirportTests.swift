import XCTest
@testable import ATCTranscribe

/// METAR decoding + flight-category rules, and the airport-summary aggregation behind the Airports tab.
final class WeatherAndAirportTests: XCTestCase {

    private func decode(_ json: String) throws -> Metar {
        let list = try JSONDecoder().decode([Metar].self, from: Data(json.utf8))
        return try XCTUnwrap(list.first)
    }

    func testMetarDecodesLenientlyAndSummarises() throws {
        let m = try decode("""
        [{"icaoId":"KBOS","wdir":250,"wspd":18,"wgst":26,"visib":"10+",
          "clouds":[{"cover":"FEW","base":6000},{"cover":"BKN","base":25000}],
          "fltCat":"VFR","obsTime":1784224440}]
        """)
        XCTAssertEqual(m.icaoId, "KBOS")
        XCTAssertEqual(m.windDir, 250)
        XCTAssertEqual(m.windKt, 18)
        XCTAssertEqual(m.gustKt, 26)
        XCTAssertEqual(m.visSm ?? 0, 10, accuracy: 0.01)         // "10+" → 10
        XCTAssertEqual(m.ceilingFt, 25000)                        // lowest BKN/OVC base
        XCTAssertEqual(m.category, .vfr)
        XCTAssertTrue(m.summary.contains("250°"), m.summary)
        XCTAssertTrue(m.summary.contains("G26"), m.summary)       // gust shown
    }

    func testVariableWindDecodesAsNil() throws {
        let m = try decode(#"[{"icaoId":"X","wdir":"VRB","wspd":5,"visib":"10+"}]"#)
        XCTAssertNil(m.windDir)                                    // "VRB" → nil, not a crash
        XCTAssertEqual(m.windKt, 5)
    }

    func testFlightCategoryDerivedFromCeilingAndVisibility() throws {
        // No fltCat → derive from the FAA ceiling/visibility rules.
        XCTAssertEqual(try decode(#"[{"icaoId":"A","visib":10.0,"clouds":[{"cover":"FEW","base":8000}]}]"#).category, .vfr)
        XCTAssertEqual(try decode(#"[{"icaoId":"B","visib":4.0,"clouds":[{"cover":"OVC","base":2500}]}]"#).category, .mvfr)
        XCTAssertEqual(try decode(#"[{"icaoId":"C","visib":5.0,"clouds":[{"cover":"OVC","base":800}]}]"#).category, .ifr)
        XCTAssertEqual(try decode(#"[{"icaoId":"D","visib":0.5,"clouds":[{"cover":"OVC","base":2000}]}]"#).category, .lifr)
        XCTAssertEqual(try decode(#"[{"icaoId":"E"}]"#).category, .unknown)      // nothing to derive from
    }

    func testAirportSummaryAggregatesPilotData() {
        let s = AirportSummary.make("KBOS")
        XCTAssertEqual(s.ident, "KBOS")
        XCTAssertNotNil(s.elevationFt)
        XCTAssertEqual(s.patternAltFt, s.elevationFt.map { $0 + 1000 })   // TPA est = field elev + 1000
        XCTAssertFalse(s.keyFreqs.isEmpty)
        XCTAssertTrue(s.procedureTypes.contains("ILS"))
        XCTAssertTrue(s.procedureTypes.contains("RNAV (GPS)"))
        XCTAssertTrue(s.hasPlates)
    }
}
