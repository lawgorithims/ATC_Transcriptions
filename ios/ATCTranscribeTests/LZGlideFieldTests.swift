import XCTest
@testable import ATCTranscribe

/// Tests for the live glide/arrival-energy engine.
///
/// Synthetic terrain throughout, in the same style as `NearestAirportsTests`: the point is to pin
/// the two imported safety invariants and the energy classification against surfaces whose right
/// answer is known by hand, not to re-measure New Mexico.
final class LZGlideFieldTests: XCTestCase {

    // MARK: - synthetic terrain

    /// Flat ground everywhere.
    private struct Flat: TerrainSampling {
        let ft: Double
        var isReady: Bool { true }
        func sampleElevationFt(at coord: Coord) -> Double? { ft }
    }

    /// A north-south wall east of the origin.
    private struct EastRidge: TerrainSampling {
        let baseFt: Double, crestFt: Double, atLonOffset: Double
        var isReady: Bool { true }
        func sampleElevationFt(at coord: Coord) -> Double? {
            coord.lon >= atLonOffset ? crestFt : baseFt
        }
    }

    /// High ground that DROPS AWAY beyond a line — the backside-of-the-mountain case.
    private struct RidgeThenValley: TerrainSampling {
        let plateauFt: Double, valleyFt: Double, crestLon: Double
        var isReady: Bool { true }
        func sampleElevationFt(at coord: Coord) -> Double? {
            coord.lon >= crestLon ? valleyFt : plateauFt
        }
    }

    /// Terrain with no data at all east of a line.
    private struct HoleEast: TerrainSampling {
        let ft: Double, holeLon: Double
        var isReady: Bool { true }
        func sampleElevationFt(at coord: Coord) -> Double? {
            coord.lon >= holeLon ? nil : ft
        }
    }

    private struct NotReady: TerrainSampling {
        var isReady: Bool { false }
        func sampleElevationFt(at coord: Coord) -> Double? { nil }
    }

    private let origin = Coord(lat: 32.0, lon: -106.0)

    private func input(altFt: Double = 9000, ratio: Double = 9,
                       windFrom: Double? = nil, windKts: Double? = nil,
                       vAcc: Double? = 10) -> LZGlideField.Input {
        LZGlideField.Input(coord: origin, altitudeFtMSL: altFt, glideRatio: ratio,
                           isDefaultGlideRatio: false, bestGlideKts: 65,
                           windFromDeg: windFrom, windKts: windKts, verticalAccuracyM: vAcc)
    }

    private func field(_ i: LZGlideField.Input, _ t: TerrainSampling) throws -> LZEnergyField {
        try XCTUnwrap(LZGlideField.compute(i, terrain: t))
    }

    // MARK: - range

    func testStillAirRangeMatchesTheGlideFormula() {
        // (9000 - 0 ground - 1000 reserve) ft at 9:1 = 72,000 ft = 11.85 NM
        let r = LZGlideField.stillAirRangeNm(altitudeFtMSL: 9000, groundFt: 0, glideRatio: 9)
        XCTAssertEqual(r, 8000 * 9 / NearestAirports.ftPerNm, accuracy: 1e-9)
        XCTAssertEqual(r, 11.85, accuracy: 0.02)
    }

    /// The reserve is AGL, not MSL. Over high ground the footprint must shrink accordingly —
    /// otherwise the glide is modelled as reaching the altitude of the terrain it sits on, and the
    /// entire outer edge trips the terrain test and paints as a ring of "blocked".
    func testReserveIsMeasuredAboveGroundNotAboveSeaLevel() {
        let sea = LZGlideField.stillAirRangeNm(altitudeFtMSL: 9000, groundFt: 0, glideRatio: 9)
        let high = LZGlideField.stillAirRangeNm(altitudeFtMSL: 9000, groundFt: 4000, glideRatio: 9)
        XCTAssertLessThan(high, sea)
        XCTAssertEqual(high, 4000 * 9 / NearestAirports.ftPerNm, accuracy: 1e-9)
        // A hole under the aircraft falls back to MSL — under-stating reach, never over-stating it.
        XCTAssertEqual(LZGlideField.stillAirRangeNm(altitudeFtMSL: 9000, groundFt: nil,
                                                    glideRatio: 9), sea, accuracy: 1e-9)
    }

    func testBelowReserveAltitudeYieldsNoRange() {
        XCTAssertEqual(LZGlideField.stillAirRangeNm(altitudeFtMSL: 500, groundFt: 0, glideRatio: 9), 0)
        XCTAssertEqual(LZGlideField.stillAirRangeNm(altitudeFtMSL: 5000, groundFt: 4500,
                                                    glideRatio: 9), 0, "no reach from 500 ft AGL")
    }

    func testFlatGroundGivesAFullFootprintOnEveryAzimuth() throws {
        // 9000 ft over ground at 4000 = 4000 ft usable after the reserve -> 5.9 NM at 9:1.
        let f = try field(input(), Flat(ft: 4000))
        XCTAssertEqual(f.maxRangeNm, 4000 * 9 / NearestAirports.ftPerNm, accuracy: 0.05)
        XCTAssertFalse(f.sawHole)
        // Every azimuth contributed a sector, so nothing is silently missing.
        let rings = f.bands.reduce(0) { $0 + $1.rings.count }
        XCTAssertGreaterThanOrEqual(rings, LZGlideField.azimuthCount)
    }

    func testUnreadyTerrainYieldsNoFieldRatherThanAnEmptyOne() {
        XCTAssertNil(LZGlideField.compute(input(), terrain: NotReady()),
                     "no terrain must be nil — an empty field would draw as 'all clear'")
    }

    func testImplausibleGlideRatioIsRefused() {
        XCTAssertNil(LZGlideField.compute(input(ratio: 200), terrain: Flat(ft: 0)))
        XCTAssertNil(LZGlideField.compute(input(ratio: 1), terrain: Flat(ft: 0)))
    }

    // MARK: - INVARIANT 1: the measurement buffer is never discounted

    func testBufferMatchesTheNRSTFormulaExactly() {
        for acc in [nil, 5.0, 25.0, 100.0] as [Double?] {
            let expected = NearestAirports.enrouteBufferFt
                + ((acc ?? NearestAirports.defaultVerticalAccuracyM)
                   + TerrainElevation.peakUnderReadM) * GPSReadout.mToFt
            XCTAssertEqual(LZGlideField.clearanceBufferFt(verticalAccuracyM: acc), expected,
                           accuracy: 1e-9, "the glide field must not invent its own clearance rule")
        }
    }

    /// Terrain just under the profile but inside the buffer must BLOCK. If the buffer were tapered
    /// or dropped, this ray would read as reachable.
    func testTerrainInsideTheBufferBlocksEvenThoughItIsBelowTheProfile() throws {
        let buffer = LZGlideField.clearanceBufferFt(verticalAccuracyM: 10)
        // At ~5 NM on a 9:1 profile from 9000 ft, the profile is ~9000 - 5*675 = 5625 ft.
        // Put the crest just inside the buffer: below the profile, but not by enough.
        let crest = 9000 - 5 * (NearestAirports.ftPerNm / 9) - buffer + 50
        let f = try field(input(), EastRidge(baseFt: 1000, crestFt: crest, atLonOffset: -105.95))
        let blocked = f.bands.first { $0.classification == .blocked }
        XCTAssertNotNil(blocked, "terrain inside the clearance buffer must block the ray")
    }

    // MARK: - INVARIANT 2: the ownship's own cell is not an obstacle

    /// The terrain grid is MAX-aggregated, so the cell the aircraft occupies routinely reads higher
    /// than the aircraft itself. Treating that as an obstruction blanks the whole field.
    func testOwnshipCellReadingAboveTheAircraftDoesNotBlankTheField() throws {
        // Ground reads 500 ft ABOVE the aircraft everywhere — the pathological case an aeroplane
        // near a peak actually produces, because the grid is MAX-aggregated.
        let f = try field(input(altFt: 5000), Flat(ft: 5500))
        XCTAssertFalse(f.bands.isEmpty, "the ownship's own cell blanked the entire field")
        XCTAssertGreaterThan(f.maxRangeNm, 1, "an over-reading own cell zeroed the sweep bound")
        // Honest outcome: the near field classifies, and everything past the ownship's own cell is
        // blocked — the model cannot see over ground it believes is above the aeroplane.
        XCTAssertTrue(f.bands.contains { $0.classification == .blocked })
    }

    // MARK: - terrain shapes

    func testARidgeBlocksOnlyItsOwnSector() throws {
        let f = try field(input(), EastRidge(baseFt: 1000, crestFt: 12000, atLonOffset: -105.98))
        let blocked = try XCTUnwrap(f.bands.first { $0.classification == .blocked })
        // Blocked sectors must all lie EAST of the origin.
        for ring in blocked.rings {
            let meanLon = ring.dropLast().map(\.lon).reduce(0, +) / Double(ring.count - 1)
            XCTAssertGreaterThan(meanLon, origin.lon - 0.001,
                                 "a ridge to the east blocked a westward ray")
        }
        // ...and the west must still be reachable.
        XCTAssertTrue(f.bands.contains { $0.classification != .blocked },
                      "an eastern ridge blocked the whole field")
    }

    func testNothingIsClassifiedBeyondABlockingRidge() throws {
        // A wall the glide cannot clear: every ray east must terminate AT it, not resume past it.
        let f = try field(input(), EastRidge(baseFt: 1000, crestFt: 20000, atLonOffset: -105.99))
        let blocked = try XCTUnwrap(f.bands.first { $0.classification == .blocked })
        let farthestBlocked = blocked.rings.flatMap { $0 }.map { Geo.nmBetween(origin, $0) }.max() ?? 0
        for band in f.bands where band.classification != .blocked {
            for ring in band.rings {
                let meanLon = ring.dropLast().map(\.lon).reduce(0, +) / Double(ring.count - 1)
                guard meanLon > origin.lon else { continue }        // only rays pointing at the wall
                let near = ring.map { Geo.nmBetween(origin, $0) }.min() ?? 0
                XCTAssertLessThanOrEqual(near, farthestBlocked + 1.0,
                                         "reachable ground appeared BEYOND a blocking ridge")
            }
        }
    }

    // MARK: - the excess-energy case (the reason this engine exists)

    func testArrivalClassificationBoundaries() {
        XCTAssertEqual(LZGlideField.arrivalClass(arrivalFt: 999), .marginal)
        XCTAssertEqual(LZGlideField.arrivalClass(arrivalFt: 1001), .comfortable)
        XCTAssertEqual(LZGlideField.arrivalClass(arrivalFt: 2999), .comfortable)
        XCTAssertEqual(LZGlideField.arrivalClass(arrivalFt: 3001), .excess)
        // Negative arrival height is still "marginal" by class — the BLOCKED test happens first,
        // against the buffer, so this branch only ever sees reachable ground.
        XCTAssertEqual(LZGlideField.arrivalClass(arrivalFt: -50), .marginal)
    }

    /// Ground that falls away past a ridge produces an EXCESS band: the aircraft arrives over the
    /// valley floor with far more height than it can shed.
    ///
    /// The altitude here is chosen so the PLATEAU side reads comfortable (2,750–3,000 ft above it)
    /// and only the dropped-away ground crosses into excess. An earlier version flew 4,000 ft above
    /// the plateau, which is legitimately excess energy over the plateau too — the engine was right
    /// and the test's geography assumption was wrong.
    func testGroundFallingAwayPastARidgeReadsAsExcessEnergy() throws {
        let t = RidgeThenValley(plateauFt: 7000, valleyFt: 1000, crestLon: -105.97)
        let f = try field(input(altFt: 10000, ratio: 12), t)
        let excess = try XCTUnwrap(f.bands.first { $0.classification == .excess },
                                   "a valley beyond a ridge must read as excess energy")
        // Aggregate rather than assert per ring: one failure should report the shape, not 60 times.
        let meanLons = excess.rings.map { r in
            r.dropLast().map(\.lon).reduce(0, +) / Double(r.count - 1)
        }
        let onPlateauSide = meanLons.filter { $0 < origin.lon }.count
        XCTAssertEqual(onPlateauSide, 0,
                       "\(onPlateauSide)/\(meanLons.count) excess sectors fell on the plateau side")
        XCTAssertFalse(meanLons.isEmpty)
    }

    /// Over FLAT ground the footprint is excess near the aircraft and comfortable at the rim — and
    /// never marginal, because the reserve and the marginal threshold are the same 1,000 ft: the
    /// edge of the glide is BY DEFINITION where arrival height falls to the reserve. Marginal only
    /// appears where terrain rises to meet the profile early, which is exactly what it should mean.
    func testFlatGroundIsExcessNearTheAircraftAndComfortableAtTheRim() throws {
        let f = try field(input(altFt: 10000, ratio: 10), Flat(ft: 0))
        XCTAssertTrue(f.bands.contains { $0.classification == .excess },
                      "high above flat ground must produce an excess band")
        XCTAssertTrue(f.bands.contains { $0.classification == .comfortable })
        XCTAssertFalse(f.bands.contains { $0.classification == .blocked },
                       "flat ground must not produce a ring of 'blocked' at the footprint edge")
    }

    /// ...and marginal DOES appear once terrain rises into the profile.
    func testRisingTerrainProducesAMarginalBandBeforeItBlocks() throws {
        // Swept rather than hand-tuned: whether a given crest lands in the marginal window depends
        // on where the ray's stations happen to fall, so pinning one magic height tests the sampling
        // grid, not the classification. Somewhere in this range the ground must read marginal —
        // high enough to eat the arrival height, not yet high enough to breach the buffer.
        var sawMarginal = false
        for crest in stride(from: 6000.0, through: 7200.0, by: 100.0) {
            let f = try field(input(altFt: 9000, ratio: 9),
                              EastRidge(baseFt: 1000, crestFt: crest, atLonOffset: -105.97))
            if f.bands.contains(where: { $0.classification == .marginal }) { sawMarginal = true; break }
        }
        XCTAssertTrue(sawMarginal,
                      "no crest height produced a marginal band — rising ground goes straight to blocked")
    }

    // MARK: - wind

    func testTailwindExtendsAndHeadwindShortensTheSameRay() {
        let calm = LZGlideField.effectiveGlideRatio(input(), azimuthDeg: 90)
        // Wind FROM 270 blows TOWARDS 090 — a tailwind for an eastbound glide.
        let tail = LZGlideField.effectiveGlideRatio(input(windFrom: 270, windKts: 25),
                                                    azimuthDeg: 90)
        let head = LZGlideField.effectiveGlideRatio(input(windFrom: 90, windKts: 25),
                                                    azimuthDeg: 90)
        XCTAssertGreaterThan(tail, calm, "a tailwind must extend the glide")
        XCTAssertLessThan(head, calm, "a headwind must shorten it")
        // Crosswind is very nearly neutral.
        let cross = LZGlideField.effectiveGlideRatio(input(windFrom: 0, windKts: 25),
                                                     azimuthDeg: 90)
        XCTAssertEqual(cross, calm, accuracy: calm * 0.02)
    }

    func testWindScalingIsBounded() {
        // An absurd wind must not invent an implausible footprint.
        let huge = LZGlideField.effectiveGlideRatio(input(windFrom: 270, windKts: 400),
                                                    azimuthDeg: 90)
        XCTAssertLessThanOrEqual(huge, input().glideRatio * LZGlideField.windRatioMax + 1e-9)
        let against = LZGlideField.effectiveGlideRatio(input(windFrom: 90, windKts: 400),
                                                       azimuthDeg: 90)
        XCTAssertGreaterThanOrEqual(against, input().glideRatio * LZGlideField.windRatioMin - 1e-9)
    }

    func testFieldReportsWhetherWindWasActuallyUsed() throws {
        XCTAssertFalse(try field(input(), Flat(ft: 1000)).usedWind)
        XCTAssertTrue(try field(input(windFrom: 270, windKts: 20), Flat(ft: 1000)).usedWind)
    }

    // MARK: - fail-closed

    /// Losing terrain coverage must be reported AND must not classify as comfortable. Unverified
    /// ground rendered as reachable is the failure this whole layer exists to avoid.
    func testDataHolesAreReportedAndNeverReadAsComfortable() throws {
        let f = try field(input(), HoleEast(ft: 1000, holeLon: -105.98))
        XCTAssertTrue(f.sawHole, "a terrain hole must be surfaced so the badge can say so")
        // No sector lying ENTIRELY in the hole may read reachable. Testing the sector's inner edge
        // rather than its centroid: a sector that straddles the boundary legitimately covers real
        // ground on its near side, and judging it by its mean would fail on geometry, not on logic.
        let holeLon = -105.98
        var offenders = 0
        for band in f.bands where band.classification == .comfortable || band.classification == .excess {
            for ring in band.rings where (ring.map(\.lon).min() ?? 0) >= holeLon {
                offenders += 1
            }
        }
        XCTAssertEqual(offenders, 0, "\(offenders) sectors with no terrain data read as reachable")
    }

    // MARK: - geometry

    func testEverySectorIsAClosedQuadWithinTheFootprint() throws {
        let f = try field(input(), Flat(ft: 2000))
        for band in f.bands {
            for ring in band.rings {
                XCTAssertEqual(ring.count, 5, "a sector must be a closed quad")
                XCTAssertEqual(ring.first?.lat, ring.last?.lat)
                XCTAssertEqual(ring.first?.lon, ring.last?.lon)
                for p in ring {
                    XCTAssertLessThanOrEqual(Geo.nmBetween(origin, p), f.maxRangeNm + 0.6,
                                             "a sector escaped the computed footprint")
                }
            }
        }
    }

    func testWorseClassesDrawOnTop() {
        XCTAssertGreaterThan(LZEnergyClass.blocked.drawPriority,
                             LZEnergyClass.comfortable.drawPriority)
        XCTAssertGreaterThan(LZEnergyClass.marginal.drawPriority,
                             LZEnergyClass.comfortable.drawPriority)
        XCTAssertGreaterThan(LZEnergyClass.excess.drawPriority,
                             LZEnergyClass.comfortable.drawPriority)
    }

    /// Bounded work: the sweep must stay inside its declared caps whatever it is handed.
    func testSweepStaysWithinItsBounds() throws {
        let f = try field(input(altFt: 45000, ratio: 55), Flat(ft: 0))
        let rings = f.bands.reduce(0) { $0 + $1.rings.count }
        XCTAssertLessThanOrEqual(rings, LZGlideField.azimuthCount * 8,
                                 "sector count grew past a sane bound")
    }
}
