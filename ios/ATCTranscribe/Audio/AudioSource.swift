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
///
/// RESILIENCE (H1 remediation): iOS stops the engine on any audio-session interruption (Siri, an
/// alarm, a call banner, a route change) and never restarts it — previously the stream stayed open
/// delivering nothing while the UI looked live. This source now observes the session notifications
/// (classified by the pure `AudioSessionEvent`), restarts the engine with bounded retries, and runs
/// a repeating liveness watchdog (the input tap fires ~12×/s even in silence, so a stalled buffer
/// counter means a dead route — never a quiet user). Two channels: `onFailure` is TERMINAL (the
/// owner flips to .error and deactivates); `onNotice` is transient (detail line only, still live).
final class DeviceAudioSource: AudioSource {
    private let preferUSB: Bool
    /// Called (off the main actor) if capture can't start / can't recover — terminal.
    private let onFailure: (@Sendable (String) -> Void)?
    /// Transient notices (interruption began / capture resumed) — the run stays live.
    private let onNotice: (@Sendable (String) -> Void)?
    // Shared state is touched from the pipeline executor (makeStream), the MainActor (stop),
    // notification handlers, and recovery tasks — guard it all with one lock.
    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var watchdog: Task<Void, Never>?
    private var continuation: AsyncStream<[Float]>.Continuation?
    private var observers: [NSObjectProtocol] = []
    private var recovery: Task<Void, Never>?      // single-flight restart
    private var interrupted = false               // between interruption .began and recovery
    private var totalRestarts = 0                 // per-session cap across all events
    /// Buffers delivered by the tap — the liveness signal (monotonic; watchdog compares).
    private let buffersSeen = OSAllocatedUnfairLock(initialState: 0)

    private static let maxAttemptsPerEvent = 3
    private static let maxRestartsPerSession = 10
    private static let livenessPeriodNs: UInt64 = 5_000_000_000
    private static let maxLivenessChecks = 17_280   // 24 h at 5 s — bounds the watchdog loop (rule 2)

    init(preferUSB: Bool = false,
         onFailure: (@Sendable (String) -> Void)? = nil,
         onNotice: (@Sendable (String) -> Void)? = nil) {
        self.preferUSB = preferUSB
        self.onFailure = onFailure
        self.onNotice = onNotice
    }

    func makeStream() -> AsyncStream<[Float]> {
        AsyncStream { continuation in
            lock.lock(); self.continuation = continuation; lock.unlock()
            // Build the engine HERE — after AppModel.start() has activated the .playAndRecord
            // session — so the input node binds to a live record route (see startEngine).
            if let problem = startEngine() {
                onFailure?(problem)
                lock.lock(); self.continuation = nil; lock.unlock()
                continuation.finish(); return
            }
            installObservers()
            startWatchdog()
            continuation.onTermination = { [weak self] _ in self?.stop() }
        }
    }

    /// (Re)build and start the engine, tearing down any prior one first. Returns nil on success or
    /// a user-facing problem description (the CALLER decides whether it is terminal — recovery
    /// retries must not spam `onFailure` per attempt). Queries the input format FRESH each time: a
    /// route change means a new format/converter, never reuse the old.
    private func startEngine() -> String? {
        lock.lock()
        let old = engine; engine = nil
        let continuation = self.continuation
        lock.unlock()
        old?.inputNode.removeTap(onBus: 0)
        if old?.isRunning == true { old?.stop() }
        guard let continuation else { return "Capture already stopped." }   // stop() won the race

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        // A zero sample rate / channel count means there's no usable input (e.g. mic permission
        // not granted, or no input route) — surface it rather than finishing silently.
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: 16000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            return "No audio input available. Check the microphone is connected and permitted."
        }

        let buffersSeen = self.buffersSeen
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            buffersSeen.withLock { $0 += 1 }   // liveness signal — fires even on silence
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
            input.removeTap(onBus: 0)
            return "Microphone failed to start: \(error.localizedDescription)"
        }
        lock.lock(); self.engine = engine; lock.unlock()
        return nil
    }

    // MARK: - Session-event handling (H1)

    private func installObservers() {
        #if os(iOS)
        let nc = NotificationCenter.default
        let names: [Notification.Name] = [AVAudioSession.interruptionNotification,
                                          AVAudioSession.routeChangeNotification,
                                          AVAudioSession.mediaServicesWereResetNotification]
        var added: [NSObjectProtocol] = []
        added.reserveCapacity(names.count)
        for name in names {   // fixed 3-element bound (rule 2)
            let object: Any? = (name == AVAudioSession.mediaServicesWereResetNotification)
                ? nil : AVAudioSession.sharedInstance()
            added.append(nc.addObserver(forName: name, object: object, queue: nil) { [weak self] note in
                self?.handle(AudioSessionEvent.classify(name: note.name, userInfo: note.userInfo))
            })
        }
        lock.lock(); observers = added; lock.unlock()
        #endif
    }

    private func handle(_ event: AudioSessionEvent) {
        switch event {
        case .interruptionBegan:
            // iOS has already stopped the engine — tear it down cleanly and mark the pause so the
            // liveness watchdog defers (the interruption path owns recovery from here).
            lock.lock()
            interrupted = true
            let e = engine; engine = nil
            lock.unlock()
            e?.inputNode.removeTap(onBus: 0)
            if e?.isRunning == true { e?.stop() }
            onNotice?("Audio paused by another app — resuming when it finishes.")
        case .interruptionEnded:
            // Attempt a restart regardless of shouldResume: the app's whole purpose is capture the
            // user explicitly started. If iOS refuses (call still active), the bounded retries fail
            // and the honest terminal message tells the user to press Start.
            scheduleRestart(reason: "an interruption")
        case .inputRouteLost:
            onNotice?(preferUSB ? "USB audio device disconnected — reconnecting the input."
                                : "Audio route changed — reconnecting the microphone.")
            scheduleRestart(reason: "a route change")
        case .mediaServicesReset:
            // Every audio handle we hold is invalid — full teardown, honest terminal state.
            onFailure?("The system audio service was reset. Press Start to resume.")
            stop()
        case .irrelevant:
            break
        }
    }

    /// Bounded, single-flight engine restart. Re-activates the session first (preserving the
    /// "engine built only after the session is active" invariant), then rebuilds the engine.
    private func scheduleRestart(reason: String) {
        lock.lock()
        guard continuation != nil, recovery == nil else { lock.unlock(); return }   // stopped / already recovering
        totalRestarts += 1
        let exhausted = totalRestarts > Self.maxRestartsPerSession
        let preferUSB = self.preferUSB
        let task = Task { [weak self] in
            guard !exhausted else {
                self?.onFailure?("Audio keeps dropping — press Start to retry.")
                self?.stop()
                return
            }
            var attempt = 0
            while attempt < Self.maxAttemptsPerEvent {   // loop bound: maxAttemptsPerEvent (rule 2)
                attempt += 1
                assert(attempt <= Self.maxAttemptsPerEvent, "restart loop exceeded its bound")
                try? await Task.sleep(nanoseconds: 500_000_000)
                if Task.isCancelled { return }
                guard let self else { return }
                AudioSessionManager.activate(recording: true, preferUSB: preferUSB)
                if self.startEngine() == nil {
                    self.lock.lock(); self.interrupted = false; self.recovery = nil; self.lock.unlock()
                    self.onNotice?("Microphone resumed.")
                    return
                }
            }
            guard let self else { return }
            self.lock.lock(); self.recovery = nil; self.lock.unlock()
            self.onFailure?("Audio didn't recover after \(reason). Press Start to retry.")
            self.stop()
        }
        recovery = task
        lock.unlock()
    }

    /// Repeating liveness watchdog. Preserves the original one-shot startup semantics (3.5 s grace,
    /// same message), then keeps checking: an unchanged buffer counter while not interrupted or
    /// recovering means the route died with NO notification (some USB unplugs post nothing usable) —
    /// schedule a restart. The tap fires ~12×/s even in a silent room, so this can never trip on a
    /// quiet user. Statically bounded (rule 2).
    private func startWatchdog() {
        let buffersSeen = self.buffersSeen
        let onFailure = self.onFailure
        let watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            if Task.isCancelled { return }   // stopped before the first buffer — not a failure
            if buffersSeen.withLock({ $0 }) == 0 {
                onFailure?("No audio from the microphone — it may be muted or used by another app.")
                return
            }
            var previous = buffersSeen.withLock { $0 }
            for i in 0..<Self.maxLivenessChecks {   // bounded: 24 h of checks (rule 2)
                assert(i < Self.maxLivenessChecks, "liveness loop bound")
                try? await Task.sleep(nanoseconds: Self.livenessPeriodNs)
                if Task.isCancelled { return }
                guard let self else { return }
                let seen = buffersSeen.withLock { $0 }
                self.lock.lock()
                let paused = self.interrupted || self.recovery != nil
                self.lock.unlock()
                if seen == previous, !paused { self.scheduleRestart(reason: "the audio went silent") }
                previous = seen
            }
        }
        lock.lock(); self.watchdog = watchdog; lock.unlock()
    }

    func stop() {
        // Atomically take ownership so a double stop() (MainActor Stop racing the stream's
        // onTermination) can't both tear down the same engine — and so any queued notification
        // handler no-ops afterwards (continuation == nil guards every restart path).
        lock.lock()
        let e = engine; engine = nil
        let w = watchdog; watchdog = nil
        let r = recovery; recovery = nil
        let obs = observers; observers = []
        let c = continuation; continuation = nil
        interrupted = false
        lock.unlock()
        w?.cancel()
        r?.cancel()
        for o in obs { NotificationCenter.default.removeObserver(o) }   // ≤3 (rule 2)
        e?.inputNode.removeTap(onBus: 0)
        if e?.isRunning == true { e?.stop() }
        c?.finish()
    }
}
