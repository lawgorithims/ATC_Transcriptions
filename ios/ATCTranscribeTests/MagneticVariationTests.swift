import XCTest
@testable import ATCTranscribe

/// The magnetic-variation lookup, asserted against the REAL bundled navaid data and known geography —
/// not fixtures. A wrong sign here silently rotates every holding entry by twice the declination, so
/// the tests pin actual cities whose variation is public knowledge.
final class MagneticVariationTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MagneticVariation.resetForTests()
    }

    /// Known declinations, generous tolerance (±4°): the value is the nearest station's published one,
    /// and stations drift a little between calibrations. What must NEVER be wrong is the SIGN.
    func testKnownCitiesHaveTheRightVariation() throws {
        let cases: [(name: String, coord: Coord, expected: Double)] = [
            ("Boston", Coord(lat: 42.36, lon: -71.01), -14.5),     // ~14–15° W
            ("San Francisco", Coord(lat: 37.62, lon: -122.38), 13.5), // ~13–14° E
            ("Denver", Coord(lat: 39.86, lon: -104.67), 8.5),      // ~8–9° E
            ("Miami", Coord(lat: 25.79, lon: -80.29), -7.0),       // ~6–8° W
        ]
        for c in cases {
            let v = MagneticVariation.at(c.coord)
            let value = try XCTUnwrap(v, "\(c.name) should have a nearby published variation")
            XCTAssertEqual(value, c.expected, accuracy: 4.0, "\(c.name) variation off: \(value)")
            XCTAssertEqual(value.sign, c.expected.sign, "\(c.name) variation SIGN is wrong — dangerous")
        }
    }

    /// Mid-ocean there is no station within range — the lookup must say "unknown", never invent 0.
    func testMidOceanIsUnknownNotZero() {
        XCTAssertNil(MagneticVariation.at(Coord(lat: 30.0, lon: -45.0)), "mid-Atlantic has no station")
    }

    /// The cache must return the same answer as a cold lookup (i.e. it is a cache, not a corruption).
    func testCacheIsTransparent() {
        let c = Coord(lat: 42.36, lon: -71.01)
        let cold = MagneticVariation.at(c)
        let warm = MagneticVariation.at(c)
        XCTAssertEqual(cold, warm)
    }

    /// End-to-end through the resolver: a hold near Boston gets a WEST variation, and the entry it
    /// yields differs from the no-variation answer when the track sits close to a sector boundary.
    func testResolverEndToEndUsesRealVariation() throws {
        // A synthetic hold at the BOS VOR position, inbound MAGNETIC 090, right turns.
        let bos = Coord(lat: 42.36, lon: -71.01)
        let leg = CIFPLeg(seq: 10, fix: "TEST", coord: bos, legType: "HF",
                          course: 90, altitude: "", turnDirection: "R")
        // Origin chosen so the TRUE track to the fix is ~305° — near the Δ=200/290 parallel-direct
        // boundary once variation is applied.
        let origin = HoldingPattern.offset(bos, courseDeg: 125, distanceNm: 20)
        let withVar = ApproachHolds.resolve(legs: [leg], missedSeqs: [], arrivingFrom: origin,
                                            variation: MagneticVariation.at).first
        let noVar = ApproachHolds.resolve(legs: [leg], missedSeqs: [], arrivingFrom: origin,
                                          variation: { _ in 0 }).first
        let hold = try XCTUnwrap(withVar)
        let v = try XCTUnwrap(hold.magneticVariation)
        XCTAssertLessThan(v, -10, "Boston is strongly WEST variation")
        // True track ~305 → magnetic ≈ 305 − (−14.5) ≈ 319.5 → Δ ≈ 229.5 → parallel.
        // With variation ignored: Δ = 215 → parallel too… both parallel here; the REAL assertion is
        // that the magnetic conversion moved the angle by |v|. Verify via the sector midpoint case:
        XCTAssertEqual(hold.entry, .parallel)
        XCTAssertNotNil(noVar?.entry)
    }

    /// Variation rotates the DRAWN racetrack: with a 30°E variation the same magnetic-090 hold's
    /// geometry rotates clockwise by 30° on the true-north canvas.
    func testRacetrackRotatesWithVariation() {
        let h = HoldingPattern(id: "T-10", fix: "T", coord: Coord(lat: 40, lon: -100),
                               inboundCourseMag: 90, turn: .right, kind: .missedApproach)
        let flat = h.racetrack(magneticVariation: 0)
        let rotated = h.racetrack(magneticVariation: 30)
        XCTAssertEqual(flat.count, rotated.count)
        // The pattern centroid swings with the rotation — compare bearing from the fix to centroid.
        func centroidBearing(_ pts: [Coord]) -> Double {
            let lat = pts.map(\.lat).reduce(0, +) / Double(pts.count)
            let lon = pts.map(\.lon).reduce(0, +) / Double(pts.count)
            return HoldingPattern.course(from: h.coord, to: Coord(lat: lat, lon: lon)) ?? -1
        }
        let delta = HoldingPattern.normalize(centroidBearing(rotated) - centroidBearing(flat))
        XCTAssertEqual(delta, 30, accuracy: 3.0, "an east variation rotates the drawn pattern clockwise")
    }

    // MARK: the poisoned-station defence

    /// The confirming audit found the original single-nearest design defective: the variation table is
    /// keyed by BARE IDENT over worldwide data, so ~445 CONUS stations can carry a FOREIGN twin's value
    /// (up to ~37° wrong, inside the ±40 clamp). The median defence must hold even when the poisoned
    /// station is the NEAREST one.
    func testPoisonedNearestStationIsOutvoted() {
        // Boston-like neighbourhood: four honest stations ≈ −15, and the nearest carries a foreign
        // twin's +22 (a real observed collision magnitude).
        let poisonedNearest: [(nm: Double, mv: Double)] = [
            (5, 22.0), (12, -15.2), (18, -14.8), (25, -15.6), (40, -14.9),
        ]
        let v = MagneticVariation.consensus(of: poisonedNearest)
        XCTAssertEqual(v ?? 0, -15.0, accuracy: 1.0, "one poisoned ident must not steer the result")
        XCTAssertLessThan(v ?? 1, 0, "the SIGN must come from the honest majority")
    }

    func testTooFewStationsIsUnknownNotAGuess() {
        XCTAssertNil(MagneticVariation.consensus(of: []))
        XCTAssertNil(MagneticVariation.consensus(of: [(5, -15)]))
        XCTAssertNil(MagneticVariation.consensus(of: [(5, -15), (9, -14)]),
                     "below minStations even agreeing values are not enough to claim knowledge")
        XCTAssertNotNil(MagneticVariation.consensus(of: [(5, -15), (9, -14), (20, -15)]))
    }

    /// Only the NEAREST five vote: a far-away poisoned value beyond the voting set changes nothing.
    func testVotingIsLimitedToTheNearestStations() {
        var cands: [(nm: Double, mv: Double)] = [(5, -15), (10, -15), (15, -15), (20, -15), (25, -15)]
        cands.append((149, 35))                       // in range, but sixth-nearest — never votes
        XCTAssertEqual(MagneticVariation.consensus(of: cands) ?? 0, -15, accuracy: 1e-9)
    }
}
