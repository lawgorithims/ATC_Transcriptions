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

    /// Consecutive failed self-heals (see `play`) — stop retrying after the cap so a dead output
    /// can't burn a start() attempt per chunk forever. Reset by an explicit start().
    private var restartFailures = 0
    private static let maxRestartFailures = 5

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
        restartFailures = 0   // an explicit start re-arms self-healing
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
        // Self-heal (L1 remediation): an AVAudioSession interruption (Siri / alarm / call) stops
        // the engine out from under us while `running` stays true — previously the scheduled-buffer
        // completions never fired, `queued` pinned at its cap, and every later chunk was silently
        // dropped for the rest of the session. play() runs ~2×/s on a live feed, so healing here
        // recovers within one chunk. Bounded; a genuinely dead output flips `running` off.
        // Known limit: after a mediaServicesWereReset the engine OBJECT may be unrecoverable —
        // heal fails out and the monitor stays silent until the next Start (re-attaching a fresh
        // engine here is the hard-crash noted at `configured`).
        if running, !engine.isRunning { healLocked() }
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
            // Floor at 0 (adversarial-review fix): player.stop() in healLocked() flushes the
            // outstanding buffers by firing these completions ASYNCHRONOUSLY, AFTER healLocked has
            // already reset `queued` to 0 — without this clamp each late completion would drive the
            // counter negative and permanently loosen the ~2 s admission cap below.
            self?.queued.withLock { $0 = max(0, $0 - n) }
        }
    }

    /// One bounded engine restart after an interruption stopped it. Caller holds `lock`.
    private func healLocked() {
        guard restartFailures < Self.maxRestartFailures else { running = false; return }
        player.stop()                      // flush stale pre-interruption buffers (fires completions)
        engine.prepare()
        do {
            try engine.start(); player.play()
            player.volume = muted ? 0 : 1
            queued.withLock { $0 = 0 }     // same reset start() does; completions drained above
            restartFailures = 0
        } catch { restartFailures += 1 }
    }

    #if DEBUG
    /// Test hooks (AudioMonitorTests): simulate an interruption stopping the engine, and observe it.
    func _stopEngineForTests() { engine.stop() }
    var _engineIsRunningForTests: Bool { engine.isRunning }
    #endif
}

/// Wraps an `AudioSource` so each PCM chunk is also played through `monitor` as it passes to the
/// pipeline — used to make the live feed audible without a second network connection.
final class MonitoredSource: AudioSource {
    private let wrapped: AudioSource
    private let monitor: AudioMonitor
    // `task` is assigned in makeStream() (runs on the LivePipeline actor's executor) and cancelled
    // in stop() (MainActor) — two executors, so guard it with a lock (same as DeviceAudioSource).
    private let lock = NSLock()
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
            lock.lock(); self.task = t; lock.unlock()
            continuation.onTermination = { _ in t.cancel() }
        }
    }

    func stop() {
        lock.lock(); let t = task; task = nil; lock.unlock()
        t?.cancel()
        wrapped.stop()
        monitor.stop()
    }
}
