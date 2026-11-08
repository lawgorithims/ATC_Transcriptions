import XCTest
@testable import ATCTranscribe

/// Between-fix smoothing for the ownship symbol.
///
/// The thing under test draws the aeroplane where the receiver has not yet said it is, so most of
/// these are about the bounds on that rather than about the smoothing: how far it will project, how
/// slow is too slow to project at all, and what it does when the next fix disagrees.
///
/// Distances come from `Geo.nmBetween`, never from degrees × 60 — the shared sphere is R = 3440.065
/// NM, so a degree is 60.0405 NM and the hand conversion is wrong by 0.07%.
final class OwnshipMotionTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_793_750_000)
    private let home = Coord(lat: 0, lon: 0)

    private func nm(_ a: Coord, _ b: Coord) -> Double { Geo.nmBetween(a, b) }

    func testTheFirstFixIsDrawnExactlyWhereItArrived() {
        var m = OwnshipMotion()
        m.ingest(home, trackDeg: 90, speedKt: 120, at: t0)
        let p = m.position(at: t0)
        XCTAssertEqual(nm(try! XCTUnwrap(p), home), 0, accuracy: 1e-9, "nothing to ease from yet")
    }

    func testNoFixDrawsNothing() {
        var m = OwnshipMotion()
        XCTAssertNil(m.position(at: t0))
        XCTAssertNil(m.displayed)
    }

    /// The point of the whole type: between deliveries the symbol keeps moving.
    func testItFliesOnBetweenFixes() {
        var m = OwnshipMotion()
        m.ingest(home, trackDeg: 90, speedKt: 360, at: t0)   // 0.1 NM per second
        _ = m.position(at: t0)
        let after1s = try! XCTUnwrap(m.position(at: t0.addingTimeInterval(1)))
        XCTAssertGreaterThan(nm(after1s, home), 0, "it must not sit still waiting for the next fix")
        XCTAssertEqual(Geo.bearing(home, after1s), 90, accuracy: 1.0, "and it must fly along the track")
    }

    /// ⚠️ A vector is evidence about the NEAR future only. Past the window the symbol holds its last
    /// fix instead of sailing across the chart on a heading nobody has confirmed for a minute.
    func testItStopsProjectingWhenTheFixesStop() {
        var m = OwnshipMotion()
        m.ingest(home, trackDeg: 90, speedKt: 360, at: t0)
        _ = m.position(at: t0)
        // Let it settle fully at the capped estimate, then confirm it goes no further.
        var settled = home
        for s in stride(from: 1.0, through: 20.0, by: 0.5) {
            settled = try! XCTUnwrap(m.position(at: t0.addingTimeInterval(s)))
        }
        let capped = OwnshipMotion.maxExtrapolationS * (360.0 / 3600.0)   // 0.2 NM
        XCTAssertEqual(nm(settled, home), capped, accuracy: 0.01,
                       "it holds at the projection cap, not wherever the clock took it")
    }

    /// Below taxi speed the reported course is noise. Projecting along it makes a parked aeroplane
    /// wander, which is worse than a symbol that sits still — because it sits still in real life.
    func testAParkedAeroplaneDoesNotDrift() {
        var m = OwnshipMotion()
        m.ingest(home, trackDeg: 90, speedKt: 2, at: t0)
        _ = m.position(at: t0)
        let later = try! XCTUnwrap(m.position(at: t0.addingTimeInterval(5)))
        XCTAssertEqual(nm(later, home), 0, accuracy: 1e-9)
    }

    func testNoVectorMeansNoProjection() {
        var m = OwnshipMotion()
        m.ingest(home, trackDeg: nil, speedKt: 300, at: t0)
        _ = m.position(at: t0)
        XCTAssertEqual(nm(try! XCTUnwrap(m.position(at: t0.addingTimeInterval(2))), home), 0, accuracy: 1e-9)

        var n = OwnshipMotion()
        n.ingest(home, trackDeg: 90, speedKt: nil, at: t0)
        _ = n.position(at: t0)
        XCTAssertEqual(nm(try! XCTUnwrap(n.position(at: t0.addingTimeInterval(2))), home), 0, accuracy: 1e-9)
    }

    /// A small disagreement is eased across, not snapped — that is what stops the symbol hopping once
    /// per delivery. After one time constant it should have closed most, but not all, of the gap.
    func testASmallCorrectionIsEasedRatherThanJumped() {
        var m = OwnshipMotion()
        m.ingest(home, trackDeg: 90, speedKt: 0, at: t0)
        _ = m.position(at: t0)
        let nudged = Geo.point(from: home, bearingDeg: 90, distanceNm: 0.05)   // ~90 m
        m.ingest(nudged, trackDeg: 90, speedKt: 0, at: t0)
        let mid = try! XCTUnwrap(m.position(at: t0.addingTimeInterval(OwnshipMotion.catchUpS)))
        let moved = nm(home, mid)
        XCTAssertGreaterThan(moved, 0.02, "it has to actually chase the new fix")
        XCTAssertLessThan(moved, 0.05, "but it must not teleport onto it")
    }

    /// ⚠️ AND A LARGE ONE IS NOT EASED. A resumed app or a recovered signal puts the aeroplane
    /// somewhere else entirely; crawling the symbol there would have the pilot watch it drift across
    /// the chart for seconds while the real aircraft is already at the far end.
    func testALargeCorrectionSnaps() {
        var m = OwnshipMotion()
        m.ingest(home, trackDeg: 90, speedKt: 0, at: t0)
        _ = m.position(at: t0)
        let elsewhere = Geo.point(from: home, bearingDeg: 90, distanceNm: 5)
        m.ingest(elsewhere, trackDeg: 90, speedKt: 0, at: t0)
        let p = try! XCTUnwrap(m.position(at: t0.addingTimeInterval(0.03)))
        XCTAssertEqual(nm(p, elsewhere), 0, accuracy: 1e-9, "a different place is taken at once")
    }

    /// Frame-rate independence: the same elapsed time must produce the same position whether it was
    /// asked for in one step or thirty, or the motion would look different on a 60 Hz and a 120 Hz
    /// panel for no reason the pilot could understand.
    func testTheEasingDoesNotDependOnHowOftenItIsAsked() {
        func run(steps: Int) -> Coord {
            var m = OwnshipMotion()
            m.ingest(home, trackDeg: 90, speedKt: 0, at: t0)
            _ = m.position(at: t0)
            m.ingest(Geo.point(from: home, bearingDeg: 90, distanceNm: 0.05),
                     trackDeg: 90, speedKt: 0, at: t0)
            for i in 1...steps {
                _ = m.position(at: t0.addingTimeInterval(0.6 * Double(i) / Double(steps)))
            }
            return m.displayed!
        }
        XCTAssertEqual(nm(run(steps: 1), run(steps: 30)), 0, accuracy: 0.002)
    }

    func testResetForgetsEverything() {
        var m = OwnshipMotion()
        m.ingest(home, trackDeg: 90, speedKt: 300, at: t0)
        _ = m.position(at: t0)
        m.reset()
        XCTAssertNil(m.displayed)
        XCTAssertNil(m.position(at: t0.addingTimeInterval(1)))
    }
}
