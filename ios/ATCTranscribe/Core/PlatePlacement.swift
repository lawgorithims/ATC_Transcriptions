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

    /// A sensible DEFAULT geographic width (metres) for an airport's plate plan-view: derived from the
    /// approach's coded fixes' extent when available (the plan view spans roughly the same area, plus
    /// margin for the page's non-plan content), else a nominal fallback. The user fine-tunes from here.
    static func defaultWidthMeters(fixExtentMeters: Double?) -> Double {
        guard let e = fixExtentMeters, e > 500 else { return 28_000 }   // ~15 NM fallback
        return min(max(e * 1.8, 8_000), 120_000)                        // clamp 4–65 NM
    }

    /// Clamp the width to a usable range (prevents pinch from collapsing/exploding the plate).
    static func clampWidthMeters(_ m: Double) -> Double { min(max(m, 2_000), 300_000) }

    /// Normalize a rotation to (-180, 180].
    static func normalizeRotation(_ deg: Double) -> Double {
        var d = deg.truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d <= -180 { d += 360 }
        return d
    }

    /// Offset a center by a geographic delta in metres (east/north) → new (lat, lon). A small-angle
    /// approximation, fine for the ~tens-of-km an approach plate spans.
    static func move(centerLat: Double, centerLon: Double, eastMeters: Double, northMeters: Double) -> (lat: Double, lon: Double) {
        let dLat = northMeters / 111_320.0
        let lat = centerLat + dLat
        let cosLat = max(cos(centerLat * .pi / 180), 0.01)
        let dLon = eastMeters / (111_320.0 * cosLat)
        return (min(max(lat, -85), 85), centerLon + dLon)
    }
}
