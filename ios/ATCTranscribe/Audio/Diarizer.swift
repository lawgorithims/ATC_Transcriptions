import Foundation

/// Heuristic on-device speaker diarization for ATC radio. **Not** a neural speaker-embedding model
/// — it leans on how ATC actually works (push-to-talk, one transmitter at a time per frequency):
///
///  1. **Split** a VAD segment at push-to-talk / squelch breaks — the brief near-silence when one
///     radio unkeys before the next keys. (The VAD only splits on long ≥700 ms silence, so
///     back-to-back ATC↔aircraft transmissions arrive merged; this catches the shorter breaks.)
///  2. **Fingerprint** each piece with cheap acoustic features: level (ATC ground stations are
///     stronger/cleaner than aircraft), brightness (zero-crossing rate), and pitch (autocorrelation).
///  3. **Merge** adjacent pieces that sound like the same speaker — so a mid-sentence pause isn't a
///     false split.
///  4. **Cluster** pieces across the session into stable speaker ids (nearest-centroid).
///
/// LIMITATION (documented for honesty): this cannot separate **simultaneous** talkers (true
/// overtalk) — that needs source separation. It targets the common alternating-transmission case.
/// A dedicated speaker-embedding CoreML model would be more robust; this is a no-extra-model v1.
final class Diarizer {
    /// One speaker-homogeneous slice of a segment.
    struct Piece { var audio: [Float]; var startSample: Int; var speaker: Int }

    // Tunables (mono 16 kHz).
    private let sr = 16_000
    private let frame = 320               // 20 ms analysis frame
    private let silenceRms: Float = 0.02  // below this RMS = near-silence
    private let minGapFrames = 7          // ~140 ms of silence = a candidate PTT break → split
    private let minPieceFrames = 10       // ~200 ms — below this, don't bother splitting
    private let minEmitFrames = 14        // ~280 ms — fold shorter pieces into a neighbor (no decode)
    private let maxPieces = 8             // cap decodes per VAD segment (a busy frequency safeguard)
    private let mergeDist: Float = 0.16   // adjacent pieces closer than this fingerprint dist = same speaker
    private let newSpeakerDist: Float = 0.30  // beyond nearest centroid by this → a new speaker
    private let maxSpeakers = 6

    /// Session speaker centroids (running mean of assigned fingerprints).
    private var centroids: [[Float]] = []

    /// Split + label a VAD segment's audio into speaker-homogeneous pieces (always ≥ 1).
    func diarize(_ audio: [Float]) -> [Piece] {
        guard audio.count >= frame * minPieceFrames else {
            return [Piece(audio: audio, startSample: 0, speaker: assign(fingerprint(audio)))]
        }

        // 1. Per-frame RMS → carve speech runs separated by silence gaps ≥ minGapFrames.
        let nFrames = (audio.count + frame - 1) / frame   // round up so the tail isn't dropped
        var rms = [Float](repeating: 0, count: nFrames)
        for f in 0..<nFrames {
            let base = f * frame
            let end = min(base + frame, audio.count)
            var s: Float = 0
            for i in base..<end { let v = audio[i]; s += v * v }
            rms[f] = (s / Float(max(1, end - base))).squareRoot()
        }

        var runs: [(start: Int, end: Int)] = []   // frame ranges [start, end)
        var i = 0
        while i < nFrames {
            while i < nFrames && rms[i] < silenceRms { i += 1 }   // skip leading silence
            if i >= nFrames { break }
            let start = i
            var end = i + 1
            var silenceRun = 0
            while i < nFrames {
                if rms[i] < silenceRms {
                    silenceRun += 1
                    if silenceRun >= minGapFrames { break }       // real gap → close the run
                } else {
                    silenceRun = 0
                    end = i + 1
                }
                i += 1
            }
            runs.append((start, end))
        }
        guard runs.count > 1 else {
            return [Piece(audio: audio, startSample: 0, speaker: assign(fingerprint(audio)))]
        }

        // 2. Build piece audio + fingerprints.
        var pieces: [(audio: [Float], start: Int, fp: [Float])] = runs.map { r in
            let lo = r.start * frame
            let hi = min(r.end * frame, audio.count)
            let a = Array(audio[lo..<hi])
            return (a, lo, fingerprint(a))
        }

        // 3. Merge adjacent pieces that sound like the same speaker (a mid-sentence pause, not a turn).
        var merged: [(audio: [Float], start: Int, fp: [Float])] = []
        for piece in pieces {
            if let last = merged.last, dist(last.fp, piece.fp) < mergeDist {
                var a = last.audio; a.append(contentsOf: piece.audio)
                merged[merged.count - 1] = (a, last.start, fingerprint(a))
            } else {
                merged.append(piece)
            }
        }
        // Bound the work: a sub-threshold fragment isn't worth a full Whisper decode, and a busy
        // frequency mustn't explode into dozens of serial decodes — fold short pieces into a
        // neighbor and cap the total (each piece = one decode).
        pieces = boundPieces(merged, minEmit: frame * minEmitFrames, maxPieces: maxPieces)

        // 4. Assign stable session speaker ids.
        return pieces.map { Piece(audio: $0.audio, startSample: $0.start, speaker: assign($0.fp)) }
    }

    /// Fold pieces shorter than `minEmit` into a neighbor, then cap the total at `maxPieces` by
    /// repeatedly merging the shortest piece into an adjacent one. Keeps audio time-ordered.
    private func boundPieces(_ input: [(audio: [Float], start: Int, fp: [Float])],
                             minEmit: Int, maxPieces: Int) -> [(audio: [Float], start: Int, fp: [Float])] {
        var pieces = input
        func merge(_ keep: Int, _ drop: Int) {   // keep < drop, adjacent
            var a = pieces[keep].audio; a.append(contentsOf: pieces[drop].audio)
            pieces[keep] = (a, pieces[keep].start, fingerprint(a))
            pieces.remove(at: drop)
        }
        var i = 0
        while pieces.count > 1, i < pieces.count {
            if pieces[i].audio.count < minEmit {
                let j = i > 0 ? i - 1 : i + 1
                merge(Swift.min(i, j), Swift.max(i, j))
                i = Swift.max(0, Swift.min(i, pieces.count - 1))
            } else { i += 1 }
        }
        while pieces.count > maxPieces {
            var shortest = 0
            for (k, p) in pieces.enumerated() where p.audio.count < pieces[shortest].audio.count { shortest = k }
            let j = shortest > 0 ? shortest - 1 : shortest + 1
            merge(Swift.min(shortest, j), Swift.max(shortest, j))
        }
        return pieces
    }

    // MARK: features

    /// Compact acoustic fingerprint: [level, brightness, pitch], each ~0…1.
    private func fingerprint(_ a: [Float]) -> [Float] {
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

    /// Autocorrelation pitch (Hz) over up to ~0.5 s from the middle; 0 when unvoiced.
    private func estimatePitch(_ a: [Float]) -> Float {
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

    private func dist(_ x: [Float], _ y: [Float]) -> Float {
        var s: Float = 0
        for k in 0..<min(x.count, y.count) { let d = x[k] - y[k]; s += d * d }
        return s.squareRoot()
    }

    /// Nearest-centroid speaker assignment with online centroid update; opens a new speaker when no
    /// centroid is close enough (until the cap).
    private func assign(_ fp: [Float]) -> Int {
        var bestIdx = -1
        var bestD = Float.greatestFiniteMagnitude
        for (idx, c) in centroids.enumerated() {
            let d = dist(c, fp)
            if d < bestD { bestD = d; bestIdx = idx }
        }
        if bestIdx >= 0, bestD < newSpeakerDist {
            for k in 0..<centroids[bestIdx].count { centroids[bestIdx][k] = centroids[bestIdx][k] * 0.8 + fp[k] * 0.2 }
            return bestIdx
        }
        if centroids.count < maxSpeakers { centroids.append(fp); return centroids.count - 1 }
        return max(0, bestIdx)
    }
}
