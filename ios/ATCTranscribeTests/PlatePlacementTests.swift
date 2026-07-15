import XCTest
import MapKit
import UIKit
@testable import ATCTranscribe

/// Pure georeferencing math for the plate-on-map overlay.
final class PlatePlacementTests: XCTestCase {

    /// The opacity slider works through the renderer's compositor-level `alpha` (MapKit caches drawn
    /// overlay tiles, so a `setNeedsDisplay()` content redraw is unreliable). Pin that the renderer
    /// self-initializes its alpha from the overlay state — the "created mid-slide" case.
    func testRendererAlphaTracksOverlayOpacity() {
        let img = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }
        let state = PlateOverlayState(name: "ILS RWY 4R", airport: "KBOS", image: img, imageAspect: 0.77,
                                      centerLat: 42.36, centerLon: -71.0,
                                      widthMeters: 20_000, rotationDeg: 0, opacity: 0.35)
        let overlay = PlateImageOverlay(state: state)
        XCTAssertEqual(PlateOverlayRenderer(overlay).alpha, 0.35, accuracy: 1e-6)
        // An opacity-only reconcile mutates the overlay + renderer alpha in place.
        overlay.opacity = 0.8
        let r = PlateOverlayRenderer(overlay)
        XCTAssertEqual(r.alpha, 0.8, accuracy: 1e-6)
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

    func testMoveEastNorthByOneDegree() {
        // ~111.32 km per degree of latitude; longitude scaled by cos(lat). At the equator both are ~equal.
        let m = PlatePlacement.move(centerLat: 0, centerLon: 0, eastMeters: 111_320, northMeters: 111_320)
        XCTAssertEqual(m.lat, 1.0, accuracy: 0.02)
        XCTAssertEqual(m.lon, 1.0, accuracy: 0.02)
        // Longitude degrees grow at higher latitude (cos shrinks the metres-per-degree).
        let hi = PlatePlacement.move(centerLat: 60, centerLon: 0, eastMeters: 111_320, northMeters: 0)
        XCTAssertEqual(hi.lon, 2.0, accuracy: 0.1, "at 60°N a degree of longitude is ~half the distance")
    }

    func testNormalizeRotation() {
        XCTAssertEqual(PlatePlacement.normalizeRotation(190), -170, accuracy: 1e-6)
        XCTAssertEqual(PlatePlacement.normalizeRotation(-190), 170, accuracy: 1e-6)
        XCTAssertEqual(PlatePlacement.normalizeRotation(360), 0, accuracy: 1e-6)
        XCTAssertEqual(PlatePlacement.normalizeRotation(45), 45, accuracy: 1e-6)
    }

    func testDefaultWidthAndClamp() {
        XCTAssertEqual(PlatePlacement.defaultWidthMeters(fixExtentMeters: nil), 28_000, accuracy: 1)
        XCTAssertEqual(PlatePlacement.defaultWidthMeters(fixExtentMeters: 100), 28_000, accuracy: 1)   // too small → fallback
        XCTAssertEqual(PlatePlacement.defaultWidthMeters(fixExtentMeters: 10_000), 18_000, accuracy: 1) // 1.8×
        XCTAssertEqual(PlatePlacement.defaultWidthMeters(fixExtentMeters: 1_000_000), 120_000, accuracy: 1) // clamped
        XCTAssertEqual(PlatePlacement.clampWidthMeters(1), 2_000, accuracy: 1)
        XCTAssertEqual(PlatePlacement.clampWidthMeters(9_999_999), 300_000, accuracy: 1)
    }
}
