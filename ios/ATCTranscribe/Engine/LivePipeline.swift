import Foundation

/// One transcribed transmission with its latency metrics. Swift port of
/// `live_atc_pipeline.LatencyRecord`. `text` is always the raw Whisper output;
/// `corrected`/`corrections` ride along when the optional correction layer changed it.
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

    /// What the UI shows: corrected text when present, else the raw transcript.
    var display: String { corrected.isEmpty ? text : corrected }
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
    private let corrector: Corrector
    private let segmenter: VADSegmenter
    private var running = false

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()

    init(transcriber: ATCTranscriber,
         context: ATCContext,
         preprocessor: AudioPreprocessor? = nil,
         corrector: Corrector = NullCorrector(),
         vadConfig: VADConfig = VADConfig()) {
        self.transcriber = transcriber
        self.context = context
        self.preprocessor = preprocessor
        self.corrector = corrector
        self.segmenter = VADSegmenter(config: vadConfig)
    }

    /// Transcribe one speech segment into a record, or nil when nothing usable was
    /// decoded. Port of `_transcribe_segment`.
    func process(_ segment: SpeechSegment) async -> TranscriptRecord? {
        let prompt = context.buildPrompt()
        let audio = preprocessor?.preprocess(segment.audio) ?? segment.audio

        let t0 = Date()
        let raw = (try? await transcriber.transcribe(audio, context: prompt)) ?? ""
        let transcribeMs = Date().timeIntervalSince(t0) * 1000.0

        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // The transcriber already drops degenerate (repetition-loop) decodes, so any
        // non-empty result is clean enough to feed back into the rolling prompt history.
        context.update(text)

        let audioMs = Double(segment.audio.count) / 16000.0 * 1000.0
        let captureToTextMs = (Date().timeIntervalSince1970 - segment.finalizedWallTime) * 1000.0
        let rtf = audioMs > 0 ? transcribeMs / audioMs : 0.0

        // Final, output-only correction (NullCorrector by default — a no-op). Never
        // touches the prompt history updated above; `text` stays the raw output.
        let correction = corrector.correct(text, history: context.recentHistory)

        return TranscriptRecord(
            text: text,
            streamStartS: round1(segment.streamStartS),
            streamEndS: round1(segment.streamEndS),
            audioDurationMs: round1(audioMs),
            captureToTextMs: round1(captureToTextMs),
            transcribeMs: round1(transcribeMs),
            realTimeFactor: round3(rtf),
            prompt: prompt,
            corrected: correction.changed ? correction.corrected : "",
            corrections: correction.changed ? correction.edits : [],
            timestamp: Self.timeFormatter.string(from: Date()))
    }

    /// Drive a live source: chunks → VAD → `process`, delivering each record via
    /// `onRecord`. Runs until the source ends or `stop()`. Port of the run loop.
    func run(source: AudioSource, onRecord: @escaping @Sendable (TranscriptRecord) -> Void) async {
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
}
