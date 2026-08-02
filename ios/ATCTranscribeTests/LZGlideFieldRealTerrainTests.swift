import XCTest
@testable import ATCTranscribe

/// The energy engine against the app's REAL bundled terrain grid, over the pilot cell.
///
/// `LZGlideFieldTests` pins the maths on synthetic surfaces whose answers are known by hand. This
/// asks the question that actually matters: put an aeroplane over Las Cruces with the Organ
/// Mountains 8 NM east, and does the footprint say what a pilot standing there would say?
///
/// Skips when the bundled grid is absent so a stripped checkout does not fail the suite.
final class LZGlideFieldRealTerrainTests: XCTestCase {

    private var terrain: TerrainElevation!

    /// Las Cruces International. The Organs run north-south about 8 NM to the EAST and top out
    /// near 9,000 ft; the Mesilla Valley falls away to the south-west.
    private let klru = Coord(lat: 32.2894, lon: -106.9219)

    override func setUpWithError() throws {
        terrain = TerrainElevation()
        try XCTSkipUnless(terrain.isAvailable, "bundled terrain grid not present")
        try XCTSkipUnless(terrain.elevationFt(at: klru) != nil, "no terrain coverage at KLRU")
    }

    private func field(altFt: Double, ratio: Double = 9) throws -> LZEnergyField {
        let input = LZGlideField.Input(coord: klru, altitudeFtMSL: altFt, glideRatio: ratio,
                                       isDefaultGlideRatio: false, bestGlideKts: 65,
                                       windFromDeg: nil, windKts: nil, verticalAccuracyM: 10)
        return try XCTUnwrap(LZGlideField.compute(input, terrain: terrain))
    }

    /// Mean bearing of a sector, for asking "which way does this band lie".
    private func meanBearing(_ ring: [Coord]) -> Double {
        let pts = ring.dropLast()
        let x = pts.map { cos(Geo.bearing(klru, $0) * .pi / 180) }.reduce(0, +)
        let y = pts.map { sin(Geo.bearing(klru, $0) * .pi / 180) }.reduce(0, +)
        var b = atan2(y, x) * 180 / .pi
        if b < 0 { b += 360 }
        return b
    }

    private func isEasterly(_ deg: Double) -> Bool { deg > 20 && deg < 160 }

    func testFieldComputesOverRealTerrain() throws {
        let f = try field(altFt: 9000)
        XCTAssertFalse(f.bands.isEmpty, "no bands over real terrain at KLRU")
        XCTAssertGreaterThan(f.maxRangeNm, 3, "implausibly small footprint from 9,000 ft")
        XCTAssertFalse(f.usedWind)
    }

    /// THE case the layer exists for: the eastern sectors must block against the Organ Mountains
    /// while the valley stays reachable — the map must not be uniformly anything.
    ///
    /// The altitude is 16,000 ft, and that is not arbitrary. MEASURED against the bundled grid, the
    /// ground east of KLRU first FALLS (4,455 ft at the field to 3,898 ft in the Rio Grande valley)
    /// and only climbs past ~15 NM, so the Organ crest sits far further out than it looks on a
    /// chart. From 7,000 ft the footprint is 2.3 NM and never reaches the mountains at all — an
    /// earlier version of this test asserted a block that no aeroplane at that altitude could
    /// possibly see.
    func testOrganMountainsBlockTheEasternSectorsButNotTheValley() throws {
        let f = try field(altFt: 16000)
        let blocked = try XCTUnwrap(f.bands.first { $0.classification == .blocked },
                                    "the Organs did not block anything from 7,000 ft")
        let easterlyBlocked = blocked.rings.filter { isEasterly(meanBearing($0)) }.count
        XCTAssertGreaterThan(easterlyBlocked, 0, "nothing blocked toward the Organ Mountains")

        // ...and the field is not uniformly blocked: the valley is still reachable.
        let reachable = f.bands.filter { $0.classification != .blocked }
            .reduce(0) { $0 + $1.rings.count }
        XCTAssertGreaterThan(reachable, 0, "the whole footprint blocked — the valley vanished")
    }

    /// Climbing must open ground up, never close it. A monotonicity check on real terrain: from
    /// higher, strictly more of the sweep is reachable.
    func testMoreAltitudeReachesMoreGround() throws {
        let low = try field(altFt: 6500)
        let high = try field(altFt: 12000)
        func reachable(_ f: LZEnergyField) -> Int {
            f.bands.filter { $0.classification != .blocked }.reduce(0) { $0 + $1.rings.count }
        }
        XCTAssertGreaterThan(high.maxRangeNm, low.maxRangeNm)
        XCTAssertGreaterThanOrEqual(reachable(high), reachable(low),
                                    "climbing reduced the reachable footprint")
    }

    /// Below the arrival reserve there is NO footprint, and the layer must draw nothing rather than
    /// invent one. 750 ft above the field is less than the 1,000 ft reserve, so the usable height
    /// is negative — the honest answer is an empty field plus a status that says why.
    func testBelowTheArrivalReserveThereIsNoFootprint() throws {
        let f = try field(altFt: 5200)      // ~750 ft above KLRU's 4,457 ft
        XCTAssertEqual(f.maxRangeNm, 0, accuracy: 0.001)
        XCTAssertTrue(f.bands.isEmpty, "a sub-reserve altitude must not produce a footprint")
    }

    /// At a normal enroute altitude the real terrain produces marginal ground somewhere — the
    /// rising edges where the profile meets the hills before the glide runs out.
    func testRealTerrainProducesMarginalGroundAtEnrouteAltitude() throws {
        let f = try field(altFt: 9000)
        XCTAssertTrue(f.bands.contains { $0.classification == .marginal },
                      "no marginal ground anywhere over real terrain from 9,000 ft")
        XCTAssertTrue(f.bands.contains { $0.classification == .comfortable })
    }

    /// High over the valley, ground far below reads EXCESS — the state that says "you would arrive
    /// with more height than you can shed", not "this is extra safety".
    func testHighOverTheValleyProducesExcessEnergy() throws {
        let f = try field(altFt: 13000, ratio: 12)   // ~8,500 ft above the field
        XCTAssertTrue(f.bands.contains { $0.classification == .excess },
                      "8,500 ft above the valley floor should read as excess energy")
    }

    /// Bounded work on real data: the sweep must not explode into thousands of sectors.
    func testSectorCountStaysBounded() throws {
        let f = try field(altFt: 14000, ratio: 15)
        let rings = f.bands.reduce(0) { $0 + $1.rings.count }
        XCTAssertLessThanOrEqual(rings, LZGlideField.azimuthCount * 8,
                                 "sector count grew past a sane bound on real terrain")
        XCTAssertGreaterThan(rings, LZGlideField.azimuthCount / 2)
    }

    /// The sweep runs every 5 s on a timer while the layer is on, so it has to be cheap.
    func testSweepIsFastEnoughForItsCadence() throws {
        let input = LZGlideField.Input(coord: klru, altitudeFtMSL: 11000, glideRatio: 10,
                                       isDefaultGlideRatio: false, bestGlideKts: 65,
                                       windFromDeg: 270, windKts: 15, verticalAccuracyM: 10)
        _ = LZGlideField.compute(input, terrain: terrain)          // warm the mmap
        let t0 = CFAbsoluteTimeGetCurrent()
        _ = LZGlideField.compute(input, terrain: terrain)
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        XCTAssertLessThan(ms, 250, "a 64-ray sweep took \(Int(ms)) ms — too slow for a 5 s cadence")
    }
}
