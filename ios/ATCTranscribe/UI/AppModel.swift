import Foundation
import SwiftUI
import Combine

/// Audio source choices in the UI's Source picker.
enum SourceKind: String, CaseIterable, Identifiable {
    case liveFeed = "Internet live feed"
    case microphone = "Device microphone"
    case usbAudio = "USB audio"
    case replay = "Replay demo"
    var id: String { rawValue }
    /// Only the internet live feed needs a stream link + airport context entry.
    var needsLink: Bool { self == .liveFeed }
}

/// The view-model the console binds to. In **live** mode (launched with `--model-dir`)
/// it loads the converted model and drives a real `TranscriptionSession` — pressing
/// Start replays the bundled clips through the pipeline and live records appear. With no
/// model it falls back to **demo** mode (sample data) so the layout still renders.
///
/// Launch args (used for Simulator verification): `--theme <t>`, `--model-dir <path>`,
/// `--audio-dir <diagnostic_data>`, `--autostart`.
@MainActor
final class AppModel: ObservableObject {
    @Published var theme: AppTheme = .cockpit

    // Source controls
    @Published var source: SourceKind = .liveFeed
    @Published var streamURL = ""
    @Published var airport = ""
    @Published var frequency = "auto"

    // Session state (forwarded from TranscriptionSession in live mode)
    @Published var status: SessionStatus = .idle
    @Published var detail = "Replay demo — press Start."
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

    // Correction layer (off by default — port of the `correction:` config block).
    // `correctionEnabled` runs the deterministic vocab/number fixer; `llmEnabled` adds the
    // on-device Apple Foundation Models stage. Toggling either rebuilds the corrector and
    // hot-swaps it into the live session.
    @Published var correctionEnabled = false { didSet { rebuildCorrector() } }
    @Published var llmEnabled = false { didSet { rebuildCorrector() } }

    @Published var showSettings = false

    private var engine: TranscriberEngine?
    private var session: TranscriptionSession?
    private var clips: [DiagnosticClip] = []
    private var liveContext: ATCContext?
    private var liveMode = false

    init() {
        let args = CommandLine.arguments
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        if let t = value("--theme").flatMap(AppTheme.init(rawValue:)) { theme = t }
        switch value("--source") {
        case "live", "feed": source = .liveFeed
        case "mic": source = .microphone
        case "usb": source = .usbAudio
        case "replay": source = .replay
        default: break
        }
        if let link = value("--link") { streamURL = link }
        if args.contains("--correct") { correctionEnabled = true }
        if args.contains("--llm") { correctionEnabled = true; llmEnabled = true }

        #if targetEnvironment(simulator)
        deviceLabel = "CPU (Simulator)"
        let cpuOnly = true
        #else
        let cpuOnly = false
        #endif

        // Resolve the model + demo clips. Explicit launch flags (Simulator verification)
        // win; otherwise fall back to the copies bundled into the app — the shipping path,
        // since a TestFlight build on a device has no command line. With a bundled model
        // the app is fully functional on first launch; only a model-less build falls
        // through to the populated demo layout.
        let modelDir = value("--model-dir") ?? Self.bundledModelDir()
        let audioDir = value("--audio-dir") ?? Self.bundledDemoClipsDir()
        if let modelDir {
            liveMode = true
            records = []
            stats = LatencyStats()
            status = .idle
            detail = "Loading model…"
            // Default to the self-contained Replay demo when clips ship with the app, so a
            // fresh install transcribes on the first Start with no network or mic needed
            // (the picker can still switch to the live feed / mic). An explicit --source wins.
            if value("--source") == nil, audioDir != nil { source = .replay }
            let autostart = args.contains("--autostart")
            Task { await setupLive(modelDir: modelDir, audioDir: audioDir, cpuOnly: cpuOnly, autostart: autostart) }
        } else {
            seedSampleData()   // no model bundled — populated layout for design/screenshots
        }
    }

    var palette: Palette { theme.palette }
    var isRunning: Bool { status == .live || status == .connecting || status == .starting }

    // MARK: live wiring

    private func setupLive(modelDir: String, audioDir: String?, cpuOnly: Bool, autostart: Bool) async {
        let engine = TranscriberEngine(models: ["small": modelDir], defaultModel: "small",
                                       fallbackModel: "small", adaptive: false, cpuOnly: cpuOnly)
        let transcriber = ATCTranscriber(modelFolder: modelDir, cpuOnly: cpuOnly)
        do { try await transcriber.load() } catch {
            detail = "Model failed to load: \(error.localizedDescription)"
            return
        }
        let context = ATCContext()
        self.liveContext = context
        let pipeline = LivePipeline(transcriber: transcriber, context: context,
                                    preprocessor: AudioPreprocessor(aggressiveRadio: true),
                                    corrector: currentCorrector())
        let session = TranscriptionSession(pipeline: pipeline)
        session.$records.assign(to: &$records)   // mirror live session state into the UI
        session.$status.assign(to: &$status)
        session.$stats.assign(to: &$stats)
        self.session = session
        self.engine = engine
        self.activeModel = "small"

        if let audioDir { clips = (try? Self.loadClips(audioDir)) ?? [] }
        detail = clips.isEmpty ? "Model ready (no demo clips)." : "Ready — press Start."
        if autostart { start() }
    }

    // MARK: correction

    private var correctionConfig: CorrectionConfig {
        var c = CorrectionConfig()
        c.enabled = correctionEnabled
        c.llmEnabled = llmEnabled
        return c
    }

    /// Build a corrector from the current toggles + the live airport vocab: `NullCorrector`
    /// when off, the deterministic stage when only `correctionEnabled`, or deterministic +
    /// on-device LLM when `llmEnabled`.
    private func currentCorrector() -> Corrector {
        buildCorrector(config: correctionConfig, vocab: { [weak self] in self?.liveContext?.vocab() ?? [] })
    }

    /// Rebuild and hot-swap the corrector into the running session (a toggle changed).
    private func rebuildCorrector() {
        session?.setCorrector(currentCorrector())
    }

    // MARK: controls

    func start() {
        guard liveMode else {           // no model → design/screenshot demo
            status = .live; detail = "Transcribing (demo)."; return
        }
        guard let session else {        // live build whose model failed to load
            status = .error; detail = "Model unavailable — cannot start."; return
        }
        let src: AudioSource
        switch source {
        case .replay:
            guard !clips.isEmpty else { detail = "No demo clips available."; return }
            var feed: [Float] = []
            let silence = [Float](repeating: 0, count: 16_000)
            for c in clips { feed += c.audio; feed += silence }
            src = ArrayAudioSource(feed, chunkSamples: 8000, realtime: false)
        case .microphone:
            src = DeviceAudioSource(preferUSB: false)
        case .usbAudio:
            src = DeviceAudioSource(preferUSB: true)
        case .liveFeed:
            guard let resolved = try? StreamURLResolver.resolve(streamURL: streamURL.isEmpty ? nil : streamURL),
                  let url = URL(string: resolved) else {
                detail = "Enter a valid LiveATC link or stream URL."; return
            }
            src = StreamAudioSource(url: url)
        }
        session.start(source: src, label: source.rawValue)
        sourceLabel = source.rawValue
        detail = "Transcribing."
    }

    func stop() {
        if let session { session.stop() } else { status = .stopped }
        detail = "Stopped."
    }

    func clear() {
        // In live mode `records`/`stats` are driven by `session.$records`/`$stats` via
        // `assign(to:)`, so clearing the local copies alone is reverted on the next
        // transmission. Clear the session's source-of-truth instead (the binding then
        // propagates the empty state); fall back to a local reset only in demo mode.
        if let session {
            session.clear()
        } else {
            records = []
            stats = LatencyStats()
        }
    }

    func runProofOfLife() {
        guard let engine, !clips.isEmpty else { return }
        polRunning = true
        Task {
            let result = await engine.proofOfLife(clips: clips, maxSnippets: clips.count)
            self.proofOfLife = result
            if let s = result.realtimeSpeed { self.measuredSpeed = s }
            self.polRunning = false
        }
    }

    // MARK: bundled resources

    /// Locate the CoreML model shipped inside the app bundle. The converter writes the
    /// `.mlmodelc` set into a sanitized-id subfolder, so we search for the
    /// `AudioEncoder.mlmodelc` marker (the same file `TranscriberEngine.modelAvailable`
    /// checks) and return its parent — no need to hardcode the model id. The model dir is
    /// added to the app target as a `type: folder` reference in project.yml, so it lands at
    /// `<bundle>/Models/…`. Returns nil for a model-less (demo-only) build.
    static func bundledModelDir() -> String? {
        guard let root = Bundle.main.resourceURL?.appendingPathComponent("Models") else { return nil }
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path),
              let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in walker where url.lastPathComponent == "AudioEncoder.mlmodelc" {
            return url.deletingLastPathComponent().path
        }
        return nil
    }

    /// The bundled diagnostic-clips folder (`manifest.json` + wavs) for the Replay demo,
    /// or nil if not shipped. Also a `type: folder` reference → `<bundle>/DemoClips/`.
    static func bundledDemoClipsDir() -> String? {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("DemoClips") else { return nil }
        let manifest = dir.appendingPathComponent("manifest.json")
        return FileManager.default.fileExists(atPath: manifest.path) ? dir.path : nil
    }

    private static func loadClips(_ audioDir: String) throws -> [DiagnosticClip] {
        struct Manifest: Decodable { struct Snip: Decodable { let file: String; let reference: String }; let snippets: [Snip] }
        let url = URL(fileURLWithPath: (audioDir as NSString).appendingPathComponent("manifest.json"))
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
        return try manifest.snippets.map { s in
            DiagnosticClip(file: s.file, reference: s.reference,
                           audio: try AudioFile.load16kMono(path: (audioDir as NSString).appendingPathComponent(s.file)))
        }
    }

    // MARK: demo data

    private func seedSampleData() {
        let samples: [(String, String, Double, Double, Double, Double, [CorrectionEdit])] = [
            ("american twelve thirty four cleared to land runway one seven center", "14:32:04", 12.3, 16.0, 280, 0.08, []),
            ("delta eight ninety contact ground point niner", "14:32:19", 18.1, 21.2, 240, 0.09,
             [CorrectionEdit(from: "niner", to: "9", reason: "number", backend: "deterministic")]),
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
        proofOfLife = ProofOfLifeResult(passed: true, activeModel: "small", meanWER: 0.091,
                                        realtimeSpeed: 12.5, snippets: [], error: nil)
    }
}
