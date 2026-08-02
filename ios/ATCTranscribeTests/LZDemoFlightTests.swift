import XCTest
import MapKit
@testable import ATCTranscribe

/// The demo drop: it must land somewhere the layer can actually answer, and it must say so plainly
/// when it cannot.
///
/// The one property that matters is that a demonstration never opens on blank ground. A demo of an
/// empty map is indistinguishable from a demo of a broken layer, and on this feature that confusion
/// has been the actual failure more than once.
final class LZDemoFlightTests: XCTestCase {

    /// A pack rect around Las Cruces, roughly a degree on a side.
    private func rect(lat: Double = 32.5, lon: Double = -106.5, span: Double = 1.0) -> MKMapRect {
        let a = MKMapPoint(CLLocationCoordinate2D(latitude: lat + span / 2, longitude: lon - span / 2))
        let b = MKMapPoint(CLLocationCoordinate2D(latitude: lat - span / 2, longitude: lon + span / 2))
        return MKMapRect(x: min(a.x, b.x), y: min(a.y, b.y),
                         width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    private func info(score: Int, vetoed: Bool = false) -> LZSampleInfo {
        LZSampleInfo(score: vetoed ? 0 : score, vetoed: vetoed, surfaceClass: LZPack.classCrop,
                     slopeDeg: 1, roughM: 0.05, hazard: 0.05, confidence: 90,
                     coarseTerrain: false, rules: [])
    }

    /// A deterministic generator, so a probabilistic search is tested rather than sampled.
    private struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    private func pick(mounted: [LZPackStore.Mounted],
                      sample: @escaping (Coord) -> LZSampleInfo?,
                      elevation: @escaping (Coord) -> Double? = { _ in 4000 },
                      seed: UInt64 = 7) -> LZDemoFlight.Drop? {
        var rng: RandomNumberGenerator = Seeded(state: seed)
        return LZDemoFlight.pick(mounted: mounted, sample: sample, elevationFt: elevation, rng: &rng)
    }

    // MARK: - the point of the whole thing

    /// ⚠️ THE INVARIANT. Never hand back a point the layer cannot score. A pack's bounding rectangle
    /// is a rectangle; the data inside it is not — a 1-degree cell fills only ~82% of its own box —
    /// so geometry alone would put the aeroplane over blank ground often enough to ruin a demo, and
    /// the audience cannot tell that from a broken layer.
    func testItOnlyEverDropsWhereTheLayerHasAnAnswer() throws {
        // Data only in the north-east quadrant of the pack; everywhere else the sampler knows nothing.
        let hot = rect(lat: 32.75, lon: -106.25, span: 0.5)
        let m = LZPackStore.Mounted(reader: try XCTUnwrap(fixtureReader()), rect: rect())
        var asked = 0
        for seed in UInt64(1)...20 {                                 // bounded
            let drop = pick(mounted: [m], sample: { c in
                asked += 1
                let p = MKMapPoint(CLLocationCoordinate2D(latitude: c.lat, longitude: c.lon))
                return hot.contains(p) ? self.info(score: 78) : nil
            }, seed: seed)
            let d = try XCTUnwrap(drop, "gave up with data plainly available (seed \(seed))")
            let p = MKMapPoint(CLLocationCoordinate2D(latitude: d.coord.lat, longitude: d.coord.lon))
            XCTAssertTrue(hot.contains(p),
                          "dropped outside the only ground that scores (seed \(seed))")
        }
        XCTAssertGreaterThan(asked, 20, "the sampler was barely consulted — is it checking at all?")
    }

    /// Nothing scores anywhere: a real answer, not an arbitrary drop. Silently parking the aeroplane
    /// somewhere blank is exactly the outcome this type exists to prevent.
    func testGroundThatScoresNowhereYieldsNoDropAtAll() throws {
        let m = LZPackStore.Mounted(reader: try XCTUnwrap(fixtureReader()), rect: rect())
        XCTAssertNil(pick(mounted: [m], sample: { _ in nil }))
    }

    func testNoPackMountedYieldsNoDrop() {
        XCTAssertNil(pick(mounted: [], sample: { _ in self.info(score: 90) }))
    }

    // MARK: - the height

    /// Parked with enough height to have somewhere to glide to. A demo at 300 ft AGL shows an empty
    /// footprint and proves nothing.
    func testItParksHighEnoughToHaveAFootprint() throws {
        let m = LZPackStore.Mounted(reader: try XCTUnwrap(fixtureReader()), rect: rect())
        for seed in UInt64(1)...15 {                                 // bounded
            let d = try XCTUnwrap(pick(mounted: [m], sample: { _ in self.info(score: 80) },
                                       elevation: { _ in 4200 }, seed: seed))
            XCTAssertGreaterThanOrEqual(d.heightAGL, LZDemoFlight.minHeightAGL - 1)
            XCTAssertLessThanOrEqual(d.heightAGL, LZDemoFlight.maxHeightAGL + 1)
            XCTAssertEqual(d.groundElevationFt, 4200, accuracy: 1)
            XCTAssertGreaterThan(d.altitudeFtMSL, d.groundElevationFt)
        }
    }

    /// No terrain grid is not fatal — the height is then measured from sea level, which still
    /// demonstrates the feature. It must not refuse to drop over it.
    func testMissingTerrainStillProducesAUsableDrop() throws {
        let m = LZPackStore.Mounted(reader: try XCTUnwrap(fixtureReader()), rect: rect())
        let d = try XCTUnwrap(pick(mounted: [m], sample: { _ in self.info(score: 80) },
                                   elevation: { _ in nil }))
        XCTAssertEqual(d.groundElevationFt, 0)
        XCTAssertGreaterThanOrEqual(d.altitudeFtMSL, LZDemoFlight.minHeightAGL - 1)
    }

    // MARK: - geometry

    /// Kept off the very edge, or half the glide footprint falls outside the data and the
    /// demonstration shows a semicircle.
    func testDropsAreInsetFromThePackEdge() {
        let r = rect()
        var rng: RandomNumberGenerator = Seeded(state: 3)
        for _ in 0..<200 {                                           // bounded
            guard let c = LZDemoFlight.randomPoint(in: r, using: &rng) else { continue }
            let p = MKMapPoint(CLLocationCoordinate2D(latitude: c.lat, longitude: c.lon))
            XCTAssertGreaterThan(p.x, r.minX + r.size.width * LZDemoFlight.edgeInsetFraction * 0.99)
            XCTAssertLessThan(p.x, r.maxX - r.size.width * LZDemoFlight.edgeInsetFraction * 0.99)
            XCTAssertGreaterThan(p.y, r.minY + r.size.height * LZDemoFlight.edgeInsetFraction * 0.99)
            XCTAssertLessThan(p.y, r.maxY - r.size.height * LZDemoFlight.edgeInsetFraction * 0.99)
        }
    }

    func testADegenerateRectYieldsNoPoint() {
        var rng: RandomNumberGenerator = Seeded(state: 1)
        XCTAssertNil(LZDemoFlight.randomPoint(in: MKMapRect(x: 0, y: 0, width: 0, height: 0),
                                              using: &rng))
    }

    /// Spread across the packs rather than always the same one, or a multi-cell region demos as one.
    func testItUsesMoreThanOnePackWhenSeveralAreMounted() throws {
        let a = LZPackStore.Mounted(reader: try XCTUnwrap(fixtureReader()),
                                    rect: rect(lat: 32.5, lon: -106.5))
        let b = LZPackStore.Mounted(reader: try XCTUnwrap(fixtureReader()),
                                    rect: rect(lat: 34.5, lon: -108.5))
        var north = 0, south = 0
        for seed in UInt64(1)...30 {                                 // bounded
            guard let d = pick(mounted: [a, b], sample: { _ in self.info(score: 80) },
                               seed: seed) else { continue }
            if d.coord.lat > 33.5 { north += 1 } else { south += 1 }
        }
        XCTAssertGreaterThan(north, 0, "never used the second pack")
        XCTAssertGreaterThan(south, 0, "never used the first pack")
    }

    // MARK: - helper

    /// The packaging fixture, which is the only .lzpack guaranteed to exist in a test run.
    private func fixtureReader() -> MBTilesReader? {
        guard let url = Bundle(for: Self.self).url(forResource: "lz_fixture", withExtension: "lzpack")
                ?? Bundle.main.url(forResource: "lz_fixture", withExtension: "lzpack") else {
            return nil
        }
        return MBTilesReader(path: url.path)
    }
}
