import XCTest
@testable import ATCTranscribe

/// Parser tests for the `/lz/<sig>/{z}/{x}/{y}` route.
///
/// The route carries the aircraft signature in the PATH rather than a query string, because the
/// server's tile parser splits on "/" and ".". A signature containing a dot — a version string like
/// "1.2", say — would be silently truncated and every tile would be served under the wrong key.
/// These tests pin the shape so that cannot regress.
final class LZServerRouteTests: XCTestCase {

    func testAcceptsAWellFormedPath() throws {
        let (sig, z, x, y) = try XCTUnwrap(MBTilesHTTPServer.lzPath("/lz/a1b2c3d4e5f60718/13/1661/3299"))
        XCTAssertEqual(sig, "a1b2c3d4e5f60718")
        XCTAssertEqual(z, 13); XCTAssertEqual(x, 1661); XCTAssertEqual(y, 3299)
    }

    func testAcceptsAnExtensionSuffix() throws {
        let got = try XCTUnwrap(MBTilesHTTPServer.lzPath("/lz/00ff/6/13/27.png"))
        XCTAssertEqual(got.0, "00ff")
        XCTAssertEqual(got.3, 27)
    }

    func testRejectsAMissingOrEmptySignature() {
        XCTAssertNil(MBTilesHTTPServer.lzPath("/lz/13/1661/3299"))
        XCTAssertNil(MBTilesHTTPServer.lzPath("/lz//13/1661/3299"))
    }

    /// The reason the signature is lowercase hex: anything else can carry a separator this parser
    /// treats as structure.
    func testRejectsANonHexOrDottedSignature() {
        XCTAssertNil(MBTilesHTTPServer.lzPath("/lz/2026.08.1/13/1661/3299"),
                     "a dotted version would be split by the '.' handling")
        XCTAssertNil(MBTilesHTTPServer.lzPath("/lz/A1B2C3/13/1661/3299"), "uppercase is not our form")
        XCTAssertNil(MBTilesHTTPServer.lzPath("/lz/not-hex/13/1661/3299"))
    }

    func testRejectsNonNumericOrOutOfRangeAddresses() {
        XCTAssertNil(MBTilesHTTPServer.lzPath("/lz/00ff/x/1661/3299"))
        XCTAssertNil(MBTilesHTTPServer.lzPath("/lz/00ff/40/1/1"), "zoom beyond any real pack")
        XCTAssertNil(MBTilesHTTPServer.lzPath("/lz/00ff/-1/1/1"))
        // x or y outside the zoom's grid is a malformed address, not an empty tile.
        XCTAssertNil(MBTilesHTTPServer.lzPath("/lz/00ff/2/9/1"))
        XCTAssertNil(MBTilesHTTPServer.lzPath("/lz/00ff/2/1/9"))
    }

    func testRejectsOtherRoutes() {
        XCTAssertNil(MBTilesHTTPServer.lzPath("/13/1661/3299"))
        XCTAssertNil(MBTilesHTTPServer.lzPath("/sat/13/1661/3299"))
        XCTAssertNil(MBTilesHTTPServer.lzPath("/base/vfr/13/1661/3299"))
        XCTAssertNil(MBTilesHTTPServer.lzPath("/font/DIN/0-255.pbf"))
    }

    /// A real compiled signature must survive the parser unchanged — the contract between the
    /// compiler's alphabet and the route's alphabet, checked end to end rather than by eyeball.
    func testACompiledSignatureIsRoutable() throws {
        let doc = try XCTUnwrap(LZRulesetCompiler.loadDocument(bundle: Bundle(for: Self.self))
                                ?? LZRulesetCompiler.loadDocument(bundle: .main))
        let rules = try XCTUnwrap(LZRulesetCompiler.compile(document: doc, aircraft: nil,
                                                            themeKey: "day", packStamp: "p"))
        let parsed = try XCTUnwrap(
            MBTilesHTTPServer.lzPath("/lz/\(rules.signature)/13/1661/3299"),
            "the compiler produced a signature the route cannot carry")
        XCTAssertEqual(parsed.0, rules.signature)
    }
}
