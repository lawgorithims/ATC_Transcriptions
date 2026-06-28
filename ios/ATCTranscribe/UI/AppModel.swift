import Foundation
import SwiftUI
import Combine
import AVFoundation

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
    // UI theme — persisted so the app reopens in the same look (was resetting to cockpit each launch).
    @Published var theme: AppTheme =
        (UserDefaults.standard.string(forKey: "atc.theme").flatMap(AppTheme.init(rawValue:)) ?? .cockpit) {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: "atc.theme") }
    }

    // Source controls — persisted so the app reopens to the input / LiveATC link / airport you left
    // on. The first-launch "default to Replay demo" still applies only when no source was ever saved.
    @Published var source: SourceKind =
        (UserDefaults.standard.string(forKey: "atc.source").flatMap(SourceKind.init(rawValue:)) ?? .liveFeed) {
        didSet { UserDefaults.standard.set(source.rawValue, forKey: "atc.source") }
    }
    @Published var streamURL = UserDefaults.standard.string(forKey: "atc.streamURL") ?? "" {
        didSet { UserDefaults.standard.set(streamURL, forKey: "atc.streamURL") }
    }
    @Published var airport = UserDefaults.standard.string(forKey: "atc.airport") ?? "" {
        didSet {
            UserDefaults.standard.set(airport, forKey: "atc.airport")
            // Recenter ADS-B only when the resolved COORDINATE changes — not on every keystroke of a
            // partial ident (which all resolve to nil), avoiding poll-task churn while typing. Clears
            // the old facility's traffic synchronously so geographically-wrong aircraft never linger.
            // NOTE: this recenters ADS-B only; the facility RAG/Whisper-prompt config is built once in
            // setupLive, so a mid-session airport change needs a Stop/Start to fully retarget the
            // corrector (pre-existing behavior, unchanged by ADS-B).
            if AirportCoordinates.coordinate(icao: airport) != AirportCoordinates.coordinate(icao: oldValue) {
                clearTraffic(); syncADSB()
            }
        }
    }
    @Published var frequency = UserDefaults.standard.string(forKey: "atc.frequency") ?? "auto" {
        didSet { UserDefaults.standard.set(frequency, forKey: "atc.frequency") }
    }

    // Session state (forwarded from TranscriptionSession in live mode)
    @Published var status: SessionStatus = .idle
    @Published var detail = "Replay demo — press Start."
    @Published var sourceLabel = "Replay demo"
    @Published var records: [TranscriptRecord] = []
    @Published var stats = LatencyStats()
    @Published var inputLevel: Float = 0   // live audio level (0…1) for the input meter

    // Engine / device. `activeModel` (small/large) is persisted so the app reopens on the model you
    // left on, instead of always preferring the larger one — see the restore logic in `init`.
    @Published var activeModel = "small" {
        didSet { UserDefaults.standard.set(activeModel, forKey: "atc.activeModel") }
    }
    /// The whisper id being loaded during a swap (nil when idle). Drives the Settings picker's
    /// optimistic highlight + spinner and blocks a re-entrant switch; cleared on every swap exit.
    @Published var loadingModel: String?
    /// Set when the speech model fails to load, so the UI can say *why* instead of a bare
    /// "model unavailable".
    @Published var modelLoadError: String?
    @Published var deviceLabel = "Neural Engine"
    @Published var measuredSpeed: Double? = 12.5
    @Published var minRealtimeSpeed = (UserDefaults.standard.object(forKey: "atc.minRealtimeSpeed") as? Double) ?? 1.2 {
        didSet { UserDefaults.standard.set(minRealtimeSpeed, forKey: "atc.minRealtimeSpeed") }
    }

    // Proof of life
    @Published var proofOfLife: ProofOfLifeResult?
    @Published var polRunning = false

    // Correction layer (ON by default — corrects spoken numbers/callsigns/phraseology out of the
    // box). `correctionEnabled` runs the fast inline tier (repetition collapse + deterministic
    // vocab/number fixer); `llmBackend` picks the slow-tier AI fixer (off / on-device llama.cpp on
    // the CPU / Apple Foundation Models). Defaults are persisted (keys mirror `atc.diarization`):
    // on / on-device / Balanced. The on-device fixer degrades to vocabulary-only until the GGUF
    // finishes downloading. Toggling either hot-swaps into the live session.
    @Published var correctionEnabled = (UserDefaults.standard.object(forKey: "atc.correctionEnabled") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(correctionEnabled, forKey: "atc.correctionEnabled"); rebuildCorrector(); rebuildLLM() }
    }
    @Published var llmBackend: LLMBackend =
        (UserDefaults.standard.string(forKey: "atc.llmBackend").flatMap(LLMBackend.init(rawValue:)) ?? .local) {
        didSet {
            UserDefaults.standard.set(llmBackend.rawValue, forKey: "atc.llmBackend")
            if llmBackend != oldValue { rebuildLLM() }
        }
    }

    // Confidence gate: only run the AI fixer when a transmission looks suspicious. `skipWhenConfident`
    // toggles the gate; `gateSensitivity` trades correction coverage against CPU savings (persisted).
    @Published var skipWhenConfident = (UserDefaults.standard.object(forKey: "atc.skipWhenConfident") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(skipWhenConfident, forKey: "atc.skipWhenConfident"); applyGate() }
    }
    @Published var gateSensitivity: GateSensitivity =
        (UserDefaults.standard.string(forKey: "atc.gateSensitivity").flatMap(GateSensitivity.init(rawValue:)) ?? .balanced) {
        didSet { UserDefaults.standard.set(gateSensitivity.rawValue, forKey: "atc.gateSensitivity"); applyGate() }
    }

    @Published var showSettings = false

    // Electronic Flight Bag: the filed flight plan (ForeFlight-style). Persisted as JSON; whenever
    // it changes, its context block is packed into the live correction layer (both LLM backends)
    // and saved. `showFlightBag` drives the briefcase editor sheet.
    @Published var flightPlan: FlightPlan? = FlightPlan.load() {
        didSet {
            if let fp = flightPlan { fp.save() } else { FlightPlan.clear() }
            pushFlightPlanContext()
        }
    }
    @Published var showFlightBag = false

    // Transcript ordering: false = newest at the bottom (default, auto-scrolls down); true = newest
    // at the top, so new transmissions appear without scrolling. Persisted; toggled from the
    // transcript card's sort control.
    @Published var transcriptNewestFirst = UserDefaults.standard.bool(forKey: "atc.transcriptNewestFirst") {
        didSet { UserDefaults.standard.set(transcriptNewestFirst, forKey: "atc.transcriptNewestFirst") }
    }

    /// When set, the transcript shows ONLY transmissions for this callsign — tap a callsign chip to
    /// filter to that aircraft's conversation; tap it again (or Clear) to remove the filter.
    @Published var callsignFilter: String?

    /// Toggle the conversation filter for a callsign (set it, or clear it if already active).
    func toggleCallsignFilter(_ cs: String) {
        callsignFilter = (callsignFilter == cs) ? nil : cs
    }

    // Sidebar widget customization: which cards are shown, in what order. Edited in-place via a
    // long-press (add / remove / drag-reorder) so the layout can be trimmed for iPad Split View /
    // Slide Over. Persisted so the choice survives relaunch.
    @Published var widgets: [SidebarWidget] = AppModel.loadWidgets() { didSet { Self.saveWidgets(widgets) } }
    @Published var editingWidgets = false

    // Performance / debug readouts (per-transmission RTF + latency). Off by default — most users
    // don't want the numbers; toggle on in Settings. Persisted.
    @Published var showDebug = UserDefaults.standard.bool(forKey: "atc.showDebug") {
        didSet {
            UserDefaults.standard.set(showDebug, forKey: "atc.showDebug")
            // Turning on "Show performance data" surfaces the debug widgets (CPU/thermal + latency)
            // so they're discoverable without the long-press Add-widget menu. Only on a genuine
            // user toggle (`didFinishInit`) — not the `--debug` launch flag, which shouldn't mutate
            // the saved sidebar layout.
            if showDebug, didFinishInit {
                for w in [SidebarWidget.diagnostics, .latency] where !widgets.contains(w) { widgets.append(w) }
            }
        }
    }
    private var didFinishInit = false

    // Squelch: Auto (default) learns the channel noise floor from the gaps between transmissions
    // so the transcriber only wakes on real speech (saves battery on a quiet feed); Manual uses a
    // fixed threshold. Persisted; hot-applied to the running VAD.
    @Published var squelchAuto = (UserDefaults.standard.object(forKey: "atc.squelchAuto") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(squelchAuto, forKey: "atc.squelchAuto"); applySquelch() }
    }
    @Published var manualSquelch = (UserDefaults.standard.object(forKey: "atc.manualSquelch") as? Double) ?? 0.2 {
        didSet { UserDefaults.standard.set(manualSquelch, forKey: "atc.manualSquelch"); applySquelch() }
    }

    // Speaker diarization: split merged transmissions and put each speaker on its own line. On by
    // default; persisted; hot-applied to the running pipeline.
    @Published var diarizationEnabled = (UserDefaults.standard.object(forKey: "atc.diarization") as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(diarizationEnabled, forKey: "atc.diarization")
            session?.setDiarization(diarizationEnabled)
        }
    }

    // Live-feed monitor: play the internet feed out the speakers so it can be heard/verified (mic &
    // USB are NOT monitored — feedback). Persisted; toggled by the speaker button. Muting just sets
    // the player volume so it doesn't disrupt the running stream.
    @Published var monitorEnabled = (UserDefaults.standard.object(forKey: "atc.monitorEnabled") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(monitorEnabled, forKey: "atc.monitorEnabled"); audioMonitor.setMuted(!monitorEnabled) }
    }
    private let audioMonitor = AudioMonitor()

    // Online ADS-B traffic: fetch in-range aircraft (callsigns + N-numbers) from a public feed so the
    // corrector can lock a misheard callsign onto a plane actually on frequency. OFF by default
    // (network + battery opt-in); persisted. Polls only while ON, a live session is running, and the
    // app is foregrounded. `aircraft` drives the UI; the corrector block is injected separately with
    // a read-site expiry so stale data can never be used (see `injectTraffic`).
    @Published var adsbStreamingEnabled = (UserDefaults.standard.object(forKey: "atc.adsbStreaming") as? Bool) ?? false {
        didSet {
            UserDefaults.standard.set(adsbStreamingEnabled, forKey: "atc.adsbStreaming")
            if !adsbStreamingEnabled { clearTraffic() }
            syncADSB()
        }
    }
    @Published private(set) var aircraft: [Aircraft] = []
    @Published private(set) var aircraftUpdatedAt: Date?
    @Published private(set) var adsbStatus: ADSBStatus = .idle
    /// Uppercased callsign/registration keys of the current fresh in-range contacts. A transcript
    /// row's ✈ chip derives "in range" from this at render time, so the live badge tracks the feed
    /// instead of freezing whatever was true when the line was decoded.
    @Published private(set) var inRangeCallsignKeys: Set<String> = []
    /// Absolute trust window (seconds) stamped on the injected traffic block; the corrector consumes
    /// it only while `Date() < snapshotAt + this`. Keep ≈2.4× the service poll interval.
    private let adsbTrustWindow: TimeInterval = 12
    private var trafficEpoch = 0
    private var scenePhaseActive = true
    /// Constructed in `init` (IUO so the publish closures can capture a fully-initialized `self`).
    private var adsbService: ADSBService!

    // Standby: a one-tap low-power state that stops capture (and releases the audio session) and
    // dims to a dark screen, so leaving the app monitoring a quiet feed doesn't drain the battery.
    @Published var standby = false
    private var resumeSource: SourceKind?
    /// The source that will restart on Resume (nil if nothing was running when standby began).
    var resumeSourceLabel: String? { resumeSource?.rawValue }

    // First-launch model download gate: true when no Whisper model is bundled or downloaded yet.
    // Drives the full-screen `OnboardingDownloadView`. `modelSource` is a small status badge.
    @Published var needsOnboarding = false
    @Published var modelSource = "—"

    private var engine: TranscriberEngine?
    private var session: TranscriptionSession?
    // The slow-tier llama.cpp engine, cached so a whisper-model swap doesn't reload the ~400 MB GGUF
    // (the fixer is independent of which speech model is active). Dropped when the backend leaves .local.
    private var cachedLLMEngine: LLMEngine?
    private var cachedLLMBackend: LLMBackend = .off
    private var clips: [DiagnosticClip] = []
    private var liveContext: ATCContext?
    private var feedKey: String?
    private var liveMode = false
    private var storedCPUOnly = false
    private var modelDirs: [String: String] = [:]   // whisper variant id → on-disk model folder
    private var audioDirPath: String?               // demo clips dir, kept for model re-load on switch

    init() {
        // Build the ADS-B service first. Its callbacks hop to the main actor: `onUpdate` applies the
        // pruned contacts + re-injects the corrector block with a fresh expiry; `onStatus` surfaces
        // feed health. `[weak self]` is safe — every stored property has a default, so `self` is fully
        // initialized here.
        adsbService = ADSBService(
            onUpdate: { [weak self] list, snapshotAt in
                Task { @MainActor in self?.applyTraffic(list, snapshotAt: snapshotAt) }
            },
            onStatus: { [weak self] status in
                Task { @MainActor in self?.adsbStatus = status }
            })

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
        if args.contains("--debug") { showDebug = true }   // surface perf metrics (verification)
        if args.contains("--correct") { correctionEnabled = true }
        if args.contains("--llm") { correctionEnabled = true; llmBackend = .local }
        if args.contains("--llm-foundation") { correctionEnabled = true; llmBackend = .foundation }

        #if targetEnvironment(simulator)
        deviceLabel = "CPU (Simulator)"
        let cpuOnly = true
        #else
        let cpuOnly = false
        #endif
        storedCPUOnly = cpuOnly

        // Resolve the model + demo clips. Explicit launch flags (Simulator verification) win;
        // otherwise prefer a model the user has DOWNLOADED into Application Support, then a copy
        // bundled into the app. A TestFlight build ships without the heavy model, so on first
        // launch nothing resolves and we gate on the download onboarding step.
        let explicitModel = value("--model-dir")
        let audioDir = value("--audio-dir") ?? Self.bundledDemoClipsDir()
        self.audioDirPath = audioDir
        // Build the variant→folder map. An explicit --model-dir (Simulator verification) wins and
        // is treated as the "small" slot; otherwise gather every downloaded/bundled variant so the
        // Settings picker can switch between Small and Large at runtime.
        let models = explicitModel.map { ["small": $0] } ?? Self.availableModelDirs()
        self.modelDirs = models
        // Restore the model the user last had active (persisted) when it's still available; else
        // prefer the larger (higher-accuracy) model when present, falling back to small/bundled.
        if let active = Self.preferredActiveModel(from: models) {
            liveMode = true
            records = []
            stats = LatencyStats()
            status = .idle
            detail = "Loading model…"
            modelSource = explicitModel != nil ? "launch"
                : (ModelStore.downloadedWhisperDir() != nil ? "downloaded" : "bundled")
            // First launch only (no source ever saved): default to the self-contained Replay demo
            // so a fresh install transcribes on the first Start with no network or mic needed. A
            // saved source preference (or an explicit --source) wins on later launches.
            if value("--source") == nil, UserDefaults.standard.string(forKey: "atc.source") == nil,
               audioDir != nil { source = .replay }
            let autostart = args.contains("--autostart")
            Task { await setupLive(models: models, active: active, audioDir: audioDir, cpuOnly: cpuOnly, autostart: autostart) }
        } else {
            seedSampleData()   // no model yet — populated demo layout behind the download gate
            // Gate the first launch on downloading the required model, unless launched with an
            // explicit flag or the user already chose to skip on a previous launch.
            needsOnboarding = explicitModel == nil && !Self.onboardingDismissed
        }
        didFinishInit = true   // from here, a showDebug toggle may add the debug widgets
    }

    var palette: Palette { theme.palette }
    var isRunning: Bool { status == .live || status == .connecting || status == .starting }
    /// Friendly name of the active model for the status badge / sidebar (maps the raw id, e.g.
    /// "cleanturbo" → "Large V2", so the internal id never leaks into the UI).
    var activeModelLabel: String { ModelCatalog.shortLabel(forID: activeModel) }

    // MARK: live wiring

    private func setupLive(models: [String: String], active: String, audioDir: String?, cpuOnly: Bool,
                           autostart: Bool, preserveHistory: Bool = false) async {
        guard let modelDir = models[active] else { detail = "Model unavailable."; return }
        // When swapping models we keep the visible transcript: snapshot it now (it still mirrors the
        // old session) and seed it into the new session below so the swap isn't destructive.
        let savedRecords = records
        let savedStats = stats
        // On a swap, release the OLD session/engine (holding the old whisper model, up to ~1.5 GB)
        // BEFORE loading the new one, so only one model is resident at the load peak. switchModel
        // already called stop(); `$records` keeps its last value once the binding is severed, and
        // the snapshot above is re-seeded via session.adopt below, so the console doesn't blank.
        if preserveHistory { self.session = nil; self.engine = nil }
        let engine = TranscriberEngine(models: models, defaultModel: active,
                                       fallbackModel: models["small"] != nil ? "small" : active,
                                       adaptive: false, cpuOnly: cpuOnly)
        let transcriber = ATCTranscriber(modelFolder: modelDir, cpuOnly: cpuOnly)
        do {
            try await transcriber.load()
            modelLoadError = nil
        } catch {
            modelLoadError = error.localizedDescription
            detail = "Model failed to load: \(error.localizedDescription)"
            return
        }

        // Load a facility config so the corrector vocabulary + RAG retrieval actually have data
        // (the shipping default is KDFW; an airport typed in the UI overrides it). Previously
        // ATCContext() was empty, so vocab()/retrieval were no-ops.
        let configName = airport.isEmpty ? "kdfw" : airport.lowercased()
        let cfg = try? AirportConfig.load(named: configName)
        let feedKey = cfg?.streams?.keys.sorted().first
        self.feedKey = feedKey
        let context = ATCContext(config: cfg, feedKey: feedKey)
        // Seed the filed flight plan (Electronic Flight Bag) before the pipeline starts using the
        // context, so the first transmission's LLM correction already sees the pilot's own callsign,
        // airports, and route. Live edits afterward go through `pushFlightPlanContext`.
        if let fp = flightPlan { context.setFlightPlan(block: fp.contextBlock, vocab: fp.vocabTerms) }
        // Seed the traffic epoch into the fresh context so clear-ordering survives the rebuild, then
        // re-seed the last FRESH ADS-B snapshot so a model swap doesn't blank traffic context until
        // the next poll (~5s). The read-site expiry self-expires it if the poller doesn't return.
        context.clearTraffic(epoch: trafficEpoch)
        if adsbStreamingEnabled, !aircraft.isEmpty, let at = aircraftUpdatedAt,
           Date() < at.addingTimeInterval(adsbTrustWindow) {
            let (block, vocab) = Self.trafficContext(aircraft)
            context.setTraffic(block: block, vocab: vocab,
                               expiry: at.addingTimeInterval(adsbTrustWindow), epoch: trafficEpoch)
        }
        self.liveContext = context

        // Build/reuse the optional slow-tier LLM off the main actor. The GGUF loads at most once per
        // app run (cached), so a whisper-model swap no longer reloads ~400 MB off disk.
        let llm = await makeLLMCorrector(knowledge: context.knowledge, feedKey: feedKey)

        let pipeline = LivePipeline(transcriber: transcriber, context: context,
                                    preprocessor: AudioPreprocessor(aggressiveRadio: true),
                                    corrector: currentCorrector(), llm: llm,
                                    gateEnabled: skipWhenConfident, gateSensitivity: gateSensitivity,
                                    diarizationEnabled: diarizationEnabled,
                                    vadConfig: VADConfig(squelchAuto: squelchAuto,
                                                         squelchLevel: Float(manualSquelch)))
        let session = TranscriptionSession(pipeline: pipeline)
        if preserveHistory { session.adopt(records: savedRecords, stats: savedStats) }  // survive a model swap
        session.$records.assign(to: &$records)   // mirror live session state into the UI
        session.$status.assign(to: &$status)
        session.$stats.assign(to: &$stats)
        session.$inputLevel.assign(to: &$inputLevel)
        self.session = session
        self.engine = engine
        self.modelDirs = models
        self.activeModel = active

        if let audioDir { clips = (try? Self.loadClips(audioDir)) ?? [] }
        detail = clips.isEmpty ? "Model ready (no demo clips)." : "Ready — press Start."
        if autostart { start(resuming: preserveHistory) }
    }

    // MARK: correction

    private var correctionConfig: CorrectionConfig {
        var c = CorrectionConfig()
        c.enabled = correctionEnabled
        c.llmBackend = correctionEnabled ? llmBackend : .off
        return c
    }

    /// Build the fast inline corrector from the current toggles + the live airport vocab:
    /// `NullCorrector` when off, else repetition collapse + the deterministic vocab/number fixer.
    private func currentCorrector() -> Corrector {
        buildCorrector(config: correctionConfig, vocab: { [weak self] in self?.liveContext?.vocab() ?? [] })
    }

    /// Rebuild and hot-swap the fast inline corrector into the running session (a toggle changed).
    private func rebuildCorrector() {
        session?.setCorrector(currentCorrector())
    }

    /// Push the confidence-gate settings into the running session (a toggle/sensitivity changed).
    private func applyGate() {
        session?.setGate(enabled: skipWhenConfident, sensitivity: gateSensitivity)
    }

    /// Push the squelch (auto / manual threshold) into the running VAD (a Settings change).
    private func applySquelch() {
        session?.setSquelch(auto: squelchAuto, level: Float(manualSquelch))
    }

    /// Push the filed flight plan into the running correction context (or clear it). Called when
    /// the plan changes; the initial value is seeded directly onto the context in `setupLive`.
    func pushFlightPlanContext() {
        session?.setFlightPlanContext(block: flightPlan?.contextBlock ?? "",
                                      vocab: flightPlan?.vocabTerms ?? [])
    }

    // MARK: ADS-B live traffic

    /// Whether ADS-B should be actively polling/injecting right now.
    private var adsbActive: Bool { adsbStreamingEnabled && isRunning && liveMode && scenePhaseActive }

    /// Reconcile the ADS-B poller with current state (single edge-triggered call). Polls only while
    /// streaming is ON, a live session is running, and the app is foregrounded.
    func syncADSB() {
        let center = facilityCoordinate()
        let active = adsbActive
        let service = adsbService
        Task { await service?.sync(center: center, enabled: active) }
    }

    /// The center for the 30 NM query: the typed airport's coordinate (bundled table; default KDFW
    /// when blank), or nil when unknown (→ no polling). Device GPS will sit ahead of this later.
    private func facilityCoordinate() -> Coord? {
        AirportCoordinates.coordinate(icao: airport.isEmpty ? "KDFW" : airport)
    }

    /// Service published a snapshot: update the UI state and re-inject the corrector block. Guarded
    /// on `adsbActive` so a late callback that lands after a toggle-off / standby / background CLEARS
    /// the carousel + corrector instead of repopulating them (the callback hops the main actor async,
    /// so it can arrive after the synchronous clearTraffic()).
    private func applyTraffic(_ list: [Aircraft], snapshotAt: Date) {
        let active = adsbActive
        let shown = active ? list : []
        aircraft = shown
        aircraftUpdatedAt = (active && snapshotAt != .distantPast) ? snapshotAt : nil
        inRangeCallsignKeys = Set(shown.flatMap { ac in
            [ac.callsign, ac.registration].compactMap { $0?.uppercased() }
        })
        injectTraffic(from: shown, snapshotAt: active ? snapshotAt : .distantPast)
    }

    /// Inject (or clear) the live-traffic block into the running correction context. Injects ONLY
    /// when streaming is actually desired right now — so a late callback after toggle-off / standby /
    /// background clears instead of re-injecting — and the block carries an absolute `expiry` the
    /// corrector re-checks at read time, so stale traffic is never used.
    private func injectTraffic(from list: [Aircraft], snapshotAt: Date) {
        guard let session else { return }
        guard adsbActive, !list.isEmpty, snapshotAt != .distantPast else {
            session.setTrafficContext(block: "", vocab: [], expiry: .distantPast, epoch: trafficEpoch)
            return
        }
        let (block, vocab) = Self.trafficContext(list)
        session.setTrafficContext(block: block, vocab: vocab,
                                  expiry: snapshotAt.addingTimeInterval(adsbTrustWindow), epoch: trafficEpoch)
    }

    /// Build the "Traffic in range" context block + the callsign/registration vocab the corrector
    /// may snap a misheard token onto. Capped so a busy sector can't bloat the prompt.
    private static func trafficContext(_ list: [Aircraft]) -> (block: String, vocab: [String]) {
        var seen = Set<String>()
        var labels: [String] = []
        for ac in list {
            for term in [ac.callsign, ac.registration] {
                guard let t = term, !t.isEmpty, seen.insert(t).inserted else { continue }
                labels.append(t)
            }
            if labels.count >= 40 { break }
        }
        guard !labels.isEmpty else { return ("", []) }
        return ("Traffic in range (live ADS-B): " + labels.joined(separator: ", ") + ".", labels)
    }

    /// Drop the injected traffic immediately and bump the epoch so any in-flight re-inject loses
    /// (toggle-off / standby / airport-change / background).
    private func clearTraffic() {
        trafficEpoch += 1
        aircraft = []
        aircraftUpdatedAt = nil
        inRangeCallsignKeys = []
        session?.clearTrafficContext(epoch: trafficEpoch)
    }

    /// Foreground/background transition from the root view: pause polling + drop traffic in the
    /// background; resume on return to the foreground.
    func setScenePhaseActive(_ active: Bool) {
        guard active != scenePhaseActive else { return }
        scenePhaseActive = active
        if !active { clearTraffic() }
        syncADSB()
    }

    /// Build the slow-tier LLM corrector, REUSING a cached llama.cpp engine for the `.local` backend
    /// so a whisper-model swap never reloads the ~400 MB GGUF. The engine loads at most once per app
    /// run; the cheap `LocalLLMCorrector` wrapper (knowledge/feedKey binding) is rebuilt each call.
    /// `makeLocalLLMEngine` returns nil until the GGUF is on disk, leaving the cache empty so the
    /// next build retries — so a fixer that finishes downloading later is picked up on the next swap.
    private func makeLLMCorrector(knowledge: ATCKnowledgeBase, feedKey: String?) async -> LLMCorrector? {
        guard correctionEnabled else { return nil }
        switch llmBackend {
        case .off:
            return nil
        case .foundation:
            return await Task.detached(priority: .utility) {
                makeFoundationModelsCorrector(knowledge: knowledge, feedKey: feedKey)
            }.value
        case .local:
            if cachedLLMEngine == nil || cachedLLMBackend != .local {
                cachedLLMEngine = await Task.detached(priority: .utility) { makeLocalLLMEngine() }.value
                cachedLLMBackend = .local
            }
            guard let engine = cachedLLMEngine else { return nil }   // GGUF not present yet — retry next build
            return LocalLLMCorrector(engine: engine, knowledge: knowledge, feedKey: feedKey)
        }
    }

    /// Rebuild and hot-swap the slow-tier LLM backend (off / local llama.cpp / Foundation Models) into
    /// the running session. Built off the main actor so a model load never janks the UI.
    private func rebuildLLM() {
        guard liveMode, let context = liveContext else { return }
        // Leaving the on-device backend frees the cached llama.cpp engine (and its ~400 MB).
        if !(correctionEnabled && llmBackend == .local) { cachedLLMEngine = nil; cachedLLMBackend = .off }
        let feedKey = self.feedKey
        let knowledge = context.knowledge
        Task { session?.setLLM(await makeLLMCorrector(knowledge: knowledge, feedKey: feedKey)) }
    }

    // MARK: controls

    /// Start (or resume) capture. `resuming: true` keeps the existing transcript/stats instead of
    /// clearing them (used by standby Resume and a model switch), so the console isn't wiped.
    func start(resuming: Bool = false) {
        guard liveMode else {           // no model → design/screenshot demo
            status = .live; detail = "Transcribing (demo)."; return
        }
        guard let session else {        // live build whose model failed to load
            status = .error
            detail = modelLoadError.map { "Speech model unavailable — \($0)" }
                ?? "Speech model isn't loaded yet. Re-download it in Settings › Models."
            return
        }
        // Microphone / USB capture needs an explicit permission grant first — without it
        // AVAudioEngine yields no input and the run just ends ("not activating").
        if source == .microphone || source == .usbAudio {
            AVAudioApplication.requestRecordPermission { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    if granted {
                        self.beginCapture(session: session, resuming: resuming)
                    } else {
                        self.status = .error
                        self.detail = "Microphone access denied. Enable it in Settings › CommSight › Microphone."
                    }
                }
            }
            return
        }
        beginCapture(session: session, resuming: resuming)
    }

    /// Build the chosen source and start the session. mic/USB failures are surfaced to `detail`.
    private func beginCapture(session: TranscriptionSession, resuming: Bool) {
        let micFailure: @Sendable (String) -> Void = { [weak self] msg in
            Task { @MainActor in
                self?.status = .error
                self?.detail = msg
                // The session was activated before capture started; a mic failure flips status to
                // .error, which makes the session's own teardown guard (`== .live`) skip — so
                // release it here, otherwise the .playAndRecord session leaks (mic light stays on).
                AudioSessionManager.deactivate()
            }
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
            src = DeviceAudioSource(preferUSB: false, onFailure: micFailure)
        case .usbAudio:
            src = DeviceAudioSource(preferUSB: true, onFailure: micFailure)
        case .liveFeed:
            guard let resolved = try? StreamURLResolver.resolve(streamURL: streamURL.isEmpty ? nil : streamURL),
                  let url = URL(string: resolved) else {
                detail = "Enter a valid LiveATC link or stream URL."; return
            }
            // Wrap the feed so it also plays out the speakers (audible monitor); the speaker toggle
            // mutes via volume without disrupting the stream.
            audioMonitor.setMuted(!monitorEnabled)
            src = MonitoredSource(StreamAudioSource(url: url), monitor: audioMonitor)
        }
        // Hold an active audio session for every source so transcription continues when the app is
        // backgrounded (the `audio` background mode is declared). mic/USB record; feed/replay play.
        AudioSessionManager.activate(recording: source == .microphone || source == .usbAudio,
                                     preferUSB: source == .usbAudio)
        session.start(source: src, label: source.rawValue, clearHistory: !resuming)
        if !resuming { callsignFilter = nil }   // a fresh transcript replaces history → drop a stale filter
        sourceLabel = source.rawValue
        detail = "Transcribing."
        syncADSB()   // a live session started → begin ADS-B polling if streaming is enabled
    }

    func stop() {
        // The session releases the audio session itself (on Stop and on a natural end); the demo
        // path never activated one, so nothing to release here.
        if let session { session.stop() } else { status = .stopped }
        detail = "Stopped."
        syncADSB()   // no live session → stop ADS-B polling + clear traffic
    }

    /// Enter standby: stop capture and release the audio session so a quiet, unattended feed
    /// stops draining the battery. Remembers whether a source was running so Resume can pick up
    /// where it left off.
    func enterStandby() {
        if isRunning { resumeSource = source; stop() } else { resumeSource = nil }
        detail = "Standby — capture paused."
        standby = true
    }

    /// Leave standby. If a source was running when standby began, restart it; otherwise just
    /// return to the idle console.
    func exitStandby() {
        standby = false
        if let s = resumeSource { source = s; start(resuming: true) }
        resumeSource = nil
    }

    func clear() {
        callsignFilter = nil   // a stale conversation filter over an empty transcript is confusing
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

    // MARK: sidebar widget customization

    private static let widgetsKey = "atc.sidebarWidgets"

    /// Load the saved widget order, falling back to all widgets (declaration order) on first run
    /// or if the saved value is empty/corrupt.
    /// Default sidebar on a fresh install: the at-a-glance health (proof of life) + host info.
    /// The Latency widget (RTF/timing) is intentionally NOT shown by default — it's debug data the
    /// user can add from the "Add widget" menu (mirrors the `showDebug` default).
    static let defaultWidgets: [SidebarWidget] = [.proofOfLife, .host]

    static func loadWidgets() -> [SidebarWidget] {
        // UI-test determinism: ignore any persisted layout and start from defaults (the sidebar
        // layout otherwise carries across Simulator launches, polluting widget tests).
        if CommandLine.arguments.contains("--reset-widgets") { return defaultWidgets }
        guard let raw = UserDefaults.standard.array(forKey: widgetsKey) as? [String] else {
            return defaultWidgets
        }
        let parsed = raw.compactMap(SidebarWidget.init(rawValue:))
        // A deliberately-emptied sidebar (raw == []) is preserved; only fall back to defaults when
        // the key is absent (first run, handled above) or every saved id is unknown (raw non-empty).
        return parsed.isEmpty && !raw.isEmpty ? defaultWidgets : parsed
    }

    static func saveWidgets(_ w: [SidebarWidget]) {
        UserDefaults.standard.set(w.map(\.rawValue), forKey: widgetsKey)
    }

    /// Widgets not currently on the sidebar — the candidates the "Add widget" menu offers.
    var availableWidgets: [SidebarWidget] { SidebarWidget.allCases.filter { !widgets.contains($0) } }

    func addWidget(_ w: SidebarWidget) { guard !widgets.contains(w) else { return }; widgets.append(w) }
    func removeWidget(_ w: SidebarWidget) { widgets.removeAll { $0 == w } }

    /// Reorder during a drag: move `w` to sit immediately before `target`.
    func moveWidget(_ w: SidebarWidget, before target: SidebarWidget) {
        guard w != target, let from = widgets.firstIndex(of: w) else { return }
        widgets.remove(at: from)
        if let to = widgets.firstIndex(of: target) { widgets.insert(w, at: to) }
        else { widgets.append(w) }
    }

    // MARK: model selection + download gate

    /// All whisper variants present on disk: a downloaded folder per variant, with the bundled
    /// model filling the "small" slot when nothing was downloaded for it. Drives the engine's
    /// model map (so the Settings picker can switch between Small and Large).
    static func availableModelDirs() -> [String: String] {
        var m: [String: String] = [:]
        // Map key is the short `id` (what the picker + persisted `atc.activeModel` use); the value is
        // the on-disk folder, resolved via the entry's `variant` (≠ id for the stock "Large V2").
        for e in ModelCatalog.whisperEntries where ModelStore.isReady(e) {
            m[e.id] = ModelStore.localURL(for: e).path
        }
        if m["small"] == nil, let bundled = bundledModelDir() { m["small"] = bundled }
        return m
    }

    /// Pick which model to activate from what's on disk: the user's saved choice when still present,
    /// else the highest-accuracy fine-tuned model (turbo → small), else any available variant (covers
    /// a box where only the stock "Large V2" was downloaded). Nil when nothing is available.
    /// Shared by first-launch (`init`) and post-download (`modelDidDownload`) so they never diverge.
    static func preferredActiveModel(from models: [String: String]) -> String? {
        if let saved = UserDefaults.standard.string(forKey: "atc.activeModel"), models[saved] != nil {
            return saved
        }
        for id in ["turbo", "small"] where models[id] != nil { return id }
        return models.keys.sorted().first
    }

    /// Is a given whisper variant present on disk? Drives the Settings picker's enablement.
    func modelDownloaded(_ id: String) -> Bool { modelDirs[id] != nil }

    /// Switch the active transcription model (Settings picker). Rebuilds the engine + live session
    /// against the chosen variant's folder. No-op if it isn't downloaded or is already active.
    /// Preserves run state: if a source was live it restarts after the new model loads.
    func switchModel(_ id: String) {
        guard liveMode, id != activeModel, modelDirs[id] != nil else { return }
        guard loadingModel == nil else { return }   // a swap is already loading — ignore the tap
        let wasRunning = isRunning
        if wasRunning { stop() }
        loadingModel = id                            // picker reflects the choice immediately
        detail = "Loading \(ModelCatalog.shortLabel(forID: id)) model…"   // friendly name, not the raw id
        let models = modelDirs
        Task {
            defer { loadingModel = nil }             // clears on success AND every early-return/failure
            await setupLive(models: models, active: id, audioDir: audioDirPath,
                            cpuOnly: storedCPUOnly, autostart: wasRunning, preserveHistory: true)
        }
    }

    /// Where the live model comes from, preferring a user-downloaded model over a bundled one.
    /// Returns nil when neither exists (a lean TestFlight build before the first download).
    static func resolvedModelDir() -> String? {
        ModelStore.downloadedWhisperDir() ?? bundledModelDir()
    }

    /// Persisted "user skipped the download gate" flag (so we don't nag in demo mode each launch).
    private static let onboardingKey = "atc.onboardingDismissed"
    static var onboardingDismissed: Bool {
        get { UserDefaults.standard.bool(forKey: onboardingKey) }
        set { UserDefaults.standard.set(newValue, forKey: onboardingKey) }
    }

    /// Dismiss the first-launch gate. If the user skipped without downloading (still no model),
    /// remember it so the gate doesn't reappear; if a model is now present, no flag is needed.
    func finishOnboarding() {
        needsOnboarding = false
        if Self.resolvedModelDir() == nil { Self.onboardingDismissed = true }
    }

    /// A model finished downloading. If the app launched without one (demo mode), bring up the
    /// live session now so the gate's "Continue" lands in a working console. (GGUF downloads are
    /// picked up the next time the AI fixer backend is built.)
    func modelDidDownload(_ entry: ModelEntry) {
        guard entry.kind == .whisperKit else { return }
        modelSource = "downloaded"
        let models = Self.availableModelDirs()
        self.modelDirs = models
        guard !liveMode else {
            // Already live: if the user just added the higher-accuracy model, switch to it — but
            // never tear down an ACTIVE run (the Settings picker enables it once modelDirs updates).
            if entry.id == "turbo", activeModel != "turbo", !isRunning { switchModel("turbo") }
            return
        }
        // Honor a previously-saved model choice when it's now available, else prefer the larger one
        // (or any available variant — covers a box where only the stock "Large V2" was downloaded).
        guard let active = Self.preferredActiveModel(from: models) else { return }
        liveMode = true
        detail = "Loading model…"
        if value(forFlag: "--source") == nil, UserDefaults.standard.string(forKey: "atc.source") == nil,
           Self.bundledDemoClipsDir() != nil { source = .replay }
        Task { await setupLive(models: models, active: active, audioDir: Self.bundledDemoClipsDir(),
                               cpuOnly: storedCPUOnly, autostart: false) }
    }

    /// Read a `--flag value` pair from the launch arguments (used post-init by `modelDidDownload`).
    private func value(forFlag flag: String) -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
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
            var r = TranscriptRecord(
                text: text, streamStartS: s0, streamEndS: s1,
                audioDurationMs: (s1 - s0) * 1000, captureToTextMs: trMs + 140,
                transcribeMs: trMs, realTimeFactor: rtf,
                prompt: "Air traffic control radio transcript from KDFW Lone Star Approach. Runways: 17C, 35C.",
                corrected: edits.isEmpty ? "" : display, corrections: edits, timestamp: ts)
            r.callsign = CallsignExtractor.extract(r.display, knowledge: .shared)?.display   // demo: tag for the filter
            return r
        }
        for r in records { stats.add(r) }
        status = .live
        detail = "Transcribing."
        proofOfLife = ProofOfLifeResult(passed: true, activeModel: "small", meanWER: 0.091,
                                        realtimeSpeed: 12.5, snippets: [], error: nil)
    }
}
