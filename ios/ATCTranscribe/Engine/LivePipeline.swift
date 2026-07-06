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
    /// The canonical callsign this transmission is about (airline "American 1234" or GA "N345AB"),
    /// extracted from the transcript — the key that groups one aircraft's conversation. nil if none.
    var callsign: String? = nil
    /// The ICAO / registration key for `callsign` ("AAL1234" / "N345AB"). The live in-range badge is
    /// derived at RENDER time by testing this against the current ADS-B snapshot, so it tracks the
    /// feed (rather than freezing whatever was true at the instant the line was decoded).
    var callsignKey: String? = nil

    /// What the UI shows: the LLM-refined text if present, else the inline-corrected text, else
    /// the raw transcript.
    var display: String {
        if !llmCorrected.isEmpty { return llmCorrected }
        return corrected.isEmpty ? text : corrected
    }

    /// `display` canonicalized for on-screen rendering — runway designators and numbers in
    /// spoken/radio form ("4R" → "4 right", "125.9" → "1 2 5 point 9"). Used ONLY by the
    /// transcript UI; `display` (raw) still feeds CallsignExtractor and the rest of the pipeline,
    /// so structured extraction is unaffected. Validated to cut WER ~9 pts on the US gold set.
    var normalizedDisplay: String { ATCNormalize.normalize(display) }

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
    private let transcriber: any Transcribing
    private let context: ATCContext
    private var preprocessor: AudioPreprocessor?
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
    /// Airport grounding for SlotSnap, resolved through the provider chain (curated → bundled →
    /// internet) and cached per facility — the lookup is a dictionary hit after first load, and
    /// the network fallback must never run per-transmission.
    private let airportStore = AirportContextStore()
    private var airportCtxCache: (ident: String, data: AirportContextData?)?
    private var gateEnabled = true

    /// Shared session speaker clustering — ONE instance feeds both the streaming speaker-aware
    /// segmenter and the post-hoc diarizer, so they number the same voice identically.
    private let speakerModel: SpeakerModel
    /// Heuristic speaker diarization: splits a VAD segment into per-speaker pieces (separate lines).
    /// Also the labeling AUTHORITY — it re-splits even a streaming-tagged segment (a clean single-
    /// speaker cut returns one piece), so a streaming false-split can never surface as mislabeled lines.
    private let diarizer: Diarizer
    private var diarizationEnabled = true

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()

    init(transcriber: any Transcribing,
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
        self.diarizationEnabled = diarizationEnabled
        let sm = SpeakerModel()
        self.speakerModel = sm
        self.diarizer = Diarizer(speaker: sm)
        // Streaming speaker-change segmentation is on exactly when diarization is (they share `sm`).
        self.segmenter = VADSegmenter(config: vadConfig, speakerAware: diarizationEnabled, speaker: sm)
        self.refiner = llm.map { LLMRefiner(corrector: $0) }
        self.gateEnabled = gateEnabled
        self.gate.sensitivity = gateSensitivity
    }

    /// Toggle diarization at runtime (Settings). Also flips the segmenter's streaming speaker-change
    /// mode 1:1. Takes effect on the next segment.
    func setDiarization(_ on: Bool) { diarizationEnabled = on; segmenter.setSpeakerAware(on) }

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
        var inlineCorrected = correction.changed ? correction.corrected : ""
        var inlineEdits = correction.changed ? correction.edits : []

        // Deterministic snap stages (see python-legacy/docs/PIPELINE.md): ground the transcript
        // in the live traffic list (CallsignSnap) and the facility's real runways + published
        // frequencies (SlotSnap, via the curated→bundled→internet provider chain). Text changes
        // only on a confident unique snap; the verdicts drive aircraft attribution, the
        // confidence gate, and the LLM grounding block.
        let snapInput = inlineCorrected.isEmpty ? text : inlineCorrected
        let csCandidates = context.snapCallsignCandidates()
        let (csText, csResult) = CallsignSnap.snapTranscript(
            snapInput, candidates: csCandidates,
            telephony: CallsignSnap.telephonyWords(context.knowledge))
        let airportCtx = await airportContext(for: context.airportIdent)
        let (slotText, slotEdits) = SlotSnap.apply(csText, context: airportCtx)
        let grounding = SnapGrounding(callsign: csResult, slots: slotEdits,
                                      airportIdent: airportCtx?.ident,
                                      airportRunways: airportCtx?.runways ?? [])
        if csResult.applied || slotEdits.contains(where: { $0.applied }) {
            inlineCorrected = slotText
            inlineEdits += grounding.correctionEdits
        }

        // QW2: seed the rolling decoder-prompt history with the CORRECTED form (not raw Whisper output),
        // AFTER the drop-check — so a mishear that the corrector fixed (or a hallucination it dropped)
        // can't prime the same error into the next transmission. The corrector above saw only PRIOR
        // history (this update runs after it reads `recentHistory`).
        context.update(inlineCorrected.isEmpty ? text : inlineCorrected)

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
            corrections: inlineEdits,
            timestamp: Self.timeFormatter.string(from: Date()))
        record.speaker = speaker
        // Extract the canonical callsign this transmission addresses (the key that groups the
        // aircraft's conversation). ATTRIBUTION is gated by the snap verdict when a live candidate
        // list existed: an unverified callsign still displays as heard, but is not attributed to
        // an aircraft (the falseCS → 2% channel). With no list (offline/stale traffic) the
        // pre-snap behavior is preserved — extraction attributes ungated.
        if let cs = CallsignExtractor.extract(record.display, knowledge: context.knowledge) {
            record.callsign = cs.display
            if csCandidates.isEmpty || grounding.callsignAttributable {
                record.callsignKey = cs.icaoKey
            }
        }

        // Slow tier: hand the best-so-far text to the background LLM, OFF the hot path. The RAG
        // context is retrieved HERE, on the actor, so the refiner never touches mutable state. The
        // confidence gate first decides whether this transmission is even worth the LLM — snap
        // verdicts count as gate signals, and the grounding block rides into the LLM prompt +
        // the validator's runway veto (the PR #5 "LLM-layer augmentation").
        if let refiner {
            let baseText = inlineCorrected.isEmpty ? text : inlineCorrected
            var retrieved = context.retrieveKnowledge(for: baseText)
            retrieved.snapGrounding = grounding
            let groundingBlock = grounding.promptBlock
            if !groundingBlock.isEmpty {
                retrieved.block += (retrieved.block.isEmpty ? "" : "\n") + groundingBlock
            }
            let decision = gate.assess(text: baseText, retrieved: retrieved, asr: asr,
                                       inlineEdits: inlineEdits,
                                       snapReasons: grounding.gateReasons)
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

    /// The active facility's grounding data, memoized per ident (nil ident → nil context; the
    /// snap stages then run verdict-free and never edit).
    private func airportContext(for ident: String?) async -> AirportContextData? {
        guard let ident, !ident.isEmpty else { return nil }
        if let cached = airportCtxCache, cached.ident == ident { return cached.data }
        let data = await airportStore.airport(ident)
        airportCtxCache = (ident, data)
        return data
    }

    /// Drive a live source: chunks → VAD → `process`, delivering each record via `onRecord` and
    /// each later background-LLM refinement via `onRefined`. Runs until the source ends or
    /// `stop()`. Port of the run loop, plus the decoupled refinement fan-out.
    func run(source: AudioSource,
             onRecord: @escaping @Sendable (TranscriptRecord) -> Void,
             onRefined: @escaping @Sendable (UUID, RefinementOutcome) -> Void = { _, _ in },
             onLevel: (@Sendable (Float) -> Void)? = nil,
             onActivity: (@Sendable (Bool) -> Void)? = nil) async {
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
                await emit(segment, onRecord: onRecord, onActivity: onActivity)
            }
        }
        // Drain any turn the streaming path parked waiting for a next speaker that never came (and any
        // open plain segment), so the last transmission of a feed is never dropped on stream-end/stop.
        for segment in segmenter.flush() {
            await emit(segment, onRecord: onRecord, onActivity: onActivity)
        }
        running = false
        onActivity?(false)
        if lastLevel != 0 { onLevel?(0) }
    }

    /// Turn one segmenter output into record(s). With diarization on, the diarizer (the labeling
    /// AUTHORITY) splits it into per-speaker pieces — re-splitting even a streaming-tagged segment; a
    /// clean single-speaker cut returns one piece — and each is transcribed onto its own line. With it
    /// off, the whole segment is transcribed. `onActivity` brackets the (slow) transcribe so the UI can
    /// show it's working on a transmission, not stalled.
    private func emit(_ segment: SpeechSegment,
                      onRecord: @escaping @Sendable (TranscriptRecord) -> Void,
                      onActivity: (@Sendable (Bool) -> Void)?) async {
        onActivity?(true)
        if diarizationEnabled {
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
        onActivity?(false)
    }

    /// RMS of a chunk mapped to a perceptual 0…1 meter level. Floors near the noise level and
    /// scales by a ~50 dB window so quiet radio still registers without pinning to full.
    private static func level(_ chunk: [Float]) -> Float {
        guard !chunk.isEmpty else { return 0 }
        let rms = (chunk.reduce(0) { $0 + $1 * $1 } / Float(chunk.count)).squareRoot()
        let db = 20 * log10(max(rms, 1e-7))            // ~ -140 (silence) … 0 (full scale)
        return max(0, min(1, (db + 50) / 50))          // -50 dB → 0, 0 dB → 1
    }

    func stop() async {
        running = false
        await refiner?.cancel()   // drop queued background LLM work so it doesn't keep cooking on Stop/standby
    }

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
    func setSquelch(auto: Bool, level: Float, calibratedGateRMS: Float? = nil) {
        segmenter.setSquelch(auto: auto, level: level, calibratedGateRMS: calibratedGateRMS)
    }

    /// Swap the audio preprocessor at runtime (source-dependent preset). Takes effect on the next
    /// segment; the internet feed uses a lighter preset than clean wideband radio (see AppModel).
    func setPreprocessor(_ p: AudioPreprocessor?) { preprocessor = p }

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
