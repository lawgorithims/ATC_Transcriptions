import Foundation

/// Native macOS probe (command-line tool). Runs the WER self-checks, an on-ANE
/// proof-of-life through the engine, and the full live pipeline (file-replay → VAD →
/// preprocess → context → transcribe) — printing results and exiting 0/1. Built as a
/// plain executable so it runs headless over SSH on the M4, unlike macOS XCTest.
///
///   ATC_MODEL_DIR=<converted model folder> ATC_AUDIO_DIR=<diagnostic_data> ./ATCKitProbe

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

/// Thread-safe record collector for the pipeline's @Sendable onRecord callback.
final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var records: [TranscriptRecord] = []
    func add(_ r: TranscriptRecord) { lock.lock(); records.append(r); lock.unlock() }
}

// --- WER self-checks (vs server/engine.py:_word_error_rate) ---
let werCases: [(ref: String, hyp: String, want: Double)] = [
    ("one six right cleared to land Rex Sixty One Thirty Four",
     "one six right cleared to land direct sixty one thirty four", 1.0 / 11.0),
    ("the tower cleared for takeoff", "tower cleared for takeoff", 0.0),
    ("thank you QNH is one zero two three", "thank you qnh is one zero two three", 0.0),
    ("roger", "", 1.0),
    ("hotel echo xray", "hotel echo x-ray", 0.0),
]
for c in werCases where abs(WER.rate(reference: c.ref, hypothesis: c.hyp) - c.want) > 1e-6 {
    die("WER mismatch: \"\(c.ref)\" | \"\(c.hyp)\"")
}
print("WER self-checks: OK (\(werCases.count) cases)")

let env = ProcessInfo.processInfo.environment
guard let modelDir = env["ATC_MODEL_DIR"], !modelDir.isEmpty,
      let audioDir = env["ATC_AUDIO_DIR"], !audioDir.isEmpty else {
    print("WER OK. Set ATC_MODEL_DIR + ATC_AUDIO_DIR to also run the proof-of-life + pipeline.")
    exit(0)
}

struct Manifest: Decodable {
    struct Snip: Decodable { let file: String; let reference: String }
    let snippets: [Snip]
}

do {
    let manifestURL = URL(fileURLWithPath: (audioDir as NSString).appendingPathComponent("manifest.json"))
    let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
    let clips = try manifest.snippets.map { snip in
        DiagnosticClip(file: snip.file, reference: snip.reference,
                       audio: try AudioFile.load16kMono(path: (audioDir as NSString).appendingPathComponent(snip.file)))
    }
    guard !clips.isEmpty else { die("no diagnostic clips found at \(audioDir)") }

    // --- proof-of-life on the real Neural Engine (real ANE → cpuOnly: false) ---
    let engine = TranscriberEngine(models: ["small": modelDir], defaultModel: "small",
                                   fallbackModel: "small", adaptive: false, cpuOnly: false)
    let pol = await engine.proofOfLife(clips: clips, maxSnippets: clips.count)
    for s in pol.snippets {
        print(String(format: "POL %@  wer=%.3f  %.2fs audio / %.2fs proc", s.file, s.wer, s.audioSeconds, s.seconds))
    }
    let mean = pol.meanWER.map { String(format: "%.3f", $0) } ?? "-"
    let rtf = pol.realtimeSpeed.map { String(format: "%.2f", $0) } ?? "-"
    print("POL summary: passed=\(pol.passed) meanWER=\(mean) realtime=\(rtf)x model=\(pol.activeModel ?? "-")")
    if let err = pol.error { die("proof-of-life error: \(err)") }
    if !pol.passed { die("proof-of-life did NOT pass") }

    // --- full live pipeline: file-replay → VAD → preprocess → context → transcribe ---
    print("--- live pipeline (source → VAD → pipeline) ---")
    let transcriber = ATCTranscriber(modelFolder: modelDir, cpuOnly: false)
    try await transcriber.load()
    let pipeline = LivePipeline(transcriber: transcriber, context: ATCContext(),
                                preprocessor: AudioPreprocessor(aggressiveRadio: true), corrector: NullCorrector())

    // Synthetic feed: each clip + 1 s silence so the energy VAD finalizes a segment.
    var feed: [Float] = []
    let silence = [Float](repeating: 0, count: 16_000)
    for clip in clips { feed += clip.audio; feed += silence }

    let collector = Collector()
    await pipeline.run(source: ArrayAudioSource(feed, chunkSamples: 8000, realtime: false)) { collector.add($0) }

    var stats = LatencyStats()
    for r in collector.records {
        print(String(format: "PIPE [%.1f–%.1fs] rtf=%.2f transcribe=%.0fms  %@",
                     r.streamStartS, r.streamEndS, r.realTimeFactor, r.transcribeMs, r.display))
        stats.add(r)
    }
    let p50 = stats.realTimeFactorSummary.map { String(format: "%.2f", $0.p50) } ?? "-"
    print("PIPELINE: \(collector.records.count) transmissions, RTF p50=\(p50)")
    if collector.records.isEmpty { die("pipeline produced no transmissions") }

    print("PROBE OK")
} catch {
    die("probe error: \(error)")
}
