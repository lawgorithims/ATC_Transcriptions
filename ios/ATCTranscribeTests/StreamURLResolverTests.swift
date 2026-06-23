import XCTest
@testable import ATCTranscribe

/// Parity with `atc_stream.resolve_stream_url` / `candidate_stream_urls` /
/// `_extract_liveatc_mount` (fixtures from the Python). Pure logic — runs on the Simulator.
final class StreamURLResolverTests: XCTestCase {
    func testResolveHlistenPage() throws {
        XCTAssertEqual(
            try StreamURLResolver.normalize("https://www.liveatc.net/hlisten.php?icao=kdfw&mount=kdfw1_app_fin_17c"),
            "https://d.liveatc.net/kdfw1_app_fin_17c")
    }

    func testDirectURLUnchanged() throws {
        XCTAssertEqual(try StreamURLResolver.normalize("https://d.liveatc.net/kdfw1_app_fin_17c"),
                       "https://d.liveatc.net/kdfw1_app_fin_17c")
    }

    func testExtractMount() {
        XCTAssertEqual(
            StreamURLResolver.extractMount("https://www.liveatc.net/hlisten.php?icao=kdfw&mount=kdfw1_app_fin_17c"),
            "kdfw1_app_fin_17c")
    }

    func testCandidateExpansion() {
        let c = StreamURLResolver.candidateURLs("https://d.liveatc.net/kdfw1_app_fin_17c")
        XCTAssertEqual(c.count, 8)
        XCTAssertEqual(c.first, "https://d.liveatc.net/kdfw1_app_fin_17c")
        XCTAssertEqual(c.last, "https://s1-lax.liveatc.net/kdfw1_app_fin_17c")
        XCTAssertTrue(c.allSatisfy { $0.hasSuffix("/kdfw1_app_fin_17c") })
    }

    func testInvalidThrows() {
        XCTAssertThrowsError(try StreamURLResolver.normalize("not a url"))
    }

    func testResolveFromConfig() throws {
        let cfg = try AirportConfig.decode(Data(#"{"streams":{"f":{"url":"https://d.liveatc.net/kjfk_twr"}}}"#.utf8))
        XCTAssertEqual(try StreamURLResolver.resolve(config: cfg, feedKey: "f"), "https://d.liveatc.net/kjfk_twr")
    }
}
