import Foundation
import AVFoundation
import os

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
    private let preferUSB: Bool
    /// Called (off the main actor) if capture can't start / delivers no audio — so the UI can show
    /// why instead of the stream silently finishing and looking like "nothing happened".
    private let onFailure: (@Sendable (String) -> Void)?
    // `engine` + `watchdog` are touched from the pipeline executor (makeStream), the MainActor
    // (stop), and the stream's onTermination — guard them with a lock to avoid a data race.
    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var watchdog: Task<Void, Never>?

    init(preferUSB: Bool = false, onFailure: (@Sendable (String) -> Void)? = nil) {
        self.preferUSB = preferUSB
        self.onFailure = onFailure
    }

    func makeStream() -> AsyncStream<[Float]> {
        AsyncStream { continuation in
            // Create the engine HERE — after AppModel.start() has activated the .playAndRecord
            // session — so the input node binds to a live record route. Building it before the
            // session is record-ready leaves the input silent (the "mic not registering" bug).
            let engine = AVAudioEngine()
            lock.lock(); self.engine = engine; lock.unlock()
            let input = engine.inputNode
            let inputFormat = input.outputFormat(forBus: 0)
            // A zero sample rate / channel count means there's no usable input (e.g. mic permission
            // not granted, or no input route) — surface it rather than finishing silently.
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
                  let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                   sampleRate: 16000, channels: 1, interleaved: false),
                  let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
                onFailure?("No audio input available. Check the microphone is connected and permitted.")
                continuation.finish(); return
            }

            // Watchdog flag: did the tap ever deliver a buffer? Distinguishes a dead route (real
            // bug — tap never fires) from a live-but-quiet mic (user just isn't talking).
            let gotAudio = OSAllocatedUnfairLock(initialState: false)
            input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
                gotAudio.withLock { $0 = true }
                let ratio = outputFormat.sampleRate / inputFormat.sampleRate
                let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
                guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
                var consumed = false
                var error: NSError?
                let status = converter.convert(to: out, error: &error) { _, s in
                    if consumed { s.pointee = .noDataNow; return nil }
                    consumed = true
                    s.pointee = .haveData
                    return buffer
                }
                guard status != .error, let channel = out.floatChannelData, out.frameLength > 0 else { return }
                continuation.yield(Array(UnsafeBufferPointer(start: channel[0], count: Int(out.frameLength))))
            }

            engine.prepare()
            do { try engine.start() }
            catch {
                onFailure?("Microphone failed to start: \(error.localizedDescription)")
                continuation.finish(); return
            }
            // If the tap never fired after a few seconds, the route is dead (not just quiet).
            let onFailure = self.onFailure
            let watchdog = Task {
                try? await Task.sleep(nanoseconds: 3_500_000_000)
                if Task.isCancelled { return }   // stopped before the first buffer — not a failure
                if !gotAudio.withLock({ $0 }) {
                    onFailure?("No audio from the microphone — it may be muted or used by another app.")
                }
            }
            lock.lock(); self.watchdog = watchdog; lock.unlock()
            continuation.onTermination = { [weak self] _ in self?.stop() }
        }
    }

    func stop() {
        // Atomically take ownership of the engine + watchdog so a double stop() (MainActor Stop
        // racing the stream's onTermination) can't both tear down the same engine.
        lock.lock()
        let e = engine; engine = nil
        let w = watchdog; watchdog = nil
        lock.unlock()
        w?.cancel()
        e?.inputNode.removeTap(onBus: 0)
        if e?.isRunning == true { e?.stop() }
    }
}
