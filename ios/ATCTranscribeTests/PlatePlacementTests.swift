import XCTest
import MapKit
import UIKit
@testable import ATCTranscribe

/// Pure georeferencing math for the plate-on-map overlay.
final class PlatePlacementTests: XCTestCase {

    /// Opacity is BAKED INTO THE DRAW (`ctx.setAlpha`), never the compositor-level renderer `alpha`:
    /// real devices ignore `MKOverlayRenderer.alpha` for custom renderers (the sim honors it, which
    /// once masked a dead slider on hardware). Pin the regression: the renderer must leave compositor
    /// alpha at 1 (anything else double-fades in the sim), while the overlay carries the draw opacity.
    func testOpacityIsCarriedByOverlayNotCompositorAlpha() {
        let img = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }
        let state = PlateOverlayState(name: "ILS RWY 4R", airport: "KBOS", pdf: "00058IL4R.PDF", image: img,
                                      imageAspect: 0.77, centerLat: 42.36, centerLon: -71.0,
                                      widthMeters: 20_000, rotationDeg: 0, opacity: 0.35)
        let overlay = PlateImageOverlay(state: state)
        XCTAssertEqual(overlay.opacity, 0.35, accuracy: 1e-6)                    // draw() reads this
        XCTAssertEqual(PlateOverlayRenderer(overlay).alpha, 1.0, accuracy: 1e-6) // compositor untouched
        XCTAssertFalse(overlay.inverted)                                        // default not inverted
    }

    func testHeightFollowsAspect() {
        // aspect = w/h. A 20 km-wide plate with aspect 0.8 (portrait) is 25 km tall.
        XCTAssertEqual(PlatePlacement.heightMeters(widthMeters: 20_000, imageAspect: 0.8), 25_000, accuracy: 1)
        // Degenerate aspect → falls back to width (never divides by ~0).
        XCTAssertEqual(PlatePlacement.heightMeters(widthMeters: 20_000, imageAspect: 0), 20_000, accuracy: 1)
    }

    func testBoundingRectCentersOnCoordinate() {
        let lat = 42.36, lon = -71.0
        let r = PlatePlacement.boundingMapRect(centerLat: lat, centerLon: lon,
                                               widthMeters: 20_000, heightMeters: 25_000, rotationDeg: 0)
        let center = MKMapPoint(x: r.midX, y: r.midY).coordinate
        XCTAssertEqual(center.latitude, lat, accuracy: 0.01)
        XCTAssertEqual(center.longitude, lon, accuracy: 0.01)
        XCTAssertGreaterThan(r.width, 0)
    }

    func testRotationGrowsTheBoundingBox() {
        let unrot = PlatePlacement.boundingMapRect(centerLat: 40, centerLon: -100,
                                                   widthMeters: 20_000, heightMeters: 10_000, rotationDeg: 0)
        let rot45 = PlatePlacement.boundingMapRect(centerLat: 40, centerLon: -100,
                                                   widthMeters: 20_000, heightMeters: 10_000, rotationDeg: 45)
        XCTAssertGreaterThan(rot45.width, unrot.width, "a rotated plate needs a larger AABB so it isn't clipped")
        XCTAssertGreaterThan(rot45.height, unrot.height)
    }

    // (Tests for the manual-placement helpers — move / normalizeRotation / defaultWidth / clamp —
    //  were removed with the hand-alignment UI: placement is georef-only and not editable.)

    // MARK: - PlateGearGeometry
    //
    // The gear is a pilot's only on-map route to plate opacity / invert / hide. It shipped unreachable
    // through seven builds because its arithmetic lived inside a GeometryReader closure where no test
    // could see it: the map is full-bleed under the console, and a plate framed with its top corner
    // inside the chrome put the button behind the InputBar, where the LiveATC URL field ate every tap.
    // These tests pin the containment invariant that makes that impossible.

    /// The whole 64x64 hit box must sit inside the usable band — not just the centre point.
    private func assertInsideBand(_ c: CGPoint, viewport: CGSize, top: CGFloat, bottom: CGFloat,
                                  _ msg: String, file: StaticString = #filePath, line: UInt = #line) {
        let h = PlateGearGeometry.hitSize / 2
        XCTAssertGreaterThanOrEqual(c.y - h, top, "\(msg): hit box crosses the top chrome", file: file, line: line)
        XCTAssertLessThanOrEqual(c.y + h, viewport.height - bottom, "\(msg): hit box crosses the bottom chrome",
                                 file: file, line: line)
        XCTAssertGreaterThanOrEqual(c.x - h, 0, "\(msg): hit box off the left edge", file: file, line: line)
        XCTAssertLessThanOrEqual(c.x + h, viewport.width, "\(msg): hit box off the right edge", file: file, line: line)
    }

    /// THE regression: the exact measured failure. A KBOS plate framed by the MapLibre engine put its
    /// top-right corner at y≈146 with 280.5pt of console chrome above it, which placed the gear's centre
    /// at (714.5, 164) — inside the LiveATC URL field (x 14…820, y 151.5…189). Recorded from the device
    /// run in scratchpad/gear_diag.log: `gear frame: (682.5, 132.0, 64.0, 64.0) hittable: true`.
    func testMeasuredFailureNowLandsBelowTheChrome() {
        let viewport = CGSize(width: 834, height: 1210)
        let c = PlateGearGeometry.center(anchor: CGPoint(x: 732.5, y: 146), viewport: viewport,
                                         topInset: 280.5, bottomInset: 96)
        XCTAssertGreaterThanOrEqual(c.y - PlateGearGeometry.hitSize / 2, 280.5,
                                    "the gear must clear the expanded InputBar that swallowed the tap")
        assertInsideBand(c, viewport: viewport, top: 280.5, bottom: 96, "measured failure")
    }

    /// When the corner IS in the usable band the gear rides it exactly — the clamp must not "help".
    func testRidesTheCornerWhenTheCornerIsClear() {
        let viewport = CGSize(width: 834, height: 1210)
        let anchor = CGPoint(x: 500, y: 600)
        let c = PlateGearGeometry.center(anchor: anchor, viewport: viewport, topInset: 280.5, bottomInset: 96)
        XCTAssertEqual(c.x, anchor.x - PlateGearGeometry.cornerInset, accuracy: 0.001)
        XCTAssertEqual(c.y, anchor.y + PlateGearGeometry.cornerInset, accuracy: 0.001)
    }

    /// A plate panned far off-screen in any direction still leaves a reachable gear.
    func testOffScreenAnchorsPinToTheBand() {
        let viewport = CGSize(width: 834, height: 1210)
        for anchor in [CGPoint(x: -5000, y: -5000), CGPoint(x: 9000, y: 9000),
                       CGPoint(x: -5000, y: 9000), CGPoint(x: 9000, y: -5000)] {
            let c = PlateGearGeometry.center(anchor: anchor, viewport: viewport, topInset: 280.5, bottomInset: 96)
            assertInsideBand(c, viewport: viewport, top: 280.5, bottom: 96, "anchor \(anchor)")
        }
    }

    /// MLNMapView returns CGPoint(NaN, NaN) for a coordinate failing CLLocationCoordinate2DIsValid, and
    /// Swift's min/max PROPAGATE NaN — so without an explicit guard the clamp passes it to `.position`.
    func testNonFiniteAnchorsCannotEscape() {
        let viewport = CGSize(width: 834, height: 1210)
        let nan = CGFloat.nan, inf = CGFloat.infinity
        for anchor in [CGPoint(x: nan, y: nan), CGPoint(x: 400, y: nan), CGPoint(x: nan, y: 400),
                       CGPoint(x: inf, y: -inf)] {
            let c = PlateGearGeometry.center(anchor: anchor, viewport: viewport, topInset: 280.5, bottomInset: 96)
            XCTAssertTrue(c.x.isFinite && c.y.isFinite, "non-finite anchor \(anchor) reached .position")
            assertInsideBand(c, viewport: viewport, top: 280.5, bottom: 96, "non-finite \(anchor)")
        }
    }

    /// The globe fork returns a FINITE far-side sentinel {-1e6,-1e6} for an occluded coordinate rather
    /// than NaN, so it must clamp normally (not trip the non-finite path).
    func testGlobeFarSideSentinelClampsIntoTheBand() {
        let viewport = CGSize(width: 834, height: 1210)
        let c = PlateGearGeometry.center(anchor: CGPoint(x: -1.0e6, y: -1.0e6), viewport: viewport,
                                         topInset: 280.5, bottomInset: 96)
        assertInsideBand(c, viewport: viewport, top: 280.5, bottom: 96, "globe far-side sentinel")
    }

    /// Every strip and banner up at once can make the chrome taller than the viewport. The band inverts;
    /// the result must stay finite and defined rather than silently returning an inverted range.
    func testDegenerateChromeCollapsesToMidpointInsteadOfInverting() {
        let viewport = CGSize(width: 834, height: 400)
        let c = PlateGearGeometry.center(anchor: CGPoint(x: 400, y: 200), viewport: viewport,
                                         topInset: 560, bottomInset: 150)
        XCTAssertTrue(c.x.isFinite && c.y.isFinite, "degenerate chrome produced a non-finite point")
        XCTAssertGreaterThan(c.y, 0, "collapsed point should still be on screen-ish, not negative-infinite")
    }

    /// Bounded sweep (Power of 10): across every plausible chrome height and anchor position, the hit box
    /// stays inside the band. This is the invariant the shipped bug violated.
    func testContainmentInvariantAcrossChromeAndAnchorSweep() {
        let viewport = CGSize(width: 834, height: 1210)
        var checked = 0
        for chrome in stride(from: CGFloat(87), through: 560, by: 43) {
            for bottom in [CGFloat(96), 150] {
                for ay in stride(from: CGFloat(-200), through: 1400, by: 100) {
                    for ax in stride(from: CGFloat(-200), through: 1000, by: 200) {
                        let c = PlateGearGeometry.center(anchor: CGPoint(x: ax, y: ay), viewport: viewport,
                                                         topInset: chrome, bottomInset: bottom)
                        // The band is non-degenerate for every chrome value in this sweep.
                        assertInsideBand(c, viewport: viewport, top: chrome, bottom: bottom,
                                         "chrome \(chrome) bottom \(bottom) anchor (\(ax),\(ay))")
                        checked += 1
                    }
                }
            }
        }
        XCTAssertGreaterThan(checked, 500, "sweep should actually cover a meaningful grid")
    }
}
