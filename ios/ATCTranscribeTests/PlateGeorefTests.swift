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

    /// Every bundled row must pass the runtime corruption guards — and the bounds differ by KIND,
    /// because an approach plan view spans ~68 km and an airport diagram spans the airport. Checked
    /// over a sample of each half rather than the first 80 keys of a dictionary, whose order is
    /// arbitrary and could land entirely on one kind.
    func testBundledEntriesArePlausible() throws {
        try XCTSkipIf(PlateGeoref.count == 0, "plate_georef.json not bundled")
        var iaps = 0, apds = 0
        for pdf in bundledPDFs() where iaps < 80 || apds < 80 {
            guard let g = PlateGeoref.lookup(pdf: pdf) else { continue }
            XCTAssertTrue(g.isPlausible, "\(pdf): a bundled georef must be plausible")
            XCTAssertTrue(g.rotationDeg.isFinite, "\(pdf): finite rotation")
            switch g.kind {
            case .iap:
                guard iaps < 80 else { continue }
                iaps += 1
                XCTAssertGreaterThan(g.widthMeters, 5_000, "\(pdf): implausibly small approach page")
                XCTAssertLessThan(g.widthMeters, 400_000, "\(pdf): implausibly large approach page")
                XCTAssertGreaterThanOrEqual(g.inliers, 3, "\(pdf): needs ≥3 control points")
            case .apd:
                guard apds < 80 else { continue }
                apds += 1
                XCTAssertGreaterThan(g.widthMeters, 500, "\(pdf): implausibly small diagram page")
                XCTAssertLessThan(g.widthMeters, 50_000, "\(pdf): implausibly large diagram page")
                XCTAssertGreaterThanOrEqual(g.inliers, 2, "\(pdf): a diagram needs ≥1 matched runway")
            }
        }
        try XCTSkipIf(iaps == 0, "no bundled pdfs resolved")
        XCTAssertGreaterThan(iaps, 0)
        XCTAssertGreaterThan(apds, 0, "the table should carry airport diagrams as well as approaches")
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

    /// The same gate for an airport diagram, where the bounds are different ON PURPOSE. Running a
    /// diagram through the approach bounds is what would have rejected every small field: a
    /// single-runway diagram spans about 2 km, which `widthMeters > 5_000` calls implausible.
    func testPlausibilityGateUsesDiagramBoundsForDiagrams() {
        func apd(w: Double = 3_000, inl: Int = 4, rot: Double = -90) -> PlateGeorefEntry {
            PlateGeorefEntry(centerLat: 32.9, centerLon: -97.0, widthMeters: w,
                             rotationDeg: rot, rmsMeters: 3, inliers: inl, kind: .apd)
        }
        XCTAssertTrue(apd().isPlausible, "a nominal diagram fit is plausible")
        XCTAssertTrue(apd(w: 2_000).isPlausible,
                      "a single-runway field's diagram spans ~2 km and is perfectly valid — the "
                      + "approach-plate floor of 5 km would have thrown away every small airport")
        XCTAssertTrue(apd(inl: 2).isPlausible,
                      "two control points is ONE matched runway, which is what a single-runway "
                      + "airport has; the builder gates those on an independent drawn-width check")
        XCTAssertTrue(apd(rot: 180).isPlausible, "diagrams are routinely turned to fit the page")
        XCTAssertFalse(apd(w: 300).isPlausible, "smaller than any airport")
        XCTAssertFalse(apd(w: 80_000).isPlausible, "that is an approach plan view, not a diagram")
        XCTAssertFalse(apd(inl: 1).isPlausible, "one control point cannot fix a similarity")
        XCTAssertFalse(apd(w: .nan).isPlausible, "non-finite width")
    }

    /// An unknown `kind` in the table must read as the STRICTER bounds, not the looser ones. A future
    /// chart type nobody here has seen gets held to the approach-plate test rather than waved through
    /// on the diagram one.
    func testUnknownKindFallsBackToTheStricterBounds() {
        let e = PlateGeorefEntry(centerLat: 32.9, centerLon: -97.0, widthMeters: 2_000,
                                 rotationDeg: 0, rmsMeters: 3, inliers: 2)
        XCTAssertEqual(e.kind, .iap, "the default is the strict kind")
        XCTAssertFalse(e.isPlausible, "2 km page + 2 control points passes only the diagram bounds")
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

    // MARK: - The airport-diagram half

    /// A coverage floor for the diagrams, on the same reasoning as the approach one above: the
    /// builder treats an uncached PDF as a silent skip, so a truncated fetch yields a table that is
    /// valid, consistent and missing half the airports, and the only symptom is a feature quietly
    /// not appearing. Measured on 2611: 891 of 925 (96.3%). The floor sits well below that so a
    /// cycle where more diagrams fail the fit's own gates is not a red suite.
    func testAirportDiagramCoverageMeetsTheFloor() throws {
        try XCTSkipIf(PlateGeoref.count == 0, "plate_georef.json not bundled")
        let index = try bundledIndex()
        try XCTSkipIf(index.apdPDFs.isEmpty, "bundled procedures.json names no airport diagrams")

        let got = index.apdPDFs.filter { PlateGeoref.lookup(pdf: $0) != nil }
        let fraction = Double(got.count) / Double(index.apdPDFs.count)
        let floor = 0.85
        XCTAssertGreaterThan(fraction, floor,
                             "only \(got.count) of \(index.apdPDFs.count) airport diagrams "
                             + String(format: "(%.1f%%) are georeferenced, below the %.0f%% floor. ",
                                      fraction * 100, floor * 100)
                             + "Re-run Tools/fetch_plates.py, then Tools/build_apd_georef.py.")
    }

    /// ⚠️ THE ONE THAT WOULD CATCH A SILENT REGRESSION TO THE OLD BEHAVIOUR. Before the diagram
    /// builder existed, `lookup` returned nil for every APD — and nil is what hides the ownship dot,
    /// the ADS-B traffic and "Overlay on map" on the one chart a pilot reads while the aircraft is
    /// moving on the ground. That failure is invisible: the app simply does not offer the feature,
    /// exactly as it would if the pilot had opened a chart that genuinely has no transform.
    func testTheKDFWAirportDiagramIsGeoreferenced() throws {
        try XCTSkipIf(PlateGeoref.count == 0, "plate_georef.json not bundled")
        let index = try bundledIndex()
        try XCTSkipIf(index.apdPDFs.isEmpty, "bundled procedures.json names no airport diagrams")
        // 06039AD.PDF is KDFW's diagram in cycle 2611. If the cycle rolled and the filename moved,
        // skip rather than fail — the floor test above is what guards coverage.
        try XCTSkipIf(!index.apdPDFs.contains("06039AD.PDF"), "KDFW's diagram is not in this cycle")
        let g = try XCTUnwrap(PlateGeoref.lookup(pdf: "06039AD.PDF"),
                              "KDFW's airport diagram has no georeference, so the app will not plot "
                              + "ownship or traffic on it and will not offer 'Overlay on map'.")
        XCTAssertEqual(g.kind, .apd)
        // The page spans the airport, not an approach: DFW is about 6.8 km across its diagram.
        XCTAssertGreaterThan(g.widthMeters, 3_000)
        XCTAssertLessThan(g.widthMeters, 15_000)
        // The diagram is turned a quarter turn to fit DFW's north-south runways on a portrait page,
        // and the SIGN of that is the whole correctness question — see the note in
        // Tools/build_apd_georef.py. A ±90° page read as ∓90° misplaces ownship by kilometres.
        XCTAssertEqual(abs(g.rotationDeg), 90, accuracy: 1.0)

        // Ownship at the airport reference point must land inside the page, near its middle.
        let size = CGSize(width: 387.4, height: 594)
        let pt = try XCTUnwrap(g.pagePoint(lat: g.centerLat, lon: g.centerLon, pageSize: size))
        XCTAssertEqual(pt.x, size.width / 2, accuracy: 1)
        XCTAssertEqual(pt.y, size.height / 2, accuracy: 1)
    }

    /// ⚠️ THE TEST THAT CATCHES A FLIPPED ROTATION SIGN, which is the single most dangerous thing
    /// that can go wrong in this table and the thing that was in fact wrong in the builder.
    ///
    /// Note what does NOT catch it. `abs(rotationDeg) == 90` passes either way. So does the SEPARATION
    /// between two thresholds: measured on KDFW's 17C/35C, both signs give 232.0 page points, because
    /// mirroring a transform preserves distance. So does "the point is somewhere on the page". What
    /// the sign actually changes is WHICH WAY ROUND the airport is drawn — and that is checkable
    /// against the chart itself, because KDFW's diagram prints "17C" near the left edge of the page
    /// (x ≈ 36 of 387) and "35C" near the right (x ≈ 338).
    ///
    /// So: the north end of the runway must come out on the LEFT. As published, 17C lands at x 71 and
    /// 35C at x 303. With the rotation negated they swap to 316 and 84 — both still on the page, both
    /// still 232 points apart, and the pilot's own aircraft on the wrong half of the airport.
    func testKDFWRunwayIsDrawnTheRightWayRoundOnThePage() throws {
        try XCTSkipIf(PlateGeoref.count == 0, "plate_georef.json not bundled")
        guard let g = PlateGeoref.lookup(pdf: "06039AD.PDF") else {
            throw XCTSkip("KDFW's diagram is not in this cycle")
        }
        let size = CGSize(width: 387.4, height: 594)
        // Both thresholds of RWY 17C/35C, read out of the FAA's APT_RWY_END survey (nav/apt.sqlite).
        // 17C is the NORTH end (lat 32.9157); 35C is the south end (lat 32.8789).
        let north = try XCTUnwrap(g.pagePoint(lat: 32.91570669, lon: -97.02597491, pageSize: size),
                                  "a threshold on the field must fall inside the diagram's page")
        let south = try XCTUnwrap(g.pagePoint(lat: 32.87887877, lon: -97.02617166, pageSize: size),
                                  "a threshold on the field must fall inside the diagram's page")
        for pt in [north, south] {
            XCTAssertTrue((0...size.width).contains(pt.x), "x on page: \(pt.x)")
            XCTAssertTrue((0...size.height).contains(pt.y), "y on page: \(pt.y)")
        }

        XCTAssertLessThan(north.x, south.x,
                          "KDFW's diagram is turned a quarter turn and prints 17C at the LEFT of the "
                          + "page and 35C at the right. The north end coming out on the right means "
                          + "the clockwise/counter-clockwise rotation convention has been flipped "
                          + "somewhere, which mirrors the whole airport about its centre — see the "
                          + "rotation note in Tools/build_apd_georef.py.")

        // The page separation has to match the runway: 13,400 ft is 4,084 m, and the diagram's scale
        // is widthMeters/pageWidth. This is what catches a scale error, which the ordering above
        // cannot see.
        let metresPerPoint = g.widthMeters / Double(size.width)
        let expected = 13_400 * 0.3048 / metresPerPoint
        XCTAssertEqual(Double(hypot(north.x - south.x, north.y - south.y)), expected, accuracy: 6,
                       "the two thresholds should be one runway length apart on the page")
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
        let orphans = Set(bundledPDFs()).subtracting(index.iapPDFs).subtracting(index.apdPDFs)
        XCTAssertTrue(orphans.isEmpty,
                      "\(orphans.count) rows reference plates the bundled index does not publish, "
                      + "e.g. \(orphans.sorted().prefix(5).joined(separator: ", ")) — rebuild the table "
                      + "from the current index rather than carrying rows forward.")
    }

    /// The cycle and the IAP plate filenames out of the BUNDLED procedures.json. Read straight from the
    /// bundle, not through `Procedures`, which resolves `NavDataUpdate.activeURL` and so could be
    /// answering from a downloaded index — the question here is what the two bundled files say.
    private func bundledIndex() throws -> (cycle: String, iapPDFs: Set<String>, apdPDFs: Set<String>) {
        let url = try XCTUnwrap(NavDataUpdate.Dataset.procedures.bundledURL,
                                "procedures.json is not in the app bundle")
        let o = try XCTUnwrap(try JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any])
        let cycle = o["cycle"] as? String ?? ""
        var iaps = Set<String>(), apds = Set<String>()
        for recs in (o["airports"] as? [String: [[String: String]]] ?? [:]).values {
            for r in recs {
                guard let f = r["f"], !f.isEmpty else { continue }
                if r["c"] == "IAP" { iaps.insert(f) }
                if r["c"] == "APD" { apds.insert(f) }
            }
        }
        return (cycle, iaps, apds)
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
