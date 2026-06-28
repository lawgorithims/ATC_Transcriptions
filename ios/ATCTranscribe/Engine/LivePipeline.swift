import Foundation

/// Where a record sits in the two-tier correction flow. The fast inline (`corrected`) tier is
/// always done by the time a record is emitted; the slow LLM (`llmCorrected`) tier lands later.
enum RefinementState: String, Sendable {
    case none             // no LLM stage active for this record
    case skippedConfident // the confidence gate judged it clean — the LLM was not run
    case pending          // queued for / awaiting the background LLM
    case refined          // the LLM produced a change (`llmCorrected`/`llmEdits` populated)
    case clean            // the LLM ran and made no change
    case skipped          // dropped under load before it could run
}

/// One transcribed transmission with its latency metrics. Swift port of
/// `live_atc_pipeline.LatencyRecord`. `text` is always the raw Whisper output;
/// `corrected`/`corrections` carry the fast inline (deterministic) fix; `llmCorrected`/
/// `llmEdits` carry the later background-LLM refinement (see `RefinementState`).
struct TranscriptRecord: Sendable, Identifiable {
    let id = UUID()
    let text: String
    let streamStartS: Double
    let streamEndS: Double
    let audioDurationMs: Double
    let captureToTextMs: Double
    let transcribeMs: Double
    let realTimeFactor: Double
    let prompt: String
    let corrected: String
    let corrections: [CorrectionEdit]
    let timestamp: String
    var refinementState: RefinementState = .none
    var llmCorrected: String = ""
    var llmEdits: [CorrectionEdit] = []
    /// Wall-clock the background AI fixer spent on this transmission (0 until it runs).
    var llmMs: Double = 0
    /// Why the confidence gate skipped (or would run) the LLM — shown when `.skippedConfident`.
    var gateReason: String = ""
    /// Diarization speaker id (0-based), or nil when diarization is off. Stable across the session.
    var speaker: Int? = nil
    /// The in-range ADS-B aircraft this transmission appears to be about — a callsign / N-number
    /// matched against the live feed — or nil. Set only from a FRESH traffic snapshot.
    var adsbCallsign: String? = nil

    /// What the UI shows: the LLM-refined text if present, else the inline-corrected text, else
    /// the raw transcript.
    var display: String {
        if !llmCorrected.isEmpty { return llmCorrected }
        return corrected.isEmpty ? text : corrected
    }

    /// All edits to surface, fast inline tier first then the LLM's.
    var allEdits: [CorrectionEdit] { corrections + llmEdits }

    /// A copy updated with a background-refinement outcome (preserves `id`).
    func applying(_ outcome: RefinementOutcome) -> TranscriptRecord {
        var copy = self
        switch outcome {
        case .refined(let c, let ms):
            copy.refinementState = .refined
            copy.llmCorrected = c.corrected
            copy.llmEdits = c.edits
            copy.llmMs = round1(ms)
        case .clean(let ms):
            copy.refinementState = .clean
            copy.llmMs = round1(ms)
        case .skipped:
            copy.refinementState = (copy.refinementState == .pending) ? .skipped : copy.refinementState
        }
        return copy
    }
}

/// Rolling latency stats. Port of `live_atc_pipeline.LatencyStats` (+ `_percentile`).
struct LatencyStats: Sendable {
    struct Summary: Sendable { let mean, p50, p95, min, max: Double }

    private(set) var count = 0
    private var captureToText: [Double] = []
    private var transcribe: [Double] = []
    private var rtf: [Double] = []

    mutating func add(_ r: TranscriptRecord) {
        count += 1
        captureToText.append(r.captureToTextMs)
        transcribe.append(r.transcribeMs)
        rtf.append(r.realTimeFactor)
    }

    var captureToTextSummary: Summary? { Self.summarize(captureToText) }
    var transcribeSummary: Summary? { Self.summarize(transcribe) }
    var realTimeFactorSummary: Summary? { Self.summarize(rtf) }

    private static func summarize(_ values: [Double]) -> Summary? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        func pct(_ p: Double) -> Double {
            let idx = Int((p / 100.0 * Double(sorted.count - 1)).rounded())
            return sorted[Swift.min(Swift.max(idx, 0), sorted.count - 1)]
        }
        let mean = values.reduce(0, +) / Double(values.count)
        return Summary(mean: round1(mean), p50: round1(pct(50)), p95: round1(pct(95)),
                       min: round1(sorted.first!), max: round1(sorted.last!))
    }
}

private func round1(_ x: Double) -> Double { (x * 10).rounded() / 10 }
private func round3(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }

/// Orchestrates one transmission end to end: VAD segment → preprocess → context prompt
/// → transcribe → (history update) → optional correction → `TranscriptRecord`. Swift
/// port of `LiveATCPipeline._transcribe_segment` + the capture→VAD→transcribe loop.
/// Source-agnostic: drive it with any `AudioSource` (file replay, mic, LiveATC stream).
actor LivePipeline {
    private let transcriber: ATCTranscriber
    private let context: ATCContext
    private let preprocessor: AudioPreprocessor?
    private var corrector: Corrector
    private let segmenter: VADSegmenter
    private var running = false

    /// Slow-tier background LLM refiner (nil when no LLM backend is selected).
    private var refiner: LLMRefiner?
    /// Where refinement outcomes are delivered (set for the duration of `run`).
    private var onRefined: (@Sendable (UUID, RefinementOutcome) -> Void)?
    /// Confidence gate: decides whether a transmission is worth the LLM. When `gateEnabled` is
    /// false the LLM runs on every (≥1-word) transmission (the gate is bypassed).
    private var gate = ConfidenceGate()
    private var gateEnabled = true

    /// Heuristic speaker diarization: splits a VAD segment into per-speaker pieces (separate lines).
    private let diarizer = Diarizer()
    private var diarizationEnabled = true

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()

    init(transcriber: ATCTranscriber,
         context: ATCContext,
         preprocessor: AudioPreprocessor? = nil,
         corrector: Corrector = NullCorrector(),
         llm: LLMCorrector? = nil,
         gateEnabled: Bool = true,
         gateSensitivity: GateSensitivity = .conservative,
         diarizationEnabled: Bool = true,
         vadConfig: VADConfig = VADConfig()) {
        self.transcriber = transcriber
        self.context = context
        self.preprocessor = preprocessor
        self.corrector = corrector
        self.segmenter = VADSegmenter(config: vadConfig)
        self.refiner = llm.map { LLMRefiner(corrector: $0) }
        self.gateEnabled = gateEnabled
        self.gate.sensitivity = gateSensitivity
        self.diarizationEnabled = diarizationEnabled
    }

    /// Toggle diarization at runtime (Settings). Takes effect on the next segment.
    func setDiarization(_ on: Bool) { diarizationEnabled = on }

    /// Transcribe one speech segment into a record, or nil when nothing usable was
    /// decoded. `speaker` tags the record with a diarization speaker id. Port of `_transcribe_segment`.
    func process(_ segment: SpeechSegment, speaker: Int? = nil) async -> TranscriptRecord? {
        let prompt = context.buildPrompt()
        let audio = preprocessor?.preprocess(segment.audio) ?? segment.audio

        let t0 = Date()
        let out = (try? await transcriber.transcribe(audio, context: prompt)) ?? .empty
        let transcribeMs = Date().timeIntervalSince(t0) * 1000.0

        let text = out.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let asr = out.asr

        // The transcriber already drops degenerate (repetition-loop) decodes, so any
        // non-empty result is clean enough to feed back into the rolling prompt history.
        context.update(text)

        let audioMs = Double(segment.audio.count) / 16000.0 * 1000.0
        let captureToTextMs = (Date().timeIntervalSince1970 - segment.finalizedWallTime) * 1000.0
        let rtf = audioMs > 0 ? transcribeMs / audioMs : 0.0

        // Fast inline tier (NullCorrector by default — a no-op): repetition collapse +
        // deterministic vocab/number fixes. Instant, never blocks. `text` stays the raw output.
        let correction = await corrector.correct(text, history: context.recentHistory)
        // Drop a wholly-hallucinated transmission: the corrector removed everything (e.g. pure
        // static decoded as a phantom phrase), so there's nothing real to show.
        if correction.changed, correction.corrected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return nil
        }
        let inlineCorrected = correction.changed ? correction.corrected : ""

        var record = TranscriptRecord(
            text: text,
            streamStartS: round1(segment.streamStartS),
            streamEndS: round1(segment.streamEndS),
            audioDurationMs: round1(audioMs),
            captureToTextMs: round1(captureToTextMs),
            transcribeMs: round1(transcribeMs),
            realTimeFactor: round3(rtf),
            prompt: prompt,
            corrected: inlineCorrected,
            corrections: correction.changed ? correction.edits : [],
            timestamp: Self.timeFormatter.string(from: Date()))
        record.speaker = speaker
        // Tag the transmission with the in-range aircraft it appears to address (live ADS-B), when a
        // callsign / N-number token matches a fresh snapshot. Honest: fires when the spoken form
        // resolves to a real label; full phonetic callsign linking is a later enhancement.
        record.adsbCallsign = context.matchTraffic(in: record.display)

        // Slow tier: hand the best-so-far text to the background LLM, OFF the hot path. The RAG
        // context is retrieved HERE, on the actor, so the refiner never touches mutable state. The
        // confidence gate first decides whether this transmission is even worth the LLM.
        if let refiner {
            let baseText = inlineCorrected.isEmpty ? text : inlineCorrected
            let retrieved = context.retrieveKnowledge(for: baseText)
            let decision = gate.assess(text: baseText, retrieved: retrieved, asr: asr,
                                       inlineEdits: correction.changed ? correction.edits : [])
            record.gateReason = decision.reason
            if !gateEnabled || decision.shouldRefine {
                record.refinementState = .pending
                await refiner.enqueue(RefinementRequest(id: record.id, text: baseText,
                                                        history: context.recentHistory, retrieved: retrieved))
            } else {
                record.refinementState = .skippedConfident
            }
        }
        return record
    }

    /// Drive a live source: chunks → VAD → `process`, delivering each record via `onRecord` and
    /// each later background-LLM refinement via `onRefined`. Runs until the source ends or
    /// `stop()`. Port of the run loop, plus the decoupled refinement fan-out.
    func run(source: AudioSource,
             onRecord: @escaping @Sendable (TranscriptRecord) -> Void,
             onRefined: @escaping @Sendable (UUID, RefinementOutcome) -> Void = { _, _ in },
             onLevel: (@Sendable (Float) -> Void)? = nil) async {
        self.onRefined = onRefined
        await refiner?.setOutcomeHandler(onRefined)
        running = true
        // Cheap input-level meter (source-agnostic: mic, USB, stream, replay). Quantize to the 7
        // bars the UI shows and only fire on a step change, so a steady/silent feed dispatches no
        // per-chunk main-actor work — just the meter, not the transcriber, gates here.
        var lastLevel: Float = -1
        for await chunk in source.makeStream() {
            if !running { break }
            if let onLevel {
                let stepped = (Self.level(chunk) * 7).rounded() / 7
                if stepped != lastLevel { lastLevel = stepped; onLevel(stepped) }
            }
            for segment in segmenter.feed(chunk) {
                if diarizationEnabled {
                    // Split the segment into per-speaker pieces (back-to-back ATC↔aircraft
                    // transmissions the VAD merged) and transcribe each onto its own line.
                    for piece in diarizer.diarize(segment.audio) {
                        let startS = segment.streamStartS + Double(piece.startSample) / 16000.0
                        let sub = SpeechSegment(audio: piece.audio, streamStartS: startS,
                                                streamEndS: startS + Double(piece.audio.count) / 16000.0,
                                                finalizedWallTime: segment.finalizedWallTime)
                        if let record = await process(sub, speaker: piece.speaker) { onRecord(record) }
                    }
                } else if let record = await process(segment) {
                    onRecord(record)
                }
            }
        }
        running = false
        if lastLevel != 0 { onLevel?(0) }
    }

    /// RMS of a chunk mapped to a perceptual 0…1 meter level. Floors near the noise level and
    /// scales by a ~50 dB window so quiet radio still registers without pinning to full.
    private static func level(_ chunk: [Float]) -> Float {
        guard !chunk.isEmpty else { return 0 }
        let rms = (chunk.reduce(0) { $0 + $1 * $1 } / Float(chunk.count)).squareRoot()
        let db = 20 * log10(max(rms, 1e-7))            // ~ -140 (silence) … 0 (full scale)
        return max(0, min(1, (db + 50) / 50))          // -50 dB → 0, 0 dB → 1
    }

    func stop() { running = false }

    /// Swap the fast inline correction stage at runtime (the Settings toggle). Takes effect on
    /// the next transmission; the in-flight one finishes with the previous corrector.
    func setCorrector(_ corrector: Corrector) { self.corrector = corrector }

    /// Swap the slow-tier LLM backend at runtime (Settings backend picker). A nil corrector
    /// disables background refinement. In-flight refinements on the previous backend are dropped.
    func setLLM(_ llm: LLMCorrector?) async {
        guard let llm else { refiner = nil; return }
        let r = LLMRefiner(corrector: llm)
        if let onRefined { await r.setOutcomeHandler(onRefined) }
        refiner = r
    }

    /// Update the confidence gate at runtime (Settings toggle + sensitivity). `enabled == false`
    /// bypasses the gate so the LLM runs on every transmission. Takes effect on the next one.
    func setGate(enabled: Bool, sensitivity: GateSensitivity) {
        gateEnabled = enabled
        gate.sensitivity = sensitivity
    }

    /// Update the squelch (Settings) at runtime. Auto re-learns the channel noise floor; manual
    /// uses a fixed threshold. Takes effect on the next audio frame.
    func setSquelch(auto: Bool, level: Float) { segmenter.setSquelch(auto: auto, level: level) }

    /// Inject the filed flight plan into the LLM correction context (Electronic Flight Bag). An
    /// empty block clears it. Takes effect on the next transmission.
    func setFlightPlanContext(block: String, vocab: [String]) {
        context.setFlightPlan(block: block, vocab: vocab)
    }

    /// Inject the fresh in-range ADS-B traffic into the LLM correction context, with its read-site
    /// `expiry` and `epoch`. Takes effect on the next transmission.
    func setTrafficContext(block: String, vocab: [String], expiry: Date, epoch: Int) {
        context.setTraffic(block: block, vocab: vocab, expiry: expiry, epoch: epoch)
    }
    func clearTrafficContext(epoch: Int) { context.clearTraffic(epoch: epoch) }
}
