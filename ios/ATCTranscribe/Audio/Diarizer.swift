import Foundation

/// Heuristic on-device speaker diarization for ATC radio. **Not** a neural speaker-embedding model
/// — it leans on how ATC actually works (push-to-talk, one transmitter at a time per frequency):
///
///  1. **Split** a VAD segment at push-to-talk / squelch breaks — the brief near-silence when one
///     radio unkeys before the next keys.
///  2. **Fingerprint** each piece (via the shared `SpeakerModel`): level, brightness, pitch.
///  3. **Merge** adjacent pieces that sound like the same speaker — so a mid-sentence pause isn't a
///     false split.
///  4. **Cluster** pieces across the session into stable speaker ids (nearest-centroid).
///
/// The fingerprint + centroid math lives in `SpeakerModel`, shared with the streaming speaker-aware
/// VAD path so both agree on speaker ids. This class keeps only the segment-SPLITTING heuristics.
///
/// LIMITATION (documented for honesty): this cannot separate **simultaneous** talkers (true
/// overtalk) — that needs source separation. It targets the common alternating-transmission case.
final class Diarizer {
    /// One speaker-homogeneous slice of a segment.
    struct Piece { var audio: [Float]; var startSample: Int; var speaker: Int }

    // Split tunables (mono 16 kHz).
    private let frame = 320               // 20 ms analysis frame
    private let silenceRms: Float = 0.02  // below this RMS = near-silence
    private let minGapFrames = 7          // ~140 ms of silence = a candidate PTT break → split
    private let minPieceFrames = 10       // ~200 ms — below this, don't bother splitting
    private let minEmitFrames = 14        // ~280 ms — fold shorter pieces into a neighbor (no decode)
    private let maxPieces = 8             // cap decodes per VAD segment (a busy frequency safeguard)
    private let mergeDist: Float = 0.16   // adjacent pieces closer than this fingerprint dist = same speaker

    /// Shared session speaker clustering (fingerprint + centroids). Injected so this post-hoc
    /// diarizer and the streaming speaker-aware VAD number the same voice identically.
    private let speaker: SpeakerModel

    init(speaker: SpeakerModel = SpeakerModel()) { self.speaker = speaker }

    /// Split + label a VAD segment's audio into speaker-homogeneous pieces (always ≥ 1).
    func diarize(_ audio: [Float]) -> [Piece] {
        guard audio.count >= frame * minPieceFrames else {
            return [Piece(audio: audio, startSample: 0, speaker: speaker.assign(speaker.fingerprint(audio)))]
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
            return [Piece(audio: audio, startSample: 0, speaker: speaker.assign(speaker.fingerprint(audio)))]
        }

        // 2. Build piece audio + fingerprints.
        var pieces: [(audio: [Float], start: Int, fp: [Float])] = runs.map { r in
            let lo = r.start * frame
            let hi = min(r.end * frame, audio.count)
            let a = Array(audio[lo..<hi])
            return (a, lo, speaker.fingerprint(a))
        }

        // 3. Merge adjacent pieces that sound like the same speaker (a mid-sentence pause, not a turn).
        var merged: [(audio: [Float], start: Int, fp: [Float])] = []
        for piece in pieces {
            if let last = merged.last, speaker.dist(last.fp, piece.fp) < mergeDist {
                var a = last.audio; a.append(contentsOf: piece.audio)
                merged[merged.count - 1] = (a, last.start, speaker.fingerprint(a))
            } else {
                merged.append(piece)
            }
        }
        // Bound the work: a sub-threshold fragment isn't worth a full Whisper decode, and a busy
        // frequency mustn't explode into dozens of serial decodes — fold short pieces into a
        // neighbor and cap the total (each piece = one decode).
        pieces = boundPieces(merged, minEmit: frame * minEmitFrames, maxPieces: maxPieces)

        // 4. Assign stable session speaker ids.
        return pieces.map { Piece(audio: $0.audio, startSample: $0.start, speaker: speaker.assign($0.fp)) }
    }

    /// Fold pieces shorter than `minEmit` into a neighbor, then cap the total at `maxPieces` by
    /// repeatedly merging the shortest piece into an adjacent one. Keeps audio time-ordered.
    private func boundPieces(_ input: [(audio: [Float], start: Int, fp: [Float])],
                             minEmit: Int, maxPieces: Int) -> [(audio: [Float], start: Int, fp: [Float])] {
        var pieces = input
        func merge(_ keep: Int, _ drop: Int) {   // keep < drop, adjacent
            var a = pieces[keep].audio; a.append(contentsOf: pieces[drop].audio)
            pieces[keep] = (a, pieces[keep].start, speaker.fingerprint(a))
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
}
