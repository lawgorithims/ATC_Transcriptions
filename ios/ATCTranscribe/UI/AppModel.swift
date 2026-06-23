import Foundation
import SwiftUI

/// Audio source choices in the UI's Source picker.
enum SourceKind: String, CaseIterable, Identifiable {
    case replay = "Replay demo"
    case mic = "Microphone"
    case stream = "LiveATC stream"
    var id: String { rawValue }
}

/// The view-model the console binds to: appearance, the audio source selection, the
/// rolling transcript + stats + status (mirrors `TranscriptionSession`), and the
/// proof-of-life result. Real pipeline wiring (model load → replay/mic) lands next; for
/// now it seeds representative sample data so the UI renders fully populated.
@MainActor
final class AppModel: ObservableObject {
    @Published var theme: AppTheme = .cockpit

    // Source controls
    @Published var source: SourceKind = .replay
    @Published var streamURL = ""
    @Published var airport = ""
    @Published var frequency = ""

    // Session state (mirrors TranscriptionSession's published state)
    @Published var status: SessionStatus = .idle
    @Published var detail = "Replay demo loaded — press Start."
    @Published var sourceLabel = "Replay demo"
    @Published var records: [TranscriptRecord] = []
    @Published var stats = LatencyStats()

    // Engine / device
    @Published var activeModel = "small"
    @Published var deviceLabel = "Neural Engine"
    @Published var measuredSpeed: Double? = 12.5
    @Published var minRealtimeSpeed: Double = 1.2

    // Proof of life
    @Published var proofOfLife: ProofOfLifeResult?
    @Published var polRunning = false

    // Sheets
    @Published var showSettings = false

    init() {
        // Initial theme can be forced for screenshots: `--theme night`.
        if let i = CommandLine.arguments.firstIndex(of: "--theme"),
           i + 1 < CommandLine.arguments.count,
           let t = AppTheme(rawValue: CommandLine.arguments[i + 1]) {
            theme = t
        }
        seedSampleData()
    }

    var palette: Palette { theme.palette }
    var isRunning: Bool { status == .live || status == .connecting || status == .starting }

    // Wired to the real TranscriptionSession in the next step.
    func start() { status = .live; detail = "Transcribing." }
    func stop() { status = .stopped; detail = "Stopped." }
    func clear() { records = []; stats = LatencyStats() }
    func runProofOfLife() { /* runs engine.proofOfLife once the model is wired */ }

    /// Representative state so the console renders fully populated for design + screenshots.
    private func seedSampleData() {
        let samples: [(String, String, Double, Double, Double, Double, [CorrectionEdit])] = [
            ("american twelve thirty four cleared to land runway one seven center", "14:32:04", 12.3, 16.0, 280, 0.08, []),
            ("delta eight ninety contact ground point niner", "14:32:19", 18.1, 21.2, 240, 0.09, [
                CorrectionEdit(from: "niner", to: "9", reason: "number", backend: "deterministic")]),
            ("skywest fifty six seventy turn left heading three four zero", "14:32:38", 24.0, 28.4, 360, 0.10, []),
            ("november three four five alpha bravo hold short runway one seven center", "14:33:01", 30.5, 35.1, 410, 0.11, []),
        ]
        records = samples.map { text, ts, s0, s1, trMs, rtf, edits in
            let display = edits.first.map { text.replacingOccurrences(of: $0.from, with: $0.to) } ?? ""
            return TranscriptRecord(
                text: text, streamStartS: s0, streamEndS: s1,
                audioDurationMs: (s1 - s0) * 1000, captureToTextMs: trMs + 140,
                transcribeMs: trMs, realTimeFactor: rtf,
                prompt: "Air traffic control radio transcript from KDFW Lone Star Approach. Runways: 17C, 35C.",
                corrected: edits.isEmpty ? "" : display, corrections: edits, timestamp: ts)
        }
        for r in records { stats.add(r) }
        status = .live
        detail = "Transcribing."
        proofOfLife = ProofOfLifeResult(
            passed: true, activeModel: "small", meanWER: 0.091, realtimeSpeed: 12.5,
            snippets: [], error: nil)
    }
}
