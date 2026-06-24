import Foundation

/// A contiguous speech region extracted from the live audio source by the VAD
/// segmenter. Audio is mono 16 kHz float32 samples in [-1, 1]. Mirrors
/// `atc_stream.SpeechSegment`.
struct SpeechSegment {
    /// Decoded PCM samples (mono, 16 kHz, float32).
    var audio: [Float]
    /// Start time of the segment within the stream timeline, in seconds.
    var streamStartS: Double
    /// End time of the segment within the stream timeline, in seconds.
    var streamEndS: Double
    /// Wall-clock time (seconds since 1970) when the segment was finalized.
    var finalizedWallTime: Double

    var durationS: Double { streamEndS - streamStartS }
}
