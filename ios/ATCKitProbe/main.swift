import Foundation

/// Native macOS probe (command-line tool). Runs the WER self-checks and an on-ANE
/// proof-of-life through the engine, prints results, and exits 0 on success / 1 on
/// failure. Built as a plain executable so it runs headless over SSH on the M4 — unlike
/// macOS XCTest, whose test-runner daemon needs a GUI session.
///
///   ATC_MODEL_DIR=<converted model folder> ATC_AUDIO_DIR=<diagnostic_data> ./ATCKitProbe
///
/// The engine/transcriber/audio sources are compiled directly into this tool (project.yml).

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
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
    die("WER mismatch: \"\(c.ref)\" | \"\(c.hyp)\" = \(WER.rate(reference: c.ref, hypothesis: c.hyp)), want \(c.want)")
}
print("WER self-checks: OK (\(werCases.count) cases)")

// --- proof-of-life on the real Neural Engine ---
let env = ProcessInfo.processInfo.environment
guard let modelDir = env["ATC_MODEL_DIR"], !modelDir.isEmpty,
      let audioDir = env["ATC_AUDIO_DIR"], !audioDir.isEmpty else {
    print("WER OK. Set ATC_MODEL_DIR + ATC_AUDIO_DIR to also run the proof-of-life.")
    exit(0)
}

do {
    struct Manifest: Decodable {
        struct Snip: Decodable { let file: String; let reference: String }
        let snippets: [Snip]
    }
    let manifestURL = URL(fileURLWithPath: (audioDir as NSString).appendingPathComponent("manifest.json"))
    let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
    let clips = try manifest.snippets.map { snip in
        DiagnosticClip(file: snip.file, reference: snip.reference,
                       audio: try AudioFile.load16kMono(path: (audioDir as NSString).appendingPathComponent(snip.file)))
    }
    guard !clips.isEmpty else { die("no diagnostic clips found at \(audioDir)") }

    // Real ANE on macOS → cpuOnly: false. Single model → non-adaptive.
    let engine = TranscriberEngine(models: ["small": modelDir], defaultModel: "small",
                                   fallbackModel: "small", adaptive: false, cpuOnly: false)
    let pol = await engine.proofOfLife(clips: clips, maxSnippets: clips.count)

    for s in pol.snippets {
        print(String(format: "POL %@  wer=%.3f  %.2fs audio / %.2fs proc\n   ref: %@\n   got: %@",
                     s.file, s.wer, s.audioSeconds, s.seconds, s.reference, s.hypothesis))
    }
    let mean = pol.meanWER.map { String(format: "%.3f", $0) } ?? "-"
    let rtf = pol.realtimeSpeed.map { String(format: "%.2f", $0) } ?? "-"
    print("POL summary: passed=\(pol.passed) meanWER=\(mean) realtime=\(rtf)x model=\(pol.activeModel ?? "-")")

    if let err = pol.error { die("proof-of-life error: \(err)") }
    if !pol.passed { die("proof-of-life did NOT pass (mean WER > 0.5 or a clip produced nothing)") }
    print("PROBE OK")
} catch {
    die("probe error: \(error)")
}
