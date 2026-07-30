import CoreGraphics
import simd

/// Speed → colour for the wind particles and the legend bar, in knots.
///
/// The day/cockpit ramp runs cool-to-hot (blue → green → yellow → orange → red → violet) because that is
/// the convention every pilot already reads on a winds-aloft product, and because hue carries the value
/// better than brightness on a chart that is itself busy.
///
/// The night ramp is deliberately NOT that. Under the app's night theme the whole cockpit is red-on-black
/// for dark adaptation, and dropping a full-spectrum overlay onto it would undo that in one glance — a blue
/// particle field is exactly the short-wavelength light night vision is most sensitive to. So at night the
/// ramp carries speed in INTENSITY along a single red hue, staying legible without bleaching the pilot's
/// eyes.
struct WindRamp {
    /// (knots, colour) stops, ascending. Interpolated linearly in RGB — the stops are close enough
    /// together that a perceptual space would not change the read.
    private let stops: [(kt: Float, rgb: SIMD3<Float>)]

    /// The speed the ramp saturates at. Above this everything is the top colour; 150 kt covers a strong
    /// jet core without flattening the whole useful range below it.
    static let topKt: Float = 150

    static func forTheme(_ theme: AppTheme) -> WindRamp {
        theme == .night ? nightRamp : dayRamp
    }

    /// THE ramp entry point, mirroring `MapTheme.forLayer`: the selected base layer can override the app
    /// theme, and `.smartDark` does — it is a purpose-built night base, and `MapTheme.forLayer` already
    /// paints its sea, land, vectors and rasters from the night palette whatever the pilot's theme is.
    ///
    /// The wind ramp was the one thing on that map still keyed on `AppTheme` alone, so a pilot on the day
    /// or cockpit theme who selected the dark base got a near-black chart with a full-spectrum blue→violet
    /// particle field laid over it — the exact short-wavelength flood the night ramp exists to avoid, and
    /// a straight contradiction of the shipped release note ("night theme keeps its night vision"). The
    /// spectrum-for-intensity trade is the same one the base map already makes on this layer.
    static func forLayer(_ layer: ChartLayer, theme: AppTheme) -> WindRamp {
        layer == .smartDark ? nightRamp : forTheme(theme)
    }

    private static let dayRamp = WindRamp(stops: [
        (0,   SIMD3(0.30, 0.44, 0.72)),   // slate blue — calm
        (10,  SIMD3(0.24, 0.62, 0.82)),   // cyan
        (20,  SIMD3(0.26, 0.76, 0.62)),   // teal-green
        (30,  SIMD3(0.52, 0.84, 0.36)),   // green
        (45,  SIMD3(0.92, 0.88, 0.30)),   // yellow
        (60,  SIMD3(0.98, 0.66, 0.22)),   // orange
        (80,  SIMD3(0.94, 0.36, 0.26)),   // red
        (110, SIMD3(0.85, 0.26, 0.55)),   // magenta
        (150, SIMD3(0.72, 0.44, 0.92)),   // violet — jet core
    ])

    private static let nightRamp = WindRamp(stops: [
        (0,   SIMD3(0.32, 0.05, 0.04)),
        (20,  SIMD3(0.50, 0.08, 0.06)),
        (40,  SIMD3(0.68, 0.12, 0.08)),
        (60,  SIMD3(0.82, 0.18, 0.12)),
        (90,  SIMD3(0.94, 0.30, 0.22)),
        (150, SIMD3(1.00, 0.52, 0.42)),
    ])

    func rgb(kt: Float) -> SIMD3<Float> {
        assert(!stops.isEmpty, "WindRamp: empty ramp")
        assert(kt.isFinite, "WindRamp: non-finite speed")
        let s = min(max(kt, 0), Self.topKt)
        var lo = stops[0]
        for stop in stops {                                   // bounded: ≤ 9 stops (rule 2)
            if stop.kt >= s {
                let span = stop.kt - lo.kt
                let t = span > 0 ? (s - lo.kt) / span : 0
                return lo.rgb + (stop.rgb - lo.rgb) * t
            }
            lo = stop
        }
        return lo.rgb
    }

    /// Opacity for a particle: slow air is drawn fainter so the eye lands on the jet and the shear zones
    /// rather than on a uniform wash of calm.
    ///
    /// The ceiling matters as much as the ramp. This is an overlay on an aeronautical chart, and the chart has
    /// to stay readable through it — at flight levels EVERY particle is fast, so a scale that saturated at
    /// 45 kt painted the whole jet at maximum opacity and buried the airspace and airway labels underneath.
    /// Referencing 85 kt and capping below full opacity keeps the jet legible as wind AND as chart.
    func alpha(kt: Float) -> Float {
        assert(kt.isFinite, "WindRamp: non-finite speed")
        assert(Self.topKt > 0, "WindRamp: invalid ramp ceiling")
        let t = min(max(kt / 85, 0), 1)
        return 0.26 + 0.36 * t
    }

    /// CoreGraphics colours for the legend bar in the altitude slider's status chip.
    func cgColors(steps: Int = 7) -> [CGColor] {
        assert(steps > 1, "WindRamp: legend needs at least two steps")
        assert(Self.topKt > 0, "WindRamp: invalid ramp ceiling")
        var out: [CGColor] = []
        for i in 0..<min(max(steps, 2), 16) {                 // bounded (rule 2)
            let kt = Float(i) / Float(min(max(steps, 2), 16) - 1) * Self.topKt
            let c = rgb(kt: kt)
            out.append(CGColor(red: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1))
        }
        return out
    }
}
