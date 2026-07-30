import CoreGraphics
import CoreLocation

/// The affine map between geographic coordinates and screen points that the wind particles live in.
///
/// **Why this is fitted rather than derived.** The obvious implementation is hand-written Web-Mercator
/// arithmetic from the camera's centre and zoom. That is wrong in this app: the map runs the forked
/// MapLibre's vertical-perspective globe below zoom 12, where the effective scale carries a `cos(lat)`
/// factor and straight mercator is off by roughly a quarter at mid latitudes — and it is wrong again
/// whenever the pilot rotates the chart. So instead of modelling the projection, this samples it: three
/// `MLNMapView.convert` calls (the centre, a step north, a step east) pin down a 2×2 Jacobian plus an
/// origin, which is exact at the centre of the screen under any projection, any bearing, and all the way
/// through the globe→mercator blend.
///
/// A single affine cannot represent a whole hemisphere, which is why the renderer fades the layer out by
/// visible span rather than trusting this at every zoom.
///
/// Pure and free of UIKit so the maths is unit-tested with no map, no GPU and no simulator.
struct WindViewportTransform: Equatable {
    /// The coordinate the fit was taken about — the expansion point of the linearisation.
    let originLon: Double
    let originLat: Double
    /// Its screen point, in view points.
    let originX: Double
    let originY: Double
    /// Jacobian: ∂x/∂lon, ∂x/∂lat, ∂y/∂lon, ∂y/∂lat (points per degree).
    let a: Double
    let b: Double
    let c: Double
    let d: Double

    /// Fit from three projected samples. The probe steps must be small enough to stay in the linear region
    /// yet large enough to clear pixel quantisation — a few hundredths of a degree at approach zooms up to
    /// a degree at continental ones.
    ///
    /// Both steps are SIGNED. Near a pole the caller probes toward the equator instead of past 90°, which
    /// makes the latitude step negative, and the derivative must be divided by the step actually taken or
    /// the whole field renders mirrored north-for-south.
    ///
    /// Returns nil for a degenerate sample set (a collapsed or mirrored basis), which is what a projection
    /// singularity looks like from here — the caller then skips the frame rather than drawing nonsense.
    static func fit(center: CLLocationCoordinate2D, centerPoint pC: CGPoint,
                    northPoint pN: CGPoint, eastPoint pE: CGPoint,
                    northDelta: Double, eastDelta: Double) -> WindViewportTransform? {
        assert(northDelta != 0 && eastDelta != 0, "WindViewportTransform: probe step must be non-zero")
        assert(pC.x.isFinite && pC.y.isFinite, "WindViewportTransform: non-finite centre point")
        guard abs(northDelta) > 1e-12, abs(eastDelta) > 1e-12,
              pC.x.isFinite, pC.y.isFinite, pN.x.isFinite, pN.y.isFinite,
              pE.x.isFinite, pE.y.isFinite else { return nil }
        let a = (Double(pE.x) - Double(pC.x)) / eastDelta
        let c = (Double(pE.y) - Double(pC.y)) / eastDelta
        let b = (Double(pN.x) - Double(pC.x)) / northDelta
        let d = (Double(pN.y) - Double(pC.y)) / northDelta
        let det = a * d - b * c
        guard det.isFinite, abs(det) > 1e-9 else { return nil }
        return WindViewportTransform(originLon: center.longitude, originLat: center.latitude,
                                     originX: Double(pC.x), originY: Double(pC.y),
                                     a: a, b: b, c: c, d: d)
    }

    /// Points per degree of longitude along the screen — the scale used to size the span gate.
    var pointsPerDegreeLon: Double { (a * a + c * c).squareRoot() }

    var determinant: Double { a * d - b * c }

    func toScreen(lon: Double, lat: Double) -> CGPoint {
        let dLon = lon - originLon, dLat = lat - originLat
        return CGPoint(x: originX + a * dLon + b * dLat,
                       y: originY + c * dLon + d * dLat)
    }

    /// Inverse of `toScreen`. nil only if the basis degenerated after construction (guarded, not asserted,
    /// because this runs per particle per frame).
    func toLonLat(_ p: CGPoint) -> (lon: Double, lat: Double)? {
        let det = determinant
        guard abs(det) > 1e-9 else { return nil }
        let dx = Double(p.x) - originX, dy = Double(p.y) - originY
        let dLon = (d * dx - b * dy) / det
        let dLat = (-c * dx + a * dy) / det
        return (originLon + dLon, originLat + dLat)
    }

    /// Screen displacement (points per second) for a wind vector in metres per second, with `speedPoints`
    /// substituted for the true magnitude.
    ///
    /// Direction comes from the projection — so a rotated chart or a curved globe still shows the wind
    /// blowing the right way — while the magnitude is chosen for legibility. Using the true magnitude would
    /// make particles crawl imperceptibly at continental zoom and streak off screen on an approach plate.
    func screenVelocity(u: Double, v: Double, atLat lat: Double, speedPoints: Double) -> CGVector {
        assert(speedPoints >= 0, "WindViewportTransform: negative render speed")
        assert(lat >= -90.5 && lat <= 90.5, "WindViewportTransform: latitude out of range")
        let cosLat = max(cos(lat * .pi / 180), 0.05)          // guard the pole singularity
        let dLon = u / (111_320.0 * cosLat)                   // degrees per second
        let dLat = v / 110_540.0
        let sx = a * dLon + b * dLat
        let sy = c * dLon + d * dLat
        let mag = (sx * sx + sy * sy).squareRoot()
        guard mag > 1e-12 else { return CGVector(dx: 0, dy: 0) }
        return CGVector(dx: sx / mag * speedPoints, dy: sy / mag * speedPoints)
    }

    /// The screen-space transform carrying a point from `old`'s frame into this one — how far the map moved.
    /// Applied to the particles and to the trail texture so a pan drags the whole slipstream along with the
    /// terrain instead of smearing it across the screen.
    func delta(from old: WindViewportTransform) -> CGAffineTransform? {
        let od = old.determinant
        guard abs(od) > 1e-9 else { return nil }
        // A = J_new · J_old⁻¹
        let i11 = old.d / od, i12 = -old.b / od
        let i21 = -old.c / od, i22 = old.a / od
        let a11 = a * i11 + b * i21, a12 = a * i12 + b * i22
        let a21 = c * i11 + d * i21, a22 = c * i12 + d * i22
        // Referred to the OLD origin, then re-anchored at this frame's origin, plus the coordinate shift
        // between the two expansion points.
        let shift = toScreen(lon: old.originLon, lat: old.originLat)
        let tx = Double(shift.x) - a11 * old.originX - a12 * old.originY
        let ty = Double(shift.y) - a21 * old.originX - a22 * old.originY
        guard tx.isFinite, ty.isFinite, a11.isFinite, a22.isFinite else { return nil }
        return CGAffineTransform(a: a11, b: a21, c: a12, d: a22, tx: tx, ty: ty)
    }
}

/// One frame's view of the camera: where the world is on screen, and how much of it is showing.
struct WindCamera {
    let transform: WindViewportTransform
    let zoom: Double
    /// Visible longitude span in degrees — the span gate reads this, not the zoom level, because the globe
    /// makes zoom a poor proxy for how much world is on screen.
    let lonSpan: Double
}
