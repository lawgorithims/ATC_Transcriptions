import Foundation

/// Session speaker clustering + the cheap acoustic fingerprint that drives it. Extracted VERBATIM
/// from `Diarizer` (no logic change) so the post-hoc diarizer AND the streaming speaker-aware VAD
/// share ONE source of truth for the session's speaker centroids and thresholds — the streaming cut
/// and the diarizer's re-split can never number the same voice differently.
///
/// Actor-confined: only ever touched on the `LivePipeline` actor (the segmenter's `feed()` and the
/// diarizer's `diarize()` both run there, serially), so no lock is needed. `assign` is the ONLY
/// mutator; `nearestSpeaker` is a non-mutating peek used to decide a turn change without committing.
final class SpeakerModel {
    private let sr = 16_000
    let newSpeakerDist: Float = 0.30    // beyond nearest centroid by this → a new speaker (also the turn-change bar)
    private let maxSpeakers = 6

    /// Running speaker centroids (running mean of assigned fingerprints).
    private var centroids: [[Float]] = []

    /// Compact acoustic fingerprint: [level, brightness, pitch], each ~0…1. (Diarizer.fingerprint)
    func fingerprint(_ a: [Float]) -> [Float] {
        guard !a.isEmpty else { return [0, 0, 0] }
        var sumSq: Float = 0
        var zc = 0
        for i in 0..<a.count {
            sumSq += a[i] * a[i]
            if i > 0 && (a[i] >= 0) != (a[i - 1] >= 0) { zc += 1 }
        }
        let rms = (sumSq / Float(a.count)).squareRoot()
        let level = max(0, min(1, (20 * log10(max(rms, 1e-6)) + 50) / 50))   // ~ -50 dB…0 dB → 0…1
        let zcr = min(1, Float(zc) / Float(a.count) * 2)                      // brightness, ~0…1
        let pitch = min(1, estimatePitch(a) / 400)                           // 0…400 Hz → 0…1
        return [level, zcr, pitch]
    }

    /// Autocorrelation pitch (Hz) over up to ~0.5 s from the middle; 0 when unvoiced. (Diarizer.estimatePitch)
    func estimatePitch(_ a: [Float]) -> Float {
        let n = min(a.count, sr / 2)
        guard n > sr / 80 else { return 0 }
        let start = max(0, (a.count - n) / 2)
        let minLag = sr / 400   // 40
        let maxLag = sr / 80    // 200
        var energy: Float = 0
        for i in start..<start + n { energy += a[i] * a[i] }
        guard energy > 0 else { return 0 }
        var bestLag = 0
        var best: Float = 0
        for lag in minLag...maxLag {
            var s: Float = 0
            var i = start
            while i + lag < start + n { s += a[i] * a[i + lag]; i += 1 }
            if s > best { best = s; bestLag = lag }
        }
        return (best / energy > 0.3 && bestLag > 0) ? Float(sr) / Float(bestLag) : 0
    }

    func dist(_ x: [Float], _ y: [Float]) -> Float {
        var s: Float = 0
        for k in 0..<min(x.count, y.count) { let d = x[k] - y[k]; s += d * d }
        return s.squareRoot()
    }

    /// Nearest centroid to `fp` WITHOUT mutating — used to decide a turn change before committing.
    /// Returns (-1, .greatestFiniteMagnitude) when no speaker exists yet.
    func nearestSpeaker(_ fp: [Float]) -> (id: Int, d: Float) {
        var bestIdx = -1
        var bestD = Float.greatestFiniteMagnitude
        for (idx, c) in centroids.enumerated() {
            let d = dist(c, fp)
            if d < bestD { bestD = d; bestIdx = idx }
        }
        return (bestIdx, bestD)
    }

    /// Nearest-centroid speaker assignment with online centroid update; opens a new speaker when no
    /// centroid is close enough (until the cap). The ONLY mutator — called once per emitted turn.
    /// (Diarizer.assign)
    func assign(_ fp: [Float]) -> Int {
        let (bestIdx, bestD) = nearestSpeaker(fp)
        if bestIdx >= 0, bestD < newSpeakerDist {
            for k in 0..<centroids[bestIdx].count { centroids[bestIdx][k] = centroids[bestIdx][k] * 0.8 + fp[k] * 0.2 }
            return bestIdx
        }
        if centroids.count < maxSpeakers { centroids.append(fp); return centroids.count - 1 }
        return max(0, bestIdx)
    }
}
