import Foundation
import MapKit
import CoreLocation

/// Pure geometry for georeferencing a rectangular plate image onto the map (unit-tested). A plate is
/// placed by its geographic CENTER, the geographic WIDTH it spans (height follows the image aspect),
/// and a clockwise ROTATION from north. Because MapKit clips an overlay to its `boundingMapRect`, the
/// bounding rect must be the axis-aligned box of the (possibly rotated) plate rectangle, so a rotated
/// plate is never cropped.
enum PlatePlacement {

    /// Height in metres for a plate `widthMeters` wide with the given image aspect (w/h). Guards a
    /// degenerate aspect.
    static func heightMeters(widthMeters: Double, imageAspect: Double) -> Double {
        guard imageAspect > 0.01, widthMeters > 0 else { return widthMeters }
        return widthMeters / imageAspect
    }

    /// The axis-aligned `MKMapRect` that fully contains the rotated plate rectangle centered at
    /// (centerLat, centerLon). `rotationDeg` clockwise from north.
    static func boundingMapRect(centerLat: Double, centerLon: Double,
                                widthMeters: Double, heightMeters: Double, rotationDeg: Double) -> MKMapRect {
        let ppm = MKMapPointsPerMeterAtLatitude(centerLat)
        let wp = max(widthMeters, 1) * ppm
        let hp = max(heightMeters, 1) * ppm
        let r = rotationDeg * .pi / 180
        let aabbW = abs(wp * cos(r)) + abs(hp * sin(r))
        let aabbH = abs(wp * sin(r)) + abs(hp * cos(r))
        let c = MKMapPoint(CLLocationCoordinate2D(latitude: centerLat, longitude: centerLon))
        return MKMapRect(x: c.x - aabbW / 2, y: c.y - aabbH / 2, width: aabbW, height: aabbH)
    }

    // (The manual-placement helpers — defaultWidthMeters / clampWidthMeters / normalizeRotation /
    //  move — were removed with the hand-alignment UI: placement is georef-only and not editable.)
}
