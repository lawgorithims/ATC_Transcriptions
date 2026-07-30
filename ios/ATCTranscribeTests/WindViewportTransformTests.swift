import XCTest
import CoreLocation
import simd
@testable import ATCTranscribe

/// The coordinate↔screen maths the wind particles live in, plus the colour ramp and the render-speed and
/// span gates. All pure: no map, no GPU, no simulator.
final class WindViewportTransformTests: XCTestCase {

    /// A north-up view: 100 points per degree east, y increasing southward (screen convention), centred at
    /// (35 N, 95 W) on a 800×600 view.
    private func northUp() -> WindViewportTransform {
        let center = CLLocationCoordinate2D(latitude: 35, longitude: -95)
        return WindViewportTransform.fit(center: center,
                                         centerPoint: CGPoint(x: 400, y: 300),
                                         northPoint: CGPoint(x: 400, y: 290),   // +0.1° lat → 10 pt UP
                                         eastPoint: CGPoint(x: 410, y: 300),    // +0.1° lon → 10 pt RIGHT
                                         northDelta: 0.1, eastDelta: 0.1)!
    }

    func testForwardAndInverseRoundTrip() throws {
        let t = northUp()
        for (lat, lon) in [(35.0, -95.0), (36.5, -93.2), (33.1, -97.9)] {
            let p = t.toScreen(lon: lon, lat: lat)
            let back = try XCTUnwrap(t.toLonLat(p))
            XCTAssertEqual(back.lat, lat, accuracy: 1e-9)
            XCTAssertEqual(back.lon, lon, accuracy: 1e-9)
        }
        XCTAssertEqual(t.toScreen(lon: -95, lat: 35).x, 400, accuracy: 1e-6)
        XCTAssertEqual(t.toScreen(lon: -94, lat: 35).x, 500, accuracy: 1e-6, "1° east = 100 pt right")
        XCTAssertEqual(t.toScreen(lon: -95, lat: 36).y, 200, accuracy: 1e-6, "1° north = 100 pt UP")
        XCTAssertEqual(t.pointsPerDegreeLon, 100, accuracy: 1e-6)
    }

    /// Probing toward the equator (a negative latitude step, which is what happens near a pole) must not
    /// invert the vertical axis. This is the mirrored-field bug the signed delta exists to prevent.
    func testNegativeNorthProbeStillYieldsNorthUp() throws {
        let center = CLLocationCoordinate2D(latitude: 88, longitude: 10)
        let t = try XCTUnwrap(WindViewportTransform.fit(center: center,
                                                       centerPoint: CGPoint(x: 400, y: 300),
                                                       northPoint: CGPoint(x: 400, y: 310),  // 0.1° SOUTH = 10 pt DOWN
                                                       eastPoint: CGPoint(x: 410, y: 300),
                                                       northDelta: -0.1, eastDelta: 0.1))
        let higher = t.toScreen(lon: 10, lat: 88.5)
        XCTAssertLessThan(higher.y, 300, "moving north must move UP the screen")
    }

    /// Both cases here are RUNTIME data, not programmer error: a projection singularity is what a
    /// collapsed or non-finite probe looks like from this side, so they must return nil rather than assert.
    /// (A zero probe step, by contrast, is unreachable — the caller clamps it — and is asserted instead.)
    func testDegenerateFitsAreRejected() {
        let c = CLLocationCoordinate2D(latitude: 0, longitude: 0)
        // Collapsed basis: the north and east probes land on the centre.
        XCTAssertNil(WindViewportTransform.fit(center: c, centerPoint: .zero, northPoint: .zero,
                                               eastPoint: .zero, northDelta: 0.1, eastDelta: 0.1))
        // Non-finite probe (a projection singularity).
        XCTAssertNil(WindViewportTransform.fit(center: c, centerPoint: .zero,
                                               northPoint: CGPoint(x: CGFloat.nan, y: 0),
                                               eastPoint: CGPoint(x: 10, y: 0),
                                               northDelta: 0.1, eastDelta: 0.1))
    }

    /// A westerly (u > 0) must push particles to the RIGHT and a southerly (v > 0) UP the screen, at the
    /// requested render speed regardless of the true magnitude.
    func testScreenVelocityDirectionAndMagnitude() {
        let t = northUp()
        let east = t.screenVelocity(u: 10, v: 0, atLat: 35, speedPoints: 50)
        XCTAssertEqual(east.dx, 50, accuracy: 1e-6)
        XCTAssertEqual(east.dy, 0, accuracy: 1e-6)

        let north = t.screenVelocity(u: 0, v: 10, atLat: 35, speedPoints: 50)
        XCTAssertEqual(north.dx, 0, accuracy: 1e-6)
        XCTAssertEqual(north.dy, -50, accuracy: 1e-6, "northward wind moves UP (negative y)")

        let calm = t.screenVelocity(u: 0, v: 0, atLat: 35, speedPoints: 50)
        XCTAssertEqual(calm.dx, 0, accuracy: 1e-9)
        XCTAssertEqual(calm.dy, 0, accuracy: 1e-9)
    }

    /// On a ROTATED chart the direction must follow the projection, not the screen axes. A 90°-clockwise
    /// view puts north to the right, so an eastward wind must travel DOWN the screen.
    func testScreenVelocityFollowsARotatedChart() throws {
        let center = CLLocationCoordinate2D(latitude: 35, longitude: -95)
        let rotated = try XCTUnwrap(WindViewportTransform.fit(center: center,
                                                             centerPoint: CGPoint(x: 400, y: 300),
                                                             northPoint: CGPoint(x: 410, y: 300),
                                                             eastPoint: CGPoint(x: 400, y: 310),
                                                             northDelta: 0.1, eastDelta: 0.1))
        let east = rotated.screenVelocity(u: 10, v: 0, atLat: 35, speedPoints: 30)
        XCTAssertEqual(east.dx, 0, accuracy: 1e-6)
        XCTAssertEqual(east.dy, 30, accuracy: 1e-6, "with north to the right, east is down the screen")
    }

    /// The pole guard: latitude 90 would divide by cos(90) = 0.
    func testPolarLatitudeDoesNotProduceInfinity() {
        let t = northUp()
        let v = t.screenVelocity(u: 30, v: 30, atLat: 89.999, speedPoints: 40)
        XCTAssertTrue(v.dx.isFinite && v.dy.isFinite)
        XCTAssertEqual((v.dx * v.dx + v.dy * v.dy).squareRoot(), 40, accuracy: 1e-6)
    }

    // MARK: map motion

    /// A pure pan: the delta must carry a screen point by exactly the pan distance, so the trails and the
    /// particles move with the terrain instead of the screen.
    func testDeltaTracksAPan() throws {
        let before = northUp()
        // The map panned 1° east: the same coordinate now appears 100 pt further LEFT.
        let after = try XCTUnwrap(WindViewportTransform.fit(
            center: CLLocationCoordinate2D(latitude: 35, longitude: -94),
            centerPoint: CGPoint(x: 400, y: 300),
            northPoint: CGPoint(x: 400, y: 290), eastPoint: CGPoint(x: 410, y: 300),
            northDelta: 0.1, eastDelta: 0.1))
        let motion = try XCTUnwrap(after.delta(from: before))
        let moved = CGPoint(x: 400, y: 300).applying(motion)
        XCTAssertEqual(moved.x, 300, accuracy: 1e-6, "the old centre is now 100 pt left")
        XCTAssertEqual(moved.y, 300, accuracy: 1e-6)
        // The delta must agree with projecting the coordinate directly through the new transform.
        let direct = after.toScreen(lon: -95, lat: 35)
        XCTAssertEqual(moved.x, direct.x, accuracy: 1e-6)
        XCTAssertEqual(moved.y, direct.y, accuracy: 1e-6)
    }

    func testDeltaTracksAZoom() throws {
        let before = northUp()
        let after = try XCTUnwrap(WindViewportTransform.fit(
            center: CLLocationCoordinate2D(latitude: 35, longitude: -95),
            centerPoint: CGPoint(x: 400, y: 300),
            northPoint: CGPoint(x: 400, y: 280), eastPoint: CGPoint(x: 420, y: 300),   // 2× zoom
            northDelta: 0.1, eastDelta: 0.1))
        let motion = try XCTUnwrap(after.delta(from: before))
        let moved = CGPoint(x: 500, y: 300).applying(motion)     // was 1° east of centre
        XCTAssertEqual(moved.x, 600, accuracy: 1e-6, "1° east is now 200 pt out")
        XCTAssertEqual(moved.y, 300, accuracy: 1e-6)
    }

    func testIdenticalCameraGivesAnIdentityDelta() throws {
        let t = northUp()
        let motion = try XCTUnwrap(t.delta(from: t))
        let p = CGPoint(x: 123, y: 456).applying(motion)
        XCTAssertEqual(p.x, 123, accuracy: 1e-6)
        XCTAssertEqual(p.y, 456, accuracy: 1e-6)
    }

    /// The trail texture is re-registered by sampling the OLD texture at each destination pixel's previous
    /// location, so the shader matrix is the inverse of the motion — and must be identity for no motion.
    func testUvTransformIsIdentityWithoutMotion() {
        let m = WindParticleRenderer.uvTransform(motion: .identity, size: CGSize(width: 800, height: 600))
        let v = m * SIMD3<Float>(0.25, 0.75, 1)
        XCTAssertEqual(v.x, 0.25, accuracy: 1e-6)
        XCTAssertEqual(v.y, 0.75, accuracy: 1e-6)
    }

    func testUvTransformInvertsAPan() {
        let size = CGSize(width: 800, height: 600)
        // The map moved content 80 pt right and 60 pt down.
        let motion = CGAffineTransform(translationX: 80, y: 60)
        let m = WindParticleRenderer.uvTransform(motion: motion, size: size)
        let v = m * SIMD3<Float>(0.5, 0.5, 1)
        XCTAssertEqual(v.x, 0.5 - 80 / 800, accuracy: 1e-6, "sample where the pixel came FROM")
        XCTAssertEqual(v.y, 0.5 - 60 / 600, accuracy: 1e-6)
    }

    func testUvTransformRejectsADegenerateMotion() {
        let m = WindParticleRenderer.uvTransform(motion: CGAffineTransform(scaleX: 0, y: 0),
                                                 size: CGSize(width: 800, height: 600))
        let v = m * SIMD3<Float>(0.3, 0.4, 1)
        XCTAssertEqual(v.x, 0.3, accuracy: 1e-6, "a collapsed motion falls back to identity")
        XCTAssertEqual(v.y, 0.4, accuracy: 1e-6)
        let zero = WindParticleRenderer.uvTransform(motion: .identity, size: .zero)
        XCTAssertEqual((zero * SIMD3<Float>(0.3, 0.4, 1)).x, 0.3, accuracy: 1e-6)
    }

    // MARK: gates and ramp

    func testSpanGateFadesTheLayerOut() {
        XCTAssertEqual(WindParticleRenderer.spanAlpha(5), 1, accuracy: 1e-9)
        XCTAssertEqual(WindParticleRenderer.spanAlpha(WindParticleRenderer.fullAlphaSpan), 1, accuracy: 1e-9)
        XCTAssertEqual(WindParticleRenderer.spanAlpha(37.5), 0.5, accuracy: 0.01)
        XCTAssertEqual(WindParticleRenderer.spanAlpha(WindParticleRenderer.cutoffSpan), 0, accuracy: 1e-9)
        XCTAssertEqual(WindParticleRenderer.spanAlpha(360), 0, accuracy: 1e-9)
    }

    func testRenderSpeedScaleIsBoundedAndMonotonic() {
        let low = WindParticleRenderer.renderSpeedScale(zoom: 3)
        let mid = WindParticleRenderer.renderSpeedScale(zoom: 7)
        let high = WindParticleRenderer.renderSpeedScale(zoom: 13)
        XCTAssertLessThan(low, mid)
        XCTAssertLessThan(mid, high)
        // Bounded at both ends: below the floor light air freezes (segments fall under the rasteriser's
        // sample grid and vanish); above the ceiling particles cross the screen faster than the eye tracks.
        for z in [-5.0, 0, 3, 7, 13, 25, 100] {
            let s = WindParticleRenderer.renderSpeedScale(zoom: z)
            XCTAssertGreaterThanOrEqual(s, 1.5, "zoom \(z)")
            XCTAssertLessThanOrEqual(s, 5.0, "zoom \(z)")
        }
        // The calibrated mid-scale: a 30 kt wind should cross roughly 70 points a second at zoom 6.
        XCTAssertEqual(Double(WindParticleRenderer.renderSpeedScale(zoom: 6)) * 30, 72, accuracy: 6)
    }

    func testRampIsMonotonicallyWarmAndClamped() {
        let day = WindRamp.forTheme(.cockpit)
        // Red rises and blue falls with speed across the cool-to-hot ramp.
        XCTAssertLessThan(day.rgb(kt: 0).x, day.rgb(kt: 60).x)
        XCTAssertGreaterThan(day.rgb(kt: 0).z, day.rgb(kt: 60).z)
        // Out-of-range input clamps rather than extrapolating into invalid colour.
        for kt in [-50, 0, 45, 150, 500] as [Float] {
            let c = day.rgb(kt: kt)
            for ch in [c.x, c.y, c.z] {
                XCTAssertGreaterThanOrEqual(ch, 0, "kt \(kt)")
                XCTAssertLessThanOrEqual(ch, 1, "kt \(kt)")
            }
            // Bounded well below full opacity: this overlay sits on a chart that must stay readable.
            let a = day.alpha(kt: kt)
            XCTAssertGreaterThanOrEqual(a, 0.25)
            XCTAssertLessThanOrEqual(a, 0.63)
        }
        XCTAssertEqual(day.rgb(kt: 200), day.rgb(kt: WindRamp.topKt), "above the ceiling is the top colour")
    }

    /// Night vision: the night ramp must stay on a red hue at every speed. A blue-heavy particle field
    /// would defeat the whole point of the red-on-black night theme.
    func testNightRampStaysRed() {
        let night = WindRamp.forTheme(.night)
        for kt in stride(from: Float(0), through: WindRamp.topKt, by: 10) {
            let c = night.rgb(kt: kt)
            XCTAssertGreaterThan(c.x, c.y, "kt \(kt): red must dominate green")
            XCTAssertGreaterThan(c.x, c.z, "kt \(kt): red must dominate blue")
            XCTAssertLessThan(c.z, 0.55, "kt \(kt): no strong blue at night")
        }
        XCTAssertLessThan(night.rgb(kt: 0).x, night.rgb(kt: 120).x, "speed reads as intensity")
        XCTAssertEqual(WindRamp.forTheme(.day).rgb(kt: 60), WindRamp.forTheme(.cockpit).rgb(kt: 60),
                       "only the night theme swaps the ramp")
    }

    func testLegendColorsSpanTheRamp() {
        let colors = WindRamp.forTheme(.cockpit).cgColors(steps: 7)
        XCTAssertEqual(colors.count, 7)
        XCTAssertEqual(colors.first?.components?.count, 4)
        XCTAssertEqual(WindRamp.forTheme(.cockpit).cgColors(steps: 99).count, 16, "step count is capped")
    }
}
