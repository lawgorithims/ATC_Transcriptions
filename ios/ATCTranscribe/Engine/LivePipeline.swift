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
    /// Why the confidence gate skipped (or would run) the LLM — shown when `.skippedConfident`.
    var gateReason: String = ""

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
        case .refined(let c):
            copy.refinementState = .refined
            copy.llmCorrected = c.corrected
            copy.llmEdits = c.edits
        case .clean:
            copy.refinementState = .clean
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
         vadConfig: VADConfig = VADConfig()) {
        self.transcriber = transcriber
        self.context = context
        self.preprocessor = preprocessor
        self.corrector = corrector
        self.segmenter = VADSegmenter(config: vadConfig)
        self.refiner = llm.map { LLMRefiner(corrector: $0) }
        self.gateEnabled = gateEnabled
        self.gate.sensitivity = gateSensitivity
    }

    /// Transcribe one speech segment into a record, or nil when nothing usable was
    /// decoded. Port of `_transcribe_segment`.
    func process(_ segment: SpeechSegment) async -> TranscriptRecord? {
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
             onRefined: @escaping @Sendable (UUID, RefinementOutcome) -> Void = { _, _ in }) async {
        self.onRefined = onRefined
        await refiner?.setOutcomeHandler(onRefined)
        running = true
        for await chunk in source.makeStream() {
            if !running { break }
            for segment in segmenter.feed(chunk) {
                if let record = await process(segment) { onRecord(record) }
            }
        }
        running = false
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
}
