import Foundation

/// Turns a pair of measured microphone levels — the room's ambient noise and the user's speaking
/// voice — into a squelch gate that sits safely between them. Pure + unit-tested; the mic capture
/// lives in `MicCalibrator` and the resulting gate is applied via the manual squelch.
enum SquelchCalibration {
    /// Minimum speech-to-ambient RMS ratio for a trustworthy calibration (≈ +5 dB). Below this the
    /// two levels are too close to separate — the mic can't tell the voice from the room, so we ask
    /// the user to try again (speak up / move somewhere quieter) rather than set a useless gate.
    static let minRatio: Float = 1.8

    /// A squelch gate (RMS) between `ambient` and `speech`, or nil when they're too close to separate
    /// reliably. The gate is the GEOMETRIC MEAN — the log-perceptual midpoint — which for any ratio
    /// ≥ `minRatio` lands a clear margin ABOVE the ambient (never trips on the room) AND below the
    /// voice (always trips on speech): geoMean = ambient·√ratio ≥ 1.34·ambient, and geoMean/speech =
    /// 1/√ratio ≤ 0.75.
    static func gate(ambientRMS ambient: Float, speechRMS speech: Float) -> Float? {
        guard ambient > 0, speech > 0, speech >= ambient * minRatio else { return nil }
        return (ambient * speech).squareRoot()
    }
}
