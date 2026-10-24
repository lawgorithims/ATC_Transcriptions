import XCTest
@testable import ATCTranscribe

/// The allowances a straight-line glide leaves out — turning, and wind — and the ONE standard the
/// airport list and the glide bands now share.
///
/// Numbers are worked by hand from the constants, never read back from the engine. The thing every
/// test here guards in some form: reach must never be FLATTERED. Stretching a glide is the classic
/// fatal error after an engine failure, and a reach model that credits a forecast tailwind, or forgets
/// the turn onto the place it names, is how a pilot gets talked into one.
final class GlideAllowanceTests: XCTestCase {

    // MARK: - turning

    func testATurnCostsHeightInProportionToHowFarItTurns() {
        let full = GlideAllowance.turnLossFtPer180
        XCTAssertEqual(GlideAllowance.turnLossFt(fromTrackDeg: 0, toBearingDeg: 0), 0)
        XCTAssertEqual(GlideAllowance.turnLossFt(fromTrackDeg: 0, toBearingDeg: 180), full, accuracy: 1e-9)
        XCTAssertEqual(GlideAllowance.turnLossFt(fromTrackDeg: 0, toBearingDeg: 90), full / 2, accuracy: 1e-9)
        // The SHORT way round, both ways.
        XCTAssertEqual(GlideAllowance.turnLossFt(fromTrackDeg: 350, toBearingDeg: 10), full * 20 / 180,
                       accuracy: 1e-9, "a 20° turn was charged as 340°")
        XCTAssertEqual(GlideAllowance.turnLossFt(fromTrackDeg: 10, toBearingDeg: 350),
                       GlideAllowance.turnLossFt(fromTrackDeg: 350, toBearingDeg: 10), accuracy: 1e-9)
    }

    /// No usable track — on the ground, hovering, a fix wandering at rest — charges nothing, which is
    /// exactly the old omnidirectional behaviour rather than an invented heading.
    func testNoTrackChargesNoTurn() {
        XCTAssertEqual(GlideAllowance.turnLossFt(fromTrackDeg: nil, toBearingDeg: 180), 0)
        XCTAssertNil(GlideAllowance.usableTrack(trackDeg: 90, groundSpeedKt: 12), "a taxi track was trusted")
        XCTAssertNil(GlideAllowance.usableTrack(trackDeg: 90, groundSpeedKt: nil))
        XCTAssertEqual(GlideAllowance.usableTrack(trackDeg: 90, groundSpeedKt: 95), 90)
    }

    // MARK: - wind

    /// ⚠️ THE RULE. A headwind is charged in full; a tailwind buys nothing.
    func testAHeadwindIsChargedAndATailwindIsNeverCredited() {
        // Wind FROM 360 at 20 kt blows south. Gliding north is into it; south is with it.
        let into = GlideAllowance.windScale(bearingDeg: 0, windFromDeg: 360, windKts: 20, bestGlideKts: 65)
        XCTAssertEqual(into, 45.0 / 65.0, accuracy: 1e-9)
        let with = GlideAllowance.windScale(bearingDeg: 180, windFromDeg: 360, windKts: 20, bestGlideKts: 65)
        XCTAssertEqual(with, 1.0, accuracy: 1e-9, "a forecast tailwind was credited to reach")
        let cross = GlideAllowance.windScale(bearingDeg: 90, windFromDeg: 360, windKts: 20, bestGlideKts: 65)
        XCTAssertEqual(cross, 1.0, accuracy: 1e-6)
    }

    func testOneBadWindSampleCannotEraseTheMap() {
        let gale = GlideAllowance.windScale(bearingDeg: 0, windFromDeg: 0, windKts: 400, bestGlideKts: 65)
        XCTAssertEqual(gale, GlideAllowance.minWindScale, accuracy: 1e-9)
        XCTAssertEqual(GlideAllowance.windScale(bearingDeg: 0, windFromDeg: nil, windKts: 20,
                                                bestGlideKts: 65), 1)
        XCTAssertEqual(GlideAllowance.windScale(bearingDeg: 0, windFromDeg: 0, windKts: .nan,
                                                bestGlideKts: 65), 1)
    }

    // MARK: - the column a glide descends through

    func testAUniformColumnAveragesToItself() throws {
        let col = [2_000.0, 5_000, 10_000].map { WindProfile.Level(altitudeFtMSL: $0, fromDeg: 250, kts: 30) }
        let m = try XCTUnwrap(WindProfile.layerMean(col, topFtMSL: 9_000, bottomFtMSL: 1_000))
        XCTAssertEqual(m.kts, 30, accuracy: 0.01)
        XCTAssertEqual(m.fromDeg, 250, accuracy: 0.01)
    }

    /// Averaged as VECTORS. Opposite winds of equal strength through the column cancel — averaging
    /// speeds would report 10 kt from a nonsense direction.
    func testOpposingLevelsCancelAsVectorsShould() throws {
        let col = [WindProfile.Level(altitudeFtMSL: 0, fromDeg: 90, kts: 10),
                   WindProfile.Level(altitudeFtMSL: 10_000, fromDeg: 270, kts: 10)]
        let m = try XCTUnwrap(WindProfile.layerMean(col, topFtMSL: 10_000, bottomFtMSL: 0))
        XCTAssertLessThan(m.kts, 0.5, "opposing winds did not cancel — speeds were averaged, not vectors")
    }

    /// A wind that veers with height comes out between the two, and below their speed.
    func testAVeeringColumnLandsBetween() throws {
        let col = [WindProfile.Level(altitudeFtMSL: 0, fromDeg: 270, kts: 20),
                   WindProfile.Level(altitudeFtMSL: 10_000, fromDeg: 360, kts: 20)]
        let m = try XCTUnwrap(WindProfile.layerMean(col, topFtMSL: 10_000, bottomFtMSL: 0))
        XCTAssertGreaterThan(m.fromDeg, 270); XCTAssertLessThan(m.fromDeg, 360)
        XCTAssertLessThan(m.kts, 20)
    }

    func testNoLevelsMeansNoWind() {
        XCTAssertNil(WindProfile.layerMean([], topFtMSL: 9_000, bottomFtMSL: 0))
    }

    // MARK: - the airport list

    private struct Flat: TerrainSampling {
        var isReady: Bool { true }
        func sampleElevationFt(at coord: Coord) -> Double? { 0 }
    }
    private let origin = Coord(lat: 35.0, lon: -98.0)

    private func field(_ id: String, nmNorth: Double) -> AirportData.Airport {
        AirportData.Airport(ident: id, icao: "", name: "\(id) test field",
                            coord: Coord(lat: origin.lat + nmNorth / 60.0, lon: origin.lon),
                            elevationFt: 0, ownership: "PU", use: "PU", status: "O",
                            tower: "NON-ATCT", fuel: "", siteType: "A", far139: "")
    }
    private let runway = [AirportData.Runway(designator: "09/27", lengthFt: 4000, widthFt: 75,
                                             surface: "ASPH", condition: "GOOD", lights: "MED")]

    /// 6,000 ft over flat sea-level ground at 9:1: spend 5,000 ft → 7.41 NM still air. One field 7 NM
    /// north, one 7 NM south — both reachable in still air with nothing charged.
    private func reach(track: Double? = nil, windFrom: Double? = nil, windKts: Double? = nil)
        -> (north: NRSTReachability?, south: NRSTReachability?) {
        var s = GlideSituation(coord: origin, altitudeFtMSL: 6_000, glideRatio: 9,
                               isDefaultGlideRatio: false, verticalAccuracyM: 10)
        s.trackDeg = track
        s.windFromDeg = windFrom
        s.windKts = windKts
        let a = NearestAirports.assess(situation: s, airports: [field("NTH", nmNorth: 7),
                                                                field("STH", nmNorth: -7)],
                                       runwaysFor: { _ in self.runway }, weather: [:], terrain: Flat(),
                                       now: Date(timeIntervalSince1970: 1_800_000_000))
        return (a.candidates.first { $0.airport.ident == "NTH" }?.reachability,
                a.candidates.first { $0.airport.ident == "STH" }?.reachability)
    }

    func testInStillAirWithNoTrackBothFieldsAreInReach() {
        let r = reach()
        XCTAssertEqual(r.north?.isReachable, true)
        XCTAssertEqual(r.south?.isReachable, true)
    }

    /// Heading north: turning round for the southern field costs 300 ft — range 6.96 NM, short of 7.
    func testTheFieldBehindYouCostsTheTurnToReachIt() {
        let r = reach(track: 0)
        XCTAssertEqual(r.north?.isReachable, true, "the field ahead must still be in reach")
        XCTAssertEqual(r.south, .outOfGlide,
                       "a field directly behind was offered without charging the 180° turn to it")
    }

    /// 20 kt from the north: the northern field is into wind (range 5.13 NM, out); the southern one is
    /// downwind and gets NO credit for it — still in reach, but no further than in still air.
    func testAHeadwindPutsAFieldOutOfReachAndATailwindDoesNotStretchOne() {
        let r = reach(windFrom: 360, windKts: 20)
        XCTAssertEqual(r.north, .outOfGlide, "the upwind field was not charged its headwind")
        XCTAssertEqual(r.south?.isReachable, true)
    }

    /// The adjustment can only ever take reach away.
    func testTowardNeverFlattersReach() {
        var s = GlideSituation(coord: origin, altitudeFtMSL: 6_000, glideRatio: 9,
                               isDefaultGlideRatio: false, verticalAccuracyM: 10)
        s.trackDeg = 45; s.windFromDeg = 200; s.windKts = 35
        for b in stride(from: 0.0, to: 360.0, by: 15.0) {
            let t = s.toward(bearingDeg: b)
            XCTAssertLessThanOrEqual(t.altitudeFtMSL, s.altitudeFtMSL)
            XCTAssertLessThanOrEqual(t.glideRatio, s.glideRatio + 1e-9, "bearing \(b) was flattered")
        }
    }

    // MARK: - the glide bands share the rule

    /// Heading north over flat ground, the footprint reaches further ahead than behind by the turn:
    /// 300 ft at 9:1 is 0.44 NM.
    func testTheGlideFootprintIsShorterBehindThanAhead() throws {
        let input = LZGlideField.Input(coord: origin, altitudeFtMSL: 6_000, glideRatio: 9,
                                       isDefaultGlideRatio: false, bestGlideKts: 65,
                                       windFromDeg: nil, windKts: nil, verticalAccuracyM: 10,
                                       trackDeg: 0)
        let f = try XCTUnwrap(LZGlideField.compute(input, terrain: Flat()))
        // Extent ALONG north and along south (1 NM = 1/60° of latitude), not the farthest point in
        // each half-plane: that picks up sectors just south of due east, where the turn is only ~95°.
        let pts = f.bands.flatMap(\.rings).flatMap { $0 }
        let north = pts.map { ($0.lat - origin.lat) * 60 }.max() ?? 0
        let south = pts.map { (origin.lat - $0.lat) * 60 }.max() ?? 0
        let expected = GlideAllowance.turnLossFtPer180 * 9 / NearestAirports.ftPerNm
        XCTAssertEqual(north - south, expected, accuracy: 0.15,
                       "ahead \(north) NM vs behind \(south) NM — the turn was not charged")
    }
}
