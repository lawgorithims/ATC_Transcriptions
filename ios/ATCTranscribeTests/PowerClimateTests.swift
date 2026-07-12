import XCTest
@testable import ATCTranscribe

/// NASA POWER climatology: unit conversions and density-altitude anchors, sector/class/tod/key
/// binning, fill-value filtering, the ingestion fold (exact histogram counts), rose normalization,
/// DA percentiles, runway pairing + favored/crosswind math, the request URL (time-standard=LST is
/// load-bearing), chunk decode guards, and the cache round-trip.
final class PowerClimateTests: XCTestCase {

    // MARK: Binning

    func testSectorEdges() {
        XCTAssertEqual(ClimateMath.sector(deg: 0), 0)          // N
        XCTAssertEqual(ClimateMath.sector(deg: 11.24), 0)
        XCTAssertEqual(ClimateMath.sector(deg: 11.25), 1)      // NNE begins
        XCTAssertEqual(ClimateMath.sector(deg: 348.74), 15)    // NNW
        XCTAssertEqual(ClimateMath.sector(deg: 348.75), 0)     // wraps back to N
        XCTAssertEqual(ClimateMath.sector(deg: 270), 12)       // W
        XCTAssertEqual(ClimateMath.sector(deg: 360), 0)
        XCTAssertEqual(ClimateMath.sector(deg: -90), 12)       // negative normalizes → W
    }

    func testSpeedClassEdges() {
        XCTAssertEqual(ClimateMath.speedClass(kt: 2.0), 0)     // [2,5)
        XCTAssertEqual(ClimateMath.speedClass(kt: 4.99), 0)
        XCTAssertEqual(ClimateMath.speedClass(kt: 5.0), 1)
        XCTAssertEqual(ClimateMath.speedClass(kt: 26.99), 6)
        XCTAssertEqual(ClimateMath.speedClass(kt: 27.0), 7)    // open-ended top class
        XCTAssertEqual(ClimateMath.speedClass(kt: 80), 7)
    }

    func testKeyParsingAndTod() {
        XCTAssertNil(ClimateMath.parseKey("2024010"))          // too short
        XCTAssertNil(ClimateMath.parseKey("20240101TT"))       // non-digits
        XCTAssertNil(ClimateMath.parseKey("2024130100"))       // month 13
        XCTAssertNil(ClimateMath.parseKey("2024010124"))       // hour 24
        let parsed = ClimateMath.parseKey("2024070114")
        XCTAssertEqual(parsed?.month, 7)
        XCTAssertEqual(parsed?.hour, 14)
        XCTAssertEqual(ClimateMath.timeOfDay(hour: 5), 0)      // night 00–05
        XCTAssertEqual(ClimateMath.timeOfDay(hour: 6), 1)      // morning
        XCTAssertEqual(ClimateMath.timeOfDay(hour: 17), 2)     // afternoon
        XCTAssertEqual(ClimateMath.timeOfDay(hour: 23), 3)     // evening
    }

    // MARK: Density altitude anchors

    func testDensityAltitudeISAAnchors() {
        // ISA sea level: 101.325 kPa / 15 °C → DA ≈ 0 ft.
        let isa = ClimateMath.densityAltitudeFt(psKPa: 101.325, t2mC: 15, gridElevM: 0, fieldElevFt: 0)
        XCTAssertEqual(isa, 0, accuracy: 5)
        // +15 °C above ISA → ≈ +1,782 ft.
        let hot = ClimateMath.densityAltitudeFt(psKPa: 101.325, t2mC: 30, gridElevM: 0, fieldElevFt: 0)
        XCTAssertEqual(hot, 1782, accuracy: 10)
        // Grid ≠ field: the same sample shifted to a field 1,000 ft above the grid cell must move
        // PA up ~1,000 ft (temperature lapses with it, so DA moves close to +1,000 too).
        let shifted = ClimateMath.densityAltitudeFt(psKPa: 101.325, t2mC: 15, gridElevM: 0, fieldElevFt: 1000)
        XCTAssertEqual(shifted, 1000, accuracy: 60)
    }

    // MARK: Ingestion fold

    private func foldedStats(fieldElevFt: Int? = 0) -> (PowerClimateStats, ClimateAccumulator) {
        var acc = ClimateAccumulator()
        // Three samples: a 5 m/s W wind on a July afternoon, a calm July night hour, and a −999
        // fill row that must be dropped. Temperatures/pressures are ISA and ISA+15.
        ClimateMath.fold(year: 2024,
                         ws: ["2024070114": 5.0, "2024070102": 0.5, "2024011506": -999],
                         wd: ["2024070114": 270, "2024070102": 10, "2024011506": 180],
                         t2m: ["2024070114": 30, "2024070102": 15],
                         ps: ["2024070114": 101.325, "2024070102": 101.325],
                         gridElevM: 0, fieldElevFt: fieldElevFt, into: &acc)
        let stats = PowerClimateStats(version: PowerClimateStats.currentVersion, ident: "KTST",
                                      lat: 42, lon: -71, gridElevationM: 0, fieldElevationFt: fieldElevFt,
                                      years: acc.years.sorted(), sampleCount: acc.sampleCount,
                                      windCounts: acc.windCounts, daCounts: acc.daCounts, builtAt: Date())
        return (stats, acc)
    }

    func testFoldExactCounts() {
        let (_, acc) = foldedStats()
        XCTAssertEqual(acc.sampleCount, 2)                     // the −999 row was dropped
        XCTAssertEqual(acc.years, [2024])
        // 5 m/s = 9.72 kt → class 2 ([8,11)), from 270° → sector 12 (W), July afternoon (tod 2).
        XCTAssertEqual(acc.windCounts[ClimateMath.windIndex(month: 7, tod: 2, dir: 12, cls: 2)], 1)
        // 0.5 m/s < 2 kt → calm bucket, July night (tod 0).
        XCTAssertEqual(acc.windCounts[ClimateMath.windIndex(month: 7, tod: 0, dir: ClimateMath.calmDirIndex, cls: 0)], 1)
        XCTAssertEqual(acc.windCounts.map(Int.init).reduce(0, +), 2)
        // DA: ISA+15 afternoon → 1,782 ft → bin 3; ISA night → 0 ft → bin 2.
        XCTAssertEqual(acc.daCounts[ClimateMath.daIndex(month: 7, tod: 2, bin: 3)], 1)
        XCTAssertEqual(acc.daCounts[ClimateMath.daIndex(month: 7, tod: 0, bin: 2)], 1)
        XCTAssertEqual(acc.daCounts.map(Int.init).reduce(0, +), 2)
    }

    func testFoldWithoutElevationSkipsDA() {
        let (_, acc) = foldedStats(fieldElevFt: nil)
        XCTAssertEqual(acc.daCounts.map(Int.init).reduce(0, +), 0)
        XCTAssertEqual(acc.windCounts.map(Int.init).reduce(0, +), 2)   // wind still counted
    }

    // MARK: Rose + percentiles

    func testRoseNormalizesToHundred() {
        let (stats, _) = foldedStats()
        let rose = ClimateMath.rose(stats: stats, months: [], tods: [])
        XCTAssertEqual(rose.totalHours, 2)
        XCTAssertEqual(rose.petalPct.reduce(0, +) + rose.calmPct, 100, accuracy: 1e-9)
        XCTAssertEqual(rose.petalPct[12], 50, accuracy: 1e-9)          // the W hour
        XCTAssertEqual(rose.calmPct, 50, accuracy: 1e-9)
        XCTAssertEqual(rose.meanKtBySector[12], 9.5, accuracy: 1e-9)   // class-2 midpoint
        let prev = ClimateMath.prevailing(rose)
        XCTAssertEqual(prev?.sector, 12)
    }

    func testRoseFilterExcludes() {
        let (stats, _) = foldedStats()
        // Afternoon-only excludes the calm night hour.
        let rose = ClimateMath.rose(stats: stats, months: [7], tods: [2])
        XCTAssertEqual(rose.totalHours, 1)
        XCTAssertEqual(rose.calmPct, 0)
        // January has no data at all.
        XCTAssertEqual(ClimateMath.rose(stats: stats, months: [1], tods: []).totalHours, 0)
        XCTAssertNil(ClimateMath.prevailing(ClimateMath.rose(stats: stats, months: [1], tods: [])))
    }

    func testDAPercentilesInterpolate() {
        var acc = ClimateAccumulator()
        // Ten identical samples land in bin 2 (0–1,000 ft): p50 mid-bin, p90 near the top.
        for h in 0..<10 {
            ClimateMath.fold(year: 2024,
                             ws: [String(format: "20240701%02d", h + 12): 5.0],
                             wd: [String(format: "20240701%02d", h + 12): 270],
                             t2m: [String(format: "20240701%02d", h + 12): 15],
                             ps: [String(format: "20240701%02d", h + 12): 101.325],
                             gridElevM: 0, fieldElevFt: 0, into: &acc)
        }
        let stats = PowerClimateStats(version: 1, ident: "KTST", lat: 42, lon: -71, gridElevationM: 0,
                                      fieldElevationFt: 0, years: [2024], sampleCount: acc.sampleCount,
                                      windCounts: acc.windCounts, daCounts: acc.daCounts, builtAt: Date())
        let da = ClimateMath.daPercentiles(stats: stats, months: [], tods: [])
        XCTAssertEqual(da?.p50 ?? -1, 500, accuracy: 1e-6)
        XCTAssertEqual(da?.p90 ?? -1, 900, accuracy: 1e-6)
        // No field elevation → nil.
        let noElev = PowerClimateStats(version: 1, ident: "KTST", lat: 42, lon: -71, gridElevationM: 0,
                                       fieldElevationFt: nil, years: [2024], sampleCount: 1,
                                       windCounts: acc.windCounts, daCounts: acc.daCounts, builtAt: Date())
        XCTAssertNil(ClimateMath.daPercentiles(stats: noElev, months: [], tods: []))
    }

    // MARK: Runway pairing + stats

    func testReciprocalDesignators() {
        XCTAssertEqual(RunwayGeometry.reciprocal(of: "RW04L"), "RW22R")
        XCTAssertEqual(RunwayGeometry.reciprocal(of: "RW22R"), "RW04L")
        XCTAssertEqual(RunwayGeometry.reciprocal(of: "RW36"), "RW18")
        XCTAssertEqual(RunwayGeometry.reciprocal(of: "RW18"), "RW36")
        XCTAssertEqual(RunwayGeometry.reciprocal(of: "RW17C"), "RW35C")
        XCTAssertNil(RunwayGeometry.reciprocal(of: "RW09W"))   // water runway suffix — skip
        XCTAssertNil(RunwayGeometry.reciprocal(of: "RW00"))
        XCTAssertNil(RunwayGeometry.reciprocal(of: "H1"))
    }

    func testPairingAndTrueHeadings() {
        let a = Coord(lat: 42.0, lon: -71.0)
        let b = Coord(lat: 42.02, lon: -71.0 + 0.02 / cos(42.0 * .pi / 180))   // ~NE of a
        let ends = [CIFPRunway(designator: "RW04L", coord: a, bearingMag: 35, lengthFt: 7864),
                    CIFPRunway(designator: "RW22R", coord: b, bearingMag: 215, lengthFt: 7864),
                    CIFPRunway(designator: "RW14", coord: a, bearingMag: 140, lengthFt: 5000)]   // no RW32 row
        let pairs = RunwayGeometry.pairs(from: ends)
        XCTAssertEqual(pairs.count, 1)                          // the unpaired 14 end is skipped
        XCTAssertEqual(pairs[0].id, "04L/22R")
        XCTAssertEqual(pairs[0].a.trueHeadingDeg, Geo.bearing(a, b), accuracy: 1e-9)
        XCTAssertEqual(pairs[0].a.trueHeadingDeg, 45, accuracy: 2)   // laid out ~NE
        XCTAssertEqual(pairs[0].b.trueHeadingDeg, Geo.bearing(b, a), accuracy: 1e-9)
        XCTAssertEqual(pairs[0].lengthFt, 7864)
        // Sanity vs the published magnetic bearing: true − magnetic stays within ±25° (US magvar).
        XCTAssertEqual(pairs[0].a.trueHeadingDeg, 35, accuracy: 25)
    }

    func testFavoredRunwayAllWindFromNorth() {
        var acc = ClimateAccumulator()
        ClimateMath.fold(year: 2024, ws: ["2024070114": 6.0], wd: ["2024070114": 0],   // from N
                         t2m: [:], ps: [:], gridElevM: 0, fieldElevFt: nil, into: &acc)
        let stats = PowerClimateStats(version: 1, ident: "KTST", lat: 42, lon: -71, gridElevationM: 0,
                                      fieldElevationFt: nil, years: [2024], sampleCount: 1,
                                      windCounts: acc.windCounts, daCounts: acc.daCounts, builtAt: Date())
        let favored = ClimateMath.favoredPct(ends: [("04", 35.0), ("22", 215.0)],
                                             stats: stats, months: [], tods: [])
        XCTAssertEqual(favored["04"] ?? 0, 100, accuracy: 1e-9)   // headwind on 04, tailwind on 22
        XCTAssertEqual(favored["22"] ?? 0, 0, accuracy: 1e-9)
    }

    func testCrosswindExceedanceKnownMass() {
        var acc = ClimateAccumulator()
        // One hour at 8 m/s (15.55 kt → class 4, midpoint 15.5) from due E.
        ClimateMath.fold(year: 2024, ws: ["2024070114": 8.0], wd: ["2024070114": 90],
                         t2m: [:], ps: [:], gridElevM: 0, fieldElevFt: nil, into: &acc)
        let stats = PowerClimateStats(version: 1, ident: "KTST", lat: 42, lon: -71, gridElevationM: 0,
                                      fieldElevationFt: nil, years: [2024], sampleCount: 1,
                                      windCounts: acc.windCounts, daCounts: acc.daCounts, builtAt: Date())
        // Runway heading 0°T: |sin(90°)| = 1 → 15.5 kt crosswind: exceeds 10 and 15, not 20.
        XCTAssertEqual(ClimateMath.crosswindExceedancePct(runwayTrueHeadingDeg: 0, thresholdKt: 10,
                                                          stats: stats, months: [], tods: []) ?? -1, 100, accuracy: 1e-9)
        XCTAssertEqual(ClimateMath.crosswindExceedancePct(runwayTrueHeadingDeg: 0, thresholdKt: 15,
                                                          stats: stats, months: [], tods: []) ?? -1, 100, accuracy: 1e-9)
        XCTAssertEqual(ClimateMath.crosswindExceedancePct(runwayTrueHeadingDeg: 0, thresholdKt: 20,
                                                          stats: stats, months: [], tods: []) ?? -1, 0, accuracy: 1e-9)
        // Runway aligned with the wind → zero crosswind component.
        XCTAssertEqual(ClimateMath.crosswindExceedancePct(runwayTrueHeadingDeg: 90, thresholdKt: 10,
                                                          stats: stats, months: [], tods: []) ?? -1, 0, accuracy: 1e-9)
    }

    // MARK: Store: years, URL, chunk decode, cache

    func testTargetYearsRespectLag() {
        let cal = Calendar(identifier: .gregorian)
        let midYear = cal.date(from: DateComponents(year: 2026, month: 7, day: 11))!
        XCTAssertEqual(PowerClimateStore.targetYears(now: midYear), [2023, 2024, 2025])
        // Early in the year the 120-day lag pushes the cutoff into the PRIOR year.
        let earlyYear = cal.date(from: DateComponents(year: 2026, month: 2, day: 1))!
        XCTAssertEqual(PowerClimateStore.targetYears(now: earlyYear), [2022, 2023, 2024])
    }

    func testRequestURLPinsLSTAndParams() {
        let url = PowerClimateStore.url(year: 2024, lat: 42.3656, lon: -71.0096)
        XCTAssertEqual(url?.absoluteString,
                       "https://power.larc.nasa.gov/api/temporal/hourly/point?"
                       + "parameters=WS10M,WD10M,T2M,PS&community=RE"
                       + "&longitude=-71.0096&latitude=42.3656"
                       + "&start=20240101&end=20241231&time-standard=LST&format=JSON")
    }

    func testChunkDecodeAndGuards() {
        let good = """
        {"type":"Feature","geometry":{"type":"Point","coordinates":[-71.0,42.36,12.5]},
         "properties":{"parameter":{"WS10M":{"2024010100":3.2,"2024010101":-999},
                                    "WD10M":{"2024010100":270,"2024010101":-999}}}}
        """.data(using: .utf8)!
        let chunk = PowerClimateStore.decodeChunk(good)
        XCTAssertEqual(chunk?.gridElevationM ?? -1, 12.5, accuracy: 1e-9)
        XCTAssertEqual(chunk?.properties.parameter["WS10M"]?["2024010100"] ?? -1, 3.2, accuracy: 1e-9)
        XCTAssertNil(PowerClimateStore.decodeChunk(Data("garbage".utf8)))
        XCTAssertNil(PowerClimateStore.decodeChunk(Data()))
    }

    func testCacheRoundTripAndVersionDiscard() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("power-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var (stats, _) = foldedStats()
        stats = PowerClimateStats(version: stats.version, ident: "KTST", lat: stats.lat, lon: stats.lon,
                                  gridElevationM: stats.gridElevationM, fieldElevationFt: stats.fieldElevationFt,
                                  years: PowerClimateStore.targetYears(), sampleCount: stats.sampleCount,
                                  windCounts: stats.windCounts, daCounts: stats.daCounts, builtAt: stats.builtAt)
        let file = try XCTUnwrap(PowerClimateStore.cacheFile(ident: "KTST",
                                                             years: PowerClimateStore.targetYears(), dir: dir))
        try JSONEncoder().encode(stats).write(to: file)

        // Round-trip through the guarded decoder…
        XCTAssertEqual(PowerClimateStore.decodeStats(at: file), stats)
        // …and through the store's cache fast path (no network is touched on a cache hit; the
        // lowercase ident also proves the key normalizes).
        let store = PowerClimateStore(cacheDirectory: dir)
        let loaded = await store.stats(ident: "ktst", coord: Coord(lat: 42, lon: -71), fieldElevFt: 0)
        XCTAssertEqual(loaded, stats)

        // A version bump discards the file instead of misreading it.
        let bumped = """
        {"version":99,"ident":"KTST","lat":42,"lon":-71,"gridElevationM":0,"years":[2023],
         "sampleCount":1,"windCounts":[],"daCounts":[],"builtAt":0}
        """
        try Data(bumped.utf8).write(to: file)
        XCTAssertNil(PowerClimateStore.decodeStats(at: file))
    }
}
