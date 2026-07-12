import XCTest
import simd
@testable import ATCTranscribe

/// The georeferencing solver. The key test is a ROUND TRIP: synthesize control points by pushing
/// known plate pixels through the renderer's forward model at a KNOWN placement, then fit them back
/// and assert the recovered placement matches — this pins the scale/rotation signs to the renderer.
final class PlateSimilarityTests: XCTestCase {

    private let imageW = 2000.0, imageH = 3000.0

    /// A spread of plate pixels to use as control points (plan-view-ish positions).
    private let samplePixels: [SIMD2<Double>] = [
        SIMD2(400, 500), SIMD2(1600, 600), SIMD2(1000, 1500),
        SIMD2(600, 2400), SIMD2(1500, 2200), SIMD2(1000, 900),
    ]

    private func roundTrip(center: SIMD2<Double>, width: Double, rotation: Double,
                           noise: Double = 0, file: StaticString = #filePath, line: UInt = #line) {
        let pl = PlateSimilarity.Placement(centerEast: center.x, centerNorth: center.y,
                                           widthMeters: width, rotationDeg: rotation)
        var world = samplePixels.map { PlateSimilarity.forwardModel(pl, imageW: imageW, imageH: imageH, px: $0.x, py: $0.y) }
        if noise > 0 {   // deterministic pseudo-noise so the test never flakes
            for i in world.indices {
                let j = Double(i)
                world[i] += SIMD2(noise * sin(j * 1.3), noise * cos(j * 2.1))
            }
        }
        guard let r = PlateSimilarity.georeference(pixels: samplePixels, world: world, imageW: imageW, imageH: imageH) else {
            return XCTFail("georeference returned nil", file: file, line: line)
        }
        XCTAssertEqual(r.placement.centerEast, center.x, accuracy: max(1, noise), file: file, line: line)
        XCTAssertEqual(r.placement.centerNorth, center.y, accuracy: max(1, noise), file: file, line: line)
        XCTAssertEqual(r.placement.widthMeters, width, accuracy: max(1, noise) + width * 0.001, file: file, line: line)
        XCTAssertEqual(PlateSimilarity.normalizeDeg(r.placement.rotationDeg - rotation), 0, accuracy: 0.2, file: file, line: line)
    }

    func testRoundTripNorthUp() { roundTrip(center: SIMD2(0, 0), width: 20_000, rotation: 0) }
    func testRoundTripOffset() { roundTrip(center: SIMD2(1500, -800), width: 25_000, rotation: 0) }
    func testRoundTripRotatedCW() { roundTrip(center: SIMD2(200, 300), width: 18_000, rotation: 30) }
    func testRoundTripRotatedLarge() { roundTrip(center: SIMD2(-500, 900), width: 40_000, rotation: 135) }
    func testRoundTripRotatedNegative() { roundTrip(center: SIMD2(0, 0), width: 22_000, rotation: -60) }

    func testRoundTripWithNoiseStaysClose() {
        // A few metres of per-point pixel-label jitter must still recover a good placement (that's why
        // we use ≥3 points + least-squares); the residual reflects the noise.
        let pl = PlateSimilarity.Placement(centerEast: 0, centerNorth: 0, widthMeters: 20_000, rotationDeg: 20)
        var world = samplePixels.map { PlateSimilarity.forwardModel(pl, imageW: imageW, imageH: imageH, px: $0.x, py: $0.y) }
        for i in world.indices { world[i] += SIMD2(120 * sin(Double(i) * 1.7), 120 * cos(Double(i) * 0.9)) }
        let r = PlateSimilarity.georeference(pixels: samplePixels, world: world, imageW: imageW, imageH: imageH)!
        XCTAssertGreaterThan(r.rmsMeters, 10, "residual should reflect the injected noise")
        XCTAssertLessThan(r.rmsMeters, 400, "least-squares should still average out the noise")
        XCTAssertEqual(r.placement.widthMeters, 20_000, accuracy: 1500)
    }

    func testTwoPointsSuffice() {
        let pl = PlateSimilarity.Placement(centerEast: 100, centerNorth: 50, widthMeters: 16_000, rotationDeg: 10)
        let px = [SIMD2(500.0, 700.0), SIMD2(1500.0, 2200.0)]
        let world = px.map { PlateSimilarity.forwardModel(pl, imageW: imageW, imageH: imageH, px: $0.x, py: $0.y) }
        let r = PlateSimilarity.georeference(pixels: px, world: world, imageW: imageW, imageH: imageH)!
        XCTAssertEqual(r.placement.widthMeters, 16_000, accuracy: 5)
        XCTAssertEqual(PlateSimilarity.normalizeDeg(r.placement.rotationDeg - 10), 0, accuracy: 0.1)
        XCTAssertLessThan(r.rmsMeters, 0.01)
    }

    func testWorldToPixelInvertsForwardModel() {
        // worldToPixel must be the exact inverse of forwardModel (used to validate a fit by checking
        // the airport lands in the plan view). Round-trip several pixels through a rotated placement.
        let pl = PlateSimilarity.Placement(centerEast: 300, centerNorth: -200, widthMeters: 30_000, rotationDeg: 18)
        for p in samplePixels {
            let world = PlateSimilarity.forwardModel(pl, imageW: imageW, imageH: imageH, px: p.x, py: p.y)
            let back = PlateSimilarity.worldToPixel(pl, imageW: imageW, imageH: imageH, east: world.x, north: world.y)
            XCTAssertEqual(back.x, p.x, accuracy: 0.01)
            XCTAssertEqual(back.y, p.y, accuracy: 0.01)
        }
    }

    func testDegenerateInputsReturnNil() {
        XCTAssertNil(PlateSimilarity.georeference(pixels: [SIMD2(1, 1)], world: [SIMD2(0, 0)], imageW: imageW, imageH: imageH))
        // Coincident source points → no scale/rotation determinable.
        let same = [SIMD2(10.0, 10.0), SIMD2(10.0, 10.0), SIMD2(10.0, 10.0)]
        let world = [SIMD2(0.0, 0.0), SIMD2(1.0, 0.0), SIMD2(0.0, 1.0)]
        XCTAssertNil(PlateSimilarity.georeference(pixels: same, world: world, imageW: imageW, imageH: imageH))
    }

    func testNonFiniteWorldFailsClosed() {
        // A single +Inf/NaN world coordinate (finite pixels) must NOT yield a "confident" garbage
        // placement — the solver fails closed (F4). Without the guard, finite src + Inf dst → scale=Inf
        // → a non-nil Placement with Inf width that only luck (a downstream rms<250 check) would catch.
        let px = [SIMD2(400.0, 500.0), SIMD2(1600.0, 600.0), SIMD2(1000.0, 1500.0)]
        for bad in [Double.infinity, -Double.infinity, Double.nan] {
            var world = px.map { PlateSimilarity.forwardModel(
                .init(centerEast: 0, centerNorth: 0, widthMeters: 20_000, rotationDeg: 0),
                imageW: imageW, imageH: imageH, px: $0.x, py: $0.y) }
            world[1] = SIMD2(bad, world[1].y)
            XCTAssertNil(PlateSimilarity.georeference(pixels: px, world: world, imageW: imageW, imageH: imageH),
                         "non-finite world \(bad) must fail closed")
        }
    }

    func testNearCoincidentPixelsFailClosed() {
        // Points 0.001 px apart are NOT exactly coincident (so the bare varS>1e-9 guard passes) but are
        // degenerate — they'd fit an astronomically-large scale. The pixel-scale-relative spread gate
        // rejects them (F3).
        let px = [SIMD2(1000.0, 1500.0), SIMD2(1000.001, 1500.0), SIMD2(1000.0, 1500.001)]
        let world = [SIMD2(0.0, 0.0), SIMD2(1.0, 0.0), SIMD2(0.0, 1.0)]
        XCTAssertNil(PlateSimilarity.georeference(pixels: px, world: world, imageW: imageW, imageH: imageH))
    }
}
