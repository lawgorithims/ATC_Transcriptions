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

    private let pipeline: LivePipeline
    private var source: AudioSource?
    private var task: Task<Void, Never>?
    private let maxRecords = 500

    init(pipeline: LivePipeline) { self.pipeline = pipeline }

    var isRunning: Bool {
        status == .starting || status == .connecting || status == .live || status == .stopping
    }

    func start(source: AudioSource, label: String) {
        guard !isRunning else { return }
        records = []
        stats = LatencyStats()
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
            }
            await MainActor.run {
                if self.status == .live { self.status = .stopped; self.detail = "Stream ended." }
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
    func setSquelch(auto: Bool, level: Float) {
        let pipeline = self.pipeline
        Task { await pipeline.setSquelch(auto: auto, level: level) }
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
