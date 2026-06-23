import Foundation

/// Tunables for `VADSegmenter`. Mirrors the constructor args of
/// `atc_stream.VADSegmenter` (and the `live_pipeline` block of `config.yaml`).
struct VADConfig {
    var aggressiveness = 2
    var silenceDurationMs = 700
    var minSpeechMs = 500
    var maxSegmentS = 12.0
    var preRollMs = 200
}

/// Accumulates mono 16 kHz float32 PCM and emits contiguous speech segments via a
/// frame-based voice-activity state machine. Faithful port of
/// `atc_stream.VADSegmenter`.
///
/// The Python version uses WebRTC VAD when available and falls back to an energy
/// threshold; this port implements the **energy path** (portable, dependency-free).
/// Swapping in WebRTC VAD or a Silero CoreML model later means replacing
/// `isSpeechFrame` — the segmentation logic around it is unchanged.
final class VADSegmenter {
    static let sampleRate = 16_000
    static let frameMs = 30
    static let frameSamples = sampleRate * frameMs / 1000   // 480

    private let silenceFrames: Int
    private let minSpeechFrames: Int
    private let maxSegmentSamples: Int
    private let preRollFrames: Int
    private let energyThreshold: Float

    private var pending: [Float] = []
    private var segmentFrames: [[Float]] = []
    private var preRoll: [[Float]] = []         // bounded deque of recent non-speech frames
    private var speechActive = false
    private var silenceCount = 0
    private var speechFrames = 0
    private var segmentStartS = 0.0
    private var streamCursorS = 0.0

    /// Injectable clock (Python uses `time.time()`); overridable so tests are
    /// deterministic.
    private let now: () -> Double

    init(config: VADConfig = VADConfig(), now: @escaping () -> Double = { Date().timeIntervalSince1970 }) {
        silenceFrames = max(1, config.silenceDurationMs / Self.frameMs)
        minSpeechFrames = max(1, config.minSpeechMs / Self.frameMs)
        maxSegmentSamples = Int(config.maxSegmentS * Double(Self.sampleRate))
        preRollFrames = max(0, config.preRollMs / Self.frameMs)
        energyThreshold = Float(0.012 - Double(config.aggressiveness) * 0.002)
        self.now = now
    }

    /// Energy (RMS) voice-activity test. Port of the energy branch of `_is_speech_frame`.
    private func isSpeechFrame(_ frame: [Float]) -> Bool {
        guard !frame.isEmpty else { return false }
        var sumSquares: Float = 0
        for s in frame { sumSquares += s * s }
        let rms = (sumSquares / Float(frame.count)).squareRoot()
        return rms >= energyThreshold
    }

    /// Emit the buffered segment if it has enough speech, else drop it. Port of `_finalize`.
    private func finalize(endS: Double) -> SpeechSegment? {
        if speechFrames < minSpeechFrames || segmentFrames.isEmpty {
            segmentFrames = []
            speechFrames = 0
            return nil
        }
        let audio = segmentFrames.flatMap { $0 }
        let seg = SpeechSegment(audio: audio, streamStartS: segmentStartS,
                                streamEndS: endS, finalizedWallTime: now())
        segmentFrames = []
        speechFrames = 0
        return seg
    }

    /// Feed PCM and return any completed speech segments. Port of `feed`.
    @discardableResult
    func feed(_ chunk: [Float]) -> [SpeechSegment] {
        pending.append(contentsOf: chunk)
        var completed: [SpeechSegment] = []

        while pending.count >= Self.frameSamples {
            let frame = Array(pending[0..<Self.frameSamples])
            pending.removeFirst(Self.frameSamples)
            let frameStartS = streamCursorS
            streamCursorS += Double(Self.frameSamples) / Double(Self.sampleRate)

            if isSpeechFrame(frame) {
                if !speechActive {
                    speechActive = true
                    segmentStartS = max(0.0, frameStartS - Double(preRollFrames) * Double(Self.frameMs) / 1000.0)
                    segmentFrames = preRoll        // seed with pre-roll (value-copied)
                }
                segmentFrames.append(frame)
                speechFrames += 1
                silenceCount = 0

                if segmentFrames.reduce(0, { $0 + $1.count }) >= maxSegmentSamples {
                    let endS = streamCursorS
                    if let seg = finalize(endS: endS) { completed.append(seg) }
                    speechActive = true
                    segmentStartS = endS
                }
            } else {
                preRoll.append(frame)
                if preRoll.count > preRollFrames {
                    preRoll.removeFirst(preRoll.count - preRollFrames)
                }
                if speechActive {
                    segmentFrames.append(frame)
                    silenceCount += 1
                    if silenceCount >= silenceFrames {
                        let endS = streamCursorS
                        if let seg = finalize(endS: endS) { completed.append(seg) }
                        speechActive = false
                        silenceCount = 0
                    }
                }
            }
        }
        return completed
    }
}
