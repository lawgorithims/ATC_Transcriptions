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
            await pipeline.run(source: source) { record in
                Task { @MainActor in self.append(record) }
            }
            await MainActor.run {
                if self.status == .live { self.status = .stopped; self.detail = "Stream ended." }
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
    }

    /// Swap the output-correction stage at runtime (Settings toggle). Safe to call while
    /// a run is active; it takes effect on the next transmission.
    func setCorrector(_ corrector: Corrector) {
        let pipeline = self.pipeline
        Task { await pipeline.setCorrector(corrector) }
    }

    private func append(_ record: TranscriptRecord) {
        records.append(record)
        if records.count > maxRecords { records.removeFirst(records.count - maxRecords) }
        stats.add(record)
        status = .live
        detail = "Transcribing."
    }
}
