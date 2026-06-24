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
    ///
    /// The Python uses `librosa.amplitude_to_db(magnitude)`, whose default `top_db=80`
    /// floors every bin's dB at `(globalMaxDb - 80)` before the threshold compare. Omitting
    /// that floor makes the gate over-suppress quiet bins on loud spectra (whose peak
    /// exceeds `thresholdDb + 80`), diverging from the reference — so we replicate it here.
    func spectralGating(_ x: [Double]) -> [Double] {
        guard let stft = STFT(nFFT: 2048, hop: 512) else { return x }
        let thresholdDb = aggressiveRadio ? -35.0 : -40.0
        let suppressGain = pow(10.0, (aggressiveRadio ? -25.0 : -20.0) / 20.0)   // 10^(-suppressDb/20)
        let amin = 1e-5   // librosa.amplitude_to_db default amin
        return stft.processGating(x) { mag, maxMag in
            let maxDb = 20.0 * log10(Swift.max(amin, maxMag))
            let db = Swift.max(20.0 * log10(Swift.max(amin, mag)), maxDb - 80.0)   // top_db=80 floor
            return db > thresholdDb ? mag : mag * suppressGain
        }
    }
}
