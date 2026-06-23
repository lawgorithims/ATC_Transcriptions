import Foundation

/// Radio-audio cleanup for ATC: high-pass → speech band-pass → spectral gating →
/// normalize, on mono 16 kHz float32. Swift port of
/// `audio_preprocessing.AudioPreprocessor`.
///
/// The Butterworth filters use SciPy-baked coefficients (`Biquad`), so they match the
/// Python at 16 kHz. Spectral gating uses an Accelerate STFT (`STFT`).
///
/// NOT yet ported: the Python's separate `noisereduce` stage (a statistical per-frequency
/// spectral-gate library that runs after the simple gate, with a second pass in aggressive
/// mode). The high-pass + band-pass + gate below cover most of the radio cleanup; a
/// faithful `noisereduce` equivalent is a later refinement. `audio_preprocessing.py`'s
/// `aggressive_radio` preset (used by the live pipeline) is mirrored here.
struct AudioPreprocessor {
    var enableHighpass = true
    var enableBandpass = false
    var enableSpectralGating = true
    var enableNormalize = true
    var aggressiveRadio = false

    init(aggressiveRadio: Bool = false) {
        self.aggressiveRadio = aggressiveRadio
        if aggressiveRadio { enableBandpass = true }   // aggressive preset enables band-pass
    }

    /// Full pipeline. Order mirrors `preprocess`: highpass → bandpass → spectral gating
    /// → normalize. (The Python's `noise_reduction` stage sits between gating and
    /// normalize and is not yet ported — see the type doc.)
    func preprocess(_ audio: [Float]) -> [Float] {
        var x = audio.map(Double.init)
        if enableHighpass { x = SOSFilter(sections: aggressiveRadio ? Biquad.hp5_350 : Biquad.hp4_300).filtfilt(x) }
        if enableBandpass { x = SOSFilter(sections: Biquad.bp4_250_3800).filtfilt(x) }
        if enableSpectralGating { x = spectralGating(x) }
        if enableNormalize { x = normalize(x) }
        return x.map { Float($0) }
    }

    /// Scale so the peak is 0.95 (prevents clipping). Port of `normalize_audio`.
    func normalize(_ x: [Double]) -> [Double] {
        let maxAbs = x.reduce(0.0) { Swift.max($0, Swift.abs($1)) }
        guard maxAbs > 0 else { return x }
        let scale = 0.95 / maxAbs
        return x.map { $0 * scale }
    }

    /// Per-bin dB-threshold spectral gate. Port of `apply_spectral_gating`: bins whose
    /// magnitude is below `thresholdDb` are attenuated by `suppressDb`; phase is kept.
    func spectralGating(_ x: [Double]) -> [Double] {
        guard let stft = STFT(nFFT: 2048, hop: 512) else { return x }
        let thresholdDb = aggressiveRadio ? -35.0 : -40.0
        let suppressGain = pow(10.0, (aggressiveRadio ? -25.0 : -20.0) / 20.0)   // 10^(-suppressDb/20)
        return stft.processGating(x) { mag in
            let db = 20.0 * log10(Swift.max(1e-10, mag))
            return db > thresholdDb ? mag : mag * suppressGain
        }
    }
}
