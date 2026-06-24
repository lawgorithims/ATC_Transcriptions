import Foundation
import WhisperKit

/// File-based audio loading for the replay demo and tests: decode an audio file to
/// mono 16 kHz float32 samples (what the VAD segmenter and transcriber expect), via
/// WhisperKit's audio loader (handles channel mix-down and resampling).
enum AudioFile {
    /// Load `path` as mono 16 kHz float32 PCM in [-1, 1].
    static func load16kMono(path: String) throws -> [Float] {
        try AudioProcessor.loadAudioAsFloatArray(fromPath: path)
    }
}
