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

    func testRadarFramesAreOrderedPastThenForecastWithTimes() {
        let json = """
        { "host": "https://h",
          "radar": { "past": [ {"time": 100, "path": "/p/1"}, {"time": 200, "path": "/p/2"} ],
                     "nowcast": [ {"time": 300, "path": "/n/1"} ] } }
        """.data(using: .utf8)!
        let frames = RainViewerService.radarFrames(from: json)
        XCTAssertEqual(frames.count, 3)
        XCTAssertEqual(frames.map(\.isForecast), [false, false, true])   // observed first, forecast last
        XCTAssertEqual(frames.first?.time, Date(timeIntervalSince1970: 100))
        XCTAssertTrue(frames.last!.template.contains("/n/1/256/{z}/{x}/{y}"))
    }

    func testRadarFramesEmptyOnMalformed() {
        XCTAssertTrue(RainViewerService.radarFrames(from: Data("nope".utf8)).isEmpty)
    }

    func testParseLastModifiedHeader() {
        let d = WXImageCache.parseLastModified("Sun, 19 Jul 2026 23:45:59 GMT")
        XCTAssertNotNil(d)
        // Round-trips to the same GMT wall clock.
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "GMT")!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: d!)
        XCTAssertEqual(c.year, 2026); XCTAssertEqual(c.month, 7); XCTAssertEqual(c.day, 19)
        XCTAssertEqual(c.hour, 23); XCTAssertEqual(c.minute, 45)
        XCTAssertNil(WXImageCache.parseLastModified(nil))
        XCTAssertNil(WXImageCache.parseLastModified("garbage"))
    }
}
