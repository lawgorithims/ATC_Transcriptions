import Foundation

/// Session speaker clustering + the MFCC acoustic fingerprint that drives it. ONE instance feeds both
/// the streaming speaker-aware VAD and the post-hoc diarizer, so they number the same voice
/// identically. Actor-confined to `LivePipeline` (its `feed()`/`diarize()` run there serially), so no
/// lock is needed; `assignReporting` is the ONLY mutator.
///
/// CODING STANDARD (NASA/JPL "Power of Ten"): loops are bounded by fixed constants (`maxSpeakers`,
/// `maxDims`); the centroid store never exceeds `maxSpeakers`; every function validates its inputs and
/// returns a safe value on violation, and asserts its invariants. No recursion, no function pointers.
final class SpeakerModel {
    // Thresholds on COSINE distance (0 = identical, larger = more different). The BACKEND sets the
    // scale: the MFCC fingerprint's same-speaker distance is tiny (~0.004, cross ~0.06), whereas the
    // ECAPA embedding's is large (same-speaker median ~0.51, cross ~0.69 — measured by SpeakerStudy).
    // So the thresholds are chosen per backend in `init`.
    let newSpeakerDist: Float           // beyond nearest centroid by this → a new speaker
    /// A streaming turn change must move the voice by at least this much (loudness-independent for
    /// MFCC). Only the streaming VAD uses this; the diarizer clusters on full `dist`.
    let turnChangeTimbreMin: Float
    /// Adjacent diarizer pieces closer than this are folded into one speaker (backend-scaled).
    let mergeDist: Float

    private static let maxSpeakers = 6
    private static let maxDims = 256    // MFCC=13, ECAPA=192; a fixed cap bounds the cosine loop

    /// Running speaker centroids (running mean of assigned fingerprints). Length is bounded by
    /// `maxSpeakers` at all times (see `assignReporting`).
    private var centroids: [[Float]] = []

    /// Per-segment MFCC front-end. One instance — its FFT setup + filterbank are built once.
    private let mfcc = MFCC()
    /// Optional neural embedder (Stage 5b). When present + available, it supplies the fingerprint
    /// instead of MFCC (with an MFCC fallback per clip it rejects). nil = the default MFCC backend.
    private let embedder: CoreMLSpeakerEmbedder?

    /// - Parameter embedder: pass a loaded `CoreMLSpeakerEmbedder` to use ECAPA embeddings; nil (the
    ///   default) uses the MFCC fingerprint. The threshold scale follows the chosen backend.
    init(embedder: CoreMLSpeakerEmbedder? = nil) {
        let ecapa = embedder?.isAvailable == true
        self.embedder = ecapa ? embedder : nil
        if ecapa {
            newSpeakerDist = 0.55; mergeDist = 0.50; turnChangeTimbreMin = 0.50
        } else {
            newSpeakerDist = 0.05; mergeDist = 0.03; turnChangeTimbreMin = 0.03
        }
    }

    /// Acoustic fingerprint of a transmission: the ECAPA embedding when the neural backend is active
    /// (falling back to MFCC for a clip it rejects), else the mean MFCC. Compared by cosine distance.
    func fingerprint(_ a: [Float]) -> [Float] {
        guard !a.isEmpty else { return [Float](repeating: 0, count: mfcc.numCoeffs) }
        if let embedder, let e = embedder.embed(a) {
            assert(e.count == CoreMLSpeakerEmbedder.dims)
            return e
        }
        let fp = mfcc.features(a)
        assert(fp.count == mfcc.numCoeffs)
        return fp
    }

    /// Cosine distance over c1…c12 (skips c0, the overall log-energy, so a louder transmission of the
    /// same voice is not read as a different speaker). Silence / malformed input → 1 (dissimilar), so
    /// it never merges a voice.
    func dist(_ x: [Float], _ y: [Float]) -> Float { cosineDistance(x, y, from: 1) }

    /// Timbre-only cosine distance — identical basis to `dist` (both skip c0); kept as a named entry
    /// point for the streaming VAD's turn-change gate. Falls back to the full compare if malformed.
    func timbreDist(_ x: [Float], _ y: [Float]) -> Float {
        guard x.count > 1, y.count > 1 else { return 1 }
        return cosineDistance(x, y, from: 1)
    }

    /// Cosine distance over dimensions [from, n). Returns 1 (max dissimilarity) for any malformed or
    /// zero-norm input, so a bad fingerprint can never spuriously merge speakers.
    private func cosineDistance(_ x: [Float], _ y: [Float], from: Int) -> Float {
        guard from >= 0, x.count <= SpeakerModel.maxDims, y.count <= SpeakerModel.maxDims else { return 1 }
        let n = min(x.count, y.count)
        guard from < n else { return 1 }
        var dot: Float = 0, nx: Float = 0, ny: Float = 0
        for k in from..<n { dot += x[k] * y[k]; nx += x[k] * x[k]; ny += y[k] * y[k] }
        guard nx > 1e-12, ny > 1e-12 else { return 1 }
        let d = 1 - dot / (nx.squareRoot() * ny.squareRoot())
        assert(d.isFinite)
        return d
    }

    /// Nearest centroid to `fp` WITHOUT mutating. Returns (-1, .greatestFiniteMagnitude) when no
    /// speaker exists yet. Loop bounded by `maxSpeakers`.
    func nearestSpeaker(_ fp: [Float]) -> (id: Int, d: Float) {
        assert(centroids.count <= SpeakerModel.maxSpeakers)
        guard !fp.isEmpty else { return (-1, .greatestFiniteMagnitude) }
        var bestIdx = -1
        var bestD = Float.greatestFiniteMagnitude
        for idx in 0..<centroids.count {
            let d = dist(centroids[idx], fp)
            if d < bestD { bestD = d; bestIdx = idx }
        }
        return (bestIdx, bestD)
    }

    /// Nearest-centroid assignment with online centroid update; opens a new speaker when none is close
    /// enough (until `maxSpeakers`). The ONLY mutator. Also reports the pre-update match distance
    /// (`.greatestFiniteMagnitude` for a newly-opened speaker) for the fusion fill-guard.
    func assignReporting(_ fp: [Float]) -> (id: Int, distance: Float) {
        guard !fp.isEmpty, fp.count <= SpeakerModel.maxDims else { return (0, .greatestFiniteMagnitude) }
        let (bestIdx, bestD) = nearestSpeaker(fp)
        if bestIdx >= 0, bestD < newSpeakerDist {
            let dims = min(centroids[bestIdx].count, fp.count)
            for k in 0..<dims { centroids[bestIdx][k] = centroids[bestIdx][k] * 0.8 + fp[k] * 0.2 }
            return (bestIdx, bestD)
        }
        if centroids.count < SpeakerModel.maxSpeakers {
            centroids.append(fp)
            assert(centroids.count <= SpeakerModel.maxSpeakers)
            return (centroids.count - 1, .greatestFiniteMagnitude)
        }
        return (max(0, bestIdx), bestD)
    }

    /// Convenience: assignment id only (behaviourally identical to `assignReporting`).
    func assign(_ fp: [Float]) -> Int { assignReporting(fp).id }
}
