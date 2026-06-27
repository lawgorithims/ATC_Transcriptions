import Foundation
import AVFoundation
import os

/// Plays the mono-16 kHz PCM the model is transcribing out through the speakers, so a live feed can
/// be HEARD to confirm it's arriving (a "monitor"). Used for the internet feed only — mic/USB would
/// feed back. Lo-fi by design: it plays the exact downsampled audio the pipeline receives.
final class AudioMonitor: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000,
                                       channels: 1, interleaved: false)!
    private let lock = NSLock()
    private var running = false
    private var configured = false        // attach/connect exactly once (re-attach is a hard crash)
    private var muted = false
    // Outstanding scheduled frames — its OWN lock (not the main one) so a buffer-completion handler
    // can never deadlock against stop()/play() holding the main lock around player operations.
    private let queued = OSAllocatedUnfairLock(initialState: 0)
    private let maxQueuedFrames = 16_000 * 2   // ~2 s at 16 kHz — drop beyond this to stay near-live

    /// Start the playback graph. Call after the audio session is active (AppModel.start). Idempotent
    /// across runs: the node graph is built once; later starts just restart the engine.
    func start() {
        lock.lock(); defer { lock.unlock() }
        guard !running else { return }
        if !configured {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            configured = true
        }
        engine.prepare()
        do {
            try engine.start(); player.play()
            player.volume = muted ? 0 : 1
            queued.withLock { $0 = 0 }
            running = true
        } catch { running = false }
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        guard running else { return }
        player.stop(); engine.stop(); running = false   // node stays attached for the next start()
    }

    /// Mute without tearing down (the speaker toggle), so toggling doesn't disrupt the stream.
    /// Remembered so a toggle set before `start()` still applies.
    func setMuted(_ muted: Bool) {
        lock.lock(); defer { lock.unlock() }
        self.muted = muted
        if running { player.volume = muted ? 0 : 1 }
    }

    /// Queue one chunk for playback. Safe to call from the pipeline's executor. Drops chunks when
    /// the queue is already ~2 s deep so a burst/reconnect can't grow latency or memory unbounded.
    func play(_ chunk: [Float]) {
        lock.lock(); defer { lock.unlock() }
        guard running, !chunk.isEmpty, queued.withLock({ $0 }) <= maxQueuedFrames,
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk.count))
        else { return }
        buf.frameLength = AVAudioFrameCount(chunk.count)
        chunk.withUnsafeBufferPointer { src in
            if let dst = buf.floatChannelData?[0], let base = src.baseAddress {
                dst.update(from: base, count: chunk.count)
            }
        }
        let n = chunk.count
        queued.withLock { $0 += n }
        player.scheduleBuffer(buf) { [weak self] in
            self?.queued.withLock { $0 -= n }
        }
    }
}

/// Wraps an `AudioSource` so each PCM chunk is also played through `monitor` as it passes to the
/// pipeline — used to make the live feed audible without a second network connection.
final class MonitoredSource: AudioSource {
    private let wrapped: AudioSource
    private let monitor: AudioMonitor
    private var task: Task<Void, Never>?

    init(_ wrapped: AudioSource, monitor: AudioMonitor) {
        self.wrapped = wrapped
        self.monitor = monitor
    }

    func makeStream() -> AsyncStream<[Float]> {
        monitor.start()
        let inner = wrapped.makeStream()
        return AsyncStream { continuation in
            let t = Task { [monitor] in
                for await chunk in inner {
                    monitor.play(chunk)
                    continuation.yield(chunk)
                }
                monitor.stop()
                continuation.finish()
            }
            self.task = t
            continuation.onTermination = { _ in t.cancel() }
        }
    }

    func stop() {
        task?.cancel()
        wrapped.stop()
        monitor.stop()
    }
}
