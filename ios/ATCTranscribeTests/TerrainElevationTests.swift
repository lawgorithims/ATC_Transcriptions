import XCTest
@testable import ATCTranscribe

/// The bundled terrain grid reader: cell indexing (including the row/column and north/south
/// orientation the whole feature depends on), coverage edges, the no-data sentinel, the metres-to-feet
/// AGL arithmetic, and every path that must refuse to produce a reading — a corrupt or truncated
/// resource, a fix with no altitude or an unbounded vertical sigma, and a position the GPS integrity
/// monitor has disowned.
///
/// Everything runs against a SYNTHETIC 3x4 grid written to a temp directory and loaded through the
/// same `init` the app uses, so the tests exercise the real mmap + index path with values chosen so a
/// transpose or a flipped latitude axis cannot pass. The expected numbers are computed by hand from
/// the format spec (`Tools/build_terrain_grid.py`), never from this reader's own output.
final class TerrainElevationTests: XCTestCase {

    /// The synthetic grid: rows run NORTH to SOUTH, columns WEST to EAST, exactly as the builder
    /// writes them. Every cell is distinct and the row bands are an order of magnitude apart, so a
    /// row/column transpose, a north/south flip, or an off-by-one row lands on an obviously wrong
    /// value rather than a plausible neighbour. Cell (1, 2) is the no-data sentinel.
    ///
    /// Geometry: latMax 43, latMin 40, lonMin -100, lonMax -96, one cell per degree.
    ///   row 0 = lat [42, 43)   row 1 = lat [41, 42)   row 2 = lat [40, 41)
    ///   col 0 = lon [-100, -99) … col 3 = lon [-97, -96)
    private static let values: [[Int16]] = [
        [100,  200,  300,        400],
        [1000, 1100, Int16.min,  1300],
        [2000, 2100, 2200,       2300],
    ]
    private static let maxRows = 8            // loop bounds for the writer (rule 2)
    private static let maxCols = 8

    private var tempDirs: [URL] = []

    override func tearDownWithError() throws {
        for dir in tempDirs.prefix(64) { try? FileManager.default.removeItem(at: dir) }
        tempDirs.removeAll()
    }

    // MARK: - Fixtures

    /// Write a grid pair into a fresh temp directory and return it, ready for
    /// `TerrainElevation(directory:)`. The knobs exist to build the broken variants: a header that is
    /// not JSON, a header that disagrees with its own bbox, a short `.bin`, a missing `.bin`.
    private func makeGrid(headerOverrides: [String: Any] = [:],
                          rawHeaderText: String? = nil,
                          truncateBin: Bool = false,
                          omitBin: Bool = false) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("terrain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)

        var header: [String: Any] = [
            "version": 1,
            "latMax": 43.0, "latMin": 40.0, "lonMin": -100.0, "lonMax": -96.0,
            "rows": 3, "cols": 4, "cellsPerDegree": 1, "noData": -32768,
            "units": "metres", "aggregation": "max",
            "datum": "orthometric (EGM96/NAVD88 ~ EGM2008)",
        ]
        for (key, value) in headerOverrides { header[key] = value }

        let headerData: Data
        if let rawHeaderText { headerData = Data(rawHeaderText.utf8) }
        else { headerData = try JSONSerialization.data(withJSONObject: header) }
        try headerData.write(to: dir.appendingPathComponent("terrain_conus.json"))

        guard !omitBin else { return dir }
        var bytes = Data()
        bytes.reserveCapacity(Self.maxRows * Self.maxCols * 2)
        for row in Self.values.prefix(Self.maxRows) {                     // bounded (rule 2)
            for value in row.prefix(Self.maxCols) {
                let raw = UInt16(bitPattern: value)                       // little-endian, per the spec
                bytes.append(UInt8(raw & 0x00FF))
                bytes.append(UInt8(raw >> 8))
            }
        }
        XCTAssertEqual(bytes.count, 24, "3 x 4 cells x 2 bytes")
        let payload = truncateBin ? bytes.prefix(10) : bytes
        try payload.write(to: dir.appendingPathComponent("terrain_conus.bin"))
        return dir
    }

    private func fix(lat: Double, lon: Double, altitudeM: Double?,
                     verticalAccuracyM: Double? = 5) -> DeviceFix {
        var f = DeviceFix(coord: Coord(lat: lat, lon: lon), altitudeMSLm: altitudeM,
                          groundSpeedMps: 60, courseDeg: 90, horizontalAccuracyM: 5)
        f.timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        f.verticalAccuracyM = verticalAccuracyM
        return f
    }

    // MARK: - Cell indexing

    func testKnownCellReturnsItsExactElevation() throws {
        let grid = TerrainElevation(directory: try makeGrid())
        XCTAssertEqual(grid.status, .ready)
        XCTAssertTrue(grid.isAvailable)
        // lat 41.5 is in row 1, lon -98.5 is in column 1 → 1100 m, exactly, no interpolation.
        XCTAssertEqual(try XCTUnwrap(grid.elevationM(at: Coord(lat: 41.5, lon: -98.5))), 1100)
    }

    /// The orientation test. The builder writes row 0 at the NORTH edge and column 0 at the WEST
    /// edge; if the reader disagrees on either axis, at least two of these four corners come back
    /// with another corner's value, and a transpose cannot even produce this shape.
    func testFourCornersProveTheGridOrientation() throws {
        let grid = TerrainElevation(directory: try makeGrid())
        XCTAssertEqual(try XCTUnwrap(grid.elevationM(at: Coord(lat: 42.5, lon: -99.5))), 100,
                       "north-west corner")
        XCTAssertEqual(try XCTUnwrap(grid.elevationM(at: Coord(lat: 42.5, lon: -96.5))), 400,
                       "north-east corner")
        XCTAssertEqual(try XCTUnwrap(grid.elevationM(at: Coord(lat: 40.5, lon: -99.5))), 2000,
                       "south-west corner — a flipped latitude axis reads 100 here")
        XCTAssertEqual(try XCTUnwrap(grid.elevationM(at: Coord(lat: 40.5, lon: -96.5))), 2300,
                       "south-east corner")
    }

    /// The bbox is inclusive on all four sides. North and west floor into cell 0 naturally; south and
    /// east floor to one PAST the last cell and are clamped back into it, which is the intended
    /// reading of a closed interval — not an out-of-bounds index.
    func testBoundingBoxEdgesResolveIntoTheEdgeCells() throws {
        let grid = TerrainElevation(directory: try makeGrid())
        XCTAssertEqual(try XCTUnwrap(grid.elevationM(at: Coord(lat: 43.0, lon: -100.0))), 100,
                       "the exact north-west corner belongs to cell (0, 0)")
        XCTAssertEqual(try XCTUnwrap(grid.elevationM(at: Coord(lat: 40.0, lon: -96.0))), 2300,
                       "the exact south-east corner clamps into the last cell, it does not run off it")
    }

    func testOutsideTheBoundingBoxHasNoCoverage() throws {
        let grid = TerrainElevation(directory: try makeGrid())
        XCTAssertNil(grid.elevationM(at: Coord(lat: 43.5, lon: -98.0)), "north of the grid")
        XCTAssertNil(grid.elevationM(at: Coord(lat: 39.9, lon: -98.0)), "south of the grid")
        XCTAssertNil(grid.elevationM(at: Coord(lat: 41.5, lon: -101.0)), "west of the grid")
        XCTAssertNil(grid.elevationM(at: Coord(lat: 41.5, lon: -95.9)), "east of the grid")
        XCTAssertNil(grid.elevationFt(at: Coord(lat: 0.0, lon: 0.0)), "the null island is not CONUS")
    }

    /// -32768 is "no source data here" (ocean, or a tile that failed to fetch), not an elevation
    /// 32 km below sea level that a caller would happily subtract.
    func testNoDataSentinelIsNoCoverageNotAnElevation() throws {
        let grid = TerrainElevation(directory: try makeGrid())
        XCTAssertNil(grid.elevationM(at: Coord(lat: 41.5, lon: -97.5)))
        let result = grid.agl(fix: fix(lat: 41.5, lon: -97.5, altitudeM: 3000))
        XCTAssertEqual(result.unavailable, .outsideCoverage,
                       "a no-data cell is a coverage hole, indistinguishable to the pilot from the edge")
    }

    // MARK: - Unit conversion

    func testElevationInFeetConvertsFromMetres() throws {
        let grid = TerrainElevation(directory: try makeGrid())
        // 1000 m x 3.280839895 ft/m = 3280.84 ft.
        XCTAssertEqual(try XCTUnwrap(grid.elevationFt(at: Coord(lat: 41.5, lon: -99.5))),
                       3280.84, accuracy: 0.01)
    }

    // MARK: - AGL arithmetic

    func testAGLIsAltitudeMinusTerrainInFeet() throws {
        let grid = TerrainElevation(directory: try makeGrid())
        // Terrain 1000 m under (41.5, -99.5); 1304.8 m MSL is exactly 304.8 m above it, and 304.8 m
        // is exactly 1000 ft by definition of the international foot.
        let reading = try XCTUnwrap(grid.agl(fix: fix(lat: 41.5, lon: -99.5, altitudeM: 1304.8)).reading)
        XCTAssertEqual(reading.aglFt, 1000.0, accuracy: 0.01)
        XCTAssertEqual(reading.terrainElevationM, 1000)
        XCTAssertEqual(reading.terrainElevationFt, 3280.84, accuracy: 0.01)
        XCTAssertEqual(reading.altitudeMSLm, 1304.8)
        XCTAssertEqual(reading.trust, .usable)
        XCTAssertFalse(reading.isBelowSurfaceModel)
    }

    /// Flying below the surface model is normal — the source includes tree canopy and buildings and is
    /// max-aggregated over ~1 NM cells. The negative must reach the caller intact; the UI floors it to
    /// "SFC" for display, but a model that clamped it would hide the one signal that separates ordinary
    /// canopy bias from a genuinely wrong altitude.
    func testNegativeAGLIsReportedNotClamped() throws {
        let grid = TerrainElevation(directory: try makeGrid())
        // Terrain 2200 m under (40.5, -97.5), aircraft at 2000 m MSL → -200 m = -656.17 ft.
        let reading = try XCTUnwrap(grid.agl(fix: fix(lat: 40.5, lon: -97.5, altitudeM: 2000)).reading)
        XCTAssertEqual(reading.aglFt, -656.17, accuracy: 0.01)
        XCTAssertTrue(reading.isBelowSurfaceModel)
        XCTAssertLessThan(reading.aglFt, 0, "the sign must survive into the reading and the log")
    }

    // MARK: - Refusals

    func testNoAltitudeYieldsNoReading() throws {
        let grid = TerrainElevation(directory: try makeGrid())
        let result = grid.agl(fix: fix(lat: 41.5, lon: -99.5, altitudeM: nil))
        XCTAssertEqual(result.unavailable, .noAltitude)
        XCTAssertNil(result.reading)
    }

    func testMissingOrNonPositiveVerticalAccuracyYieldsNoReading() throws {
        let grid = TerrainElevation(directory: try makeGrid())
        XCTAssertEqual(grid.agl(fix: fix(lat: 41.5, lon: -99.5, altitudeM: 1300,
                                         verticalAccuracyM: nil)).unavailable,
                       .verticalAccuracyUnknown)
        XCTAssertEqual(grid.agl(fix: fix(lat: 41.5, lon: -99.5, altitudeM: 1300,
                                         verticalAccuracyM: 0)).unavailable,
                       .verticalAccuracyUnknown,
                       "CoreLocation's <=0 sentinel means invalid, never perfectly accurate")
    }

    func testPoorVerticalAccuracyYieldsNoReading() throws {
        let grid = TerrainElevation(directory: try makeGrid())
        // 80 m sigma is a +/-520 ft 95% band — worse than useless in the low regime AGL is read in.
        XCTAssertEqual(grid.agl(fix: fix(lat: 41.5, lon: -99.5, altitudeM: 1300,
                                         verticalAccuracyM: 80)).unavailable,
                       .verticalAccuracyPoor)
        // 50 m is the limit itself: still answered, but hedged.
        let atLimit = try XCTUnwrap(grid.agl(fix: fix(lat: 41.5, lon: -99.5, altitudeM: 1300,
                                                      verticalAccuracyM: 50)).reading)
        XCTAssertEqual(atLimit.trust, .coarse)
    }

    func testWideVerticalSigmaIsCoarseNotRefused() throws {
        let grid = TerrainElevation(directory: try makeGrid())
        let reading = try XCTUnwrap(grid.agl(fix: fix(lat: 41.5, lon: -99.5, altitudeM: 1304.8,
                                                      verticalAccuracyM: 30)).reading)
        XCTAssertEqual(reading.trust, .coarse, "usable, but the UI must show it hedged")
        XCTAssertEqual(reading.aglFt, 1000.0, accuracy: 0.01, "the arithmetic is unchanged by trust")
        XCTAssertEqual(reading.verticalAccuracyM, 30)
    }

    func testUntrustedPositionYieldsNoReading() throws {
        let grid = TerrainElevation(directory: try makeGrid())
        let f = fix(lat: 41.5, lon: -99.5, altitudeM: 1304.8)
        let unreliable = GPSIntegrityAssessment(state: .unreliable, reasons: [.accuracyUnusable])
        XCTAssertEqual(grid.agl(fix: f, integrity: unreliable).unavailable, .positionNotTrusted)
        let suspect = GPSIntegrityAssessment(state: .suspect, reasons: [.positionJump])
        XCTAssertEqual(grid.agl(fix: f, integrity: suspect).unavailable, .positionNotTrusted,
                       "the horizontal error picks the cell — a disowned position picks the wrong one")
    }

    /// A merely degraded fix is still worth a number; it is the trust flag that changes, because the
    /// alternative is a readout that blinks out every time accuracy wanders past 30 m.
    func testDegradedIntegrityIsCoarseAndNominalIsUsable() throws {
        let grid = TerrainElevation(directory: try makeGrid())
        let f = fix(lat: 41.5, lon: -99.5, altitudeM: 1304.8)
        let degraded = GPSIntegrityAssessment(state: .degraded, reasons: [.accuracyDegraded])
        XCTAssertEqual(try XCTUnwrap(grid.agl(fix: f, integrity: degraded).reading).trust, .coarse)
        let nominal = GPSIntegrityAssessment(state: .nominal)
        XCTAssertEqual(try XCTUnwrap(grid.agl(fix: f, integrity: nominal).reading).trust, .usable)
    }

    func testOutsideCoverageIsDistinctFromEveryOtherRefusal() throws {
        let grid = TerrainElevation(directory: try makeGrid())
        let result = grid.agl(fix: fix(lat: 47.0, lon: -110.0, altitudeM: 3000))
        XCTAssertEqual(result.unavailable, .outsideCoverage,
                       "'you are off the grid' and 'the grid is broken' are different messages")
    }

    // MARK: - Degradation, never a crash

    func testTruncatedGridDegradesToUnavailable() throws {
        let grid = TerrainElevation(directory: try makeGrid(truncateBin: true))
        XCTAssertEqual(grid.status, .sizeMismatch)
        XCTAssertFalse(grid.isAvailable)
        XCTAssertNil(grid.gridHeader, "a rejected grid must not publish a header the UI would trust")
        XCTAssertNil(grid.elevationM(at: Coord(lat: 41.5, lon: -98.5)),
                     "a short file must never be indexed — that is a read past the mapping")
        XCTAssertEqual(grid.agl(fix: fix(lat: 41.5, lon: -98.5, altitudeM: 1300)).unavailable,
                       .gridUnavailable)
    }

    func testMissingFilesDegradeToUnavailable() throws {
        let empty = TerrainElevation(directory: try makeGrid(omitBin: true))
        XCTAssertEqual(empty.status, .missing)
        XCTAssertNil(empty.elevationM(at: Coord(lat: 41.5, lon: -98.5)))

        let nowhere = TerrainElevation(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("terrain-absent-\(UUID().uuidString)", isDirectory: true))
        XCTAssertEqual(nowhere.status, .missing)
        XCTAssertEqual(nowhere.agl(fix: fix(lat: 41.5, lon: -98.5, altitudeM: 1300)).unavailable,
                       .gridUnavailable)
    }

    func testCorruptHeaderDegradesToUnavailable() throws {
        let grid = TerrainElevation(directory: try makeGrid(rawHeaderText: "{ this is not json"))
        XCTAssertEqual(grid.status, .headerInvalid)
        XCTAssertNil(grid.elevationM(at: Coord(lat: 41.5, lon: -98.5)))
    }

    /// A header whose shape disagrees with its own bbox would decode fine and then place every lookup
    /// several cells away — a plausible-looking WRONG elevation, which is the worst possible failure.
    func testHeaderInconsistentWithItsBoundingBoxIsRejected() throws {
        let stretched = TerrainElevation(directory: try makeGrid(headerOverrides: ["rows": 5]))
        XCTAssertEqual(stretched.status, .headerInvalid)
        let shifted = TerrainElevation(directory: try makeGrid(headerOverrides: ["lonMax": -90.0]))
        XCTAssertEqual(shifted.status, .headerInvalid)
        let inverted = TerrainElevation(directory: try makeGrid(headerOverrides: ["latMin": 60.0]))
        XCTAssertEqual(inverted.status, .headerInvalid)
    }

    func testUnknownFormatVersionIsRejected() throws {
        let future = TerrainElevation(directory: try makeGrid(headerOverrides: ["version": 2]))
        XCTAssertEqual(future.status, .headerInvalid,
                       "a future cell encoding must be refused, not mis-indexed by an old app")
    }

    // MARK: - The shipped grid

    /// Integration guard on the real bundled resource when the test host carries it: the shape must be
    /// the CONUS one and Denver must come out near its actual field elevation (1655 m), which is the
    /// end-to-end proof that the bundled bytes, the header, and the indexing all agree. Skipped rather
    /// than failed in a bare host, where the resource is not present at all.
    func testBundledGridWhenPresentPutsDenverAtTheRightHeight() throws {
        let grid = TerrainElevation.shared
        try XCTSkipUnless(grid.isAvailable, "terrain grid not in this test host's bundle")
        let header = try XCTUnwrap(grid.gridHeader)
        XCTAssertEqual(header.version, TerrainGridHeader.supportedVersion)
        XCTAssertEqual(header.cellsPerDegree, 60, "one arc-minute cells")
        XCTAssertEqual(header.aggregation, "max", "the reader's nearest-cell rule depends on this")

        // KDEN. The grid is a max-aggregated SURFACE model, so it reads at or above field elevation;
        // the band is wide enough to survive a re-build at another zoom but far too tight to pass if
        // the row or column axis were ever flipped.
        let denver = try XCTUnwrap(grid.elevationM(at: Coord(lat: 39.8617, lon: -104.6731)))
        XCTAssertGreaterThan(denver, 1400)
        XCTAssertLessThan(denver, 2200)
        XCTAssertNil(grid.elevationM(at: Coord(lat: 51.5, lon: -0.12)), "London is not in CONUS")
    }
}
