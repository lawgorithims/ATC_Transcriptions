import Foundation

/// Rejects dead air BEFORE it reaches Whisper.
///
/// WHY THIS EXISTS. On a continuously-monitored frequency most of the airtime is not speech, and on
/// pure radio noise the transcriber does not stay quiet — it invents plausible ATC text, including
/// fully-formed instructions ("cleared for takeoff two five right"). Measured on 500 held-out
/// no-speech clips, the shipped model produced words on 66% of them. A fabricated clearance is the
/// worst output this app can produce, so the cheapest correct fix is to never hand Whisper the audio.
///
/// WHY NOT FIX IT IN THE MODEL. Whisper has a no-speech token and we can train it (measured: 99.6%
/// of noise correctly silenced). But every training recipe that added it cost real accuracy — the
/// best such model was +3.7pt WER vs the shipped one (p=0.009, i.e. not noise). The detector and the
/// transcriber do not have to be the same model, and this filter is a few hundred bytes of arithmetic.
///
/// WHY THE EXISTING VAD IS NOT ENOUGH. `VADSegmenter` gates on ENERGY, and radio noise is loud. Its
/// own replica, run over the same clips: it passes 138/139 real transmissions (good) but also passes
/// 280/500 dead-air clips — those 280 are the entire hallucination surface.
///
/// THE FEATURE. Speech is BURSTY: gaps between words give the 30 ms RMS envelope a wide dynamic
/// range and a high coefficient of variation. Radio noise is STEADY. Measured over gold-137 vs
/// noise-500, at thresholds that lose ZERO real transmissions:
///   envelope range > 14.4 dB  ->  rejects 98.2% of dead air
///   envelope CV    > 0.583    ->  rejects 97.6% of dead air
/// (For contrast, speech-frame fraction managed 46% and 4-8 Hz syllabic modulation only 13%.)
///
/// BIAS TOWARD PASSING. A hallucinated line is visible and recoverable; a dropped clearance is not.
/// So both statistics must say "steady" before anything is rejected, the thresholds carry margin
/// below the zero-loss point, and anything too short to measure is passed through untouched.
///
/// ⚠️ GENERALISATION CAVEAT. The 500 no-speech clips are phase-scrambled real ATC audio, which is
/// stationary BY CONSTRUCTION — exactly what these features detect. Real dead air (squelch tails,
/// clicks, mic keying) is burstier and may score higher. 60% of the test clips did carry synthetic
/// squelch/click bursts and were still rejected, which is reassuring but not the same as validating
/// on real captured silence. Hence the margin, the AND, and `atc.filter.deadAir` to switch it off.
struct DeadAirFilter {

    /// 30 ms at 16 kHz — the same framing `VADSegmenter` uses, so the envelope is directly comparable.
    static let frameSamples = 480

    /// Below this many frames (~0.24 s) the envelope statistics are not meaningful — pass it through.
    static let minFrames = 8

    /// Keep the segment if EITHER statistic looks bursty. Zero-gold-loss points measured at
    /// 14.36 dB / 0.583; shipped a little lower so a quieter-but-real transmission still survives.
    static let minRangeDB: Float = 12.0
    static let minCV: Float = 0.50

    enum Verdict: Equatable {
        case speech                 // hand it to the transcriber
        case deadAir(rangeDB: Float, cv: Float)
    }

    /// Frame-RMS envelope of `audio`. Bounded loop, no allocation beyond the result.
    static func envelope(_ audio: [Float]) -> [Float] {
        let n = audio.count / frameSamples
        guard n > 0 else { return [] }
        var out = [Float](repeating: 0, count: n)
        for f in 0..<n {
            let base = f * frameSamples
            var sum: Float = 0
            for i in 0..<frameSamples { let s = audio[base + i]; sum += s * s }
            out[f] = (sum / Float(frameSamples)).squareRoot()
        }
        return out
    }

    /// Decide whether this segment carries speech. Pure — no state, no I/O, deterministic.
    static func verdict(for audio: [Float]) -> Verdict {
        let env = envelope(audio)
        guard env.count >= minFrames else { return .speech }   // too short to judge: never gamble
        assert(env.count >= minFrames, "envelope shorter than the guard just checked")

        var mean: Float = 0
        for v in env { mean += v }
        mean /= Float(env.count)
        guard mean > 0 else { return .deadAir(rangeDB: 0, cv: 0) }   // digital silence

        var varsum: Float = 0
        for v in env { let d = v - mean; varsum += d * d }
        let cv = (varsum / Float(env.count)).squareRoot() / mean

        let sorted = env.sorted()
        let lo = sorted[max(0, Int(Float(sorted.count) * 0.10))]
        let hi = sorted[min(sorted.count - 1, Int(Float(sorted.count) * 0.90))]
        let rangeDB = 20 * log10f(max(hi, 1e-9) / max(lo, 1e-9))
        assert(rangeDB.isFinite && cv.isFinite, "non-finite envelope statistics")

        // Bursty on EITHER axis means keep it. Only steady-on-both is dead air.
        if rangeDB > minRangeDB || cv > minCV { return .speech }
        return .deadAir(rangeDB: rangeDB, cv: cv)
    }
}
