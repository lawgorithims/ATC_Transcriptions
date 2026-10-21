import XCTest
@testable import ATCTranscribe

/// The bundled plate-georeference table reader, and the table's agreement with the plate index it
/// has to match. Uses the shipped `nav/plate_georef.json` (built by Tools/fetch_plates.py +
/// Tools/build_plate_georef_embedded.py). Skips gracefully if the resource isn't bundled in the
/// test host.
final class PlateGeorefTests: XCTestCase {

    func testTableLoads() throws {
        try XCTSkipIf(PlateGeoref.count == 0, "plate_georef.json not bundled in the test host")
        XCTAssertFalse(PlateGeoref.cycle.isEmpty, "a loaded table has a chart cycle")
    }

    func testBundledEntriesArePlausible() throws {
        try XCTSkipIf(PlateGeoref.count == 0, "plate_georef.json not bundled")
        // Every bundled entry comes from the FAA's embedded transform → it must pass the runtime
        // corruption guards (finite, sane page width, valid rotation, ≥3 control points).
        var checked = 0
        for pdf in bundledPDFs().prefix(80) {
            guard let g = PlateGeoref.lookup(pdf: pdf) else { continue }
            checked += 1
            XCTAssertTrue(g.isPlausible, "\(pdf): a bundled georef must be plausible")
            XCTAssertGreaterThan(g.widthMeters, 5_000, "\(pdf): implausibly small page")
            XCTAssertLessThan(g.widthMeters, 400_000, "\(pdf): implausibly large page")
            XCTAssertTrue(g.rotationDeg.isFinite, "\(pdf): finite rotation")
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
        XCTAssertTrue(e().isPlausible, "a nominal fit is plausible")
        XCTAssertTrue(e(rot: 35).isPlausible, "a legitimately-rotated (e.g. Alaska) plan view is valid — the FAA transform captures it exactly")
        XCTAssertFalse(e(w: .nan).isPlausible, "non-finite width")
        XCTAssertFalse(e(rot: .infinity).isPlausible, "non-finite rotation")
        XCTAssertFalse(e(lat: .infinity).isPlausible, "non-finite lat")
        XCTAssertFalse(e(lat: 95).isPlausible, "lat out of range")
        XCTAssertFalse(e(lon: 200).isPlausible, "lon out of range")
        XCTAssertFalse(e(w: 3_000).isPlausible, "page too small")
        XCTAssertFalse(e(w: 500_000).isPlausible, "page too large")
        XCTAssertFalse(e(rms: -1).isPlausible, "negative residual")
        XCTAssertFalse(e(inl: 2).isPlausible, "too few inliers")
    }

    // MARK: - Agreement with the bundled plate index

    /// ⚠️ THE DIRECTION THAT MISPLACES INSTEAD OF GAPPING.
    ///
    /// Every row is a page→ground transform read out of ONE cycle's plate PDF, and the app fetches the
    /// plate from `https://aeronav.faa.gov/d-tpp/<Procedures.cycle>/<pdf>`. Plate filenames are stable
    /// across cycles but their contents are not — `00001AD.PDF` was 142,831 bytes in 2607 and 164,419
    /// in 2610 — so a table built against a different cycle than the index hands the overlay a
    /// transform for geometry the pilot is not looking at. Measured on the 2607→2610 roll: of the 9,007
    /// plates in both tables, 24 had a transform that moved — 22 by over 500 m, 14 by over 2 km, the
    /// worst (`00095VA.PDF`) by 17.6 km on a ~68 km-wide page. `isPlausible` cannot catch any of them:
    /// the numbers are all perfectly in range.
    /// A stale row therefore puts ownship confidently in the wrong place, which is strictly worse than
    /// the honest "no georeference → hand-align" a missing row produces.
    func testTableCycleMatchesTheBundledPlateIndex() throws {
        try XCTSkipIf(PlateGeoref.count == 0, "plate_georef.json not bundled")
        let index = try bundledIndex()
        XCTAssertEqual(PlateGeoref.cycle, index.cycle,
                       "plate_georef.json is cycle \(PlateGeoref.cycle) but the bundled procedures.json "
                       + "is cycle \(index.cycle). The transforms describe a different cycle's PDFs than "
                       + "the ones the app will download, which MISPLACES the overlay rather than "
                       + "leaving a gap. Rebuild both from the same cycle "
                       + "(Tools/fetch_plates.py then Tools/build_plate_georef_embedded.py).")
    }

    /// A coverage FLOOR, so a partial build cannot quietly ship.
    ///
    /// The builder skips any plate it does not find in its PDF cache and reports it as "not-cached" on
    /// stdout — a count nobody reads after the fact. An interrupted download therefore produces a table
    /// that is valid, correctly shaped, internally consistent and *half empty*, and the only symptom is
    /// that pilots hand-align more plates than they used to. Nothing else in the suite would notice: the
    /// rows that are present are all perfect.
    ///
    /// Measured: cycle 2610 covers 9,987 of 11,140 IAPs (89.7%). The 1,153 that miss out carry no /VP
    /// viewport at all — the FAA did not publish them as geospatial PDFs, and they are overwhelmingly
    /// military and high-altitude charts (TACAN, HI-TACAN, HI-ILS, HI-VOR, COPTER). That is a real
    /// ceiling, not a build defect, and it moves: cycle 2607 reached only 80.9% of this same index.
    /// The floor sits below both so a cycle where the FAA regresses is not a red suite, but far enough
    /// above zero that a truncated cache is impossible to miss.
    func testCoverageOfTheBundledPlateIndexMeetsTheFloor() throws {
        try XCTSkipIf(PlateGeoref.count == 0, "plate_georef.json not bundled")
        let index = try bundledIndex()
        try XCTSkipIf(index.iapPDFs.isEmpty, "bundled procedures.json names no IAP plates")

        let georeferenced = index.iapPDFs.filter { PlateGeoref.lookup(pdf: $0) != nil }
        let fraction = Double(georeferenced.count) / Double(index.iapPDFs.count)
        let floor = 0.85

        XCTAssertGreaterThan(fraction, floor,
                             "only \(georeferenced.count) of \(index.iapPDFs.count) approach plates "
                             + String(format: "(%.1f%%) are georeferenced, below the %.0f%% floor. ",
                                      fraction * 100, floor * 100)
                             + "The builder treats an uncached plate as a silent skip, so this is what "
                             + "an interrupted download looks like — re-run Tools/fetch_plates.py until "
                             + "it exits 0, then rebuild.")
    }

    /// Rows for plates the index does not name are dead weight — 50 of them survived the 2607→2610 roll
    /// — and a growing pile of them is the sign of a table being patched instead of rebuilt.
    func testTableHasNoRowsForPlatesTheIndexDoesNotName() throws {
        try XCTSkipIf(PlateGeoref.count == 0, "plate_georef.json not bundled")
        let index = try bundledIndex()
        try XCTSkipIf(index.iapPDFs.isEmpty, "bundled procedures.json names no IAP plates")
        let orphans = Set(bundledPDFs()).subtracting(index.iapPDFs)
        XCTAssertTrue(orphans.isEmpty,
                      "\(orphans.count) rows reference plates the bundled index does not publish, "
                      + "e.g. \(orphans.sorted().prefix(5).joined(separator: ", ")) — rebuild the table "
                      + "from the current index rather than carrying rows forward.")
    }

    /// The cycle and the IAP plate filenames out of the BUNDLED procedures.json. Read straight from the
    /// bundle, not through `Procedures`, which resolves `NavDataUpdate.activeURL` and so could be
    /// answering from a downloaded index — the question here is what the two bundled files say.
    private func bundledIndex() throws -> (cycle: String, iapPDFs: Set<String>) {
        let url = try XCTUnwrap(NavDataUpdate.Dataset.procedures.bundledURL,
                                "procedures.json is not in the app bundle")
        let o = try XCTUnwrap(try JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any])
        let cycle = o["cycle"] as? String ?? ""
        var pdfs = Set<String>()
        for recs in (o["airports"] as? [String: [[String: String]]] ?? [:]).values {
            for r in recs where r["c"] == "IAP" {
                if let f = r["f"], !f.isEmpty { pdfs.insert(f) }
            }
        }
        return (cycle, pdfs)
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
