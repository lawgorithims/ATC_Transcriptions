import XCTest
@testable import ATCTranscribe

/// The bundled plate-georeference table reader. Uses the shipped `nav/plate_georef.json` (built by
/// Tools/build_plate_georef). Skips gracefully if the resource isn't bundled in the test host.
final class PlateGeorefTests: XCTestCase {

    func testTableLoads() throws {
        try XCTSkipIf(PlateGeoref.count == 0, "plate_georef.json not bundled in the test host")
        XCTAssertFalse(PlateGeoref.cycle.isEmpty, "a loaded table has a chart cycle")
    }

    func testLookupReturnsPlausibleNorthUpPlacement() throws {
        try XCTSkipIf(PlateGeoref.count == 0, "plate_georef.json not bundled")
        // Any entry in the table is a HIGH-CONFIDENCE fit: north-up (rotation ≈ 0), a sane page width,
        // and a low residual. Assert those invariants hold for every bundled entry.
        // (We don't hardcode a specific pdf — the bundled cycle changes.)
        var checked = 0
        for pdf in bundledPDFs().prefix(50) {
            guard let g = PlateGeoref.lookup(pdf: pdf) else { continue }
            checked += 1
            XCTAssertLessThan(abs(PlateSimilarity.normalizeDeg(g.rotationDeg)), 12,
                              "\(pdf): a bundled georef must be north-up")
            XCTAssertGreaterThan(g.widthMeters, 8_000, "\(pdf): implausibly small page")
            XCTAssertLessThan(g.widthMeters, 250_000, "\(pdf): implausibly large page")
            XCTAssertLessThan(g.rmsMeters, 250, "\(pdf): a bundled georef must be a tight fit")
            XCTAssertGreaterThanOrEqual(g.inliers, 3, "\(pdf): needs ≥3 control points")
        }
        try XCTSkipIf(checked == 0, "no bundled pdfs resolved")
        XCTAssertGreaterThan(checked, 0)
    }

    func testUnknownPdfReturnsNil() {
        XCTAssertNil(PlateGeoref.lookup(pdf: "ZZ_NOT_A_REAL_PLATE_99.PDF"))
    }

    /// The world→PDF-page mapping used to plot ownship/traffic on a plate: the georef center lands at
    /// the page center; a point far outside the page returns nil.
    func testPagePointMapsCenterAndRejectsFarPoints() throws {
        let e = PlateGeorefEntry(centerLat: 42.36, centerLon: -71.01, widthMeters: 30_000,
                                 rotationDeg: 0, rmsMeters: 50, inliers: 4)
        let size = CGSize(width: 600, height: 800)
        let center = try XCTUnwrap(e.pagePoint(lat: 42.36, lon: -71.01, pageSize: size))
        XCTAssertEqual(center.x, 300, accuracy: 0.5, "center world → page center x")
        XCTAssertEqual(center.y, 400, accuracy: 0.5, "center world → page center y")
        // ~150 km away is well off a 30 km-wide page.
        XCTAssertNil(e.pagePoint(lat: 43.7, lon: -71.01, pageSize: size))
        // An implausible entry never yields a point.
        let bad = PlateGeorefEntry(centerLat: 42.36, centerLon: -71.01, widthMeters: .nan,
                                   rotationDeg: 0, rmsMeters: 50, inliers: 4)
        XCTAssertNil(bad.pagePoint(lat: 42.36, lon: -71.01, pageSize: size))
    }

    /// The runtime plausibility gate (F1): `lookup` must fail closed on any out-of-range / non-finite
    /// stored entry so a corrupted or stale table can never place a mis-scaled/rotated plate. Test the
    /// predicate directly (we can't inject a bad row into the bundled table).
    func testPlausibilityGateRejectsBadEntries() {
        func e(lat: Double = 42, lon: Double = -71, w: Double = 30_000, rot: Double = 0,
               rms: Double = 50, inl: Int = 4) -> PlateGeorefEntry {
            PlateGeorefEntry(centerLat: lat, centerLon: lon, widthMeters: w, rotationDeg: rot, rmsMeters: rms, inliers: inl)
        }
        XCTAssertTrue(e().isPlausible, "a nominal north-up fit is plausible")
        XCTAssertTrue(e(rot: -11.9).isPlausible)
        XCTAssertFalse(e(w: .nan).isPlausible, "non-finite width")
        XCTAssertFalse(e(lat: .infinity).isPlausible, "non-finite lat")
        XCTAssertFalse(e(lat: 95).isPlausible, "lat out of range")
        XCTAssertFalse(e(lon: 200).isPlausible, "lon out of range")
        XCTAssertFalse(e(w: 5_000).isPlausible, "page too small")
        XCTAssertFalse(e(w: 300_000).isPlausible, "page too large")
        XCTAssertFalse(e(rot: 25).isPlausible, "not north-up")
        XCTAssertFalse(e(rot: -30).isPlausible, "not north-up")
        XCTAssertFalse(e(rms: 400).isPlausible, "residual too high")
        XCTAssertFalse(e(rms: -1).isPlausible, "negative residual")
        XCTAssertFalse(e(inl: 2).isPlausible, "too few inliers")
    }

    /// Read the pdf keys straight out of the bundled JSON (independent of the reader under test).
    private func bundledPDFs() -> [String] {
        guard let url = Bundle.main.url(forResource: "plate_georef", withExtension: "json", subdirectory: "nav")
                ?? Bundle.main.url(forResource: "plate_georef", withExtension: "json"),
              let d = try? Data(contentsOf: url),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let plates = o["plates"] as? [String: Any] else { return [] }
        return Array(plates.keys)
    }
}
