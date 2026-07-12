import Foundation
import simd

/// Pure 2D-similarity georeferencing for approach plates — solve the transform that maps plate
/// PIXELS to the world, from control points (a fix's pixel position on the plate + its known
/// lat/lon). A similarity (uniform scale + rotation + translation, 4 DOF) is exactly what the map
/// overlay stores (center / width / rotation), and 2 control points determine it; 3+ give a
/// least-squares fit whose residual is the confidence signal. Shared by the app AND the offline
/// `build_plate_georef` tool (compiled into both), so the math is unit-tested once.
///
/// World coordinates here are a local ENU tangent plane in METRES relative to a chosen origin
/// (the airport reference point); the caller converts lat/lon ↔ ENU. Over the ~tens of km an
/// approach spans, the plane is effectively exact.
enum PlateSimilarity {

    /// A fitted similarity: `dst = scale · Rccw(rotationRad) · src + t`.
    struct Fit: Equatable {
        var scale: Double
        var rotationRad: Double       // counter-clockwise, standard math convention
        var tx: Double
        var ty: Double
    }

    /// The overlay placement the renderer consumes: image center in world ENU, the geographic width
    /// the whole page spans, and a CLOCKWISE-from-north rotation (the renderer's convention).
    struct Placement: Equatable {
        var centerEast: Double
        var centerNorth: Double
        var widthMeters: Double
        var rotationDeg: Double
    }

    static func apply(_ f: Fit, _ p: SIMD2<Double>) -> SIMD2<Double> {
        let c = cos(f.rotationRad), s = sin(f.rotationRad)
        return SIMD2(f.scale * (c * p.x - s * p.y) + f.tx,
                     f.scale * (s * p.x + c * p.y) + f.ty)
    }

    /// Umeyama / Horn least-squares proper similarity from `src` to `dst` (equal counts, ≥2 points).
    /// Returns the fit + RMS residual (in `dst` units), or nil if degenerate (coincident src points).
    static func fit(src: [SIMD2<Double>], dst: [SIMD2<Double>]) -> (fit: Fit, rms: Double)? {
        guard src.count == dst.count, src.count >= 2 else { return nil }
        let n = Double(src.count)
        var muS = SIMD2<Double>(0, 0), muD = SIMD2<Double>(0, 0)
        for i in src.indices { muS += src[i]; muD += dst[i] }
        muS /= n; muD /= n

        var varS = 0.0
        var sxx = 0.0, syy = 0.0, sxy = 0.0, syx = 0.0   // Σ a·bᵀ terms (a = centered src, b = centered dst)
        for i in src.indices {
            let a = src[i] - muS, b = dst[i] - muD
            varS += a.x * a.x + a.y * a.y
            sxx += a.x * b.x; syy += a.y * b.y
            sxy += a.x * b.y; syx += a.y * b.x
        }
        guard varS > 1e-9 else { return nil }

        let alpha = atan2(sxy - syx, sxx + syy)                 // optimal CCW rotation
        let scale = hypot(sxx + syy, sxy - syx) / varS          // optimal uniform scale
        guard scale > 1e-12 else { return nil }
        // t = muD - scale·R·muS
        let c = cos(alpha), s = sin(alpha)
        let rMuS = SIMD2(scale * (c * muS.x - s * muS.y), scale * (s * muS.x + c * muS.y))
        let t = muD - rMuS
        let f = Fit(scale: scale, rotationRad: alpha, tx: t.x, ty: t.y)

        var sq = 0.0
        for i in src.indices { sq += simd_distance_squared(apply(f, src[i]), dst[i]) }
        return (f, (sq / n).squareRoot())
    }

    /// Georeference a plate from control points: `pixels` (origin top-left, +y DOWN — image space)
    /// paired with `world` (ENU metres). Returns the overlay placement + RMS residual (metres) + the
    /// control-point count, or nil if the fit is degenerate. The pixel y is flipped internally so the
    /// fit is a proper rotation, and the result is expressed in the renderer's clockwise-from-north
    /// convention (verified by the round-trip test against `forwardModel`).
    static func georeference(pixels: [SIMD2<Double>], world: [SIMD2<Double>],
                             imageW: Double, imageH: Double) -> (placement: Placement, rmsMeters: Double, n: Int)? {
        guard pixels.count == world.count, pixels.count >= 2, imageW > 1, imageH > 1 else { return nil }
        let flipped = pixels.map { SIMD2($0.x, imageH - $0.y) }         // → y-up so the fit is a rotation
        guard let (f, rms) = fit(src: flipped, dst: world) else { return nil }
        let center = apply(f, SIMD2(imageW / 2, imageH / 2))            // image center pixel → world
        let placement = Placement(centerEast: center.x, centerNorth: center.y,
                                  widthMeters: f.scale * imageW,
                                  rotationDeg: normalizeDeg(-f.rotationRad * 180 / .pi))  // Rcw(ρ)=Rccw(-ρ)
        return (placement, rms, pixels.count)
    }

    /// The renderer's forward model: where a plate pixel lands in world ENU under a placement. Encodes
    /// exactly how `PlateOverlayRenderer` draws (center pixel → center; +x → east, +y → south at 0°;
    /// clockwise-from-north rotation). Used to generate synthetic control points in tests.
    static func forwardModel(_ pl: Placement, imageW: Double, imageH: Double, px: Double, py: Double) -> SIMD2<Double> {
        let k = pl.widthMeters / imageW
        let e0 = k * (px - imageW / 2)          // east at 0° rotation
        let n0 = -k * (py - imageH / 2)         // north at 0° (image-down = south)
        let r = pl.rotationDeg * .pi / 180
        let e = e0 * cos(r) + n0 * sin(r)       // clockwise-from-north rotation
        let n = -e0 * sin(r) + n0 * cos(r)
        return SIMD2(pl.centerEast + e, pl.centerNorth + n)
    }

    /// Inverse of `forwardModel`: where a world ENU point lands in PLATE PIXELS under a placement.
    /// Used to validate a fit — the airport reference point (ENU origin) must land inside the plan
    /// view, or the fit matched the wrong fixes (a low residual over a coincidental cluster).
    static func worldToPixel(_ pl: Placement, imageW: Double, imageH: Double, east: Double, north: Double) -> SIMD2<Double> {
        let k = pl.widthMeters / imageW
        let e = east - pl.centerEast, n = north - pl.centerNorth
        let r = pl.rotationDeg * .pi / 180
        // invert the clockwise-from-north rotation
        let e0 = e * cos(r) - n * sin(r)
        let n0 = e * sin(r) + n * cos(r)
        return SIMD2(e0 / k + imageW / 2, imageH / 2 - n0 / k)
    }

    static func normalizeDeg(_ deg: Double) -> Double {
        var d = deg.truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d <= -180 { d += 360 }
        return d
    }
}
