import Foundation
import Combine

/// Status lifecycle the UI renders on the "Stream" pill (port of session.py's states).
enum SessionStatus: String, Sendable {
    case idle, starting, connecting, live, stopping, stopped, error
}

/// Observable wrapper around `LivePipeline` for SwiftUI: status lifecycle, rolling
/// transcript records, and latency stats. Swift port of
/// `server/session.py:TranscriptionSession`, adapted to `ObservableObject`. One run at
/// a time; `start` is a no-op while a run is active.
@MainActor
final class TranscriptionSession: ObservableObject {
    @Published private(set) var status: SessionStatus = .idle
    @Published private(set) var detail = "No stream running."
    @Published private(set) var records: [TranscriptRecord] = []
    @Published private(set) var stats = LatencyStats()
    @Published private(set) var sourceLabel = ""
    @Published private(set) var errorMessage: String?
    /// Live input audio level (0…1) for the UI meter. 0 when idle.
    @Published private(set) var inputLevel: Float = 0
    /// True while a transmission is being transcribed (the slow step). Lets the UI show "Transcribing…"
    /// so a slow model reads as working, not stalled.
    @Published private(set) var transcribing = false
    /// When the current transcribe began — drives the elapsed timer on the "Transcribing…" indicator.
    @Published private(set) var transcribeStartedAt: Date?

    private let pipeline: LivePipeline
    private var source: AudioSource?
    private var task: Task<Void, Never>?
    private let maxRecords = 500

    init(pipeline: LivePipeline) { self.pipeline = pipeline }

    var isRunning: Bool {
        status == .starting || status == .connecting || status == .live || status == .stopping
    }

    /// Start a run. `clearHistory: false` keeps the existing transcript/stats (used when resuming
    /// from standby or switching model) so the accumulated console isn't wiped.
    func start(source: AudioSource, label: String, clearHistory: Bool = true) {
        guard !isRunning else { return }
        if clearHistory { records = []; stats = LatencyStats() }
        errorMessage = nil
        status = .live
        detail = "Transcribing."
        sourceLabel = label
        self.source = source

        task = Task { [pipeline] in
            await pipeline.run(source: source) { [weak self] record in
                Task { @MainActor in self?.append(record) }
            } onRefined: { [weak self] id, outcome in
                Task { @MainActor in self?.applyRefinement(id: id, outcome: outcome) }
            } onLevel: { [weak self] level in
                Task { @MainActor in self?.updateInputLevel(level) }
            } onActivity: { [weak self] on in
                Task { @MainActor in self?.setTranscribing(on) }
            }
            await MainActor.run {
                // The source ended on its own (clips drained / feed disconnected). Release the
                // audio session so a finished run doesn't keep the app awake in the background.
                if self.status == .live {
                    self.status = .stopped; self.detail = "Stream ended."
                    AudioSessionManager.deactivate()
                }
                self.inputLevel = 0
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        status = .stopping
        detail = "Stopping..."
        source?.stop()
        let pipeline = self.pipeline
        Task { await pipeline.stop() }
        task?.cancel()
        status = .stopped
        detail = "Stopped."
        inputLevel = 0
        transcribing = false; transcribeStartedAt = nil
        AudioSessionManager.deactivate()   // release the session on an explicit stop too
    }

    /// Reflect the pipeline's transcribe activity (signalled per transmission). Ignored once stopped so
    /// a late callback can't leave a stuck "Transcribing…".
    private func setTranscribing(_ on: Bool) {
        guard isRunning else { transcribing = false; transcribeStartedAt = nil; return }
        transcribing = on
        transcribeStartedAt = on ? Date() : nil
    }

    /// Seed the transcript/stats from a prior session (used when switching model rebuilds the
    /// session) so the visible console survives the swap. Call before binding `$records`/`$stats`.
    func adopt(records: [TranscriptRecord], stats: LatencyStats) {
        self.records = records
        self.stats = stats
    }

    /// Swap the fast inline-correction stage at runtime (Settings toggle). Safe to call while
    /// a run is active; it takes effect on the next transmission.
    func setCorrector(_ corrector: Corrector) {
        let pipeline = self.pipeline
        Task { await pipeline.setCorrector(corrector) }
    }

    /// Swap the slow-tier LLM backend at runtime (Settings backend picker). nil disables
    /// background refinement. Safe while a run is active.
    func setLLM(_ llm: LLMCorrector?) {
        let pipeline = self.pipeline
        Task { await pipeline.setLLM(llm) }
    }

    /// Update the LLM confidence gate at runtime (Settings toggle + sensitivity). Safe while a
    /// run is active; takes effect on the next transmission.
    func setGate(enabled: Bool, sensitivity: GateSensitivity) {
        let pipeline = self.pipeline
        Task { await pipeline.setGate(enabled: enabled, sensitivity: sensitivity) }
    }

    /// Update the squelch (Settings) at runtime — auto noise-floor learning vs a fixed manual
    /// threshold. Safe while a run is active; takes effect on the next frame.
    func setSquelch(auto: Bool, level: Float, calibratedGateRMS: Float? = nil) {
        let pipeline = self.pipeline
        Task { await pipeline.setSquelch(auto: auto, level: level, calibratedGateRMS: calibratedGateRMS) }
    }

    /// Toggle speaker diarization (Settings) at runtime. Takes effect on the next segment.
    func setDiarization(_ on: Bool) {
        let pipeline = self.pipeline
        Task { await pipeline.setDiarization(on) }
    }

    /// Push the filed flight plan into the live correction context (Electronic Flight Bag). Safe
    /// while a run is active; takes effect on the next transmission.
    func setFlightPlanContext(block: String, vocab: [String]) {
        let pipeline = self.pipeline
        Task { await pipeline.setFlightPlanContext(block: block, vocab: vocab) }
    }

    /// Push fresh in-range ADS-B traffic into the live correction context (with its read-site
    /// expiry/epoch). Safe while a run is active; takes effect on the next transmission.
    func setTrafficContext(block: String, vocab: [String], expiry: Date, epoch: Int) {
        let pipeline = self.pipeline
        Task { await pipeline.setTrafficContext(block: block, vocab: vocab, expiry: expiry, epoch: epoch) }
    }
    func clearTrafficContext(epoch: Int) {
        let pipeline = self.pipeline
        Task { await pipeline.clearTrafficContext(epoch: epoch) }
    }

    /// Apply a background-refinement outcome to the matching record (updates the `@Published`
    /// array element so the UI flips "refining…" → refined text). No-op if the record is gone.
    private func applyRefinement(id: UUID, outcome: RefinementOutcome) {
        guard let idx = records.firstIndex(where: { $0.id == id }) else { return }
        records[idx] = records[idx].applying(outcome)
    }

    /// Reset the rolling transcript + stats (the Clear button). Resets the session's own
    /// source-of-truth so a UI bound to `$records`/`$stats` clears too — and the next
    /// transmission appends to the now-empty buffers rather than resurrecting old records.
    func clear() {
        records = []
        stats = LatencyStats()
    }

    /// Quantize the meter level to the 7 bars the UI actually shows and only republish on a step
    /// change. A steady or silent feed then stops re-rendering the console (the meter fires every
    /// audio chunk — ~12×/s on mic — so unthrottled it would churn the UI even during silence).
    private func updateInputLevel(_ level: Float) {
        let stepped = (level * 7).rounded() / 7
        if stepped != inputLevel { inputLevel = stepped }
    }

    private func append(_ record: TranscriptRecord) {
        // Ignore records that arrive after the user stopped (or before a run starts). An
        // in-flight transcription can still complete and call back after stop() set a
        // terminal state; without this guard it would resurrect status to .live and append
        // a stray record. (Python drains the worker thread in stop(); we guard instead.)
        guard status == .live || status == .starting || status == .connecting else { return }
        records.append(record)
        if records.count > maxRecords { records.removeFirst(records.count - maxRecords) }
        stats.add(record)
        status = .live
        detail = "Transcribing."
    }
}
