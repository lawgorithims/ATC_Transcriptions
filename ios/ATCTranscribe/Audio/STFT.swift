import Foundation
import Accelerate

/// Short-time Fourier transform with per-bin magnitude gating and overlap-add
/// resynthesis, using Accelerate's double-precision DFT. Hann window, hop `hop`, size
/// `nFFT` (must be f·2^n, f ∈ {1,3,5,15}; 2048 qualifies). The signal is center-padded
/// (reflect) so the gated output length equals the input, then COLA-normalized.
///
/// Backs `AudioPreprocessor`'s spectral gating (port of
/// `audio_preprocessing.apply_spectral_gating`). This is a correct STFT/ISTFT — not
/// bit-matched to librosa's exact centering — but the per-bin gating effect is equivalent.
final class STFT {
    let nFFT: Int
    let hop: Int
    private let window: [Double]
    private let forward: vDSP_DFT_SetupD
    private let inverse: vDSP_DFT_SetupD

    init?(nFFT: Int = 2048, hop: Int = 512) {
        guard let f = vDSP_DFT_zop_CreateSetupD(nil, vDSP_Length(nFFT), .FORWARD),
              let inv = vDSP_DFT_zop_CreateSetupD(nil, vDSP_Length(nFFT), .INVERSE) else { return nil }
        self.nFFT = nFFT
        self.hop = hop
        self.forward = f
        self.inverse = inv
        // Periodic Hann window (librosa default).
        self.window = (0..<nFFT).map { 0.5 - 0.5 * cos(2.0 * .pi * Double($0) / Double(nFFT)) }
    }

    deinit {
        vDSP_DFT_DestroySetupD(forward)
        vDSP_DFT_DestroySetupD(inverse)
    }

    /// Run the STFT, apply `gate` to every bin of every frame (phase preserved by scaling
    /// real+imag), and overlap-add back to a signal the same length as `x`. The gate
    /// receives each bin's magnitude and the spectrogram's peak magnitude — the latter so a
    /// gate can express librosa-style dB thresholds relative to the global maximum.
    func processGating(_ x: [Double], gate: (_ mag: Double, _ maxMag: Double) -> Double) -> [Double] {
        let n = x.count
        guard n > 1 else { return x }
        let pad = nFFT / 2
        let padded = STFT.reflectPad(x, pad)
        let m = padded.count

        var out = [Double](repeating: 0, count: m)
        var winSq = [Double](repeating: 0, count: m)

        var inR = [Double](repeating: 0, count: nFFT)
        let inI = [Double](repeating: 0, count: nFFT)        // input imaginary is always zero
        var specR = [Double](repeating: 0, count: nFFT)
        var specI = [Double](repeating: 0, count: nFFT)
        var recR = [Double](repeating: 0, count: nFFT)
        var recI = [Double](repeating: 0, count: nFFT)
        var timeR = [Double](repeating: 0, count: nFFT)
        var timeI = [Double](repeating: 0, count: nFFT)
        let invScale = 1.0 / Double(nFFT)

        // First pass: peak magnitude across the whole spectrogram. librosa's
        // amplitude_to_db (top_db=80) floors every bin's dB relative to this global max, so
        // the gate needs it before any bin decision is made.
        var maxMag = 0.0
        var scan = 0
        while scan + nFFT <= m {
            for i in 0..<nFFT { inR[i] = padded[scan + i] * window[i] }
            vDSP_DFT_ExecuteD(forward, inR, inI, &specR, &specI)
            for k in 0..<nFFT {
                let mag = (specR[k] * specR[k] + specI[k] * specI[k]).squareRoot()
                if mag > maxMag { maxMag = mag }
            }
            scan += hop
        }

        var start = 0
        while start + nFFT <= m {
            for i in 0..<nFFT { inR[i] = padded[start + i] * window[i] }
            vDSP_DFT_ExecuteD(forward, inR, inI, &specR, &specI)
            for k in 0..<nFFT {
                let mag = (specR[k] * specR[k] + specI[k] * specI[k]).squareRoot()
                if mag < 1e-12 {
                    recR[k] = 0; recI[k] = 0
                } else {
                    let s = gate(mag, maxMag) / mag        // ≤ 1; scales magnitude, keeps phase
                    recR[k] = specR[k] * s; recI[k] = specI[k] * s
                }
            }
            vDSP_DFT_ExecuteD(inverse, recR, recI, &timeR, &timeI)
            for i in 0..<nFFT {
                out[start + i] += timeR[i] * invScale * window[i]   // synthesis window
                winSq[start + i] += window[i] * window[i]
            }
            start += hop
        }

        for i in 0..<m where winSq[i] > 1e-8 { out[i] /= winSq[i] }
        return Array(out[pad..<(pad + n)])
    }

    /// Reflect-pad `x` by `pad` on each side (librosa `center=True` default).
    static func reflectPad(_ x: [Double], _ pad: Int) -> [Double] {
        guard pad > 0, x.count > 1 else { return x }
        let p = min(pad, x.count - 1)
        var ext = [Double]()
        ext.reserveCapacity(x.count + 2 * pad)
        for i in stride(from: p, through: 1, by: -1) { ext.append(x[i]) }
        ext.append(contentsOf: x)
        let last = x.count - 1
        for i in 1...p { ext.append(x[last - i]) }
        if p < pad {   // signal shorter than the requested pad: zero-fill the remainder
            ext = [Double](repeating: 0, count: pad - p) + ext + [Double](repeating: 0, count: pad - p)
        }
        return ext
    }
}
