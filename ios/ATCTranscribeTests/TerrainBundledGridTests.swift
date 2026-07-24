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
    /// the cell) and somewhat BELOW a sharp summit (a 1 NM cell cannot hold a peak). Tolerances reflect
    /// that honestly rather than being widened until the test passes.
    private let sites: [(name: String, lat: Double, lon: Double, truthM: Double, tolM: Double)] = [
        ("KDEN Denver",      39.8617, -104.6731, 1656, 60),
        ("KDFW Dallas",      32.8998,  -97.0403,  185, 60),
        ("KMIA Miami",       25.7959,  -80.2870,    3, 40),
        ("KMSY New Orleans", 29.9934,  -90.2580,    1, 40),
        ("KLAS Las Vegas",   36.0840, -115.1537,  665, 80),
        ("KSEA Seattle",     47.4502, -122.3088,  132, 60),
        ("Mt Whitney",       36.5785, -118.2923, 4421, 250),   // summit: grid reads low, see above
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
        XCTAssertLessThan(worst.v, 4600,
                          "highest sampled cell \(worst.v) m at \(worst.lat),\(worst.lon) — CONUS tops out at Whitney (4421 m)")
        XCTAssertGreaterThan(worst.v, 3000, "the sample lattice should still find real mountains")
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
