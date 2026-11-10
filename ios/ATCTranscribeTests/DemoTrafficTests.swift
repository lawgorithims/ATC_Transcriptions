import XCTest
@testable import ATCTranscribe

/// `Aircraft.demoTargets` — the offline ADS-B seam behind `--demo-traffic`.
///
/// It exists because traffic was the one layer that could not be staged without a network: storms,
/// hazards, TFRs and the flight plan all had a `--demo-` seam and ADS-B had none, so every staged
/// frame of the app in use had an empty sky in it. These pin the properties that make the seeded
/// sky worth showing — and worth trusting, since a demo that quietly produced unplottable or stale
/// contacts would look exactly like the broken feed it is meant to stand in for.
final class DemoTrafficTests: XCTestCase {

    func testEveryDemoContactCanActuallyBePlotted() {
        let targets = Aircraft.demoTargets()
        XCTAssertGreaterThanOrEqual(targets.count, 4, "too few contacts to read as traffic")
        for ac in targets {
            XCTAssertNotNil(ac.coordinate, "\(ac.hex) has no position — it would draw nowhere")
            XCTAssertNotNil(ac.trackDeg, "\(ac.hex) has no track; the chevron carries heading")
            XCTAssertNotNil(ac.altBaroFt, "\(ac.hex) has no altitude")
            XCTAssertFalse(ac.onGround, "a parked aeroplane is not the traffic this is staging")
        }
        XCTAssertEqual(Set(targets.map(\.hex)).count, targets.count, "duplicate ICAO addresses")
    }

    /// ⚠️ FRESH, OR THE LAYER HIDES THEM. Contacts age out against `isStale`, so a seed stamped in
    /// the past would vanish from a screenshot taken a moment later — intermittently, which is the
    /// worst way for it to fail.
    func testTheSeededSkyIsFreshEnoughToSurvive() {
        let now = Date()
        for ac in Aircraft.demoTargets(now: now) {
            XCTAssertFalse(ac.isStale(window: 60, now: now),
                           "\(ac.hex) is already stale when seeded")
            XCTAssertLessThanOrEqual(ac.lastSeen.timeIntervalSince(now), 0,
                                     "\(ac.hex) was last heard in the future")
        }
    }

    /// The chevron shows where an aeroplane is GOING, so a sky of targets all on one heading, or
    /// all at one level, demonstrates nothing. This is a marketing asset's whole job.
    func testTheContactsAreSpreadInTrackAndAltitude() {
        let targets = Aircraft.demoTargets()
        let tracks = targets.compactMap(\.trackDeg)
        let alts = targets.compactMap(\.altBaroFt)
        XCTAssertGreaterThan(Set(tracks).count, 3, "the tracks are not spread; chevrons would align")
        XCTAssertGreaterThan((alts.max() ?? 0) - (alts.min() ?? 0), 10_000,
                             "every contact is at airline cruise — no GA traffic in the sky")
        XCTAssertNotNil(alts.first { $0 < 12_000 }, "nothing below the flight levels")
    }

    /// Positions are fixed on purpose: a demo that moved with the ownship could not be shot twice
    /// the same way, which is the same reason `ConvectiveCell.demoCells` fixes its own.
    func testTheSkyIsIdenticalEveryRun() {
        let a = Aircraft.demoTargets(now: Date(timeIntervalSince1970: 1_000_000))
        let b = Aircraft.demoTargets(now: Date(timeIntervalSince1970: 2_000_000))
        XCTAssertEqual(a.map(\.hex), b.map(\.hex))
        XCTAssertEqual(a.compactMap(\.lat), b.compactMap(\.lat), "positions must not drift")
        XCTAssertEqual(a.compactMap(\.lon), b.compactMap(\.lon), "positions must not drift")
    }
}

/// `Breadcrumb.demoTrail` — the flown-track seam behind `--demo-track`.
///
/// The trail is the one thing on the map that says an aeroplane has BEEN somewhere rather than
/// merely being somewhere, and `--hold-ownship` holds a position by definition, so there is no
/// movement to leave one. This draws the history a held position cannot have.
final class DemoTrailTests: XCTestCase {

    private let here = Coord(lat: 42.5, lon: -77.0)

    /// The newest point is the aeroplane. A trail that ends anywhere else is a trail behind
    /// somebody else, and it reads as a second aircraft rather than as where this one has been.
    func testTheTrailEndsAtTheAeroplane() {
        let trail = Breadcrumb.demoTrail(to: here, trackDeg: 270)
        let last = try! XCTUnwrap(trail.last)
        XCTAssertEqual(last.lat, here.lat, accuracy: 0.02, "the trail does not end at the aeroplane")
        XCTAssertEqual(last.lon, here.lon, accuracy: 0.02, "the trail does not end at the aeroplane")
    }

    /// Laid back along the RECIPROCAL: flying west, the history is to the east.
    func testTheTrailLiesBehindNotAhead() {
        let west = Breadcrumb.demoTrail(to: here, trackDeg: 270)
        let tail = try! XCTUnwrap(west.first)
        XCTAssertGreaterThan(tail.lon, here.lon, "flying west, the trail must be to the EAST")

        let east = Breadcrumb.demoTrail(to: here, trackDeg: 90)
        XCTAssertLessThan(try! XCTUnwrap(east.first).lon, here.lon,
                          "flying east, the trail must be to the WEST")
    }

    /// Oldest first, so the map draws it in the order it was flown.
    func testTheTrailIsInTimeOrder() {
        let trail = Breadcrumb.demoTrail(to: here, trackDeg: 270)
        XCTAssertEqual(trail.map(\.t), trail.map(\.t).sorted(), "the trail is not oldest-first")
        XCTAssertGreaterThan(trail.count, 10, "too few points to draw as a track")
    }

    /// ⚠️ IT MUST WANDER. A trail laid down as a straight line reads as a ROUTE — which is already
    /// on the map, in magenta, meaning something else entirely. Real GPS wanders, so this does too.
    func testTheTrailIsFlownNotRuled() {
        let trail = Breadcrumb.demoTrail(to: Coord(lat: 0, lon: 0), trackDeg: 270)
        let lats = trail.map(\.lat)
        XCTAssertGreaterThan((lats.max() ?? 0) - (lats.min() ?? 0), 0.001,
                             "the trail is perfectly straight — it will read as a route, not a track")
    }
}
