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

// --- OPTIONAL: local CPU context-fixer LLM (llama.cpp), independent of the Whisper model ---
// Loads the GGUF on the CPU and runs canned noisy transcripts through the full LocalLLMCorrector
// path (RAG retrieval → grammar-constrained JSON → guardrails), asserting the JSON parses and
// numbers are preserved. Opt-in via ATC_LLM_MODEL. Runs entirely off the ANE (n_gpu_layers = 0).
if let llmModel = env["ATC_LLM_MODEL"], !llmModel.isEmpty {
    print("--- local LLM context-fixer (CPU llama.cpp) ---")
    guard let llmEngine = makeLlamaEngine(modelPath: llmModel, nThreads: 2) else {
        die("failed to load LLM model at \(llmModel) (is llama.xcframework linked?)")
    }
    // Inline knowledge so the probe doesn't depend on app-bundle resources.
    let kb = ATCKnowledgeBase(
        airlineTelephony: ["DAL": "Delta", "SKW": "SkyWest", "AAL": "American"],
        spokenNamesByAirport: ["KJFK": ["Kennedy", "New York"]],
        spokenBaseByAirport: [:],
        phrasesByType: ["tower": ["cleared to land", "line up and wait", "contact ground"]],
        spellingByType: ["tower": ["niner", "fife", "squawk"]],
        phonetic: [:], digits: [:])
    let retriever = ATCKnowledgeRetriever(kb: kb, config: nil, feedKey: "tower")
    let corrector = LocalLLMCorrector(engine: llmEngine, knowledge: kb, feedKey: "tower")
    let cases = [
        "delta eight ninety runway runway three four left",            // repetition loop
        "skywest fifty six seventy contact kenedy tower",              // misheard facility
        "american twelve thirty four cleared to land one seven center",// already clean
    ]
    for text in cases {
        let retrieved = retriever.retrieve(transcript: text, history: [])
        let t0 = Date()
        let c = await corrector.correct(text: text, history: [], retrieved: retrieved)
        let ms = Date().timeIntervalSince(t0) * 1000
        print(String(format: "LLM %.0fms  [%@] -> %@", ms, text, c.display))
        if text.filter(\.isNumber) != c.display.filter(\.isNumber) {
            die("LLM guardrail FAILED — digits changed: \(text) -> \(c.display)")
        }
    }
    print("LLM mode OK")
    if env["ATC_MODEL_DIR"] == nil { exit(0) }   // LLM-only run when no Whisper model is set
}

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

    // --- BB1: decoder callsign-biasing HALLUCINATION check (opt-in ATC_BB1=1) --------------------
    // Decodes each captured live transmission with NO callsign hint vs an ADVERSARIAL hint (callsigns
    // that are almost certainly NOT in the audio). If the adversarial hint makes the model EMIT those
    // callsigns, decoder biasing is unsafe; if the two transcripts match, it's safe. Needs ATC_STREAM_URL.
    if env["ATC_BB1"] == "1" {
        print("=== BB1 callsign-biasing hallucination check ===")
        let tr = ATCTranscriber(modelFolder: modelDir, cpuOnly: false)
        try await tr.load()
        let kb = ATCKnowledgeBase(
            airlineTelephony: ["JBU": "JetBlue", "AAL": "American", "DAL": "Delta", "UAL": "United",
                               "SWA": "Southwest", "FDX": "FedEx", "RPA": "Brickyard", "EDV": "Endeavor"],
            spokenNamesByAirport: [:], spokenBaseByAirport: [:], phrasesByType: [:], spellingByType: [:],
            phonetic: ["N": "November", "Z": "Zulu"], digits: [:])
        func ctx(_ vocab: [String]) -> ATCContext {
            let c = ATCContext(knowledge: kb)
            if !vocab.isEmpty { c.setTraffic(block: "traffic", vocab: vocab, expiry: Date().addingTimeInterval(3600), epoch: 1) }
            return c
        }
        let noneP = ctx([]).buildPrompt()
        let advVocab = ["UAL111", "SWA222", "FDX333", "N999ZZ"]
        let advP = ctx(advVocab).buildPrompt()
        let advSpoken = advVocab.map { ATCContext.spokenCallsign($0, knowledge: kb) }
        print("adversarial hint: \(advSpoken.joined(separator: " | "))")

        var pcm: [Float] = []
        if let urlRaw = env["ATC_STREAM_URL"], !urlRaw.isEmpty {
            let secs = Double(env["ATC_STREAM_SECONDS"] ?? "") ?? 120
            let resolved = (try? StreamURLResolver.resolve(streamURL: urlRaw)) ?? urlRaw
            print("--- live capture \(Int(secs))s: \(resolved) ---")
            final class PCM: @unchecked Sendable { let lock = NSLock(); var buf: [Float] = []; func add(_ c: [Float]) { lock.lock(); buf += c; lock.unlock() } }
            let acc = PCM()
            if let url = URL(string: resolved) {
                let src = StreamAudioSource(url: url)
                let t = Task { for await c in src.makeStream() { acc.add(c) } }
                try? await Task.sleep(nanoseconds: UInt64(secs * 1_000_000_000))
                src.stop(); _ = await t.value
            }
            pcm = acc.buf
        }
        print("captured \(pcm.count / 16_000)s")
        guard pcm.count > 16_000 else { die("BB1: no stream audio captured") }
        // Light preset (matches the shipped internet-feed path).
        let pp = AudioPreprocessor.lightCompressed()
        let seg = VADSegmenter(config: VADConfig())
        var segs = seg.feed(pcm); segs += seg.flush()
        let advWords: Set<String> = ["united", "southwest", "fedex", "november"]
        var leaks = 0
        print("--- \(segs.count) transmissions: NONE vs ADVERSARIAL hint ---")
        for (i, s) in segs.enumerated() {
            let a = pp.preprocess(s.audio)
            let none = (try? await tr.transcribe(a, context: noneP)) ?? .empty
            let adv = (try? await tr.transcribe(a, context: advP)) ?? .empty
            let nl = Set(none.text.lowercased().split(separator: " ").map(String.init))
            let al = Set(adv.text.lowercased().split(separator: " ").map(String.init))
            let newAdv = al.subtracting(nl).intersection(advWords)
            if !newAdv.isEmpty { leaks += 1 }
            print("SEG \(i)\(newAdv.isEmpty ? "" : "  ⚠️LEAK \(newAdv.sorted())")")
            print("   NONE: \(none.text)")
            print("   ADV : \(adv.text)")
        }
        print("BB1 RESULT: \(leaks)/\(segs.count) transmissions leaked an adversarial callsign (0 = biasing is safe)")
        exit(0)
    }

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

    // --- confidence gate: real avgLogprob per clip + what the gate decides (threshold calibration) ---
    print("--- confidence gate (avgLogprob / compression -> decision) ---")
    let gctx = ATCContext()   // no facility config in the probe → ASR signals dominate
    var outs: [(file: String, out: TranscriptionOutput)] = []
    for clip in clips {
        let out = (try? await transcriber.transcribe(clip.audio)) ?? .empty
        if !out.text.isEmpty { outs.append((clip.file, out)) }
    }
    for sensitivity in [GateSensitivity.conservative, .balanced, .aggressive] {
        let gate = ConfidenceGate(sensitivity: sensitivity)
        var refine = 0, skip = 0
        for (file, out) in outs {
            let d = gate.assess(text: out.text, retrieved: gctx.retrieveKnowledge(for: out.text),
                                asr: out.asr, inlineEdits: [])
            if d.shouldRefine { refine += 1 } else { skip += 1 }
            if sensitivity == .conservative {
                print(String(format: "GATE %@  avgLogprob=%.3f compression=%.2f -> %@ (%@)",
                             file, out.asr.avgLogprob, out.asr.compressionRatio,
                             d.shouldRefine ? "REFINE" : "skip", d.reason))
            }
        }
        print("GATE[\(sensitivity.rawValue)]: refine=\(refine) skip=\(skip)")
    }

    // --- OPTIONAL: live LiveATC stream → VAD → preprocess → context → ANE transcribe ---
    // Validates the StreamAudioSource live-decode path (serial-queue concurrency + edge-server
    // candidate failover + stop/teardown) end-to-end on the real Neural Engine. Opt-in via
    // ATC_STREAM_URL so the default probe stays offline/deterministic; ATC_STREAM_SECONDS
    // bounds the capture window.
    if let streamURLRaw = env["ATC_STREAM_URL"], !streamURLRaw.isEmpty {
        let seconds = Double(env["ATC_STREAM_SECONDS"] ?? "") ?? 75
        let resolved = (try? StreamURLResolver.resolve(streamURL: streamURLRaw)) ?? streamURLRaw
        print("--- live stream (StreamAudioSource → VAD → ANE) for \(Int(seconds))s ---")
        print("   url: \(resolved)")
        guard let streamURL = URL(string: resolved) else { die("bad stream URL: \(resolved)") }

        let streamContext = ATCContext()
        let streamPipeline = LivePipeline(transcriber: transcriber, context: streamContext,
                                          preprocessor: AudioPreprocessor(aggressiveRadio: true),
                                          corrector: NullCorrector())
        let streamSource = StreamAudioSource(url: streamURL)
        let streamCollector = Collector()
        let streamTask = Task { await streamPipeline.run(source: streamSource) { streamCollector.add($0) } }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        streamSource.stop()                 // exercises the rewritten stop()/teardown path
        await streamPipeline.stop()
        _ = await streamTask.value
        for r in streamCollector.records {
            print(String(format: "STREAM [%.1f-%.1fs] rtf=%.2f transcribe=%.0fms  %@",
                         r.streamStartS, r.streamEndS, r.realTimeFactor, r.transcribeMs, r.display))
        }
        print("STREAM: \(streamCollector.records.count) transmissions transcribed in \(Int(seconds))s")
    }

    print("PROBE OK")
} catch {
    die("probe error: \(error)")
}
