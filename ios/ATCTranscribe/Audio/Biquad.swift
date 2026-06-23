import Foundation

/// Butterworth second-order-section (SOS) coefficients, produced by SciPy
/// `signal.butter(..., output="sos")` for the fixed 16 kHz pipeline and baked in so
/// the Swift filters match `audio_preprocessing.py` exactly. Regenerate with
/// `Tools/gen_filter_fixtures.py`. Each section is `[b0, b1, b2, a0(=1), a1, a2]`.
enum Biquad {
    /// Aggressive high-pass: butter(5, 350 Hz).
    static let hp5_350: [[Double]] = [
        [0.80042945958129008, -0.80042945958129008, 0, 1, -0.87120368366295875, 0],
        [1, -2, 1, 1, -1.7834514472467875, 0.80043069619755991],
        [1, -2, 1, 1, -1.9006661085853718, 0.91876129311074062],
    ]
    /// Default high-pass: butter(4, 300 Hz).
    static let hp4_300: [[Double]] = [
        [0.85724608479567443, -1.7144921695913489, 0.85724608479567443, 1, -1.791587696777784, 0.80409284398316272],
        [1, -2, 1, 1, -1.9006465638071277, 0.91391293369153392],
    ]
    /// Speech band-pass: butter(4, [250 Hz, 3800 Hz]).
    static let bp4_250_3800: [[Double]] = [
        [0.064601798102256705, 0.12920359620451341, 0.064601798102256705, 1, -0.182744134422585, 0.057645511401949887],
        [1, 2, 1, 1, -0.1358215888279343, 0.48514629729790354],
        [1, -2, 1, 1, -1.8116289806180226, 0.8222537303641172],
        [1, -2, 1, 1, -1.9236156020163664, 0.93317063692979652],
    ]
}

/// A cascade of biquad sections with a zero-phase forward-backward pass (`filtfilt`),
/// the Swift equivalent of SciPy `sosfiltfilt`. Interior samples match SciPy closely;
/// the very edges may differ slightly (different padding/initial-condition handling).
struct SOSFilter {
    /// Sections as `[b0, b1, b2, a0, a1, a2]` (a0 assumed 1).
    let sections: [[Double]]

    /// One forward pass through all sections (Direct Form II transposed).
    private func sosfilt(_ input: [Double]) -> [Double] {
        var y = input
        for s in sections {
            let b0 = s[0], b1 = s[1], b2 = s[2], a1 = s[4], a2 = s[5]
            var z1 = 0.0, z2 = 0.0
            for i in 0..<y.count {
                let x = y[i]
                let out = b0 * x + z1
                z1 = b1 * x - a1 * out + z2
                z2 = b2 * x - a2 * out
                y[i] = out
            }
        }
        return y
    }

    /// Zero-phase filtering: forward, reverse, forward, reverse. Edges are odd-reflected
    /// (like SciPy's default `padtype="odd"`) so interior samples agree with SciPy.
    func filtfilt(_ x: [Double]) -> [Double] {
        guard x.count > 1 else { return x }
        let pad = min(max(3 * (sections.count * 2 + 1), 12), x.count - 1)

        var ext = [Double]()
        ext.reserveCapacity(x.count + 2 * pad)
        for i in stride(from: pad, through: 1, by: -1) { ext.append(2 * x[0] - x[i]) }   // odd-reflect front
        ext.append(contentsOf: x)
        let last = x.count - 1
        for i in 1...pad { ext.append(2 * x[last] - x[last - i]) }                        // odd-reflect back

        var y = sosfilt(ext)
        y.reverse()
        y = sosfilt(y)
        y.reverse()
        return Array(y[pad..<(pad + x.count)])
    }
}
