import XCTest
@testable import ATCTranscribe

/// The engine-out NRST engine: glide range, the descent-profile terrain sweep (with its corridor,
/// ramp, and fail-closed hole handling), and the pilot-specified ranking hierarchy — in-glide first,
/// then weather LEXICOGRAPHICALLY, then terrain hostility, runways, and facilities as descending
/// weights. Everything here runs against synthetic terrain and synthetic airports with numbers
/// computed by hand from the constants, never from the engine's own output.
final class NearestAirportsTests: XCTestCase {

    // MARK: synthetic terrain

    /// Uniform elevation everywhere (or a dead grid when `ready` is false).
    private struct ConstTerrain: TerrainSampling {
        var elevFt: Double? = 0
        var ready = true
        var isReady: Bool { ready }
        func sampleElevationFt(at coord: Coord) -> Double? { ready ? elevFt : nil }
    }

    /// High ground inside a latitude band — a synthetic east–west ridge.
    private struct LatRidge: TerrainSampling {
        let lo: Double, hi: Double, ridgeFt: Double
        var floorFt = 0.0
        var isReady: Bool { true }
        func sampleElevationFt(at c: Coord) -> Double? { (c.lat >= lo && c.lat <= hi) ? ridgeFt : floorFt }
    }

    /// High ground inside a LONGITUDE band — a north–south ridge beside a northbound course.
    private struct LonRidge: TerrainSampling {
        let lo: Double, hi: Double, ridgeFt: Double
        var isReady: Bool { true }
        func sampleElevationFt(at c: Coord) -> Double? { (c.lon >= lo && c.lon <= hi) ? ridgeFt : 0 }
    }

    /// A grid with a no-data hole across a latitude band.
    private struct HoleTerrain: TerrainSampling {
        let lo: Double, hi: Double
        var isReady: Bool { true }
        func sampleElevationFt(at c: Coord) -> Double? { (c.lat >= lo && c.lat <= hi) ? nil : 0 }
    }

    /// Coverage that ends at a longitude — everything west of `edgeLon` is off-grid. Models a coastal
    /// or border glide where only the LATERAL corridor tracks leave the grid.
    private struct WestEdgeTerrain: TerrainSampling {
        let edgeLon: Double
        var isReady: Bool { true }
        func sampleElevationFt(at c: Coord) -> Double? { c.lon < edgeLon ? nil : 0 }
    }

    /// High ground confined to the aircraft's OWN cell — the MAX-aggregation case where the grid reads
    /// above the airplane because its cell holds a ridge the airplane is flying beside.
    private struct OwnCellHigh: TerrainSampling {
        let center: Coord, radiusNm: Double, highFt: Double, floorFt: Double
        var isReady: Bool { true }
        func sampleElevationFt(at c: Coord) -> Double? {
            Geo.nmBetween(center, c) <= radiusNm ? highFt : floorFt
        }
    }

    // MARK: fixtures

    private let origin = Coord(lat: 35.0, lon: -98.0)

    private func sit(altFt: Double, ratio: Double = 9, vAccM: Double? = 10) -> GlideSituation {
        GlideSituation(coord: origin, altitudeFtMSL: altFt, glideRatio: ratio,
                       isDefaultGlideRatio: false, verticalAccuracyM: vAccM)
    }

    /// An airport `nm` due north of the origin (1 NM = 1/60° latitude on the test sphere).
    private func apt(_ ident: String, nmNorth: Double, lonOffset: Double = 0, elev: Double = 0,
                     icao: String = "", use: String = "PU", status: String = "O",
                     tower: String = "NON-ATCT", fuel: String = "", siteType: String = "A",
                     far139: String = "") -> AirportData.Airport {
        AirportData.Airport(ident: ident, icao: icao, name: "\(ident) test field",
                            coord: Coord(lat: origin.lat + nmNorth / 60.0, lon: origin.lon + lonOffset),
                            elevationFt: elev, ownership: use, use: use, status: status,
                            tower: tower, fuel: fuel, siteType: siteType, far139: far139)
    }

    private let paved4000 = [AirportData.Runway(designator: "09/27", lengthFt: 4000, widthFt: 75,
                                                surface: "ASPH", condition: "GOOD", lights: "MED")]
    private let turf2000 = [AirportData.Runway(designator: "18/36", lengthFt: 2000, widthFt: 60,
                                               surface: "TURF", condition: "GOOD", lights: "")]
    private let paved12000 = [AirportData.Runway(designator: "17/35", lengthFt: 12000, widthFt: 150,
                                                 surface: "CONC", condition: "GOOD", lights: "HIGH")]

    private func assess(_ airports: [AirportData.Airport],
                        situation: GlideSituation,
                        runways: [String: [AirportData.Runway]] = [:],
                        weather: [String: NRSTWeather] = [:],
                        terrain: TerrainSampling) -> NRSTAssessment {
        NearestAirports.assess(situation: situation, airports: airports,
                               runwaysFor: { runways[$0] ?? self.paved4000 },
                               weather: weather, terrain: terrain, now: Date(timeIntervalSince1970: 1_800_000_000))
    }

    // MARK: glide range math

    func testStillAirRangeIsAltitudeTimesRatioMinusReserve() {
        // 8,076 ft over a 1,000 ft field: spend = 8,076 − 1,000 − 1,000 = 6,076 ft ≈ 1 NM of drop,
        // so at 10:1 the still-air range is (6076 / 6076.115) * 10 ≈ 10 NM.
        let s = sit(altFt: 8076, ratio: 10)
        XCTAssertEqual(NearestAirports.stillAirRangeNm(s, fieldElevFt: 1000), 10.0, accuracy: 0.001)
        // Below the arrival reserve there is no range at all — never a negative.
        XCTAssertEqual(NearestAirports.stillAirRangeNm(sit(altFt: 900), fieldElevFt: 0), 0)
    }

    // MARK: altitude sourcing (live GPS, and the carry-forward when it drops out)

    func testGlideSinkMatchesTheBookFigure() {
        // A C172 at 65 kt on 9:1 books ~730 fpm: 65/9 = 7.22 NM/h down = 43,882 ft/h = 731 fpm.
        XCTAssertEqual(NearestAirports.glideSinkFpm(glideRatio: 9, bestGlideKts: 65), 731, accuracy: 1)
        // Steeper glide = faster sink; better glide = slower.
        XCTAssertGreaterThan(NearestAirports.glideSinkFpm(glideRatio: 7, bestGlideKts: 65),
                             NearestAirports.glideSinkFpm(glideRatio: 9, bestGlideKts: 65))
        // No profile speed → the documented default, still a sane sink.
        let d = NearestAirports.glideSinkFpm(glideRatio: NearestAirports.defaultGlideRatio)
        XCTAssertGreaterThan(d, 500)
        XCTAssertLessThan(d, 1500)
    }

    func testCarriedAltitudeOnlyEverDescends() {
        let last = 8000.0
        let sink = NearestAirports.glideSinkFpm(glideRatio: 9, bestGlideKts: 65)   // 731 fpm
        // 30 s of carry costs half a minute of sink — and the result is LOWER than the last known
        // altitude, which is the only safe direction (it shortens every range on the list).
        let at30 = NearestAirports.carriedAltitudeFt(lastFtMSL: last, ageS: 30, sinkFpm: sink)
        XCTAssertEqual(at30, last - sink / 2, accuracy: 0.5)
        XCTAssertLessThan(at30, last)
        // Monotonic in age, and never negative however long the gap.
        let at60 = NearestAirports.carriedAltitudeFt(lastFtMSL: last, ageS: 60, sinkFpm: sink)
        XCTAssertLessThan(at60, at30)
        XCTAssertEqual(NearestAirports.carriedAltitudeFt(lastFtMSL: 200, ageS: 600, sinkFpm: sink), 0)
        // Age zero is a no-op (the live-fix path must not be perturbed by this helper).
        XCTAssertEqual(NearestAirports.carriedAltitudeFt(lastFtMSL: last, ageS: 0, sinkFpm: sink), last)
    }

    /// A carried altitude must SHRINK the reachable set, never grow it.
    func testCarriedAltitudeShortensRangeAndCanDropAFieldOutOfGlide() {
        let live = sit(altFt: 6000)                                     // range 7.41 NM to a sea-level field
        let sink = NearestAirports.glideSinkFpm(glideRatio: 9, bestGlideKts: 65)
        let carriedFt = NearestAirports.carriedAltitudeFt(lastFtMSL: 6000, ageS: 45, sinkFpm: sink)
        var carried = sit(altFt: carriedFt)
        carried.altitudeAgeS = 45
        XCTAssertTrue(carried.isAltitudeCarried)
        XCTAssertFalse(live.isAltitudeCarried)
        XCTAssertLessThan(NearestAirports.stillAirRangeNm(carried, fieldElevFt: 0),
                          NearestAirports.stillAirRangeNm(live, fieldElevFt: 0))
        // A field near the live edge of glide must fall OUT once the altitude is carried forward.
        let edge = apt("EDGE", nmNorth: 7.2)
        XCTAssertEqual(assess([edge], situation: live, terrain: ConstTerrain()).candidates.first?.reachability,
                       .caution(.thinMargin))
        XCTAssertEqual(assess([edge], situation: carried, terrain: ConstTerrain()).candidates.first?.reachability,
                       .outOfGlide, "a stale altitude must never keep a field on the reachable list")
    }

    func testAssessmentReportsTerrainUnderTheAircraftForAgl() {
        // AGL is height over the ground BELOW; the ranges are height over each FIELD. Both must be right.
        let s = sit(altFt: 9000)
        let a = assess([apt("FLD", nmNorth: 4, elev: 5000)], situation: s,
                       terrain: ConstTerrain(elevFt: 5000))
        XCTAssertEqual(a.ownshipTerrainFt ?? 0, 5000, accuracy: 0.5)
        XCTAssertEqual(a.ownshipAglFt ?? 0, 4000, accuracy: 0.5)
        // No grid → no AGL claim at all (rather than a wrong one).
        let dead = assess([apt("FLD", nmNorth: 4)], situation: s, terrain: ConstTerrain(ready: false))
        XCTAssertNil(dead.ownshipTerrainFt)
        XCTAssertNil(dead.ownshipAglFt)
    }

    func testReachabilityGroupsOverFlatTerrain() {
        // 6,000 ft, 9:1, sea-level fields: spend 5,000 ft → range 7.406 NM.
        let s = sit(altFt: 6000)
        let a = assess([apt("NEAR", nmNorth: 4), apt("EDGE", nmNorth: 7), apt("FAR", nmNorth: 30)],
                       situation: s, terrain: ConstTerrain())
        let by = Dictionary(uniqueKeysWithValues: a.candidates.map { ($0.id, $0) })
        XCTAssertEqual(by["NEAR"]?.reachability, .clear)
        // margin at 4 NM = (7.406 − 4) / 9 * 6076.115 ≈ 2,300 ft
        XCTAssertEqual(by["NEAR"]?.arrivalMarginFt ?? 0, 2300, accuracy: 15)
        XCTAssertEqual(by["EDGE"]?.reachability, .caution(.thinMargin))   // ~274 ft to spare
        XCTAssertEqual(by["FAR"]?.reachability, .outOfGlide)
        XCTAssertNil(by["FAR"]?.arrivalMarginFt)
        // Display order: the reachable ones first, the unreachable one last.
        XCTAssertEqual(a.candidates.last?.id, "FAR")
    }

    // MARK: the terrain sweep

    func testRidgeAcrossTheDescentProfileBlocks() {
        // 10,000 ft at 9:1 → range 13.3 NM. A 6,000 ft ridge 3–7 NM out: the profile crosses it at
        // ~5 NM sitting at 10,000 − 5 × 675 ≈ 6,625 ft — inside the required buffer → BLOCKED.
        let s = sit(altFt: 10_000)
        let ridge = LatRidge(lo: origin.lat + 3.0 / 60, hi: origin.lat + 7.0 / 60, ridgeFt: 6000)
        let a = assess([apt("BLKD", nmNorth: 10)], situation: s, terrain: ridge)
        guard case .blocked(let atNm)? = a.candidates.first?.reachability else {
            return XCTFail("expected blocked, got \(String(describing: a.candidates.first?.reachability))")
        }
        XCTAssertGreaterThan(atNm, 2.0)
        XCTAssertLessThan(atNm, 7.5)
        // Control: the same field over flat ground is clear.
        let flat = assess([apt("BLKD", nmNorth: 10)], situation: s, terrain: ConstTerrain())
        XCTAssertEqual(flat.candidates.first?.reachability, .clear)
    }

    func testBufferRampDoesNotBlankTheListWhenLow() {
        // 3,000 ft AGL over a 2,000 ft plateau (5,000 MSL): a strict ~800 ft buffer applied at
        // distance zero would fail every path immediately — the ramp must let the field 2 NM away
        // through (margin there is ~650 ft, comfortably past the thin-margin line).
        let s = sit(altFt: 5000)
        let a = assess([apt("LOW", nmNorth: 2, elev: 2000)], situation: s,
                       terrain: ConstTerrain(elevFt: 2000))
        XCTAssertEqual(a.candidates.first?.reachability, .clear,
                       "a low aircraft over flat ground must still see the field beside it")
    }

    func testCorridorCatchesARidgeJustOffCourse() {
        // Course is due north along lon −98. A 7,000 ft N–S wall covering only the WESTERN corridor
        // track (0.75 NM ≈ 0.0153° of longitude at 35°N) must still block — wind drift and track
        // error make "the direct line misses it by half a mile" no defence.
        let s = sit(altFt: 10_000)
        let offsetWall = LonRidge(lo: -98.030, hi: -98.010, ridgeFt: 7000)
        let a = assess([apt("DRFT", nmNorth: 10)], situation: s, terrain: offsetWall)
        guard case .blocked? = a.candidates.first?.reachability else {
            return XCTFail("the lateral corridor must catch a wall 0.75 NM off course")
        }
        // Control: a wall two miles further west is outside the corridor → clear.
        let farWall = LonRidge(lo: -98.080, hi: -98.060, ridgeFt: 7000)
        let b = assess([apt("DRFT", nmNorth: 10)], situation: s, terrain: farWall)
        XCTAssertEqual(b.candidates.first?.reachability, .clear)
    }

    // MARK: review regressions — the measurement margin and the endpoint-cell rule

    func testMeasurementMarginIsNeverDiscountedNearTheOwnship() {
        // A ridge 1.5 NM out, sitting between the OLD ramped threshold and the correct constant one.
        // At 10,000 ft, 9:1, vAcc 25 m: buffer = 500 + (25+80)*3.2808 = 844 ft, profile at 1.5 NM =
        // 10,000 − 1,013 = 8,987 ft, so anything above 8,143 ft must block. The old code ramped the
        // buffer to 633 ft there (1.5/2 of the sum) and let terrain up to 8,354 ft pass — with the
        // grid's own 262 ft summit under-read on top, that admitted rock ABOVE the true glide path.
        let s = sit(altFt: 10_000, ratio: 9, vAccM: 25)
        let ridge = LatRidge(lo: origin.lat + 1.4 / 60, hi: origin.lat + 1.7 / 60, ridgeFt: 8250)
        let a = assess([apt("RIDG", nmNorth: 8)], situation: s, terrain: ridge)
        guard case .blocked? = a.candidates.first?.reachability else {
            return XCTFail("terrain inside the measurement margin must block, got \(String(describing: a.candidates.first?.reachability))")
        }
        // Sanity: the same ridge 300 ft lower (clear of the full buffer) does not block.
        let lower = LatRidge(lo: origin.lat + 1.4 / 60, hi: origin.lat + 1.7 / 60, ridgeFt: 7900)
        XCTAssertEqual(assess([apt("RIDG", nmNorth: 8)], situation: s, terrain: lower)
                        .candidates.first?.reachability, .clear)
    }

    func testOwnshipCellReadingAboveTheAircraftDoesNotBlankTheList() {
        // The MAX-aggregated grid routinely reads ABOVE the aircraft: its ~1 NM cell can hold a
        // ridgetop the airplane is flying BESIDE, not under (`AGLReading.isBelowSurfaceModel`
        // documents this as normal). Station 0 is common to every candidate, so comparing that
        // reading against the profile marked the ENTIRE list blocked at 0.0 NM — the blanking this
        // feature exists to avoid. Here: at 8,000 ft with the ownship cell reading 8,500 ft and
        // plains beyond it, the fields must still be reachable.
        let s = sit(altFt: 8000)
        let ownCellHigh = OwnCellHigh(center: origin, radiusNm: 0.9, highFt: 8500, floorFt: 1000)
        let a = assess([apt("PLN1", nmNorth: 4, elev: 1000), apt("PLN2", nmNorth: 6, elev: 1000)],
                       situation: s, terrain: ownCellHigh)
        XCTAssertEqual(a.candidates.count, 2)
        for c in a.candidates {
            XCTAssertEqual(c.reachability, .clear,
                           "\(c.id): the ownship's own cell must not read as an obstruction (got \(c.reachability))")
        }
        // But terrain HIGHER than the ownship's own reading must still block even inside that first
        // mile: the exemption is "no higher than what I am demonstrably clearing", not "anything near".
        let towerAhead = LatRidge(lo: origin.lat + 0.5 / 60, hi: origin.lat + 0.9 / 60,
                                  ridgeFt: 12_000, floorFt: 1000)
        guard case .blocked? = assess([apt("PLN1", nmNorth: 4, elev: 1000)], situation: s,
                                      terrain: towerAhead).candidates.first?.reachability else {
            return XCTFail("terrain above the ownship-cell reading must still block")
        }
        // And a ridge past the exempt zone blocks normally.
        let ridge = LatRidge(lo: origin.lat + 2.0 / 60, hi: origin.lat + 3.0 / 60,
                             ridgeFt: 9000, floorFt: 1000)
        guard case .blocked? = assess([apt("PLN2", nmNorth: 6, elev: 1000)], situation: s,
                                      terrain: ridge).candidates.first?.reachability else {
            return XCTFail("a ridge across the enroute profile must block")
        }
    }

    func testLateralCorridorLeavingCoverageIsCautionNotClear() {
        // Course due north with the grid ending 0.5 NM west of it: the centre track and the eastern
        // track are in coverage, the western one is not. Silently dropping that sample ranked a
        // coastal/border glide CLEAR on two thirds of the evidence.
        let s = sit(altFt: 10_000)
        let edge = WestEdgeTerrain(edgeLon: origin.lon - 0.010)     // ~0.5 NM west at 35°N
        let a = assess([apt("COAST", nmNorth: 8)], situation: s, terrain: edge)
        XCTAssertEqual(a.candidates.first?.reachability, .caution(.terrainUnknown),
                       "an unverifiable corridor track must be CAUTION, never CLEAR")
    }

    func testBestInGlideFieldIsNotTruncatedAwayByNearerRecords() {
        // 60 helipad/closed records nearer than the one real airport: capping the INPUT nearest-first
        // would drop the only landable field before it was ever swept, presenting "nothing reachable".
        var airports: [AirportData.Airport] = []
        for i in 0..<60 {
            airports.append(apt("H\(i)", nmNorth: 1 + Double(i) * 0.05, siteType: "H"))
        }
        airports.append(apt("REAL", nmNorth: 6, icao: "KRLA"))
        let a = assess(airports, situation: sit(altFt: 8000), terrain: ConstTerrain())
        XCTAssertEqual(a.candidates.map(\.id), ["REAL"],
                       "the one landable field must survive candidate truncation")
    }

    func testGridHolesFailClosedToCaution() {
        let s = sit(altFt: 10_000)
        let hole = HoleTerrain(lo: origin.lat + 3.0 / 60, hi: origin.lat + 5.0 / 60)
        let a = assess([apt("HOLE", nmNorth: 10)], situation: s, terrain: hole)
        XCTAssertEqual(a.candidates.first?.reachability, .caution(.terrainUnknown),
                       "a sweep through a data hole is unverified — never clear, never blocked")
        // A grid that is not ready at all: every in-glide field is caution, none clear.
        let dead = assess([apt("HOLE", nmNorth: 5)], situation: s, terrain: ConstTerrain(ready: false))
        XCTAssertEqual(dead.candidates.first?.reachability, .caution(.terrainUnknown))
        XCTAssertFalse(dead.terrainAvailable)
    }

    // MARK: the ranking hierarchy

    func testVisualFieldOutranksInstrumentFieldWithBetterEverything() {
        // The pilot's own example: both in glide, one visual — choose the visual one, even though
        // the other is a towered Part-139 field with a 12,000 ft lit concrete runway and fuel.
        // (±0.05° of longitude ≈ 2.5 NM at 35°N → both sit ~5.6 NM out, well inside the 10.4 NM range.)
        let s = sit(altFt: 8000)
        let small = apt("GRA", nmNorth: 5, lonOffset: -0.05)
        let big = apt("BIG", nmNorth: 5, lonOffset: 0.05, icao: "KBIG",
                      tower: "ATCT", fuel: "100LL,A", far139: "I E")
        let a = assess([big, small], situation: s,
                       runways: ["GRA": turf2000, "BIG": paved12000],
                       weather: ["KGRA": .init(category: .vfr, ageMinutes: 10),
                                 "KBIG": .init(category: .ifr, ageMinutes: 10)],
                       terrain: ConstTerrain())
        XCTAssertEqual(a.candidates.map(\.id), ["GRA", "BIG"],
                       "weather is lexicographic: VFR beats IFR regardless of runways/facilities")
        // Same two fields, both VFR: now the hierarchy falls to runways/facilities → BIG first.
        let b = assess([small, big], situation: s,
                       runways: ["GRA": turf2000, "BIG": paved12000],
                       weather: ["KGRA": .init(category: .vfr, ageMinutes: 10),
                                 "KBIG": .init(category: .vfr, ageMinutes: 10)],
                       terrain: ConstTerrain())
        XCTAssertEqual(b.candidates.map(\.id), ["BIG", "GRA"])
    }

    func testUnknownWeatherRanksBetweenMvfrAndIfr() {
        let s = sit(altFt: 8000)
        let a = assess([apt("AAAA", nmNorth: 5, lonOffset: -0.05, icao: "KAAA"),
                        apt("BBBB", nmNorth: 5, icao: "KBBB"),
                        apt("CCCC", nmNorth: 5, lonOffset: 0.05, icao: "KCCC")],
                       situation: s,
                       weather: ["KAAA": .init(category: .ifr, ageMinutes: 5),
                                 "KCCC": .init(category: .mvfr, ageMinutes: 5)],
                       terrain: ConstTerrain())
        XCTAssertEqual(a.candidates.map(\.id), ["CCCC", "BBBB", "AAAA"],
                       "MVFR, then no-report, then IFR")
    }

    func testTerrainHostilityOutranksRunwayAndFacilities() {
        // Both no-report, both clear: a flat-country turf strip must outrank a big towered field
        // ringed by 4,500 ft of rising terrain (tier 3 above tiers 4–5). The hostile wall sits
        // 0.025°–0.085° EAST of CNYN: its 3 NM vicinity ring reaches it, but the glide corridor
        // (≤0.75 NM ≈ 0.015° beside the course) never does.
        let s = sit(altFt: 8000)
        let flat = apt("FLAT", nmNorth: 4, lonOffset: -0.05)
        let canyon = apt("CNYN", nmNorth: 4, lonOffset: 0.05, tower: "ATCT", fuel: "100LL", far139: "I A")
        let ring = LonRidge(lo: canyon.coord.lon + 0.025, hi: canyon.coord.lon + 0.085, ridgeFt: 4500)
        let a = assess([canyon, flat], situation: s,
                       runways: ["FLAT": turf2000, "CNYN": paved12000],
                       terrain: ring)
        XCTAssertEqual(a.candidates.first?.id, "FLAT",
                       "wTerrain (\(NearestAirports.wTerrain)) must dominate runway+facility (\(NearestAirports.wRunway + NearestAirports.wFacility)) — got \(a.candidates.map(\.id))")
        XCTAssertGreaterThan(a.candidates.first(where: { $0.id == "CNYN" })?.terrainRiseFt ?? 0, 4000)
    }

    func testCloserFieldWinsTheTiebreakWhenOtherwiseEqual() {
        let s = sit(altFt: 8000)
        let a = assess([apt("FARR", nmNorth: 6), apt("CLOS", nmNorth: 3)],
                       situation: s, terrain: ConstTerrain())
        XCTAssertEqual(a.candidates.first?.id, "CLOS", "more margin = better tiebreak")
    }

    // MARK: exclusions + inputs

    func testNonAirplaneAndClosedFacilitiesAreExcluded() {
        let s = sit(altFt: 8000)
        let heli = apt("HELI", nmNorth: 2, siteType: "H")
        let seap = apt("SEAP", nmNorth: 2, lonOffset: 0.1, siteType: "C")
        let closed = apt("CLSD", nmNorth: 2, lonOffset: 0.2, status: "CI")
        let waterOnly = apt("WATR", nmNorth: 2, lonOffset: 0.3)
        let padOnly = apt("PADS", nmNorth: 2, lonOffset: 0.4, siteType: "")
        let legacyOK = apt("LGCY", nmNorth: 2, lonOffset: 0.5, siteType: "")   // pre-site_type DB row
        let a = assess([heli, seap, closed, waterOnly, padOnly, legacyOK], situation: s,
                       runways: ["WATR": [AirportData.Runway(designator: "N/S", lengthFt: 8000, widthFt: 500,
                                                             surface: "WATER", condition: "")],
                                 "PADS": [AirportData.Runway(designator: "H1", lengthFt: 60, widthFt: 60,
                                                             surface: "CONC", condition: "GOOD")],
                                 "LGCY": turf2000],
                       terrain: ConstTerrain())
        XCTAssertEqual(a.candidates.map(\.id), ["LGCY"],
                       "heliports, seaplane bases, closed fields, water-only and pad-only records must not be glide targets")
    }

    func testStaleMetarRanksAsUnknown() {
        XCTAssertEqual(NearestAirports.effectiveCategory(NRSTWeather(category: .vfr, ageMinutes: 200)), .unknown)
        XCTAssertEqual(NearestAirports.effectiveCategory(NRSTWeather(category: .vfr, ageMinutes: 60)), .vfr)
        XCTAssertEqual(NearestAirports.effectiveCategory(nil), .unknown)
    }

    func testWxIdentUsesTheIcaoColumnAndNeverFabricatesOne() {
        XCTAssertEqual(NearestAirports.wxIdent(for: apt("DFW", nmNorth: 0, icao: "KDFW")), "KDFW")
        XCTAssertNil(NearestAirports.wxIdent(for: apt("52F", nmNorth: 0)),
                     "alphanumeric FAA idents have no ICAO form and never report")
        // No "prepend K" fallback: measured against the shipped cycle it fired only on Alaska/Pacific
        // fields, where K is the WRONG prefix (PAEN, not KENA) — fabricating an ident that fetches
        // nothing and ranks a reporting field as no-report.
        XCTAssertNil(NearestAirports.wxIdent(for: apt("ENA", nmNorth: 0)),
                     "a blank icao column must not be turned into a guessed K-ident")
    }

    func testFacilitiesScoring() {
        XCTAssertEqual(NearestAirports.facilities(apt("A", nmNorth: 0, far139: "I E")), 0.92, accuracy: 1e-9)
        XCTAssertEqual(NearestAirports.facilities(apt("B", nmNorth: 0, far139: "I A")), 0.60, accuracy: 1e-9)
        XCTAssertEqual(NearestAirports.facilities(apt("C", nmNorth: 0, tower: "ATCT", fuel: "100LL")), 0.70, accuracy: 1e-9)
        XCTAssertEqual(NearestAirports.facilities(apt("D", nmNorth: 0, use: "PR")), 0.0, accuracy: 1e-9)
    }

    func testGeodesyHelpers() {
        // ~60 NM due north ≈ 1° of latitude (1° = 60.04 NM on the R=3440.065 sphere).
        let north = Geo.destination(from: origin, bearingDeg: 0, distanceNm: 60)
        XCTAssertEqual(north.lat, origin.lat + 1.0, accuracy: 0.002)
        XCTAssertEqual(north.lon, origin.lon, accuracy: 0.001)
        let mid = Geo.interpolate(origin, north, fraction: 0.5)
        XCTAssertEqual(Geo.nmBetween(origin, mid), 30, accuracy: 0.05)
    }
}
