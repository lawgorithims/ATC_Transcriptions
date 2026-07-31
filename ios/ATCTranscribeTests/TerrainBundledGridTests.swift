import XCTest
@testable import ATCTranscribe

/// Tests the REAL bundled terrain grid — not a synthetic fixture.
///
/// `TerrainElevationTests` proves the reader's logic against a grid it builds itself; this proves the
/// artifact that actually ships. It is the only thing standing between a silent packaging or build-script
/// regression (grid missing from the bundle, axes transposed, datum changed, units switched to feet) and
/// an AGL readout that is confidently wrong in flight. Every expected value below is an independently
/// known field elevation, not a number this code produced.
final class TerrainBundledGridTests: XCTestCase {

    private var terrain: TerrainElevation { TerrainElevation.shared }

    /// Known ground elevations in metres. The grid is a max-aggregated SURFACE model on ~1 NM cells, so
    /// it reads at or slightly above field elevation at an airport (buildings, and the highest ground in
    /// the cell). Sharp summits used to read hundreds of feet LOW until the build's summit-refinement
    /// pass; the western high peaks now recover to within ~35 ft, which these tolerances now PIN so a
    /// regression that dropped the refinement (or re-smoothed a peak) fails here. Tolerances reflect the
    /// measured accuracy, not a number widened until the test passes.
    private let sites: [(name: String, lat: Double, lon: Double, truthM: Double, tolM: Double)] = [
        ("KDEN Denver",      39.8617, -104.6731, 1656, 60),
        ("KDFW Dallas",      32.8998,  -97.0403,  185, 60),
        ("KMIA Miami",       25.7959,  -80.2870,    3, 40),
        ("KMSY New Orleans", 29.9934,  -90.2580,    1, 40),
        ("KLAS Las Vegas",   36.0840, -115.1537,  665, 80),
        ("KSEA Seattle",     47.4502, -122.3088,  132, 60),
        // Refined summits — tolerances now tight (were 250 m); a lost refinement pass fails these.
        ("Mt Whitney",       36.5785, -118.2923, 4421, 40),
        ("Grand Teton",      43.7412, -110.8024, 4199, 40),   // was -528 ft before refinement
        ("Mt Rainier",       46.8528, -121.7603, 4392, 40),
        ("Granite Pk MT",    45.1633, -109.8074, 3901, 40),   // was -394 ft before refinement
    ]

    func testBundledGridIsLoaded() {
        XCTAssertEqual(terrain.status, .ready,
                       "the terrain grid must ship in the app bundle — a packaging regression disables AGL")
    }

    func testKnownElevationsMatchRealWorld() throws {
        try XCTSkipUnless(terrain.status == .ready, "no bundled grid")
        for s in sites {
            let got = try XCTUnwrap(terrain.elevationM(at: Coord(lat: s.lat, lon: s.lon)),
                                    "\(s.name) is inside CONUS and must have coverage")
            XCTAssertEqual(got, s.truthM, accuracy: s.tolM,
                           "\(s.name): grid \(got) m vs known \(s.truthM) m")
        }
    }

    /// A transposed or flipped grid would still return plausible-looking numbers, so this pins the axes
    /// with sites whose elevations are very different in each direction: Denver is high and inland,
    /// Miami is at sea level in the far south-east, Seattle is low in the far north-west.
    func testAxesAreNotFlippedOrTransposed() throws {
        try XCTSkipUnless(terrain.status == .ready, "no bundled grid")
        let denver = try XCTUnwrap(terrain.elevationM(at: Coord(lat: 39.8617, lon: -104.6731)))
        let miami = try XCTUnwrap(terrain.elevationM(at: Coord(lat: 25.7959, lon: -80.2870)))
        let seattle = try XCTUnwrap(terrain.elevationM(at: Coord(lat: 47.4502, lon: -122.3088)))
        XCTAssertGreaterThan(denver, 1200, "Denver must be mile-high; a flipped axis would not be")
        XCTAssertLessThan(miami, 60, "Miami must be near sea level")
        XCTAssertLessThan(seattle, 300, "Seattle must be low")
        XCTAssertGreaterThan(denver - miami, 1000, "the west-east elevation gradient must survive")
    }

    /// Ocean must read sea level, not bathymetry. The raw source carries depths to -5900 m, and leaving
    /// them in would make AGL over water read thousands of feet too high — the dangerous direction.
    func testOceanReadsSeaLevelNotBathymetry() throws {
        try XCTSkipUnless(terrain.status == .ready, "no bundled grid")
        let atlantic = try XCTUnwrap(terrain.elevationM(at: Coord(lat: 39.0, lon: -70.0)))
        let gulf = try XCTUnwrap(terrain.elevationM(at: Coord(lat: 26.0, lon: -90.0)))
        XCTAssertEqual(atlantic, 0, accuracy: 1, "deep ocean must clamp to sea level")
        XCTAssertEqual(gulf, 0, accuracy: 1, "the Gulf must clamp to sea level")
    }

    /// No cell may exceed the highest ground in the grid's own bbox by a meaningful margin. This is the
    /// regression test for the source spikes (a verified 6512 m artifact in Wyoming) — a spike makes AGL
    /// read far too LOW and would fire a false "you are about to hit the ground".
    func testNoImplausibleSpikes() throws {
        try XCTSkipUnless(terrain.status == .ready, "no bundled grid")
        // Sample a coarse lattice across CONUS rather than the whole 5.5M-cell grid (bounded, rule 2).
        var worst = (v: -9999.0, lat: 0.0, lon: 0.0)
        for latI in stride(from: 250, through: 495, by: 5) {           // 25.0 .. 49.5 N
            for lonI in stride(from: -1245, through: -670, by: 5) {    // -124.5 .. -67.0 E
                let lat = Double(latI) / 10, lon = Double(lonI) / 10
                if let v = terrain.elevationM(at: Coord(lat: lat, lon: lon)), v > worst.v {
                    worst = (v, lat, lon)
                }
            }
        }
        XCTAssertLessThan(worst.v, 4425,
                          "highest sampled cell \(worst.v) m at \(worst.lat),\(worst.lon) — nothing in CONUS exceeds Whitney (4421 m); a value above it is a source artifact the refinement's plausibility clamp must reject")
        XCTAssertGreaterThan(worst.v, 3000, "the sample lattice should still find real mountains")
    }

    /// Ceiling tripwire — the refinement maxes zoom-13 pixels in, and one corrupt/no-data pixel decodes
    /// to ~32767 m under the Terrarium formula. Maxing that in would poison a cell in the unsafe direction
    /// (terrain too high -> AGL too low -> a false ground-proximity reading). The build script's
    /// plausibility clamp is the real guarantee; this is a regression tripwire that samples a dense
    /// lattice (every ~1.8 cells) so a systemic reintroduction of the artifact fails loudly.
    func testNoCellExceedsConusCeiling() throws {
        try XCTSkipUnless(terrain.status == .ready, "no bundled grid")
        var maxSeen = -9999.0
        for latMilli in stride(from: 24_000, through: 50_000, by: 30) {        // 0.03° steps (~1.8 cells)
            for lonMilli in stride(from: -125_000, through: -66_000, by: 30) {
                if let v = terrain.elevationM(at: Coord(lat: Double(latMilli) / 1000, lon: Double(lonMilli) / 1000)) {
                    maxSeen = max(maxSeen, v)
                }
            }
        }
        XCTAssertLessThanOrEqual(maxSeen, 4425, "a cell above the CONUS ceiling is a refinement artifact")
    }

    /// LOCAL plausibility, which the two GLOBAL ceiling tests above cannot see.
    ///
    /// `testNoImplausibleSpikes` and `testNoCellExceedsConusCeiling` both ask only "is anything taller
    /// than Whitney". A phantom 475 m cell on Nantucket — where the true high ground is about 35 m —
    /// passes both of them trivially, and that is exactly the artifact that shipped: NRST sweeps this
    /// grid, so a 1,558 ft reading beside a sea-level island field turns the only airport within glide of
    /// an offshore engine failure into a hard BLOCKED verdict.
    ///
    /// Islands and low coastal plains are the right place to assert this because their truth is known and
    /// flat. Deliberately NOT a general "no cell exceeds its neighbourhood" rule: real coastal summits
    /// (Cadillac Mountain rises 456 m almost from the water) would fail that, and a test that can be made
    /// to pass by deleting real terrain is worse than no test.
    func testLowCountryHasNoPhantomTerrain() throws {
        try XCTSkipUnless(terrain.status == .ready, "no bundled grid")
        // (name, lat range, lon range, true high ground in metres — generous)
        // Ceilings are BARE-EARTH truth plus headroom for what this grid actually is: a max-aggregated
        // SURFACE model, so a ~1 NM cell legitimately carries the tallest tree, tower or building in it.
        // They are set to catch the class of artifact that shipped — Nantucket read 475 m and Martha's
        // Vineyard 289 m against real high ground of 33 m and 95 m — not to assert bare earth, which this
        // grid does not claim to be. A regression to that magnitude fails loudly; surface clutter does not.
        let flatPlaces: [(String, ClosedRange<Double>, ClosedRange<Double>, Double)] = [
            ("Nantucket",         41.23...41.32, (-70.25)...(-69.96), 110),   // true high ground 33 m
            ("Martha's Vineyard", 41.34...41.44, (-70.78)...(-70.45), 140),   // Peaked Hill 95 m
            ("Outer Banks NC",    35.20...35.95, (-75.75)...(-75.45),  70),   // Jockey's Ridge 30 m
            ("Everglades FL",     25.40...26.10, (-81.20)...(-80.60),  90),   // essentially 3 m
            ("Mississippi Delta", 29.20...29.80, (-90.20)...(-89.40),  95),   // essentially 5 m
        ]
        for (name, lats, lons, ceiling) in flatPlaces {
            var worst = (v: -9999.0, lat: 0.0, lon: 0.0)
            for latM in stride(from: Int(lats.lowerBound * 1000), through: Int(lats.upperBound * 1000), by: 10) {
                for lonM in stride(from: Int(lons.lowerBound * 1000), through: Int(lons.upperBound * 1000), by: 10) {
                    let c = Coord(lat: Double(latM) / 1000, lon: Double(lonM) / 1000)
                    if let v = terrain.elevationM(at: c), v > worst.v { worst = (v, c.lat, c.lon) }
                }
            }
            XCTAssertLessThanOrEqual(worst.v, ceiling,
                "\(name): \(Int(worst.v)) m at \(worst.lat),\(worst.lon) — true high ground is under "
                + "\(Int(ceiling)) m. A gross high in low country is a source artifact, and NRST reads it "
                + "as terrain blocking the glide.")
        }
    }

    /// The hold-out half of the test above: the same low-country rule must NOT have eaten real terrain.
    /// Isolated peaks in otherwise low country are precisely what an over-eager artifact filter destroys,
    /// and terrain reading LOW is the unsafe direction — it raises reported AGL.
    func testIsolatedRealPeaksSurvive() throws {
        try XCTSkipUnless(terrain.status == .ready, "no bundled grid")
        let peaks: [(String, Double, Double, Double)] = [       // name, lat, lon, true summit m
            ("Mt Monadnock NH",  42.8613, -72.1085, 965),
            ("Mt Wachusett MA",  42.4890, -71.8860, 622),
            ("Stone Mountain GA", 33.8053, -84.1455, 514),
            ("Cadillac Mtn ME",  44.3528, -68.2247, 466),       // coastal: rises ~450 m from the sea
            ("Bear Butte SD",    44.4722, -103.4283, 1283),
            ("Mt Magazine AR",   35.1672, -93.6444, 839),
        ]
        for (name, lat, lon, truth) in peaks {
            // Take the local max over a small box — the summit may not sit exactly on a cell centre.
            var best = -9999.0
            for dLat in stride(from: -0.02, through: 0.02, by: 0.01) {
                for dLon in stride(from: -0.02, through: 0.02, by: 0.01) {
                    if let v = terrain.elevationM(at: Coord(lat: lat + dLat, lon: lon + dLon)) { best = max(best, v) }
                }
            }
            XCTAssertGreaterThan(best, truth * 0.55,
                "\(name) reads \(Int(best)) m against a true \(Int(truth)) m — an artifact filter has "
                + "removed real terrain, which raises reported AGL and is the unsafe direction.")
        }
    }

    func testOutsideCoverageIsRefusedNotGuessed() {
        XCTAssertNil(terrain.elevationM(at: Coord(lat: 60.0, lon: -150.0)), "Alaska is outside the CONUS grid")
        XCTAssertNil(terrain.elevationM(at: Coord(lat: 48.0, lon: 2.35)), "Paris is outside the CONUS grid")
    }

    // MARK: - AGL through the real grid

    private func fix(lat: Double, lon: Double, altM: Double?, vacc: Double? = 4) -> DeviceFix {
        var f = DeviceFix(coord: Coord(lat: lat, lon: lon), altitudeMSLm: altM,
                          groundSpeedMps: 50, courseDeg: 90, horizontalAccuracyM: 5)
        f.timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        f.verticalAccuracyM = vacc
        return f
    }

    /// The end-to-end number a pilot actually reads: MSL altitude minus the real grid, in FEET.
    func testAGLOverDenverFromRealGrid() throws {
        try XCTSkipUnless(terrain.status == .ready, "no bundled grid")
        // 10,000 ft MSL over Denver's 1656 m (5433 ft) field elevation ≈ 4,570 ft AGL.
        let altM = 10_000 / GPSReadout.mToFt
        let result = terrain.agl(fix: fix(lat: 39.8617, lon: -104.6731, altM: altM))
        let r = try XCTUnwrap(result.reading, "Denver at 10,000 ft must produce a reading")
        XCTAssertEqual(r.aglFt, 4570, accuracy: 250, "AGL must be MSL minus terrain, in feet")
        XCTAssertFalse(r.isBelowSurfaceModel)
    }

    func testAGLIsRefusedWithoutAltitude() throws {
        try XCTSkipUnless(terrain.status == .ready, "no bundled grid")
        let result = terrain.agl(fix: fix(lat: 39.8617, lon: -104.6731, altM: nil))
        XCTAssertEqual(result.unavailable, .noAltitude,
                       "no GPS altitude must refuse, never assume sea level — that would invent 5,400 ft of clearance")
    }

    func testAGLIsRefusedOutsideCoverage() throws {
        try XCTSkipUnless(terrain.status == .ready, "no bundled grid")
        let result = terrain.agl(fix: fix(lat: 60.0, lon: -150.0, altM: 3000))
        XCTAssertEqual(result.unavailable, .outsideCoverage)
    }

    /// An untrusted position must not produce an AGL number: subtracting terrain from a position we have
    /// already told the pilot not to believe would launder a bad fix into a confident-looking altitude.
    func testAGLIsRefusedWhenPositionIsNotTrusted() throws {
        try XCTSkipUnless(terrain.status == .ready, "no bundled grid")
        var untrusted = GPSIntegrityAssessment()
        untrusted.state = .suspect
        let result = terrain.agl(fix: fix(lat: 39.8617, lon: -104.6731, altM: 3000), integrity: untrusted)
        XCTAssertEqual(result.unavailable, .positionNotTrusted)
    }

    /// Below the surface model is routine (canopy, buildings, max-aggregation) and must be reported as
    /// such rather than clamped silently — the bar renders it as "SFC".
    func testBelowSurfaceModelIsFlaggedNotClamped() throws {
        try XCTSkipUnless(terrain.status == .ready, "no bundled grid")
        let result = terrain.agl(fix: fix(lat: 39.8617, lon: -104.6731, altM: 1500))   // below Denver's 1656 m
        let r = try XCTUnwrap(result.reading)
        XCTAssertTrue(r.isBelowSurfaceModel)
        XCTAssertLessThan(r.aglFt, 0, "the raw value stays negative; only the UI floors it")
    }
}
