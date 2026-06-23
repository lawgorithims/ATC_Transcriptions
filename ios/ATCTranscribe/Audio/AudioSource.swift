import Foundation
import AVFoundation

/// A source of mono 16 kHz float32 PCM chunks for the live pipeline. Implementations:
/// `FileReplaySource` (replay demo), `MicAudioSource` (device mic), and — added later —
/// a LiveATC stream source. Mirrors the role of `atc_stream`'s capture classes.
protocol AudioSource {
    /// Emits PCM chunks until the source ends or `stop()` is called.
    func makeStream() -> AsyncStream<[Float]>
    func stop()
}

/// Emits chunks from an in-memory buffer (used by `FileReplaySource` and tests/probe).
final class ArrayAudioSource: AudioSource {
    private let audio: [Float]
    private let chunkSamples: Int
    private let realtime: Bool
    private var task: Task<Void, Never>?

    /// - Parameter realtime: pace chunks at wall-clock speed (like a live feed). False
    ///   replays as fast as possible (for tests / the probe).
    init(_ audio: [Float], chunkSamples: Int = 8000, realtime: Bool = false) {
        self.audio = audio
        self.chunkSamples = chunkSamples
        self.realtime = realtime
    }

    func makeStream() -> AsyncStream<[Float]> {
        AsyncStream { continuation in
            let task = Task { [audio, chunkSamples, realtime] in
                var offset = 0
                while offset < audio.count {
                    if Task.isCancelled { break }
                    let end = Swift.min(offset + chunkSamples, audio.count)
                    continuation.yield(Array(audio[offset..<end]))
                    offset = end
                    if realtime {
                        try? await Task.sleep(nanoseconds: UInt64(Double(chunkSamples) / 16000.0 * 1_000_000_000))
                    }
                }
                continuation.finish()
            }
            self.task = task
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func stop() { task?.cancel() }
}

/// Replays a recording at live pace (the "replay demo"). Decodes the file to mono
/// 16 kHz once via WhisperKit's loader, then streams it. Works without any network.
final class FileReplaySource: AudioSource {
    private let backing: ArrayAudioSource

    init(path: String, realtime: Bool = true) throws {
        backing = ArrayAudioSource(try AudioFile.load16kMono(path: path), realtime: realtime)
    }

    func makeStream() -> AsyncStream<[Float]> { backing.makeStream() }
    func stop() { backing.stop() }
}

/// Live capture from the device microphone or a connected USB audio interface, via
/// AVAudioEngine, resampled to mono 16 kHz. `preferUSB` routes the session to a USB
/// input when present. NOTE: device-tested later (no audio input over headless SSH).
final class DeviceAudioSource: AudioSource {
    private let engine = AVAudioEngine()
    private let preferUSB: Bool

    init(preferUSB: Bool = false) { self.preferUSB = preferUSB }

    func makeStream() -> AsyncStream<[Float]> {
        AsyncStream { continuation in
            configureSession()
            let input = engine.inputNode
            let inputFormat = input.outputFormat(forBus: 0)
            guard let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                   sampleRate: 16000, channels: 1, interleaved: false),
                  let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
                continuation.finish(); return
            }

            input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
                let ratio = outputFormat.sampleRate / inputFormat.sampleRate
                let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
                guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
                var consumed = false
                var error: NSError?
                converter.convert(to: out, error: &error) { _, status in
                    if consumed { status.pointee = .noDataNow; return nil }
                    consumed = true
                    status.pointee = .haveData
                    return buffer
                }
                if let channel = out.floatChannelData, out.frameLength > 0 {
                    continuation.yield(Array(UnsafeBufferPointer(start: channel[0], count: Int(out.frameLength))))
                }
            }

            do { try engine.start() } catch { continuation.finish() }
            continuation.onTermination = { [weak self] _ in self?.stop() }
        }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
    }

    private func configureSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .measurement, options: [.allowBluetooth, .defaultToSpeaker])
        try? session.setActive(true)
        if preferUSB, let usb = session.availableInputs?.first(where: { $0.portType == .usbAudio }) {
            try? session.setPreferredInput(usb)
        } else if !preferUSB, let mic = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
            try? session.setPreferredInput(mic)
        }
        #endif
    }
}
