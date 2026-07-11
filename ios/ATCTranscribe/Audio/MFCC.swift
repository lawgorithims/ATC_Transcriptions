import Foundation
import Accelerate

/// Utterance-level MFCC for speaker fingerprinting — the Stage-5a upgrade that replaces the old
/// 3-scalar `[level, brightness, pitch]` fingerprint (which could not separate voices on real
/// band-limited ATC audio). 16 kHz mono, 25 ms frames / 10 ms hop, a 26-band mel filterbank over the
/// ATC voice band (300–3800 Hz), 13 cepstral coefficients (c0…c12), mean-pooled across frames.
///
/// CODING STANDARD — this file follows the NASA/JPL "Power of Ten" rules:
///  • every loop has a fixed, statically-provable upper bound (see `maxFrames`; all others iterate a
///    compile-time-constant count);
///  • no heap allocation after initialisation — the constant tables and the FFT setup are built once
///    in `init`, and every per-call/per-frame buffer is preallocated scratch, written in place;
///  • each function validates its inputs and RECOVERS (returns a safe value) on violation, plus
///    asserts its invariants (≥2 checks/function on the substantive ones);
///  • no recursion, no function pointers; the only pointer use is the one-level vDSP split-complex
///    access, scoped by the standard-library `withUnsafeMutableBufferPointer`.
/// `features` is not reentrant (it writes shared scratch); it is only ever called serially on the
/// `LivePipeline` actor that owns the enclosing `SpeakerModel`.
final class MFCC {
    // MARK: fixed configuration (compile-time constants)
    private static let sr: Float = 16_000
    private static let frameLen = 400          // 25 ms
    private static let hop = 160               // 10 ms
    private static let nFFT = 512
    private static let half = 256              // nFFT / 2
    private static let log2n: vDSP_Length = 9  // log2(512)
    private static let melBands = 26
    private static let coeffs = 13
    private static let specSize = 257          // nFFT / 2 + 1
    private static let maxFrames = 4096        // hard upper bound on the analysis loop (≈40 s @ 10 ms)
    private static let eps: Float = 1e-6

    let numCoeffs = MFCC.coeffs

    // MARK: constant tables (built once at init; never reallocated)
    private let window: [Float]
    private let melFilters: [[Float]]
    private let dctMatrix: [[Float]]
    private let fftSetup: FFTSetup

    // MARK: preallocated scratch (reused every call/frame; never reallocated)
    private var windowed = [Float](repeating: 0, count: MFCC.nFFT)
    private var realp = [Float](repeating: 0, count: MFCC.half)
    private var imagp = [Float](repeating: 0, count: MFCC.half)
    private var power = [Float](repeating: 0, count: MFCC.specSize)
    private var logMelSum = [Float](repeating: 0, count: MFCC.melBands)
    private var result = [Float](repeating: 0, count: MFCC.coeffs)

    init() {
        window = MFCC.makeHann(MFCC.frameLen)
        melFilters = MFCC.makeMelFilters()
        dctMatrix = MFCC.makeDCT()
        // vDSP setup is acquired once at construction; a null setup would be dereferenced per frame,
        // so fail fast here (init cannot return an error). This never fails for a valid power-of-two.
        guard let setup = vDSP_create_fftsetup(MFCC.log2n, FFTRadix(kFFTRadix2)) else {
            fatalError("MFCC: vDSP FFT setup allocation failed at init")
        }
        fftSetup = setup
        assert(window.count == MFCC.frameLen)
        assert(melFilters.count == MFCC.melBands && dctMatrix.count == MFCC.coeffs)
    }

    deinit { vDSP_destroy_fftsetup(fftSetup) }

    /// Mean MFCC (c0…c12) across all frames; a zeroed fingerprint for audio shorter than one frame
    /// (safe: a zero vector compares as maximally dissimilar, so it never merges into a voice).
    func features(_ audio: [Float]) -> [Float] {
        guard audio.count >= MFCC.frameLen else { return zeroResult() }
        assert(logMelSum.count == MFCC.melBands)
        for j in 0..<MFCC.melBands { logMelSum[j] = 0 }
        var frames = 0
        var start = 0
        while frames < MFCC.maxFrames {                 // Rule 2: bounded regardless of audio length
            if start + MFCC.frameLen > audio.count { break }
            guard analyzeFrame(audio, at: start) else { break }
            frames += 1
            start += MFCC.hop
        }
        assert(frames <= MFCC.maxFrames)
        guard frames > 0 else { return zeroResult() }
        return finalize(frames: frames)
    }

    // MARK: - per-frame pipeline (all scratch preallocated)

    /// Window one frame, run the real FFT, and fold its power spectrum into `logMelSum`.
    private func analyzeFrame(_ audio: [Float], at start: Int) -> Bool {
        guard start >= 0, start + MFCC.frameLen <= audio.count else { return false }
        assert(windowed.count == MFCC.nFFT)
        for i in 0..<MFCC.frameLen { windowed[i] = audio[start + i] * window[i] }
        for i in MFCC.frameLen..<MFCC.nFFT { windowed[i] = 0 }
        for k in 0..<MFCC.half { realp[k] = windowed[2 * k]; imagp[k] = windowed[2 * k + 1] }
        runFFT()
        powerSpectrum()
        accumulateMel()
        return true
    }

    private func runFFT() {
        assert(realp.count == MFCC.half && imagp.count == MFCC.half)
        realp.withUnsafeMutableBufferPointer { rp in
            imagp.withUnsafeMutableBufferPointer { ip in
                guard let rb = rp.baseAddress, let ib = ip.baseAddress else { return }
                var split = DSPSplitComplex(realp: rb, imagp: ib)
                vDSP_fft_zrip(fftSetup, &split, 1, MFCC.log2n, FFTDirection(FFT_FORWARD))
            }
        }
    }

    /// Power spectrum from vDSP's packed real FFT (DC in realp[0], Nyquist in imagp[0]; 2× scaled).
    private func powerSpectrum() {
        assert(power.count == MFCC.specSize)
        assert(MFCC.half >= 1 && MFCC.half < MFCC.specSize)
        power[0] = (realp[0] * 0.5) * (realp[0] * 0.5)
        power[MFCC.half] = (imagp[0] * 0.5) * (imagp[0] * 0.5)
        for k in 1..<MFCC.half {
            let re = realp[k] * 0.5
            let im = imagp[k] * 0.5
            power[k] = re * re + im * im
        }
    }

    private func accumulateMel() {
        assert(logMelSum.count == MFCC.melBands)
        assert(melFilters.count == MFCC.melBands)
        for j in 0..<MFCC.melBands {
            var e: Float = 0
            let f = melFilters[j]
            for b in 0..<MFCC.specSize { e += f[b] * power[b] }
            logMelSum[j] += log(e + MFCC.eps)
        }
    }

    /// DCT-II of the mean log-mel spectrum into `result` (returned COW-safe: a caller's retained copy
    /// is preserved when `result` is next overwritten).
    private func finalize(frames: Int) -> [Float] {
        guard frames > 0 else { return zeroResult() }
        assert(dctMatrix.count == MFCC.coeffs)
        let inv = 1 / Float(frames)
        for i in 0..<MFCC.coeffs {
            var c: Float = 0
            let row = dctMatrix[i]
            for j in 0..<MFCC.melBands { c += row[j] * (logMelSum[j] * inv) }
            result[i] = c
        }
        return result
    }

    private func zeroResult() -> [Float] {
        assert(result.count == MFCC.coeffs)
        for i in 0..<MFCC.coeffs { result[i] = 0 }
        return result
    }

    // MARK: - constant-table builders (init-time only; allocation permitted at initialisation)

    private static func makeHann(_ n: Int) -> [Float] {
        precondition(n > 1, "Hann window needs n > 1")
        var w = [Float](repeating: 0, count: n)
        for i in 0..<n { w[i] = 0.5 - 0.5 * cos(2 * Float.pi * Float(i) / Float(n - 1)) }
        return w
    }

    private static func hzToMel(_ f: Float) -> Float { 2595 * log10(1 + f / 700) }
    private static func melToHz(_ m: Float) -> Float { 700 * (pow(10, m / 2595) - 1) }

    private static func makeMelFilters() -> [[Float]] {
        let lowMel = hzToMel(300), highMel = hzToMel(3800)
        precondition(highMel > lowMel, "mel band inverted")
        var bins = [Int](repeating: 0, count: melBands + 2)
        for p in 0...(melBands + 1) {
            let hz = melToHz(lowMel + (highMel - lowMel) * Float(p) / Float(melBands + 1))
            var bin = Int((Float(nFFT + 1) * hz / sr).rounded(.down))
            if bin < 0 { bin = 0 }
            if bin > specSize - 1 { bin = specSize - 1 }
            bins[p] = bin
        }
        var filters = [[Float]](repeating: [Float](repeating: 0, count: specSize), count: melBands)
        for j in 1...melBands {
            let l = bins[j - 1], c = bins[j], r = bins[j + 1]
            if c > l { for b in l..<c { filters[j - 1][b] = Float(b - l) / Float(c - l) } }
            if r > c { for b in c..<r { filters[j - 1][b] = Float(r - b) / Float(r - c) } }
        }
        return filters
    }

    private static func makeDCT() -> [[Float]] {
        var m = [[Float]](repeating: [Float](repeating: 0, count: melBands), count: coeffs)
        for i in 0..<coeffs {
            for j in 0..<melBands {
                m[i][j] = cos(Float.pi * Float(i) * (Float(j) + 0.5) / Float(melBands))
            }
        }
        return m
    }
}
