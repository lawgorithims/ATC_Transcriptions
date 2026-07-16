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

    /// The geographic coordinate of a corner of the (possibly rotated) plate rectangle. `dxSign`/`dySign`
    /// pick the corner in PLATE-LOCAL axes (+1,+1 = the plate's top-right; -1,+1 = top-left), which is
    /// then rotated clockwise-from-north with the plate — so the returned point rides the plate's own
    /// corner, wherever the rotation puts it. Used to pin the on-plate chrome (✕ / opacity control).
    static func corner(centerLat: Double, centerLon: Double,
                       widthMeters: Double, heightMeters: Double, rotationDeg: Double,
                       dxSign: Double, dySign: Double) -> CLLocationCoordinate2D {
        let dx = dxSign * widthMeters / 2          // plate-local: +x = plate-right
        let dy = dySign * heightMeters / 2         // plate-local: +y = plate-up
        let r = rotationDeg * .pi / 180            // clockwise from north
        let east = dx * cos(r) + dy * sin(r)       // rotate the local offset into geographic east/north
        let north = -dx * sin(r) + dy * cos(r)
        let mPerDegLat = 111_320.0
        let lat = centerLat + north / mPerDegLat
        let lon = centerLon + east / (mPerDegLat * max(cos(centerLat * .pi / 180), 0.01))
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    // (The manual-placement helpers — defaultWidthMeters / clampWidthMeters / normalizeRotation /
    //  move — were removed with the hand-alignment UI: placement is georef-only and not editable.)
}
