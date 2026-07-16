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
}
