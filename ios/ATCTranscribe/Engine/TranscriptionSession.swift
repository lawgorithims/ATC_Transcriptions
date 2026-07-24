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
    /// Live input audio level (0…1) for the UI meter. 0 when idle.
    @Published private(set) var inputLevel: Float = 0
    /// True while a transmission is being transcribed (the slow step). Lets the UI show "Transcribing…"
    /// so a slow model reads as working, not stalled.
    @Published private(set) var transcribing = false
    /// When the current transcribe began — drives the elapsed timer on the "Transcribing…" indicator.
    @Published private(set) var transcribeStartedAt: Date?

    private let pipeline: LivePipeline
    private var source: AudioSource?
    private var task: Task<Void, Never>?
    private let maxRecords = 500
    /// Fuses each appended record's content role + acoustic cluster + callsign into its per-line
    /// `speakerLabel`, and retroactively relabels a speaker's unknown lines as its cluster matures.
    private let labeler = SpeakerLabeler()
    /// Opt-in append-only transcript log (nil unless the pilot enabled logging). Writes happen on the
    /// store actor, off this main actor.
    private var logStore: TranscriptLogStore?

    init(pipeline: LivePipeline) { self.pipeline = pipeline }

    var isRunning: Bool {
        status == .starting || status == .connecting || status == .live || status == .stopping
    }

    /// Start a run. `clearHistory: false` keeps the existing transcript/stats (used when resuming
    /// from standby or switching model) so the accumulated console isn't wiped. `onTrouble` receives
    /// transient pipeline notices (a failed decode, runaway noise) for the owner's detail line.
    func start(source: AudioSource, label: String, clearHistory: Bool = true,
               onTrouble: (@Sendable (String) -> Void)? = nil) {
        guard !isRunning else { return }
        if clearHistory { records = []; stats = LatencyStats(); labeler.reset() }
        errorMessage = nil
        status = .live
        detail = "Transcribing."
        sourceLabel = label
        self.source = source

        task = Task { [pipeline] in
            await pipeline.run(source: source) { [weak self] record in
                // Sequential await: the pipeline emits records one at a time and each append
                // COMPLETES on the main actor before the next emit — FIFO order, and run()
                // cannot return (and flip status below) until every append has landed, so the
                // final drained record can never be dropped on a natural stream end.
                await MainActor.run { self?.append(record) }
            } onRefined: { [weak self] id, outcome in
                Task { @MainActor in self?.applyRefinement(id: id, outcome: outcome) }
            } onLevel: { [weak self] level in
                Task { @MainActor in self?.updateInputLevel(level) }
            } onActivity: { [weak self] on in
                Task { @MainActor in self?.setTranscribing(on) }
            } onTrouble: { [weak self] msg in
                Task { @MainActor in self?.noteTrouble(msg, forward: onTrouble) }
            }
            await MainActor.run {
                // The source ended on its own (clips drained / feed disconnected). Release the
                // audio session so a finished run doesn't keep the app awake in the background.
                // This runs only after the run loop's flush drain fully delivered (see onRecord).
                if self.status == .live {
                    self.status = .stopped; self.detail = "Stream ended."
                    AudioSessionManager.deactivate()
                }
                self.inputLevel = 0
                if let store = self.logStore { Task { await store.close() } }   // flush the log on a natural end
            }
        }
    }

    /// Transient trouble from the pipeline: count it (diag card) + surface it on the detail line.
    /// Status stays `.live` — the stream is healthy; one transmission failed. Ignored once stopped.
    private func noteTrouble(_ msg: String, forward: (@Sendable (String) -> Void)?) {
        guard isRunning else { return }
        if msg == LivePipeline.decodeFailureNotice { stats.addDecodeFailure() }
        detail = msg
        forward?(msg)
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
        inputLevel = 0
        transcribing = false; transcribeStartedAt = nil
        AudioSessionManager.deactivate()   // release the session on an explicit stop too
        if let logStore { Task { await logStore.close() } }   // flush the log on an explicit stop
    }

    /// Reflect the pipeline's transcribe activity (signalled per transmission). Ignored once stopped so
    /// a late callback can't leave a stuck "Transcribing…".
    private func setTranscribing(_ on: Bool) {
        guard isRunning else { transcribing = false; transcribeStartedAt = nil; return }
        transcribing = on
        transcribeStartedAt = on ? Date() : nil
    }

    /// Seed the transcript/stats from a prior session (used when switching model rebuilds the
    /// session) so the visible console survives the swap. Call before binding `$records`/`$stats`.
    func adopt(records: [TranscriptRecord], stats: LatencyStats) {
        self.records = records
        self.stats = stats
        labeler.rebuild(from: records)   // restore cluster tallies so relabeling stays consistent
    }

    /// Swap the fast inline-correction stage at runtime (Settings toggle). Safe to call while
    /// a run is active; it takes effect on the next transmission.
    func setCorrector(_ corrector: Corrector) {
        let pipeline = self.pipeline
        Task { await pipeline.setCorrector(corrector) }
    }

    /// Swap the slow-tier LLM backend at runtime (Settings backend picker). nil disables
    /// background refinement. Safe while a run is active.
    func setLLM(_ llm: LLMCorrector?) {
        let pipeline = self.pipeline
        Task { await pipeline.setLLM(llm) }
    }

    /// Update the LLM confidence gate at runtime (Settings toggle + sensitivity). Safe while a
    /// run is active; takes effect on the next transmission.
    func setGate(enabled: Bool, sensitivity: GateSensitivity) {
        let pipeline = self.pipeline
        Task { await pipeline.setGate(enabled: enabled, sensitivity: sensitivity) }
    }

    /// Update the squelch (Settings) at runtime — auto noise-floor learning vs a fixed manual
    /// threshold. Safe while a run is active; takes effect on the next frame.
    func setSquelch(auto: Bool, level: Float, calibratedGateRMS: Float? = nil) {
        let pipeline = self.pipeline
        Task { await pipeline.setSquelch(auto: auto, level: level, calibratedGateRMS: calibratedGateRMS) }
    }

    /// Swap the audio preprocessor at runtime (source-dependent preset). Safe while stopped/before a
    /// run; takes effect on the next segment.
    func setPreprocessor(_ p: AudioPreprocessor?) {
        let pipeline = self.pipeline
        Task { await pipeline.setPreprocessor(p) }
    }

    /// Toggle speaker diarization (Settings) at runtime. Takes effect on the next segment.
    func setDiarization(_ on: Bool) {
        let pipeline = self.pipeline
        Task { await pipeline.setDiarization(on) }
    }

    /// Toggle the experimental acoustic fill (Settings): when on, an unknown-content line may be
    /// labeled from its voice cluster (see `SpeakerLabeler.acousticFillEnabled`). Off by default —
    /// on-device voice separation is unreliable on single-feed radio. Re-fuses EVERY retained line so
    /// the change applies to already-appended records: turning it OFF retracts prior voice-inferred
    /// labels back to their honest content label; turning it ON applies mature-cluster fills.
    func setAcousticFill(_ on: Bool) {
        guard labeler.acousticFillEnabled != on else { return }
        labeler.acousticFillEnabled = on
        refuseAll()
    }

    /// Set the backend-scaled fill-distance ceiling on the labeler (MFCC vs ECAPA scale); called at
    /// session build once the active speaker backend is known, BEFORE `setAcousticFill`.
    func setFillDistance(_ d: Float) { labeler.maxFillDistance = d }

    /// Inject (or clear, with nil) the opt-in transcript log store. Set at session build from the model,
    /// and torn down when the pilot disables logging.
    func setLogStore(_ store: TranscriptLogStore?) { logStore = store }

    /// Re-fuse every retained record in place (bounded by `maxRecords`), writing each back one-by-one so
    /// SwiftUI diffs per row. Used when the acoustic-fill toggle flips so the change is reflected on
    /// already-shown lines, not just future ones.
    private func refuseAll() {
        assert(records.count <= maxRecords, "records must stay within the cap")
        for i in records.indices {
            var u = records[i]
            labeler.refuse(&u)
            records[i] = u
        }
    }

    /// Push the filed flight plan into the live correction context (Electronic Flight Bag). Safe
    /// while a run is active; takes effect on the next transmission.
    func setFlightPlanContext(block: String, vocab: [String]) {
        let pipeline = self.pipeline
        Task { await pipeline.setFlightPlanContext(block: block, vocab: vocab) }
    }

    /// Push the ownship callsign + next waypoint into the live DECODE prompt (gap C). Safe while a run is
    /// active; takes effect on the next transmission.
    func setOwnshipContext(callsign: String, nextWaypoint: String) {
        let pipeline = self.pipeline
        Task { await pipeline.setOwnshipContext(callsign: callsign, nextWaypoint: nextWaypoint) }
    }

    /// Push the filed route's PLATE priming (chart frequencies/fixes) into the live decode + correction
    /// context. Safe while a run is active; takes effect on the next transmission.
    func setPlatePriming(promptLine: String, block: String) {
        let pipeline = self.pipeline
        Task { await pipeline.setPlatePriming(promptLine: promptLine, block: block) }
    }

    /// Push fresh in-range ADS-B traffic into the live correction context (with its read-site
    /// expiry/epoch). Safe while a run is active; takes effect on the next transmission.
    func setTrafficContext(block: String, vocab: [String], expiry: Date, epoch: Int) {
        let pipeline = self.pipeline
        Task { await pipeline.setTrafficContext(block: block, vocab: vocab, expiry: expiry, epoch: epoch) }
    }
    func clearTrafficContext(epoch: Int) {
        let pipeline = self.pipeline
        Task { await pipeline.clearTrafficContext(epoch: epoch) }
    }

    /// Push the GPS-vicinity grounding (in-cockpit sources) into the live correction context: the nearest
    /// airport grounds deterministic SlotSnap, the vicinity union feeds the LLM/Whisper procedures. Safe
    /// while a run is active; takes effect on the next transmission.
    func setGroundingAirports(hard: AirportContextData?, soft: [AirportContextData]) {
        let pipeline = self.pipeline
        Task { await pipeline.setGroundingAirports(hard: hard, soft: soft) }
    }
    /// Leave vicinity mode (LiveATC feed / replay / stop) — SlotSnap returns to the typed airport.
    func clearGroundingAirports() {
        let pipeline = self.pipeline
        Task { await pipeline.clearGroundingAirports() }
    }

    /// Apply a background-refinement outcome to the matching record (updates the `@Published`
    /// array element so the UI flips "refining…" → refined text). No-op if the record is gone.
    private func applyRefinement(id: UUID, outcome: RefinementOutcome) {
        guard let idx = records.firstIndex(where: { $0.id == id }) else { return }
        records[idx] = records[idx].applying(outcome)
        if let logStore {   // a second "refine" line, joined to the record line by id
            let entry = TranscriptLogEntry.refine(from: records[idx])
            Task { await logStore.log(entry) }
        }
    }

    /// Reset the rolling transcript + stats (the Clear button). Resets the session's own
    /// source-of-truth so a UI bound to `$records`/`$stats` clears too — and the next
    /// transmission appends to the now-empty buffers rather than resurrecting old records.
    func clear() {
        records = []
        stats = LatencyStats()
        labeler.reset()
    }

    /// Quantize the meter level to the 7 bars the UI actually shows and only republish on a step
    /// change. A steady or silent feed then stops re-rendering the console (the meter fires every
    /// audio chunk — ~12×/s on mic — so unthrottled it would churn the UI even during silence).
    private func updateInputLevel(_ level: Float) {
        let stepped = (level * 7).rounded() / 7
        if stepped != inputLevel { inputLevel = stepped }
    }

    private func append(_ record: TranscriptRecord) {
        // Ignore records that arrive after the user stopped (or before a run starts). An
        // in-flight transcription can still complete and call back after stop() set a
        // terminal state; without this guard it would resurrect status to .live and append
        // a stray record. (Python drains the worker thread in stop(); we guard instead.)
        // A NATURAL stream end never hits this guard: run() awaits each append inline, so the
        // terminal status flip happens only after the flush drain's records have all landed.
        guard status == .live || status == .starting || status == .connecting else { return }
        var rec = record
        let flipped = labeler.ingest(&rec)   // fuse this line; get the speaker whose affinity changed
        records.append(rec)
        // Bounded FIFO by removeFirst — O(records.count) per append at the cap, ~µs at 500 and
        // dwarfed by the @Published full-array republish any structure would pay. A ring buffer
        // was considered and rejected: it changes `records`' array semantics for every consumer
        // (SwiftUI diffing, the AppModel mirror, the EFB sink, applyRefinement's firstIndex)
        // for no visible win.
        if records.count > maxRecords { records.removeFirst(records.count - maxRecords) }
        // The cluster matured/flipped → re-fuse its still-unknown lines. Only unknown-content lines
        // can change (a confident role is immutable), and we write each back the SAME way
        // `applyRefinement` does (a one-element `records[i] = …`) so SwiftUI diffs a single row.
        if let spk = flipped {
            assert(records.count <= maxRecords)   // loop bound: records are capped at maxRecords
            for i in records.indices where records[i].speaker == spk && records[i].role == .unknown {
                var u = records[i]
                labeler.refuse(&u)
                records[i] = u
            }
        }
        shadowLog(rec)
        if let logStore {   // the fully-fused record line (opt-in; off the main actor)
            let entry = TranscriptLogEntry.record(from: rec)
            Task { await logStore.log(entry) }
        }
        stats.add(rec)
        status = .live
        detail = "Transcribing."
    }

    /// Optional per-line fusion diagnostics (behind the app's debug flag) so the fill-guard
    /// thresholds and acoustic fingerprint can be tuned against real audio without a UI or ground
    /// truth. No-op unless `atc.showDebug` is set. Prints, deliberately — it's a dev shadow log.
    private func shadowLog(_ r: TranscriptRecord) {
        guard UserDefaults.standard.bool(forKey: "atc.showDebug") else { return }
        let d = r.speakerDistance.map { $0 > 1e6 ? "new" : String(format: "%.3f", $0) } ?? "—"
        print("[fuse-shadow] role=\(r.role.rawValue)(\(String(format: "%.2f", r.roleConfidence))) "
            + "spk=\(r.speaker.map(String.init) ?? "—") dist=\(d) "
            + "→ label=\(r.speakerLabel.fixtureString) from=\(r.fusedFrom.rawValue)")
    }
}
