import XCTest
@testable import ATCTranscribe

/// The map must never come up on MapLibre's default (demotiles) style.
///
/// Two separate failures came from it: an offline-first EFB fetching a third-party basemap on every
/// launch, and an intermittent SIGSEGV on a MapLibre tile-worker thread — the demo style's VECTOR
/// tiles were still being parsed when the real (loopback) style replaced them, and
/// `mbgl::LayerManager::createLayout` dereferences a null layer factory in release builds. A
/// source-less local bootstrap style closes both: nothing to fetch, and no parse in flight to
/// invalidate.
final class BootstrapStyleTests: XCTestCase {

    private func bootstrapJSON(globe: Bool, theme: MapTheme) throws -> String {
        let url = MapLibreChartView.Coordinator.bootstrapStyleURLForTests(globe: globe, theme: theme)
        if url.isFileURL { return try String(contentsOf: url, encoding: .utf8) }
        // data: fallback (write failed) — decode the payload back out.
        let payload = url.absoluteString.components(separatedBy: ",").dropFirst().joined(separator: ",")
        return payload.removingPercentEncoding ?? ""
    }

    func testBootstrapStyleOwnsNoSourcesAndTouchesNoNetwork() throws {
        for theme in [AppTheme.cockpit, .day, .night] {
            let json = try bootstrapJSON(globe: false, theme: MapTheme.forTheme(theme))
            XCTAssertTrue(json.contains("\"sources\": {}"),
                          "\(theme): a source means tiles, and tiles in flight are the crash window")
            XCTAssertFalse(json.lowercased().contains("http"),
                           "\(theme): the bootstrap style must reference no URL at all")
            XCTAssertFalse(json.lowercased().contains("demotiles"), "\(theme): the demo basemap must never appear")
            XCTAssertFalse(json.contains("\"glyphs\""), "\(theme): glyphs are a fetch too")
            XCTAssertTrue(json.contains("\"version\": 8"), "\(theme): must still be a valid style")
            XCTAssertTrue(json.contains("background-color"), "\(theme): one background layer is the whole style")
        }
    }

    /// The bootstrap is FLAT on both projections. The first version carried `projection: globe` so the
    /// globe would "boot already spherical" — and the globe fork then never drew its sphere at all: the
    /// fork builds the ocean and the Blue Marble backstop when a style install CHANGES the projection to
    /// globe, and a globe bootstrap spent that change on a style about to be thrown away. Charts floated
    /// on black space (sea RGB 2,4,7). Under the globe the bootstrap paints the void colour instead.
    func testTheBootstrapIsFlatEvenOnTheGlobe() throws {
        let theme = MapTheme.forTheme(.cockpit)
        let flat = try bootstrapJSON(globe: false, theme: theme)
        let globe = try bootstrapJSON(globe: true, theme: theme)
        XCTAssertFalse(flat.contains("projection"), "mercator must stay flat")
        XCTAssertFalse(globe.contains("projection"),
                       "a globe bootstrap leaves the real style's sphere undrawn — the bootstrap must be flat")
        XCTAssertTrue(flat.contains(MapTheme.hexString(theme.sea)), "mercator boots on its own sea colour")
        XCTAssertTrue(globe.contains(MapTheme.hexString(theme.space)),
                      "under the globe the bootstrap paints the void the sphere appears in, not an ocean")
    }

    /// The real style is unchanged by this work: it still carries the loopback FAA raster + glyphs.
    func testRealStyleStillUsesTheLoopbackServerOnly() throws {
        let url = try XCTUnwrap(MapLibreChartView.Coordinator.styleURLForTests(port: 8137, globe: false,
                                                                              theme: MapTheme.forTheme(.cockpit)))
        let json = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(json.contains("http://127.0.0.1:8137/"), "chart tiles come from the loopback server")
        XCTAssertFalse(json.lowercased().contains("demotiles"))
        // Every http reference must be loopback — no third-party host may sneak into the offline style.
        for line in json.components(separatedBy: .newlines) where line.lowercased().contains("http") {
            XCTAssertTrue(line.contains("127.0.0.1"), "non-loopback URL in the offline style: \(line)")
        }
    }
}
