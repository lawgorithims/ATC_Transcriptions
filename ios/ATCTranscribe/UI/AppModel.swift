import Foundation
import SwiftUI
import Combine
import AVFoundation

/// Audio source choices in the UI's Source picker.
enum SourceKind: String, CaseIterable, Identifiable {
    case liveFeed = "Internet live feed"
    case stratux = "Stratux receiver"
    case microphone = "Device microphone"
    case usbAudio = "USB audio"
    case replay = "Replay demo"
    var id: String { rawValue }
    /// Only the internet live feed needs a LiveATC stream link + frequency.
    var needsLink: Bool { self == .liveFeed }
    /// Cockpit-audio sources from a Stratux receiver (audio sidecar + on-board ADS-B/GPS).
    var isStratux: Bool { self == .stratux }
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
        didSet {
            UserDefaults.standard.set(source.rawValue, forKey: "atc.source")
            if didFinishInit, source != oldValue {
                // Picking the Stratux receiver as the input implies wanting its link up — auto-enable
                // it (its own didSet persists, adds the sidebar widget, and re-syncs both providers).
                if source == .stratux, !stratuxEnabled { stratuxEnabled = true }
                // Switching to/from the Stratux receiver changes which traffic provider is active.
                syncTraffic()
                // Surface the Stratux link card in the sidebar when the receiver becomes the source, so
                // the connection state is visible without digging into the Add-widget menu.
                if source == .stratux, !widgets.contains(.stratux) { widgets.append(.stratux) }
            }
        }
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
            // While the Stratux link is streaming, the airport coordinate doesn't drive traffic (the
            // receiver reports its own in-range aircraft via on-board GPS), so skip the clear/re-sync —
            // it would only blink the live Stratux traffic off for a refresh tick.
            if !stratuxTrafficActive,
               AirportCoordinates.coordinate(icao: airport) != AirportCoordinates.coordinate(icao: oldValue) {
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
    // True while a transmission is being transcribed (drives the "Transcribing…" indicator so a slow
    // model reads as working, not stalled); `transcribeStartedAt` drives its elapsed timer.
    @Published private(set) var transcribing = false
    @Published private(set) var transcribeStartedAt: Date?

    // Engine / device. `activeModel` (small/large) is persisted so the app reopens on the model you
    // left on, instead of always preferring the larger one — see the restore logic in `init`.
    @Published var activeModel = "small" {
        didSet { UserDefaults.standard.set(activeModel, forKey: "atc.activeModel") }
    }
    /// The whisper id being loaded during a swap (nil when idle). Drives the Settings picker's
    /// optimistic highlight + spinner and blocks a re-entrant switch; cleared on every swap exit.
    @Published var loadingModel: String?
    /// When the current (initial) model load began — drives the on-screen "loading…" elapsed timer so a
    /// long first load reads as progressing, not frozen. Set in `beginModelLoad`.
    @Published private(set) var modelLoadStartedAt: Date?
    /// Set when the speech model fails to load, so the UI can say *why* instead of a bare
    /// "model unavailable".
    @Published var modelLoadError: String?
    @Published var deviceLabel = "Neural Engine"
    @Published var measuredSpeed: Double? = 12.5   // real once the performance check runs (runProofOfLife)

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
        AppModel.defaultLLMBackend() {
        didSet {
            UserDefaults.standard.set(llmBackend.rawValue, forKey: "atc.llmBackend")
            if llmBackend != oldValue { rebuildLLM() }
        }
    }

    /// The AI-fixer backend to start with. An explicit user choice always wins; otherwise, on a
    /// device where Apple Intelligence is actually available, default to it (a ~3B on-device model
    /// vs the 0.5B llama.cpp fallback — the offline gold benchmark showed the 0.5B tier is
    /// net-neutral, so the larger model is the better default where it exists). Falls back to the
    /// on-device llama.cpp path everywhere else. The pipeline still degrades to vocabulary-only at
    /// runtime if the chosen backend turns out unavailable, so this is a safe preference, not a
    /// hard requirement.
    static func defaultLLMBackend() -> LLMBackend {
        if let saved = UserDefaults.standard.string(forKey: "atc.llmBackend").flatMap(LLMBackend.init(rawValue:)) {
            return saved
        }
        if foundationModelsAvailable() { return .foundation }
        return .local
    }

    /// Optional user-set URL of a larger remote "context fixer" model. When present, the on-device
    /// AI fixer runs first and this endpoint gets a second pass within the remaining latency budget
    /// (CascadeCorrector); empty = purely on-device. Read by `RemoteLLMCorrector.fromSettings`.
    @Published var remoteFixerURL = UserDefaults.standard.string(forKey: "atc.remoteFixerURL") ?? "" {
        didSet {
            let trimmed = remoteFixerURL.trimmingCharacters(in: .whitespacesAndNewlines)
            UserDefaults.standard.set(trimmed, forKey: "atc.remoteFixerURL")
            if didFinishInit, trimmed != oldValue.trimmingCharacters(in: .whitespacesAndNewlines) { rebuildLLM() }
        }
    }

    /// True iff the remote URL is non-empty and parses as an http(s) endpoint (mirrors the guard in
    /// `RemoteLLMCorrector.fromSettings`) — drives the Settings validity hint.
    var remoteFixerURLValid: Bool {
        let t = remoteFixerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let u = URL(string: t) else { return false }
        return u.scheme == "https" || u.scheme == "http"
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

    // Heading-bar view toggles: each collapsible strip below the heading bar (input controls,
    // diagnostics, flight plan, Stratux) is shown/hidden by its own heading-bar icon. Persisted so
    // the console reopens the way it was left; first launch shows only the Input bar (so a source can
    // be picked and started) with the rest collapsed for a clean, transcript-first screen. UI-only —
    // these gate visibility, never capture/pipeline behaviour.
    @Published var showInputBar = (UserDefaults.standard.object(forKey: "atc.bar.input") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(showInputBar, forKey: "atc.bar.input") }
    }
    @Published var showDiagnosticsBar = UserDefaults.standard.bool(forKey: "atc.bar.diag") {
        didSet { UserDefaults.standard.set(showDiagnosticsBar, forKey: "atc.bar.diag") }
    }
    @Published var showFlightPlanBar = UserDefaults.standard.bool(forKey: "atc.bar.plan") {
        didSet { UserDefaults.standard.set(showFlightPlanBar, forKey: "atc.bar.plan") }
    }
    @Published var showStratuxBar = UserDefaults.standard.bool(forKey: "atc.bar.stratux") {
        didSet { UserDefaults.standard.set(showStratuxBar, forKey: "atc.bar.stratux") }
    }

    // Electronic Flight Bag: the filed flight plan (ForeFlight-style). Persisted as JSON; whenever
    // it changes, its context block is packed into the live correction layer (both LLM backends)
    // and saved. `showFlightBag` drives the briefcase editor sheet.
    @Published var flightPlan: FlightPlan? = FlightPlan.load() {
        didSet {
            if let fp = flightPlan { fp.save() } else { FlightPlan.clear() }
            pushFlightPlanContext()
            prefetchRouteCharts()          // pull the FAA packs the filed route crosses in the background
        }
    }
    @Published var showFlightBag = false
    /// Drives the full-screen route map (`RouteMapSheet`) — the filed route, the selectable FAA chart
    /// layer, and live traffic. Transient (not persisted); opened from the flight-plan strip's Map button
    /// or the flight-bag editor.
    @Published var showRouteMap = false

    /// The chart base layer the user last viewed (VFR sectional / IFR low / standard / satellite) so the
    /// map reopens where they left off; defaults to VFR sectional on first run. Read at view-init time via
    /// `savedChartLayer`; the map writes any switch back here.
    nonisolated static let chartLayerKey = "atc.chartLayer"
    nonisolated static var savedChartLayer: ChartLayer {
        UserDefaults.standard.string(forKey: chartLayerKey).flatMap(ChartLayer.init(rawValue:)) ?? .sectional
    }
    @Published var chartLayer: ChartLayer = AppModel.savedChartLayer {
        didSet { UserDefaults.standard.set(chartLayer.rawValue, forKey: Self.chartLayerKey) }
    }

    // MARK: Home-screen map + floating widgets

    /// The map object the user tapped on the home map (nil = nothing selected). Drives the object side
    /// panel (regular width) / bottom sheet (compact). Transient.
    @Published var mapProbe: MapProbeResult?
    /// Recenter the home map here (a search result). Transient.
    @Published var mapFocus: Coord?
    /// Drives the map search sheet (top-bar magnifying glass). Transient.
    @Published var showMapSearch = false

    /// A search result / programmatic selection: center the map on it and open its info panel.
    func selectMapObject(_ o: IdentifiedObject) {
        mapFocus = o.coord
        mapProbe = MapProbeResult(id: "sel-\(o.id)", objects: [o])
    }

    /// Map overlay toggles shared by the always-on home map and the top-bar layers menu. Persisted.
    @Published var showAirspace = (UserDefaults.standard.object(forKey: "atc.map.airspace") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(showAirspace, forKey: "atc.map.airspace") }
    }
    @Published var showNearby = (UserDefaults.standard.object(forKey: "atc.map.nearby") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(showNearby, forKey: "atc.map.nearby") }
    }
    @Published var showWxRadar = UserDefaults.standard.bool(forKey: "atc.map.wxRadar") {   // stub overlay for now
        didSet { UserDefaults.standard.set(showWxRadar, forKey: "atc.map.wxRadar") }
    }
    /// Master switch for the live map background — off shows a plain background instead, saving battery on
    /// hot/old devices. Persisted (default on).
    @Published var mapBackgroundEnabled = (UserDefaults.standard.object(forKey: "atc.map.background") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(mapBackgroundEnabled, forKey: "atc.map.background") }
    }
    /// True when the device is thermally stressed — the home map pauses so it never starves transcription.
    /// Updated from `ProcessInfo.thermalStateDidChangeNotification` (observer installed in `init`).
    @Published var thermalSerious = ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue

    /// The floating-widget layout (positions, sizes, opacity, visibility, pins). Persisted JSON.
    @Published var widgetLayout: WidgetLayout = AppModel.initialWidgetLayout() {
        didSet { widgetLayout.save() }
    }

    /// First run under the redesign migrates the old `atc.sidebarWidgets` list into a layout; else defaults.
    /// `--reset-widgets` (UI tests / recovery) forces the default layout regardless of what's persisted.
    nonisolated static func initialWidgetLayout() -> WidgetLayout {
        if CommandLine.arguments.contains("--reset-widgets") { return .defaults() }
        if let saved = WidgetLayout.load() { return saved }
        if let ids = UserDefaults.standard.array(forKey: "atc.sidebarWidgets") as? [String] {
            return .migrating(fromSidebarIDs: ids)
        }
        return .defaults()
    }

    func updateWidget(_ kind: FloatingWidgetKind, _ mutate: (inout WidgetFrame) -> Void) { widgetLayout.update(kind, mutate) }
    func bringWidgetToFront(_ kind: FloatingWidgetKind) { widgetLayout.bringToFront(kind) }
    func showFloatingWidget(_ kind: FloatingWidgetKind) {
        widgetLayout.update(kind) { $0.visible = true }
        widgetLayout.bringToFront(kind)
    }
    func resetWidgetLayout() { widgetLayout = .defaults() }

    // "What's new" popup: shown once after the app updates to a newer build (gated on CFBundleVersion
    // vs the persisted `atc.lastSeenBuild`). `whatsNewEntries` holds the release notes the sheet
    // renders; Settings → About re-shows the full log without touching this gate.
    @Published var showWhatsNew = false
    @Published var whatsNewEntries: [ReleaseNote] = []
    private static let lastSeenBuildKey = "atc.lastSeenBuild"
    /// True when the sheet was opened via the `--whats-new` preview override — so dismissing it must
    /// NOT advance the persisted baseline (a preview shouldn't consume a genuine pending catch-up).
    private var whatsNewForcedPreview = false

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
        didSet {
            UserDefaults.standard.set(manualSquelch, forKey: "atc.manualSquelch")
            if !suppressCalibrationClear { calibratedGateRMS = nil }   // dragging the slider overrides a calibration
            applySquelch()
        }
    }
    /// An absolute manual gate (RMS) from mic calibration — used verbatim (uncapped) when Manual is on,
    /// so a loud room gets its true gate instead of one clamped to the slider ceiling. nil = use the
    /// slider. Cleared when the user drags the slider. Persisted.
    @Published var calibratedGateRMS: Float? = (UserDefaults.standard.object(forKey: "atc.calibratedGate") as? Double).map(Float.init) {
        didSet {
            if let g = calibratedGateRMS { UserDefaults.standard.set(Double(g), forKey: "atc.calibratedGate") }
            else { UserDefaults.standard.removeObject(forKey: "atc.calibratedGate") }
        }
    }
    /// Guards the manualSquelch didSet from wiping a just-applied calibration when WE move the slider.
    private var suppressCalibrationClear = false

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
    /// Backgrounding (home screen / app switcher) pauses capture so the app doesn't keep streaming +
    /// playing the live feed in the background. These remember what to resume when the app returns.
    private var backgroundPaused = false
    private var backgroundResumeSource: SourceKind?
    /// Constructed in `init` (IUO so the publish closures can capture a fully-initialized `self`).
    private var adsbService: ADSBService!

    // Stratux receiver: an on-board ADS-B/GPS box (+ a cockpit-audio sidecar on its Pi) reached over
    // its own Wi-Fi. The traffic/GPS link runs whenever `stratuxEnabled` is on and the app is
    // foregrounded — no Start needed (see `stratuxTrafficActive`); cockpit AUDIO additionally requires
    // picking "Stratux receiver" as the input source and starting a run. Host + audio port persisted;
    // the traffic block feeds the SAME corrector pipeline as airplanes.live (see `applyTraffic`).
    /// The always-on Stratux link switch: traffic + GPS stream whenever this is on and the app is
    /// foregrounded (standby off) — independent of the input source (that only gates audio). Toggled
    /// from the Stratux bar (console) or Settings; auto-enabled by picking the receiver as the input.
    /// The initial value is assigned in `init` (migration: users who had the receiver selected as
    /// their source before this switch existed keep working).
    @Published var stratuxEnabled = false {
        didSet {
            guard didFinishInit, stratuxEnabled != oldValue else { return }
            UserDefaults.standard.set(stratuxEnabled, forKey: "atc.stratuxEnabled")
            // Surface the link card in the sidebar when the link turns on (mirrors the source
            // picker's auto-add) so the connection state is visible without the Add-widget menu.
            if stratuxEnabled, !widgets.contains(.stratux) { widgets.append(.stratux) }
            // Flipping the link changes BOTH providers — an enabled link also suppresses the
            // internet ADS-B poller (see `adsbActive`) — so reconcile both, not just Stratux.
            syncTraffic()
        }
    }
    @Published var stratuxHost = UserDefaults.standard.string(forKey: "atc.stratuxHost") ?? "192.168.10.1" {
        didSet {
            UserDefaults.standard.set(stratuxHost, forKey: "atc.stratuxHost")
            if didFinishInit, stratuxHost != oldValue { syncStratux() }
        }
    }
    @Published var stratuxAudioPort = (UserDefaults.standard.object(forKey: "atc.stratuxAudioPort") as? Int) ?? 8090 {
        didSet { UserDefaults.standard.set(stratuxAudioPort, forKey: "atc.stratuxAudioPort") }
    }
    @Published private(set) var stratuxGPS: StratuxGPS?
    @Published private(set) var stratuxStatus: StratuxStatus = .idle
    /// Built in `init` alongside `adsbService`.
    private var stratuxService: StratuxService!

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
    // Bumped on every model switch. A slow/stuck load checks it at its commit point and discards its
    // result if a newer switch superseded it, so an abandoned load can't clobber the live selection.
    private var modelSwapGeneration = 0
    // The in-flight load + its watchdog, cancelled when a newer switch starts. Cancellation can't
    // interrupt a non-cancellable CoreML compile mid-flight, but it stops the superseded load from
    // doing any more work once that step returns — so heavy compiles don't pile up across rapid taps.
    private var loadTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
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
        // Stratux receiver: traffic feeds the SAME `applyTraffic` pipeline as airplanes.live; GPS +
        // link health drive UI status only. Active whenever the Stratux link is enabled + the app is
        // foregrounded — independent of the input source (see `stratuxTrafficActive`).
        stratuxService = StratuxService(
            onTraffic: { [weak self] list, snapshotAt in
                Task { @MainActor in self?.applyTraffic(list, snapshotAt: snapshotAt) }
            },
            onGPS: { [weak self] gps in
                Task { @MainActor in self?.stratuxGPS = gps }
            },
            onStatus: { [weak self] status in
                Task { @MainActor in self?.stratuxStatus = status }
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
        // The Stratux link switch, evaluated AFTER `source` is settled. Migration: the switch didn't
        // exist before build 29 — "enabled" was implied by having the receiver selected as the source —
        // so a user in that state keeps traffic/GPS streaming without touching anything. (didSet side
        // effects are inert here: `didFinishInit` is still false.)
        stratuxEnabled = (UserDefaults.standard.object(forKey: "atc.stratuxEnabled") as? Bool)
            ?? (source == .stratux)
        if let link = value("--link") { streamURL = link }
        if args.contains("--debug") { showDebug = true }   // surface perf metrics (verification)
        if args.contains("--correct") { correctionEnabled = true }
        if args.contains("--llm") { correctionEnabled = true; llmBackend = .local }
        if args.contains("--llm-foundation") { correctionEnabled = true; llmBackend = .foundation }
        // Demo / screenshot affordance: seed a sample cross-country plan so the route map has a route
        // to draw without filing one (every ident resolves in the bundled nav DB). Persists like a
        // filed plan; harmless otherwise.
        if args.contains("--demo-flightplan") {
            flightPlan = FlightPlan(departure: "KBOS", destination: "KORD",
                                    route: ["ALB", "SYR", "BUF", "ERI", "DJB", "OBK"])
        }
        if args.contains("--demo-terminal") {   // screenshot/demo: a short terminal-area plan so the map
            flightPlan = FlightPlan(departure: "KBOS", destination: "KPVD",   // auto-frames zoomed-in over
                                    route: ["BOS", "PVD"])                     // Boston Class B + Providence Class C
        }
        if args.contains("--open-route-map") { showRouteMap = true }   // screenshot/demo: open the map at launch
        // The FAA chart is now a layer on the unified route map; `--open-chart` opens it there. Pair with
        // `--chart-layer ifr|vfr|std|sat` to pick the layer and `--chart-center lat,lon` to frame it.
        if args.contains("--open-chart") { showRouteMap = true }
        if args.contains("--open-settings") { showSettings = true }     // screenshot/demo: open Settings at launch

        #if targetEnvironment(simulator)
        deviceLabel = "CPU (Simulator)"
        let cpuOnly = true
        #else
        let cpuOnly = false
        #endif
        storedCPUOnly = cpuOnly

        // Reclaim disk from any Whisper model folder orphaned by a variant bump (e.g. the old `small/`
        // superseded by `small-v2` in build 21) — only non-current variants are removed, never a live
        // model, so this is safe to run on every launch.
        ModelStore.pruneStaleWhisperVariants()

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
            modelSource = explicitModel != nil ? "launch"
                : (ModelStore.downloadedWhisperDir() != nil ? "downloaded" : "bundled")
            // First launch only (no source ever saved): default to the self-contained Replay demo
            // so a fresh install transcribes on the first Start with no network or mic needed. A
            // saved source preference (or an explicit --source) wins on later launches.
            if value("--source") == nil, UserDefaults.standard.string(forKey: "atc.source") == nil,
               audioDir != nil { source = .replay }
            let autostart = args.contains("--autostart")
            beginModelLoad(models: models, active: active, audioDir: audioDir, autostart: autostart)
        } else {
            seedSampleData()   // no model yet — populated demo layout behind the download gate
            // Gate the first launch on downloading the required model, unless launched with an
            // explicit flag or the user already chose to skip on a previous launch.
            needsOnboarding = explicitModel == nil && !Self.onboardingDismissed
        }
        didFinishInit = true   // from here, a showDebug toggle may add the debug widgets
        // Bring the traffic providers in line with the restored state: the Stratux link is decoupled
        // from Start (see `stratuxTrafficActive`), so an enabled link must connect at launch — nothing
        // else fires an edge on a plain foreground launch (`scenePhaseActive` starts true, making the
        // first `.active` scene-phase change a no-op). Harmless when everything is off.
        syncTraffic()
        // Pause the live home map under thermal pressure so it never starves on-device transcription.
        NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            let hot = ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
            Task { @MainActor in self?.thermalSerious = hot }
        }
        evaluateWhatsNew()     // decide whether to greet this launch with the "What's new" popup
    }

    var palette: Palette { theme.palette }
    var isRunning: Bool { status == .live || status == .connecting || status == .starting }
    /// A REAL capture session is live (a model is loaded and running) — as opposed to the model-less
    /// demo, which shows `.live` but has no audio source bound. Used to lock the input-source picker
    /// only when switching would actually strand the pipeline on the old provider.
    var isLiveCapturing: Bool { isRunning && liveMode }
    /// Friendly name for the status badge / sidebar (maps the raw id, e.g. "cleanturbo" → "Large V2").
    /// While a model is loading it shows the model being LOADED, so a slow first load doesn't keep the
    /// widgets showing the previous/default model ("Small") the whole time.
    var activeModelLabel: String { ModelCatalog.shortLabel(forID: loadingModel ?? activeModel) }

    // MARK: live wiring

    /// Build a session for `active` and (on success) make it the live one. Returns false if the model
    /// can't be loaded or the swap was superseded — in which case **nothing is torn down**, so the
    /// previously-loaded model keeps working. A big model (e.g. Large V2) can take a long time, or
    /// stall, to load the first time CoreML compiles it; the old session stays usable throughout and
    /// is only released once the new one is fully built (see `switchModel`'s watchdog + generation).
    @discardableResult
    private func setupLive(models: [String: String], active: String, audioDir: String?, cpuOnly: Bool,
                           autostart: Bool, preserveHistory: Bool = false, generation: Int? = nil) async -> Bool {
        guard let modelDir = models[active] else { detail = "Model unavailable."; return false }
        // Snapshot the visible transcript so the new session can adopt it (a swap isn't destructive to
        // history). The OLD session keeps running/loaded until the new model is confirmed loaded.
        let savedRecords = records
        let savedStats = stats
        let engine = TranscriberEngine(models: models, defaultModel: active,
                                       fallbackModel: models["small"] != nil ? "small" : active,
                                       adaptive: false, cpuOnly: cpuOnly)
        let transcriber = ATCTranscriber(modelFolder: modelDir, cpuOnly: cpuOnly)
        do {
            try await transcriber.load()
            // Superseded by a newer switch while this compile ran? Bail before building anything else,
            // so an abandoned load stops consuming resources as soon as its CoreML step returns.
            if let generation, generation != modelSwapGeneration { return false }
            modelLoadError = nil
            // Share the just-loaded model with the engine so the performance check reuses it instead of
            // compiling a SECOND resident copy (two big models in memory at once).
            await engine.adopt(transcriber, name: active)
        } catch {
            // Only the current (or generation-less init/download) load may write status — a superseded
            // load that fails late must not flash a stale "failed" over the newer selection.
            if generation == nil || generation == modelSwapGeneration {
                modelLoadError = error.localizedDescription
                detail = "Model failed to load: \(error.localizedDescription)"
            }
            return false                          // old session/engine untouched → still usable
        }

        // Build the new context + corrector into LOCALS first (no `self.*` mutation yet) so a swap that
        // is superseded mid-load — or whose model loaded but is no longer wanted — can be discarded
        // without disturbing the live session. Load a facility config so the corrector vocabulary +
        // RAG retrieval have data (shipping default KDFW; a typed airport overrides it).
        // QW1: only load a facility config when the user actually named an airport. Defaulting to KDFW
        // primed Whisper with DFW runways/fixes/TRACON on ANY feed (e.g. a KBOS internet stream),
        // biasing the decode toward the wrong runway numbers + facility names. No airport → neutral
        // ATC prompt, which can't mislead.
        let cfg = airport.isEmpty ? nil : (try? AirportConfig.load(named: airport.lowercased()))
        let feedKey = cfg?.streams?.keys.sorted().first
        let context = ATCContext(config: cfg, feedKey: feedKey)
        // Seed the filed flight plan (Electronic Flight Bag) before the pipeline starts using the
        // context, so the first transmission's LLM correction already sees the pilot's own callsign,
        // airports, and route. Live edits afterward go through `pushFlightPlanContext`.
        if let fp = flightPlan { context.setFlightPlan(block: fp.contextBlock, vocab: fp.vocabTerms) }
        // Seed the traffic epoch into the fresh context so clear-ordering survives the rebuild, then
        // re-seed the last FRESH ADS-B snapshot so a model swap doesn't blank traffic context until
        // the next poll (~5s). The read-site expiry self-expires it if the poller doesn't return.
        context.clearTraffic(epoch: trafficEpoch)
        if trafficActive, !aircraft.isEmpty, let at = aircraftUpdatedAt,
           Date() < at.addingTimeInterval(adsbTrustWindow) {
            let (block, vocab) = Self.trafficContext(aircraft)
            context.setTraffic(block: block, vocab: vocab,
                               expiry: at.addingTimeInterval(adsbTrustWindow), epoch: trafficEpoch)
        }

        // Build/reuse the optional slow-tier LLM off the main actor. The GGUF loads at most once per
        // app run (cached), so a whisper-model swap no longer reloads ~400 MB off disk. (`currentCorrector`
        // reads `self.liveContext` lazily at transcribe time, so building it before the commit is fine.)
        let llm = await makeLLMCorrector(knowledge: context.knowledge, feedKey: feedKey)

        let pipeline = LivePipeline(transcriber: transcriber, context: context,
                                    preprocessor: livePreprocessor(),
                                    corrector: currentCorrector(), llm: llm,
                                    gateEnabled: skipWhenConfident, gateSensitivity: gateSensitivity,
                                    diarizationEnabled: diarizationEnabled,
                                    vadConfig: VADConfig(squelchAuto: squelchAuto,
                                                         squelchLevel: Float(manualSquelch),
                                                         calibratedGateRMS: squelchAuto ? nil : calibratedGateRMS))
        let session = TranscriptionSession(pipeline: pipeline)
        if preserveHistory { session.adopt(records: savedRecords, stats: savedStats) }  // survive a model swap

        // Commit point. If a newer switch superseded this one while the model (or the LLM) was loading,
        // discard this result — nothing above touched `self.*`, so the live session is unaffected.
        if let generation, generation != modelSwapGeneration { return false }

        // Now that the new session is fully built, release the OLD one (severing its UI bindings +
        // freeing the old whisper model) and wire the new one in. Doing this only AFTER the load means
        // there is never a window with no usable model.
        let oldSession = self.session
        self.session = nil
        self.feedKey = feedKey
        self.liveContext = context
        session.$records.assign(to: &$records)   // mirror live session state into the UI
        session.$status.assign(to: &$status)
        session.$stats.assign(to: &$stats)
        session.$inputLevel.assign(to: &$inputLevel)
        session.$transcribing.assign(to: &$transcribing)
        session.$transcribeStartedAt.assign(to: &$transcribeStartedAt)
        self.session = session
        self.engine = engine
        self.modelDirs = models
        self.activeModel = active
        // Stop the old session's source explicitly. `TranscriptionSession` has no deinit and its
        // run-loop Task strongly holds the pipeline + source, so dropping the reference alone would
        // NOT stop a source the user restarted during the watchdog-freed window (leaking a live feed /
        // network stream / hot mic). stop() no-ops when it was already stopped (the normal swap path).
        oldSession?.stop()

        // A flight-plan edit made WHILE the model was compiling (the await above) was routed to the OLD
        // session/context; the freshly-built context only has the entry-time snapshot. Re-push the
        // current plan now that the new session + context are committed, so the edit isn't lost.
        pushFlightPlanContext()

        if let audioDir { clips = (try? Self.loadClips(audioDir)) ?? [] }
        detail = clips.isEmpty ? "Model ready (no demo clips)." : "Ready — press Start."
        if autostart {
            // Only resume capture if we're on screen. If the model finished compiling while the app was
            // backgrounded, do NOT start Whisper + the (Stratux) audio pipeline in the background — that
            // would run the AI hot with the screen off (the battery-drain rule). Defer via the same
            // background-resume path the scene-phase handler uses; it restarts on foreground.
            if scenePhaseActive { start(resuming: preserveHistory) }
            else { backgroundResumeSource = source; backgroundPaused = true }
        }
        return true
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
        session?.setSquelch(auto: squelchAuto, level: Float(manualSquelch),
                            calibratedGateRMS: squelchAuto ? nil : calibratedGateRMS)
    }

    // MARK: - Mic squelch calibration
    // Guided two-step measurement: record the room's ambient noise, then record the user speaking, and
    // set the squelch to a gate between the two (via `SquelchCalibration`). This hands the threshold a
    // real measurement of THIS device + room instead of a guessed constant — the reliable fix for a
    // mic whose ambient the auto floor can't perfectly separate. Device-only (needs a real mic).

    enum CalibrationStage: Equatable {
        case idle              // ready to record ambient (step 1)
        case measuringAmbient
        case ambientDone       // ambient captured, ready to record the voice (step 2)
        case measuringVoice
        case success(gate: Float)
        case failed(String)
    }
    @Published var calibrationStage: CalibrationStage = .idle
    @Published var showMicCalibration = false
    private var calibrationAmbientRMS: Float?
    /// The in-flight measurement (cancelled by resetCalibration so a dismissed/retried flow can't keep
    /// the mic engine running or write a stale result).
    private var calibrationTask: Task<Void, Never>?

    /// Calibration and a live run can't share the audio engine, so it's only offered while stopped.
    var canCalibrateMic: Bool { !isRunning }

    /// Step 1 — capture the room's background level (requests mic permission on first use).
    func recordCalibrationAmbient() {
        guard !isRunning else { calibrationStage = .failed("Stop the feed before calibrating."); return }
        guard calibrationStage == .idle || isFailed else { return }   // reject re-entry (double-tap)
        calibrationStage = .measuringAmbient   // flip synchronously so the button is replaced at once
        requestMicPermission { [weak self] granted in
            guard let self, self.calibrationStage == .measuringAmbient else { return }
            guard granted else {
                self.calibrationStage = .failed("Microphone access is off. Enable it in Settings › CommSight › Microphone.")
                return
            }
            AudioSessionManager.activate(recording: true)
            self.calibrationTask = Task { @MainActor in
                do {
                    let rms = try await MicCalibrator.measureRMS(seconds: 2.0)
                    guard !Task.isCancelled, case .measuringAmbient = self.calibrationStage else { return }
                    self.calibrationAmbientRMS = rms
                    self.calibrationStage = .ambientDone
                } catch {
                    guard !Task.isCancelled else { return }
                    AudioSessionManager.deactivate()
                    self.calibrationStage = .failed("Couldn't read the microphone — make sure it isn't muted or used by another app.")
                }
            }
        }
    }

    /// Step 2 — capture the user's voice and, if it's clearly louder than the room, set the squelch.
    func recordCalibrationVoice() {
        guard !isRunning, calibrationStage == .ambientDone, let ambient = calibrationAmbientRMS else { return }
        calibrationStage = .measuringVoice
        AudioSessionManager.activate(recording: true)   // re-establish in case the app backgrounded between steps
        calibrationTask = Task { @MainActor in
            defer { if !self.isRunning { AudioSessionManager.deactivate() } }
            do {
                let voice = try await MicCalibrator.measureRMS(seconds: 3.0)
                guard !Task.isCancelled, case .measuringVoice = self.calibrationStage else { return }
                guard let gate = SquelchCalibration.gate(ambientRMS: ambient, speechRMS: voice) else {
                    self.calibrationStage = .failed("Your voice wasn't clearly louder than the background. Speak normally a bit closer to the device, or move somewhere quieter, and try again.")
                    return
                }
                // Apply the ABSOLUTE calibrated gate (uncapped) as the manual squelch, and move the slider
                // to reflect it (clamped for display). Persisted via the didSet chain → the running / next
                // mic session picks it up. `suppressCalibrationClear` keeps the slider move from wiping it.
                self.calibratedGateRMS = gate
                self.squelchAuto = false
                self.suppressCalibrationClear = true
                self.manualSquelch = Double(min(1, gate / VADSegmenter.manualGateMaxRMS))
                self.suppressCalibrationClear = false
                self.applySquelch()
                self.calibrationStage = .success(gate: gate)
            } catch {
                guard !Task.isCancelled else { return }
                self.calibrationStage = .failed("Couldn't read the microphone — make sure it isn't muted or used by another app.")
            }
        }
    }

    /// Reset the flow (sheet open/close/retry): cancel any in-flight measurement and release the session.
    func resetCalibration() {
        calibrationTask?.cancel()
        calibrationTask = nil
        calibrationStage = .idle
        calibrationAmbientRMS = nil
        if !isRunning { AudioSessionManager.deactivate() }
    }

    private var isFailed: Bool { if case .failed = calibrationStage { return true }; return false }

    private func requestMicPermission(_ completion: @escaping (Bool) -> Void) {
        #if os(iOS)
        AVAudioApplication.requestRecordPermission { granted in Task { @MainActor in completion(granted) } }
        #else
        completion(true)
        #endif
    }

    /// Push the filed flight plan into the running correction context (or clear it). Called when
    /// the plan changes; the initial value is seeded directly onto the context in `setupLive`.
    func pushFlightPlanContext() {
        session?.setFlightPlanContext(block: flightPlan?.contextBlock ?? "",
                                      vocab: flightPlan?.vocabTerms ?? [])
    }

    // MARK: Flight-plan edits from the map (tap an object → act on the route)

    /// Apply an edit to the filed plan and reassign it, so the `flightPlan` didSet persists + re-prefetches.
    /// A plan that becomes empty is cleared to nil.
    private func editPlan(_ mutate: (inout FlightPlan) -> Void) {
        var p = flightPlan ?? FlightPlan()
        mutate(&p)
        flightPlan = p.isEmpty ? nil : p
    }

    func addToRoute(_ ident: String) { editPlan { $0.addWaypoint(ident) } }
    func insertInRoute(_ ident: String, at coord: Coord, resolved: [ResolvedLeg]) {
        editPlan { $0.insertWaypointInOrder(ident, at: coord, resolved: resolved) }
    }
    func directTo(_ ident: String) { editPlan { $0.directTo(ident) } }
    func setDeparture(_ ident: String) { editPlan { $0.setDeparture(ident) } }
    func setDestination(_ ident: String) { editPlan { $0.setDestination(ident) } }
    func removeFromRoute(_ ident: String) { editPlan { $0.removeWaypoint(ident) } }

    // MARK: Chart prefetch (background — so the map opens instantly)

    /// The raster layers worth pre-downloading: the remembered layer when it's a chart, else VFR sectional.
    private var prefetchChartLayers: [ChartLayer] { chartLayer.isRaster ? [chartLayer] : [.sectional] }

    /// Prefetch the FAA packs the filed route crosses. Called when a plan is filed/edited so the charts
    /// are on disk before the pilot opens the map. Resolves the route OFF the main thread (first nav-DB
    /// access parses a few MB) and no-ops when nothing is filed.
    func prefetchRouteCharts() {
        guard let legs = flightPlan?.fullRoute, !legs.isEmpty else { return }
        let layers = prefetchChartLayers
        Task {
            let points = await Task.detached(priority: .utility) {
                _ = NavDatabase.count
                return RouteResolver.resolve(legs).points
            }.value
            let rects = ChartGeo.routeRects(points)
            guard !rects.isEmpty else { return }
            await ChartLibrary.shared.prefetch(rects: rects, layers: layers, cap: 12)
        }
    }

    /// Prefetch the charts around the device (GPS, or the Stratux fix when connected) plus the last filed
    /// route — kicked on launch and each foreground so the map is warm by the time it's opened.
    func prefetchChartsOnLaunch() {
        let layers = prefetchChartLayers
        let stratux = stratuxGPS?.coordinate
        Task {
            if let here = await ChartLibrary.shared.nearestFix(preferring: stratux) {
                await ChartLibrary.shared.prefetchAround(here, layers: layers)
            }
        }
        prefetchRouteCharts()
    }

    // MARK: ADS-B live traffic

    /// Whether airplanes.live (internet) ADS-B should be polling now. Session-coupled by design (its
    /// Settings copy promises it only runs while transcribing) and suppressed while the Stratux link
    /// is streaming — that path provides traffic on-board instead (works with no internet), and both
    /// providers publish into the same `applyTraffic`, so at most one may run.
    private var adsbActive: Bool { adsbStreamingEnabled && !stratuxTrafficActive && isRunning && liveMode && scenePhaseActive }
    /// Whether the Stratux link should be streaming traffic/GPS now: whenever it's enabled, the app
    /// is foregrounded, and standby is off — independent of the input source and of a running
    /// session (audio still requires picking the source + Start; see `beginCapture`). `!standby`
    /// is explicit because standby's whole point is stopping battery drain, and without `isRunning`
    /// in this predicate nothing else would stop the link there.
    private var stratuxTrafficActive: Bool { stratuxEnabled && scenePhaseActive && !standby }
    /// Either traffic provider is feeding the corrector/UI right now.
    private var trafficActive: Bool { adsbActive || stratuxTrafficActive }

    /// Reconcile BOTH traffic providers with the current state (at most one streams — an enabled
    /// Stratux link outranks the internet poller). Call on every transition (start/stop, source
    /// change, link toggle, standby, scene phase).
    func syncTraffic() { syncADSB(); syncStratux() }

    /// Reconcile the airplanes.live poller (single edge-triggered call). Polls only while online ADS-B
    /// is ON, the Stratux link is not streaming, a live session is running, and the app is foregrounded.
    func syncADSB() {
        let center = facilityCoordinate()
        let active = adsbActive
        let service = adsbService
        Task { await service?.sync(center: center, enabled: active) }
    }

    /// Reconcile the Stratux link (traffic WebSocket + GPS poll). Streams whenever the link is
    /// enabled and the app is foregrounded (standby off) — no session or source selection required.
    func syncStratux() {
        let active = stratuxTrafficActive
        let host = stratuxHost
        let service = stratuxService
        Task { await service?.sync(host: host, enabled: active) }
    }

    /// The center for the 30 NM query: the typed airport's coordinate, or nil when blank/unknown (→ no
    /// polling). QW1: no longer defaults to KDFW when blank — pulling Dallas traffic into the correction
    /// prompt of a KBOS (or any) feed injects wrong-facility aircraft, the same wrong-airport bias QW1
    /// removed from the decoder prompt. Device GPS will sit ahead of this later.
    private func facilityCoordinate() -> Coord? {
        airport.isEmpty ? nil : AirportCoordinates.coordinate(icao: airport)
    }

    /// The audio preprocessor preset for the CURRENT source: a lighter touch for the already-compressed
    /// internet feed, the aggressive radio cleanup for clean wideband sources (Stratux/mic/USB/replay).
    /// Measured on a live 8 kHz feed: the aggressive band-pass + spectral gate caused hallucinations +
    /// lower confidence there, while still helping clean audio.
    private func livePreprocessor() -> AudioPreprocessor {
        source == .liveFeed ? AudioPreprocessor.lightCompressed() : AudioPreprocessor(aggressiveRadio: true)
    }

    /// Service published a snapshot: update the UI state and re-inject the corrector block. Guarded
    /// on `adsbActive` so a late callback that lands after a toggle-off / standby / background CLEARS
    /// the carousel + corrector instead of repopulating them (the callback hops the main actor async,
    /// so it can arrive after the synchronous clearTraffic()).
    private func applyTraffic(_ list: [Aircraft], snapshotAt: Date) {
        let active = trafficActive
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
        guard trafficActive, !list.isEmpty, snapshotAt != .distantPast else {
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
        // Provider-neutral wording — the same block serves airplanes.live and the Stratux receiver.
        return ("Traffic in range: " + labels.joined(separator: ", ") + ".", labels)
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

    /// Respond to app foreground/background transitions. **Backgrounding** (home screen / app switcher)
    /// STOPS capture and releases the audio session, so the app doesn't keep streaming + playing the
    /// live ATC feed (and draining the battery) while it isn't on screen; **foregrounding** resumes
    /// whatever was running. `.inactive` — a transient overlay like Control Center or an incoming call
    /// banner — is ignored so a quick glance doesn't tear the feed down. ADS-B is paused/cleared in the
    /// background either way.
    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            guard !scenePhaseActive else { return }
            scenePhaseActive = true
            syncTraffic()
            prefetchChartsOnLaunch()        // top up charts around the (possibly moved) position
            if backgroundPaused {
                backgroundPaused = false
                let resume = backgroundResumeSource
                backgroundResumeSource = nil
                if let resume { source = resume; start(resuming: true) }
            }
        case .background:
            guard scenePhaseActive else { return }
            scenePhaseActive = false
            clearTraffic()
            // Stop capture so the feed isn't streamed/played in the background, and release the audio
            // session so the `audio` background mode can't keep the app awake (the battery drain + the
            // "I still hear ATC on the home screen" report).
            if isRunning { backgroundResumeSource = source; backgroundPaused = true; stop() }
            AudioSessionManager.deactivate()
            syncTraffic()
        case .inactive:
            break                       // transient — don't tear down the feed
        @unknown default:
            break
        }
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
                    .map { wrapWithRemoteCascade($0, knowledge: knowledge, feedKey: feedKey) }
            }.value
        case .local:
            if cachedLLMEngine == nil || cachedLLMBackend != .local {
                cachedLLMEngine = await Task.detached(priority: .utility) { makeLocalLLMEngine() }.value
                cachedLLMBackend = .local
            }
            guard let engine = cachedLLMEngine else { return nil }   // GGUF not present yet — retry next build
            return wrapWithRemoteCascade(
                LocalLLMCorrector(engine: engine, knowledge: knowledge, feedKey: feedKey),
                knowledge: knowledge, feedKey: feedKey)
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

    /// The AI fixer GGUF finished downloading (it isn't bundled in the speech-only build). Drop any
    /// empty cached engine and rebuild the corrector so a running session starts using the fixer now,
    /// rather than only after the next model swap or relaunch.
    func refreshLLMAfterDownload() {
        cachedLLMEngine = nil; cachedLLMBackend = .off   // force makeLocalLLMEngine to pick up the new GGUF
        rebuildLLM()
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
        case .stratux:
            // Cockpit audio from the Stratux sidecar (raw 16 kHz PCM at <host>:<port>/audio.raw). On-
            // board ADS-B/GPS run over the always-on Stratux link (auto-enabled when this source is
            // picked), not through this capture path. Monitored like the feed so it can be heard/
            // verified on the ground (mute it in the cockpit via the speaker toggle).
            guard let stx = StratuxAudioSource(host: stratuxHost, audioPort: stratuxAudioPort,
                                               onTrouble: { [weak self] msg in Task { @MainActor in self?.detail = msg } }) else {
                detail = "Set a valid Stratux address in Settings › Stratux receiver."; return
            }
            audioMonitor.setMuted(!monitorEnabled)
            src = MonitoredSource(stx, monitor: audioMonitor)
        }
        // Hold an active audio session for every source so transcription continues when the app is
        // backgrounded (the `audio` background mode is declared). mic/USB record; feed/replay/Stratux play.
        AudioSessionManager.activate(recording: source == .microphone || source == .usbAudio,
                                     preferUSB: source == .usbAudio)
        // Bind the source-appropriate preprocessor NOW: the session/pipeline was built at setupLive, but
        // the user can Stop → switch source → Start without rebuilding it, so re-pick the preset here so a
        // wideband source never keeps the internet feed's light preset (or vice-versa).
        session.setPreprocessor(livePreprocessor())
        session.start(source: src, label: source.rawValue, clearHistory: !resuming)
        if !resuming { callsignFilter = nil }   // a fresh transcript replaces history → drop a stale filter
        sourceLabel = source.rawValue
        detail = "Transcribing."
        syncTraffic()   // a live session started → the session-coupled ADS-B poller may begin (Stratux is independent)
    }

    func stop() {
        // The session releases the audio session itself (on Stop and on a natural end); the demo
        // path never activated one, so nothing to release here.
        if let session { session.stop() } else { status = .stopped }
        detail = "Stopped."
        syncTraffic()   // no live session → stop the session-coupled ADS-B poller (an enabled Stratux link keeps streaming)
    }

    /// Enter standby: stop capture and release the audio session so a quiet, unattended feed
    /// stops draining the battery. Remembers whether a source was running so Resume can pick up
    /// where it left off.
    func enterStandby() {
        if isRunning { resumeSource = source; stop() } else { resumeSource = nil }
        // Belt-and-suspenders: unconditionally release the audio session so the `audio` background mode
        // can't keep the app (and the audio hardware) awake in standby. stop() already does this on the
        // running path; this also covers the not-running path and any edge where the session lingered,
        // so once the screen locks the device can actually suspend instead of draining at full tilt.
        AudioSessionManager.deactivate()
        detail = "Standby — capture paused."
        standby = true
        // Standby exists to stop battery drain — the always-on Stratux link follows it down too
        // (`stratuxTrafficActive` gates on `!standby`; the stop() above only fired if capture ran).
        syncTraffic()
    }

    /// Leave standby. If a source was running when standby began, restart it; otherwise just
    /// return to the idle console.
    func exitStandby() {
        standby = false
        syncTraffic()   // re-open an enabled Stratux link on wake (the resume below only covers capture)
        if let s = resumeSource { source = s; start(resuming: true) }
        resumeSource = nil
    }

    // MARK: "What's new" popup

    /// Decide whether to show the "What's new" popup for this launch. Called once at the end of `init`,
    /// after the onboarding decision is final. Shows the catch-up of any builds the tester hasn't seen
    /// since `atc.lastSeenBuild`; records the running build silently when there's nothing to show.
    private func evaluateWhatsNew() {
        // Test/preview seam: force the full changelog regardless of the gate (dev builds report
        // CFBundleVersion "1", so the auto-path is otherwise dormant in the Simulator). It's a preview,
        // so it must NOT advance the persisted baseline (see `whatsNewDismissed`). Respect the onboarding
        // cover — a sheet can't present under a fullScreenCover — and defer to `finishOnboarding`.
        if CommandLine.arguments.contains("--whats-new") {
            whatsNewEntries = WhatsNew.releaseNotes
            whatsNewForcedPreview = true
            if !needsOnboarding { showWhatsNew = true }
            return
        }
        let current = WhatsNew.currentBuild()
        let lastSeen = UserDefaults.standard.integer(forKey: Self.lastSeenBuildKey)
        let entries = WhatsNew.autoShowEntries(lastSeen: lastSeen, current: current, onboarding: needsOnboarding)
        guard !entries.isEmpty else {
            // Nothing to show (already seen, a downgrade, or a relaunch): advance the baseline so the
            // next genuine update shows. While the onboarding gate is up, leave it to `finishOnboarding`
            // so a fresh install's baseline is set only once it's actually past onboarding. NOTE: an
            // absent key reads as 0 here, so an existing install updating from a pre-feature build (no
            // baseline yet) correctly gets the catch-up — that's the intended debut on the lean ship
            // path, where every truly-fresh install instead goes through onboarding first.
            if !needsOnboarding { markWhatsNewSeen() }
            return
        }
        whatsNewEntries = entries
        showWhatsNew = true
    }

    /// Record the running build as seen so the popup doesn't reappear until the next update. Never
    /// lowers the stored value (so a downgrade build can't replay an old changelog). Called after
    /// onboarding and (via `whatsNewDismissed`) when the sheet closes.
    func markWhatsNewSeen() {
        let stored = UserDefaults.standard.integer(forKey: Self.lastSeenBuildKey)
        UserDefaults.standard.set(WhatsNew.advancedBaseline(stored: stored, current: WhatsNew.currentBuild()),
                                  forKey: Self.lastSeenBuildKey)
    }

    /// The What's-new sheet was dismissed (button or swipe). Advance the baseline so it won't reappear
    /// until the next update — UNLESS it was a `--whats-new` preview, which must leave a genuine pending
    /// catch-up intact.
    func whatsNewDismissed() {
        if !whatsNewForcedPreview { markWhatsNewSeen() }
        whatsNewForcedPreview = false
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
        // A BUNDLED required (Small) model is AUTHORITATIVE: it's baked into the app and verified at
        // build time, so prefer it over any downloaded copy — this sidesteps a failed/partial on-device
        // download of the same model leaving an unloadable folder. In a lean build bundledModelDir() is
        // nil, so a downloaded model still wins (unchanged behavior).
        if let bundled = bundledModelDir() { m["small"] = bundled }
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

    /// Accuracy-preference rank (lower = better), mirroring `preferredActiveModel`'s turbo→small order.
    /// Used to decide which of two candidate models should win when several are resolving at once.
    static func preferredRank(_ id: String) -> Int { ["turbo", "small"].firstIndex(of: id) ?? Int.max }

    /// Is a given whisper variant present on disk? Drives the Settings picker's enablement.
    func modelDownloaded(_ id: String) -> Bool { modelDirs[id] != nil }

    /// Load `active` as the live model from a no-working-model state (first launch / right after a
    /// download). Unlike `switchModel` there is nothing to fall back to, so a slow or failed load is
    /// SURFACED — and the download gate re-offered — instead of hanging on "Loading model…" forever.
    /// Shows the model actually being loaded (so the widgets don't keep showing the default "Small").
    private func beginModelLoad(models: [String: String], active: String, audioDir: String?, autostart: Bool) {
        self.modelDirs = models
        liveMode = true
        loadingModel = active            // `activeModelLabel` now reflects the model being loaded
        modelLoadStartedAt = Date()      // drives the on-screen elapsed timer
        modelLoadError = nil
        proofOfLife = nil                // drop the demo "performance check" so it doesn't show a stale model
        records = []; stats = LatencyStats()
        status = .idle                   // clear any demo `.live` state so loading isn't seen as "running"
        detail = "Loading \(ModelCatalog.shortLabel(forID: active))…"
        modelSwapGeneration += 1
        let gen = modelSwapGeneration
        watchdogTask?.cancel(); loadTask?.cancel()
        // Watchdog: a big model (Large V2 especially) can take a long time — or stall — to load the
        // first time CoreML compiles it for this device. If there's still no usable model after a long
        // grace period, stop hanging on the spinner and surface a recovery instead.
        watchdogTask = Task {
            try? await Task.sleep(nanoseconds: 60_000_000_000)   // 60s — a first big-model compile can be slow
            guard !Task.isCancelled, modelSwapGeneration == gen, loadingModel == active, session == nil else { return }
            loadingModel = nil
            surfaceInitialLoadProblem(active: active,
                reason: "\(ModelCatalog.shortLabel(forID: active)) is taking too long to load — it may be too large for this device.")
        }
        loadTask = Task {
            let ok = await setupLive(models: models, active: active, audioDir: audioDir,
                                     cpuOnly: storedCPUOnly, autostart: autostart, generation: gen)
            guard modelSwapGeneration == gen else { return }
            if loadingModel == active { loadingModel = nil }
            if !ok, session == nil {
                surfaceInitialLoadProblem(active: active,
                    reason: modelLoadError.map { "Couldn’t load \(ModelCatalog.shortLabel(forID: active)): \($0)" }
                        ?? "Couldn’t load \(ModelCatalog.shortLabel(forID: active)).")
            }
        }
    }

    /// The user's chosen model wouldn't load and there is no usable model. Explain it, and if no
    /// reliable (fine-tuned) model is on disk, bring the download gate back so the Small model is one
    /// tap away — so a device that can't run the big model isn't left permanently stuck.
    private func surfaceInitialLoadProblem(active: String, reason: String) {
        modelLoadError = reason
        // Don't leave the app stranded with NO session — Start would silently fail and the widgets
        // would still read "Small" (the default `activeModel`) even though nothing is loaded. If the
        // Small model is downloaded, load it automatically so the app ends up usable; loading it also
        // commits it as the active model, so the next launch goes straight to Small instead of
        // retrying the model that won't load. Fall back FROM another model only (no Small→Small loop).
        if active != "small", modelDownloaded("small") {
            detail = "\(reason) Loading the Small model instead."
            beginModelLoad(models: modelDirs, active: "small", audioDir: audioDirPath, autostart: false)
        } else if !modelDownloaded("small") {
            detail = "\(reason) Download the Small model to continue."
            needsOnboarding = true
        } else {
            // The Small (required) model itself failed to LOAD despite being on disk — its files are
            // corrupt/incomplete, so a picker retry would just re-fail. Wipe the folder so it stops
            // reading as "ready", drop the stale resolution, and re-show the download gate — which now
            // offers a working Download button for a clean copy instead of a dead-end message.
            try? FileManager.default.removeItem(at: ModelStore.whisperDir(ModelCatalog.small.variant ?? "small"))
            modelDirs["small"] = nil
            detail = "\(reason) The Small model looks corrupt — re-download it to continue."
            needsOnboarding = true
        }
    }

    /// Abandon an in-flight model swap and stay on the current (resident) model — used when the user
    /// re-selects the model that's still running while another is loading. The active model never left,
    /// so there's nothing to reload: supersede the load (bump the generation so its late result is
    /// discarded at the commit gate), cancel its tasks, and unlock the picker.
    private func cancelModelLoad(detail newDetail: String) {
        modelSwapGeneration += 1
        watchdogTask?.cancel(); watchdogTask = nil
        loadTask?.cancel(); loadTask = nil
        loadingModel = nil
        detail = newDetail
    }

    /// Switch the active transcription model (Settings picker). Rebuilds the engine + live session
    /// against the chosen variant's folder. No-op if it isn't downloaded or is already active. A pick
    /// made while another model is loading supersedes that load; re-picking the running model cancels it.
    /// Preserves run state: if a source was live it restarts after the new model loads.
    func switchModel(_ id: String) {
        guard liveMode, modelDirs[id] != nil else { return }
        // Let the user change their mind WHILE a model is compiling. The swap is non-destructive, so a
        // different pick just supersedes the in-flight load (the old model keeps running until whichever
        // load lands), and re-tapping the running model cancels the swap and stays put. Only re-tapping
        // the model already loading is a no-op. (This used to be a hard lock — EVERY tap was dropped for
        // the whole compile, trapping the user on "Loading…" with no escape.)
        if let loading = loadingModel {
            if id == loading { return }                              // already loading this one
            if id == activeModel, session != nil {                  // tap the still-running model → cancel
                cancelModelLoad(detail: "Staying on \(ModelCatalog.shortLabel(forID: id)).")
                return
            }
            // else: a different model → fall through and supersede the in-flight load.
        } else {
            // Nothing loading: skip a plain reselect of the active model — unless there's NO working
            // session (a prior load stranded us), in which case allow reselect to retry/recover.
            guard session == nil || id != activeModel else { return }
        }
        let wasRunning = isRunning
        // Do NOT stop() here. `setupLive` is non-destructive: the CURRENT model and its live run — a
        // feed, or the Stratux cockpit audio + ADS-B traffic + GPS — keep streaming until the new model
        // finishes compiling, then it swaps atomically and re-autostarts (`autostart: wasRunning`).
        // Tearing the run down up front would drop audio + traffic + GPS for the entire compile, and a
        // stalled first-compile would leave them dead behind the watchdog's "still using …" message.
        // Keeping the old run alive the whole time makes that message true and lets the traffic re-seed
        // in `setupLive` actually fire (it's gated on `trafficActive`, which needs the run still live).
        loadingModel = id                            // picker reflects the choice immediately
        detail = "Loading \(ModelCatalog.shortLabel(forID: id))…"   // friendly name, not the raw id
        modelSwapGeneration += 1
        let gen = modelSwapGeneration
        let models = modelDirs
        // Cancel the prior swap's tasks so a superseded (non-cancellable) compile stops doing work the
        // moment its in-flight CoreML step returns, instead of two heavy compiles contending at once.
        watchdogTask?.cancel()
        loadTask?.cancel()

        // Watchdog: a big model (e.g. Large V2) can take a long time — or stall — to load, especially
        // the first time CoreML compiles it for this device. The swap is non-destructive (the current
        // model stays loaded and usable the whole time), so if the new one hasn't landed after a grace
        // period, UNLOCK the picker rather than trapping the user on a spinner with no escape: they can
        // keep using the current model or pick another. The load keeps going; its result is applied
        // only if it's still the latest swap when it finishes (generation check in `setupLive`).
        watchdogTask = Task {
            try? await Task.sleep(nanoseconds: 30_000_000_000)   // 30s grace
            guard !Task.isCancelled, modelSwapGeneration == gen, loadingModel == id else { return }
            loadingModel = nil
            detail = "\(ModelCatalog.shortLabel(forID: id)) is still loading — still using \(activeModelLabel). It’ll switch when ready, or pick another model."
        }

        loadTask = Task {
            let ok = await setupLive(models: models, active: id, audioDir: audioDirPath,
                                     cpuOnly: storedCPUOnly, autostart: wasRunning,
                                     preserveHistory: true, generation: gen)
            guard modelSwapGeneration == gen else { return }   // a newer switch owns the UI now
            if loadingModel == id { loadingModel = nil }
            if !ok {
                if session == nil {
                    // A reselect-to-recover attempt (no fallback model is resident) failed AGAIN — there
                    // is no previous model to "still use", so route to real recovery instead of a lie.
                    surfaceInitialLoadProblem(active: id,
                        reason: modelLoadError.map { "Couldn’t load \(ModelCatalog.shortLabel(forID: id)): \($0)" }
                            ?? "Couldn’t load \(ModelCatalog.shortLabel(forID: id)).")
                } else {
                    // The previous model is intact — tell the user and resume it if it had been running.
                    detail = "Couldn’t load \(ModelCatalog.shortLabel(forID: id)). Still using \(activeModelLabel)."
                    if wasRunning, !isRunning { start(resuming: true) }
                }
            }
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
        // The gate is gone, so a What's-new sheet can present now. A pending `--whats-new` preview that
        // was deferred under the cover shows here; otherwise this is a fresh install — start its "seen"
        // baseline at the current build so the catch-up popup debuts on the NEXT update, not on top of
        // first-run setup.
        if whatsNewForcedPreview { showWhatsNew = true }
        else { markWhatsNewSeen() }
    }

    /// A model finished downloading. If the app launched without one (demo mode), bring up the
    /// live session now so the gate's "Continue" lands in a working console. (GGUF downloads are
    /// picked up the next time the AI fixer backend is built.)
    func modelDidDownload(_ entry: ModelEntry) {
        guard entry.kind == .whisperKit else { return }
        modelSource = "downloaded"
        let models = Self.availableModelDirs()
        self.modelDirs = models
        // Already live WITH A WORKING session: don't disturb it — only auto-upgrade to the higher-
        // accuracy model if that's what just arrived. (A swap never tears down an active run.)
        if liveMode, session != nil {
            if entry.id == "turbo", activeModel != "turbo", !isRunning { switchModel("turbo") }
            return
        }
        // No working model yet — first download, OR a prior load that never finished (e.g. a Large V2
        // that stalled). Load the model that JUST downloaded: it's the one the user asked for and the
        // one we can definitely use now, so the recovery "download a model that works" actually loads.
        guard models[entry.id] != nil else { return }
        // …but if a HIGHER-accuracy model is already loading, don't let this (smaller) one override it —
        // e.g. Small finishing after Large started loading. The better in-flight load wins; this model is
        // still recorded in modelDirs above, so it stays pickable in Settings.
        if let loading = loadingModel, Self.preferredRank(loading) <= Self.preferredRank(entry.id) { return }
        if value(forFlag: "--source") == nil, UserDefaults.standard.string(forKey: "atc.source") == nil,
           Self.bundledDemoClipsDir() != nil { source = .replay }
        beginModelLoad(models: models, active: entry.id, audioDir: Self.bundledDemoClipsDir(), autostart: false)
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
    nonisolated static func bundledModelDir() -> String? {   // pure (Bundle+FileManager); callable off the main actor
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
