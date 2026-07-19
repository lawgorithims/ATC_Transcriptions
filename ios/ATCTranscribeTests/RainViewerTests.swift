import XCTest
@testable import ATCTranscribe

/// The pure parse of RainViewer's weather-maps.json → the newest radar frame's {z}/{x}/{y} tile template.
final class RainViewerTests: XCTestCase {

    func testLatestRadarTemplatePrefersNowcastTip() {
        let json = """
        { "host": "https://tilecache.rainviewer.com",
          "radar": { "past": [ {"time": 1, "path": "/v2/radar/aaa"}, {"time": 2, "path": "/v2/radar/bbb"} ],
                     "nowcast": [ {"time": 3, "path": "/v2/radar/ccc"} ] } }
        """.data(using: .utf8)!
        let t = RainViewerService.latestRadarTemplate(from: json)
        XCTAssertEqual(t, "https://tilecache.rainviewer.com/v2/radar/ccc/256/{z}/{x}/{y}/2/1_1.png")
    }

    func testFallsBackToLatestPastWhenNoNowcast() {
        let json = """
        { "host": "https://h", "radar": { "past": [ {"time": 1, "path": "/p/1"}, {"time": 2, "path": "/p/2"} ] } }
        """.data(using: .utf8)!
        let t = RainViewerService.latestRadarTemplate(from: json)
        XCTAssertEqual(t, "https://h/p/2/256/{z}/{x}/{y}/2/1_1.png")   // newest past frame, and a real {z}/{x}/{y}
        XCTAssertTrue(t!.contains("{z}/{x}/{y}"))
    }

    func testNilOnEmptyOrMalformed() {
        XCTAssertNil(RainViewerService.latestRadarTemplate(from: Data("{}".utf8)))
        XCTAssertNil(RainViewerService.latestRadarTemplate(from: Data(#"{"host":"h","radar":{"past":[]}}"#.utf8)))
        XCTAssertNil(RainViewerService.latestRadarTemplate(from: Data("not json".utf8)))
    }
}
