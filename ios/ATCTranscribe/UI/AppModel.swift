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
    /// In-cockpit live audio (mic / USB / Stratux) — grounds the corrector on the surrounding GPS
    /// vicinity rather than the typed "Airport context" field (which the internet feed uses, and which
    /// can be stale vs an in-cockpit feed). Replay has no location, so it grounds on neither.
    var isInCockpit: Bool { self == .microphone || self == .usbAudio || self == .stratux }
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
            if didFinishInit, airport != oldValue { refreshEFBGrounding() }   // L4: airport changed → rebuild grounding
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

    /// True iff the remote URL would actually be USED (mirrors `RemoteLLMCorrector.fromSettings`'s
    /// transport policy: https anywhere, plain http only to a private/LAN host) — drives the
    /// Settings validity hint, so it never says "enabled" for an endpoint the factory drops.
    var remoteFixerURLValid: Bool {
        let t = remoteFixerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let u = URL(string: t) else { return false }
        return RemoteLLMCorrector.isEndpointAllowed(u)
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
    // and saved. Edited LIVE in the flight-plan strip (`FlightPlanBar`) — there is no Save button,
    // the strip's debounced commits land here directly.
    @Published var flightPlan: FlightPlan? = FlightPlan.load() {
        didSet {
            if let fp = flightPlan { fp.save() } else { FlightPlan.clear() }
            pushFlightPlanContext()
            pushPlatePriming()             // prime the decode+corrector with the route's chart freqs/fixes
            prefetchRouteCharts()          // pull the FAA packs the filed route crosses in the background
            if didFinishInit, flightPlan != oldValue {
                refreshEFBGrounding()          // L4: plan changed → rebuild grounding
                autoPackFlightBagIfEnabled()   // download the route's plates into the Flight Bag
            }
            if didFinishInit {                 // a plan is an `eonetActive` input (route hazard alerts)
                syncEONET()
                syncTFRs()
                if flightPlan != oldValue { hazardDismissedIDs.removeAll(); refreshHazardAlert() }
            }
            if flightPlan != oldValue { refreshTripStats() }   // strip's DIST/ETE/ETA/FUEL row
        }
    }

    // The pilot's saved aircraft (the strip's callsign box menu). Selecting one copies its
    // callsign/type into the filed plan — the plan remains the single source the EFB ownship gate
    // and corrector grounding read. Persisted as JSON (AircraftStore).
    @Published var aircraftProfiles: [AircraftProfile] = AircraftStore.load() {
        didSet { AircraftStore.save(aircraftProfiles) }
    }

    /// The ForeFlight-style trip overview for the filed route (DIST always; ETE/ETA/FUEL when the
    /// selected aircraft has performance numbers). Recomputed off-main whenever the plan changes.
    @Published private(set) var tripStats: TripStats?
    private var tripStatsEpoch = 0
    /// Drives the full-screen route map (`RouteMapSheet`) — the filed route, the selectable FAA chart
    /// layer, and live traffic. Transient (not persisted); opened from the flight-plan strip's Map
    /// button. An `eonetActive` input (the sheet shows hazards even when the home-map background is off).
    @Published var showRouteMap = false {
        didSet { if didFinishInit, showRouteMap != oldValue { syncEONET(); syncTFRs() } }
    }

    /// The chart base layer the user last viewed (VFR sectional / IFR low / standard / satellite) so the
    /// map reopens where they left off; defaults to VFR sectional on first run. Read at view-init time via
    /// `savedChartLayer`; the map writes any switch back here.
    nonisolated static let chartLayerKey = "atc.chartLayer"
    nonisolated static var savedChartLayer: ChartLayer {
        // A `--chart-layer` launch arg (demo/screenshot only) frames the home map on that layer; otherwise
        // restore the last-used layer, defaulting to VFR sectional on first run.
        ChartLayer.launchOverride
            ?? UserDefaults.standard.string(forKey: chartLayerKey).flatMap(ChartLayer.init(rawValue:))
            ?? .sectional
    }
    @Published var chartLayer: ChartLayer = AppModel.savedChartLayer {
        didSet { UserDefaults.standard.set(chartLayer.rawValue, forKey: Self.chartLayerKey) }
    }

    // MARK: Home-screen map + floating widgets

    /// Recenter the home map here (a search result). Transient.
    @Published var mapFocus: Coord?
    /// A plate (approach/departure PDF) superimposed on the home map as a hand-aligned REFERENCE
    /// overlay; nil = none. See `PlateOverlayState` — it is never a precise nav source.
    @Published var plateOverlay: PlateOverlayState?
    /// Which bottom-bar tab is showing (Map / Plates). Switched to `.map` when a plate is sent to
    /// the map so the pilot sees the overlay.
    @Published var selectedTab: RootTab = .map
    /// A transient one-shot: "open the Plates tab on this airport." Set by a map→Plates hand-off (or
    /// the `--start-tab plates <ICAO>` QA arg); `PlatesTabView` CONSUMES it (applies it, then clears it
    /// back to nil) so a repeat hand-off to the same airport still fires. nil = no pending request.
    @Published var platesAirport: String?

    /// The Flight Bag plate downloader (per-airport / route / region bundle downloads + cache stats).
    let plateBag = PlateBag()
    /// Continuous device-GPS ownship (for a Stratux-less iPad) — the plate viewer starts/stops it and
    /// observes it directly. Preferred fallback after a valid Stratux fix (see `ownshipCoord`).
    let deviceLocation = DeviceLocation()
    /// Auto-download the filed route's plates when a plan is entered (the "pack your flight bag" flow).
    @Published var autoPackFlightBag = (UserDefaults.standard.object(forKey: "atc.autoPackBag") as? Bool ?? true) {
        didSet { UserDefaults.standard.set(autoPackFlightBag, forKey: "atc.autoPackBag") }
    }
    private var lastPackedRouteSignature = ""
    /// QA-arg one-shot: present the Flight Bag when the Plates tab first appears (`--flight-bag`).
    @Published var showFlightBagOnLaunch = false
    /// QA-arg one-shot: a plate PDF to auto-open full-page in the Plates viewer (`--preview-plate-full`).
    @Published var previewPlatePdf: String?

    /// A coded procedure (approach/SID/STAR) drawn as a georeferenced overlay on the home map; nil = none.
    @Published var previewedProcedure: CIFPProcedure? {
        didSet { if didFinishInit, previewedProcedure?.id != oldValue?.id { resolvePreviewedProcedure() } }
    }
    /// The previewed procedure's resolved legs (georeferenced overlay). Resolved ONCE off-main when
    /// `previewedProcedure` changes (L8), instead of MapHostView re-scanning CIFP (SQLite) on every
    /// SwiftUI re-render — the live-data storm made that run many times a second.
    @Published private(set) var previewedProcedureLegs: [ResolvedLeg] = []
    private var previewEpoch = 0
    /// Drives the map search sheet (top-bar magnifying glass). Transient.
    @Published var showMapSearch = false

    // Electronic Flight Bag automation (Phase 4, suggest-and-confirm). A finished CONTROLLER transmission
    // addressed to the pilot's own aircraft is parsed into at most one pending suggestion; NOTHING changes
    // until the user taps Accept. `efbSuggestionsEnabled` lets the pilot silence the chips entirely.
    @Published var efbSuggestion: EFBSuggestion?
    @Published var efbSuggestionsEnabled = (UserDefaults.standard.object(forKey: "atc.efbSuggestions") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(efbSuggestionsEnabled, forKey: "atc.efbSuggestions") }
    }
    // ForeFlight hand-off: send the amended plan to ForeFlight via its offline URL scheme (and a
    // Garmin .fpl share from the flight bag). `foreflightEnabled` is the pilot's master switch;
    // `foreflightInstalled` re-probes the scheme on each read so installing/removing ForeFlight
    // mid-session is picked up on the next render (the query is a cheap LaunchServices lookup) —
    // iOS reports installed-or-not only (never whether ForeFlight is RUNNING), and the probe
    // requires the LSApplicationQueriesSchemes entry in Info.plist.
    @Published var foreflightEnabled = (UserDefaults.standard.object(forKey: "atc.foreflight") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(foreflightEnabled, forKey: "atc.foreflight") }
    }
    var foreflightInstalled: Bool {
        URL(string: ForeFlightExport.scheme + "://").map { UIApplication.shared.canOpenURL($0) } ?? false
    }
    /// True when the EFB chip should offer the one-tap "Accept ➔ ForeFlight" action.
    var offersForeFlight: Bool { foreflightEnabled && foreflightInstalled }
    private var lastEFBRecordID: UUID?
    private var efbCancellable: AnyCancellable?
    /// Cached EFB command grounding (fixes/airports/SIDs/STARs), keyed on the (airport ident, plan)
    /// it was built for, so `interpretForEFB` doesn't hit CIFP (SQLite) on the main actor per
    /// transmission (L4). Rebuilt off-main by `refreshEFBGrounding` on the setupLive commit and on
    /// airport / flight-plan changes; the epoch discards a superseded async build.
    private var efbGroundingCache: (ident: String, plan: FlightPlan, grounding: ATCCommandParser.Grounding)?
    private var efbGroundingEpoch = 0
    /// Subscriptions mirroring the CURRENT session's published state into the UI. Torn down and
    /// rebuilt on every model swap (L5 remediation): the old `.assign(to: &$…)` bindings were never
    /// cancelled, so a swapped-out session's late `.stopped` publish clobbered the new session's
    /// status. Cleared before rewiring in `setupLive`.
    private var sessionCancellables: Set<AnyCancellable> = []

    /// A search result / programmatic selection: center the map on it and open its info panel.
    func selectMapObject(_ o: IdentifiedObject) {
        mapFocus = o.coord
        widgetStore.mapProbe = MapProbeResult(id: "sel-\(o.id)", objects: [o])
    }

    // MARK: - Plate overlay (superimpose an approach plate on the map — reference aid)

    /// Superimpose an approach/departure plate on the home map. When the plate has a precomputed,
    /// plausibility-checked georeference (`PlateGeoref.lookup` — OCR'd fixes → CIFP coords → a solved
    /// north-up placement), it auto-aligns to scale/position/rotation; otherwise it falls back to a
    /// hand-aligned default centered on the airport. Either way it is a REFERENCE aid the pilot then
    /// fine-tunes (size/rotation/position/opacity) via the `PlateControlBar` — never presented as
    /// survey-accurate, and the auto-align caption asks the pilot to verify before use. Rendering
    /// page 1 is a one-time cost on this explicit tap. No-op if neither a georeference nor an airport
    /// reference point is known, or the PDF is unreadable.
    func overlayPlate(_ proc: AirportProcedure, airport: String, pdf: URL) {
        guard let img = PlateImageRenderer.firstPageImage(pdfURL: pdf) else { return }
        let aspect = Double(img.size.width / max(img.size.height, 1))
        // Auto-align from the precomputed georeference when the plate has one (OCR'd fixes → CIFP
        // coords → a solved north-up placement); otherwise fall back to a hand-aligned default centered
        // on the airport. Either way the pilot can fine-tune — it is a reference aid.
        if let g = PlateGeoref.lookup(pdf: proc.pdf) {
            plateOverlay = PlateOverlayState(name: proc.name, airport: airport, image: img, imageAspect: aspect,
                                             centerLat: g.centerLat, centerLon: g.centerLon,
                                             widthMeters: g.widthMeters, rotationDeg: g.rotationDeg,
                                             opacity: 0.7, autoAligned: true)
            mapFocus = Coord(lat: g.centerLat, lon: g.centerLon)   // frame the map on it so it's visible
            return
        }
        // Hand-aligned: center on the airport. Resolve the coordinate from the bundled table, else the
        // CIFP runway centroid (covers ~every airport that publishes a plate), else the current map
        // focus — so send-to-map NEVER silently no-ops for an off-table airport like KLRU.
        let center = airportCenter(airport) ?? mapFocus ?? Coord(lat: 39.5, lon: -98.35)
        plateOverlay = PlateOverlayState(name: proc.name, airport: airport, image: img, imageAspect: aspect,
                                         centerLat: center.lat, centerLon: center.lon,
                                         widthMeters: PlatePlacement.defaultWidthMeters(fixExtentMeters: nil),
                                         rotationDeg: 0, opacity: 0.7, autoAligned: false)
        mapFocus = center
    }

    /// Resolve an airport's coordinate for plate centering: the bundled 78-airport table first, then the
    /// CIFP runway centroid (thousands of airports — any airport with a coded procedure has runways).
    private func airportCenter(_ icao: String) -> Coord? {
        let key = icao.trimmingCharacters(in: .whitespaces).uppercased()
        if let c = AirportCoordinates.coordinate(icao: key) { return c }
        let coords = CIFP.runways(airport: key).map(\.coord)
        guard !coords.isEmpty else { return nil }
        let lat = coords.map(\.lat).reduce(0, +) / Double(coords.count)
        let lon = coords.map(\.lon).reduce(0, +) / Double(coords.count)
        return Coord(lat: lat, lon: lon)
    }
    /// Download the filed route's plates into the Flight Bag (departure/destination/alternate + route
    /// airports) when enabled and the route changed. Cheap when everything is cached (PlateBag skips
    /// those), and it won't interrupt a manual/region job in progress.
    private func autoPackFlightBagIfEnabled() {
        guard autoPackFlightBag else { return }
        let airports = PlateBag.routeAirports(flightPlan)
        guard !airports.isEmpty else { return }
        let sig = airports.sorted().joined(separator: ",")
        guard sig != lastPackedRouteSignature else { return }   // don't re-pack an unchanged route
        // Record the signature only once the download actually launches — otherwise a route change
        // dropped because another job (e.g. a region bundle) is in flight would be marked "packed" and
        // never retried on the next didSet (C5).
        guard !plateBag.isRunning else { return }
        lastPackedRouteSignature = sig
        plateBag.download(airports: airports, label: "Packing flight bag · \(airports.count) airports")
    }

    func clearPlateOverlay() { plateOverlay = nil }
    func setPlateOpacity(_ v: Double) { plateOverlay?.opacity = min(max(v, 0.05), 1) }
    func setPlateWidth(_ v: Double) { plateOverlay?.widthMeters = PlatePlacement.clampWidthMeters(v) }
    func setPlateRotation(_ v: Double) { plateOverlay?.rotationDeg = PlatePlacement.normalizeRotation(v) }

    /// Move the plate's center by a geographic delta (metres east/north) — the nudge pad.
    func nudgePlate(eastMeters: Double, northMeters: Double) {
        guard var s = plateOverlay else { return }
        let m = PlatePlacement.move(centerLat: s.centerLat, centerLon: s.centerLon,
                                    eastMeters: eastMeters, northMeters: northMeters)
        s.centerLat = m.lat; s.centerLon = m.lon
        plateOverlay = s
    }

    /// Snap the plate back onto the airport reference point (undo an over-nudge).
    func recenterPlateOnAirport() {
        guard var s = plateOverlay, let c = AirportCoordinates.coordinate(icao: s.airport) else { return }
        s.centerLat = c.lat; s.centerLon = c.lon
        plateOverlay = s
    }

    /// Resolve the previewed procedure's legs to plottable coordinates OFF the main actor (L8), then
    /// publish them once — instead of MapHostView re-scanning CIFP on every re-render. Epoch-guarded
    /// so a rapid preview change discards a superseded resolve; legs are statically bounded (rule 2).
    private func resolvePreviewedProcedure() {
        previewEpoch += 1
        let epoch = previewEpoch
        guard let procID = previewedProcedure?.id else { previewedProcedureLegs = []; return }
        Task.detached { [weak self] in
            let legs = CIFP.legs(procedureID: procID).prefix(256).compactMap { leg in
                leg.coord.map { ResolvedLeg(ident: leg.fix, kind: .waypoint, coord: $0) }
            }
            await MainActor.run {
                guard let self, self.previewEpoch == epoch else { return }
                self.previewedProcedureLegs = Array(legs)
            }
        }
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
    /// NASA EONET natural-hazard overlay (wildfires / storms / dust / volcanoes). OFF by default —
    /// it's a network feature the pilot opts into from the layers menu. Persisted; flipping it
    /// reconciles the poller (see `eonetActive`).
    @Published var showHazards = UserDefaults.standard.bool(forKey: "atc.map.hazards") {
        didSet {
            UserDefaults.standard.set(showHazards, forKey: "atc.map.hazards")
            syncEONET()
            refreshHazardAlert()               // off → clears the banner; on → recomputes
        }
    }
    /// Live TFR layer toggle (network — opt-in, default off). Gated like the hazard layer.
    @Published var showTFRs = UserDefaults.standard.bool(forKey: "atc.map.tfrs") {
        didSet { UserDefaults.standard.set(showTFRs, forKey: "atc.map.tfrs"); syncTFRs() }
    }
    /// Master switch for the live map background — off shows a plain background instead, saving battery on
    /// hot/old devices. Persisted (default on).
    @Published var mapBackgroundEnabled = (UserDefaults.standard.object(forKey: "atc.map.background") as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(mapBackgroundEnabled, forKey: "atc.map.background")
            syncEONET()                    // the home map is an `eonetActive` input
            syncTFRs()
        }
    }
    /// True when the device is thermally stressed — the home map pauses so it never starves transcription.
    /// Updated (with exit hysteresis) from `ProcessInfo.thermalStateDidChangeNotification` via
    /// `applyThermal` — see there for why the exit is delayed.
    @Published var thermalSerious = ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
        didSet { if didFinishInit, thermalSerious != oldValue { syncEONET(); syncTFRs() } }   // hot → pause the pollers too
    }
    /// The single pending "clear thermalSerious" timer (M7). A device hovering at the threshold used
    /// to flip thermalSerious repeatedly, and each flip destroys + rebuilds the whole ChartMapView
    /// (new Coordinator, refetched context, reset framing). Enter is immediate (protect transcription
    /// now); exit waits out `thermalExitDwell` of sustained cooling, cancel-on-re-entry so exactly one
    /// clear is ever pending.
    private var thermalClearTask: Task<Void, Never>?
    private static let thermalExitDwell: UInt64 = 60_000_000_000   // 60 s
    /// The user's last settled map pan/zoom (M7). Set at the map's debounced settle rate, so it is
    /// deliberately NOT `@Published` (it must not re-render the console) and NOT persisted (a fresh
    /// launch frames the route). Read back only when the map rebuilds after a thermal blip.
    var lastMapCamera: SavedMapCamera?

    /// The floating-widget layout + tapped-object probe live in their OWN store (not `@Published` here) so
    /// the several-per-second live-data storm on this model never re-renders the widget chrome — see
    /// `WidgetStore`. Injected into the environment alongside this model at the app root.
    let widgetStore = WidgetStore()

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

    // EXPERIMENTAL acoustic fill: when a line's speaker can't be told from the words, guess it from the
    // sound of the voice. OFF by default — on a single radio frequency every voice shares the same
    // channel, so voice-based guessing is unreliable (a corpus study measured ~coin-flip accuracy).
    // Persisted; hot-applied to the running session's labeler. Only has any effect when "Separate
    // speakers" is also on (it needs the per-line voice clusters).
    @Published var acousticFillEnabled = (UserDefaults.standard.object(forKey: "atc.acousticFill") as? Bool) ?? false {
        didSet {
            UserDefaults.standard.set(acousticFillEnabled, forKey: "atc.acousticFill")
            session?.setAcousticFill(acousticFillEnabled)
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

    // NASA EONET natural hazards (map overlay; route/vicinity alerts ride the same snapshot).
    // Polls only while hazard awareness is wanted (see `eonetActive`); the last snapshot is
    // disk-cached by the service so the layer shows immediately (with an age note) on relaunch.
    @Published private(set) var hazardEvents: [EONETEvent] = []
    @Published private(set) var hazardsUpdatedAt: Date?
    @Published private(set) var eonetStatus: EONETStatus = .idle
    /// The route/vicinity hazard banner (nil = nothing to show). Recomputed off-main by
    /// `refreshHazardAlert` on hazard snapshots, plan changes, and ≥5 NM ownship movement.
    @Published private(set) var hazardAlert: HazardAlert?
    /// Events the pilot dismissed from the banner. Transient; cleared when the plan changes.
    private var hazardDismissedIDs: Set<String> = []
    private var hazardAlertEpoch = 0
    /// `--demo-hazards` screenshot mode: seed synthetic events and SUPPRESS the live poller so the
    /// seeded snapshot isn't clobbered by a live fetch (the demo has to work offline and on-screen).
    private var demoHazardsMode = false
    /// Ownship position of the last alert recompute — the movement dedup anchor.
    private var lastHazardAlertCenter: Coord?
    private static let hazardRecomputeNm: Double = 5
    /// Built in `init` alongside `adsbService`.
    private var eonetService: EONETService!

    // Live TFR layer (FAA tfr.faa.gov) — the dynamic counterpart to the bundled Special Use Airspace.
    @Published private(set) var tfrs: [TFR] = []
    @Published private(set) var tfrsUpdatedAt: Date?
    @Published private(set) var tfrStatus: TFRStatus = .idle
    private var tfrService: TFRService!

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
    @Published private(set) var stratuxGPS: StratuxGPS? {
        didSet {
            // Ownship moved → re-resolve the GPS-vicinity corrector grounding (in-cockpit feeds only;
            // `syncGrounding` dedups by distance so a ~1 Hz fix doesn't rescan the nav table every tick).
            guard didFinishInit, stratuxGPS?.coordinate != oldValue?.coordinate else { return }
            syncGrounding()
            maybeRefreshHazardAlertForMovement()   // vicinity hazard check rides the same movement edge
        }
    }
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

    // GPS-vicinity corrector grounding (in-cockpit feeds). Resolves the surrounding airports off-main
    // and pushes them to the running session as ownship moves — the analogue of the traffic push.
    private let groundingStore = AirportContextStore()
    /// The source of the RUNNING session (nil when stopped). Grounding follows what's actually
    /// transcribing, NOT the picker — the picker can change mid-run without swapping the live source.
    private var groundingSource: SourceKind?
    /// Ownship position of the last resolve — the movement dedup anchor (nil re-arms a fresh resolve).
    private var lastGroundingCenter: Coord?
    /// Bumped on every resolve/clear so a stale off-main resolution that lands late is dropped.
    private var groundingEpoch = 0
    private static let vicinityRadiusNm: Double = 40       // SOFT LLM/Whisper union — the surrounding vicinity
    private static let hardGroundingRadiusNm: Double = 15  // HARD SlotSnap — only the nearest airport, terminal-area
    private static let vicinityAirportCap = 6              // airports fed into the soft union
    private static let groundingRecomputeNm: Double = 2    // ownship movement before a re-scan
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
        // NASA EONET natural hazards: same publish-hops-to-main shape as the other services.
        // Polling is gated by `eonetActive` (layer on + a map to show it, foregrounded, not hot).
        eonetService = EONETService(
            onUpdate: { [weak self] events, snapshotAt in
                Task { @MainActor in self?.applyHazards(events, snapshotAt: snapshotAt) }
            },
            onStatus: { [weak self] status in
                Task { @MainActor in self?.eonetStatus = status }
            })
        // Live FAA TFR layer: same publish-hops-to-main shape.
        tfrService = TFRService(
            onUpdate: { [weak self] tfrs, at in
                Task { @MainActor in self?.tfrs = tfrs; self?.tfrsUpdatedAt = at }
            },
            onStatus: { [weak self] status in
                Task { @MainActor in self?.tfrStatus = status }
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
        // screenshot/demo: draw an airport's first coded approach on the map (`--preview-proc KBOS`).
        if let i = args.firstIndex(of: "--preview-proc"), i + 1 < args.count {
            previewedProcedure = CIFP.procedures(airport: args[i + 1]).first { $0.kind == "IAP" }
            resolvePreviewedProcedure()   // didSet is inert during init (L8) — resolve the launch preview explicitly
        }
        // QA/screenshot: auto-align + overlay a specific plate on the map (`--preview-plate KBOS 00058IL4R.PDF`).
        // Downloads it, applies the georeference, and frames the map on it so the alignment can be
        // eyeballed against the chart. No-op if the plate/airport is unknown.
        if let i = args.firstIndex(of: "--preview-plate"), i + 2 < args.count {
            let icao = args[i + 1], pdf = args[i + 2]
            Task { @MainActor [weak self] in
                guard let self, let proc = Procedures.forAirport(icao).first(where: { $0.pdf == pdf }),
                      let url = await PlateStore.ensureOnDisk(proc) else { return }
                self.overlayPlate(proc, airport: icao, pdf: url)
                if let s = self.plateOverlay { self.mapFocus = Coord(lat: s.centerLat, lon: s.centerLon) }
            }
        }
        // QA/screenshot: open the tapped-airport card for an airport (`--preview-airport KATL`).
        if let i = args.firstIndex(of: "--preview-airport"), i + 1 < args.count {
            let icao = args[i + 1].uppercased()
            if let c = AirportCoordinates.coordinate(icao: icao) {
                Task { @MainActor [weak self] in
                    self?.selectMapObject(IdentifiedObject(kind: .airport, ident: icao, coord: c, onRoute: false))
                }
            }
        }
        // QA/screenshot: open a plate FULL-PAGE in the Plates tab viewer (`--preview-plate-full KATL 00026IL27L.PDF`).
        if let i = args.firstIndex(of: "--preview-plate-full"), i + 2 < args.count {
            selectedTab = .plates; platesAirport = args[i + 1].uppercased(); previewPlatePdf = args[i + 2]
        }
        // QA/screenshot: auto-present the Flight Bag on the Plates tab (`--flight-bag`).
        if args.contains("--flight-bag") { selectedTab = .plates; showFlightBagOnLaunch = true }
        // QA/screenshot: open the app on a specific bottom tab (`--start-tab plates [KBOS]`).
        if let i = args.firstIndex(of: "--start-tab"), i + 1 < args.count,
           let tab = RootTab(rawValue: args[i + 1]) {
            selectedTab = tab
            if i + 2 < args.count, !args[i + 2].hasPrefix("-") { platesAirport = args[i + 2].uppercased() }
        }
        // screenshot/demo: show a sample one-tap EFB suggestion banner (`--demo-efb`).
        if args.contains("--demo-efb") {
            efbSuggestion = EFBSuggestion.make(id: "demo",
                                               command: ATCCommand(kind: .directTo, target: "BOSOX", qualifier: ""),
                                               source: "commsight 3 4 5 cleared direct bosox")
        }
        // screenshot/demo: seed synthetic EONET hazards near the demo route and turn the layer on.
        // `demoHazardsMode` suppresses the live poller (see `syncEONET`) so these seeded events are
        // NOT overwritten by a live NASA fetch — the demo must render offline and on-screen.
        if args.contains("--demo-hazards") {
            demoHazardsMode = true
            showHazards = true
            hazardEvents = EONETEvent.demoEvents()
            hazardsUpdatedAt = Date()
            refreshHazardAlert()   // observers are inert during init — compute the banner explicitly
        }

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
        syncEONET()      // same launch edge for a restored hazards toggle
        syncTFRs()       // and a restored TFR toggle
        refreshTripStats()   // seed the flight-plan strip's stats row from the restored plan
        // Pause the live home map under thermal pressure so it never starves on-device transcription.
        NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            let hot = ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
            Task { @MainActor in self?.applyThermal(serious: hot) }
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
        // Nationwide CIFP grounding (fixes/ILS + the SlotSnap lookup) from the TYPED airport is limited to
        // the internet feed, where the user explicitly names the facility for that stream. On an in-cockpit
        // feed the typed field can be stale (feed + airport are independent persisted fields), so it must
        // NOT drive deterministic SlotSnap edits on live audio from elsewhere — those feeds instead ground
        // DYNAMICALLY on the surrounding GPS vicinity, pushed live via `syncGrounding`/`setGroundingAirports`
        // (NOT baked in here: GPS may not have a fix yet at build time, and the aircraft moves). Curated
        // configs (KDFW/KJFK) still ground on any source, unchanged.
        let groundIdent = (source == .liveFeed && !airport.isEmpty) ? airport : nil
        let context = ATCContext(config: cfg, feedKey: feedKey, groundingIdent: groundIdent)
        // Seed the filed flight plan (Electronic Flight Bag) before the pipeline starts using the
        // context, so the first transmission's LLM correction already sees the pilot's own callsign,
        // airports, and route. Live edits afterward go through `pushFlightPlanContext`.
        if let fp = flightPlan {
            context.setFlightPlan(block: fp.contextBlock, vocab: fp.vocabTerms)
            let pr = PlateIndex.priming(for: PlateBag.routeAirports(fp))   // route's chart freqs/fixes
            context.setPlatePriming(promptLine: pr.promptLine, block: pr.block)
        }
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

        // The experimental "guess speaker by voice" toggle selects the neural ECAPA backend. Load its
        // 80 MB Core ML model OFF the main actor (mirroring makeLLMCorrector) and INJECT it, so the
        // pipeline's actor init never blocks the UI thread. nil → the default MFCC backend.
        let embedder = acousticFillEnabled
            ? await Task.detached(priority: .utility) { CoreMLSpeakerEmbedder() }.value
            : nil
        let ecapaActive = embedder?.isAvailable == true

        let pipeline = LivePipeline(transcriber: transcriber, context: context,
                                    preprocessor: livePreprocessor(),
                                    corrector: currentCorrector(), llm: llm,
                                    gateEnabled: skipWhenConfident, gateSensitivity: gateSensitivity,
                                    diarizationEnabled: diarizationEnabled,
                                    embedder: embedder,
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
        refreshEFBGrounding()   // L4: the live airport ident just changed → rebuild the EFB grounding cache
        // Rewire the UI mirror to the NEW session. Tear the OLD subscriptions down FIRST (L5): the
        // former `.assign(to: &$…)` bindings were never cancelled across a swap, so `oldSession.stop()`
        // below (which publishes `.stopped`) clobbered the just-committed new session's status. The
        // session is @MainActor, so a `.sink` delivers identically (including the initial replay).
        sessionCancellables.removeAll()
        session.$records.sink { [weak self] in self?.records = $0 }.store(in: &sessionCancellables)
        // Phase 4: interpret each finished transmission for a one-tap EFB suggestion (fires only on the
        // latest new record; the interpreter itself gates on controller-role + ownship, and only proposes).
        efbCancellable = session.$records.sink { [weak self] recs in self?.interpretForEFB(recs) }
        session.$status.sink { [weak self] in self?.status = $0 }.store(in: &sessionCancellables)
        session.$stats.sink { [weak self] in self?.stats = $0 }.store(in: &sessionCancellables)
        session.$inputLevel.sink { [weak self] in self?.inputLevel = $0 }.store(in: &sessionCancellables)
        session.$transcribing.sink { [weak self] in self?.transcribing = $0 }.store(in: &sessionCancellables)
        session.$transcribeStartedAt.sink { [weak self] in self?.transcribeStartedAt = $0 }.store(in: &sessionCancellables)
        // Match the fill-guard distance to the ACTUAL backend that loaded (ECAPA vs the MFCC fallback),
        // then apply the persisted toggle — order matters so a fill re-fuse uses the right scale.
        session.setFillDistance(ecapaActive ? SpeakerModel.ecapaFillMax : SpeakerModel.mfccFillMax)
        session.setAcousticFill(acousticFillEnabled)
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
        pushPlatePriming()

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

    /// Prime the decode + corrector with the frequencies/fix idents printed on the filed route's plates
    /// (`PlateIndex`, distilled from the offline OCR corpus). Empty payload clears it when no plan/route.
    func pushPlatePriming() {
        let airports = PlateBag.routeAirports(flightPlan)
        let p = PlateIndex.priming(for: airports)
        session?.setPlatePriming(promptLine: p.promptLine, block: p.block)
    }

    // MARK: - EFB command interpreter (Phase 4, suggest-and-confirm; NASA/JPL Power-of-10 style)

    /// Interpret the most-recent finished transmission as a possible one-tap EFB suggestion. Fires only
    /// for a CONTROLLER transmission addressed to the pilot's own aircraft, and only PROPOSES — accepting
    /// is a separate tap (`acceptEFBSuggestion`). Every guard is a parameter/state check with recovery.
    private func interpretForEFB(_ records: [TranscriptRecord]) {
        guard efbSuggestionsEnabled else { return }
        guard let latest = records.last else { return }
        guard latest.id != lastEFBRecordID else { return }        // one interpretation per transmission
        lastEFBRecordID = latest.id
        guard latest.role == .controller else { return }   // content role (a clearance's text is controller)
        guard let plan = flightPlan, !plan.callsign.isEmpty else { return }   // no ownship → never act
        // Ownship identity from the filed callsign + aircraft type. It recognizes the standard ATC
        // abbreviations of the pilot's OWN tail ("Seneca 25T", "November 8 9 2 5 Tango", "8925T") — but
        // only when ownship is ADDRESSED (transmission-initial or before an instruction), never merely
        // mentioned to another aircraft. Matching one known callsign keeps abbreviation safe.
        let identity = OwnshipIdentity(callsign: plan.callsign, aircraftType: plan.aircraftType,
                                       spokenCallsign: ownshipSpokenTokens(plan.callsign))
        guard identity.isValid else { return }
        guard identity.isAddressed(inNormalized: latest.normalizedDisplay) else { return }
        // EFB grounding (fixes/airports/SIDs/STARs) is fetched from CIFP (SQLite) — do it OFF the main
        // thread and CACHE it, keyed on (airport ident, flight plan), instead of running four SQLite
        // scans on the main actor per transmission (L4). A miss (cache stale/absent) refreshes async
        // and skips THIS transmission — miss-safe: the FIRST addressed clearance right after an airport
        // or plan change may not fire (documented), every one after uses the fresh cache.
        guard let cache = efbGroundingCache, cache.ident == efbActiveIdent(), cache.plan == plan else {
            refreshEFBGrounding()
            return
        }
        guard let command = ATCCommandParser.parse(latest.normalizedDisplay, grounding: cache.grounding,
                                                   addressee: identity.addressee(airlineStarts: efbAirlineStarts())) else { return }
        assert(!command.target.isEmpty, "parser returned an empty target")
        efbSuggestion = EFBSuggestion.make(id: latest.id.uuidString, command: command, source: latest.display)
    }

    /// The airport ident EFB grounding resolves against — the live context's, else the picker's.
    private func efbActiveIdent() -> String { liveContext?.airportIdent ?? (airport.isEmpty ? "" : airport) }

    /// Rebuild the EFB grounding cache off-main for the current (ident, plan). Epoch-guarded so a
    /// superseding refresh (airport/plan change mid-build) discards a stale result. On a matching
    /// epoch return, `self.flightPlan` is unchanged (a plan change would have bumped the epoch), so
    /// it is the plan this grounding was built from.
    private func refreshEFBGrounding() {
        guard let plan = flightPlan else { efbGroundingCache = nil; return }
        let ident = efbActiveIdent()
        efbGroundingEpoch += 1
        let epoch = efbGroundingEpoch
        let routeIdents = plan.fullRoute.prefix(256).map { $0.ident }
        let endpoints = [plan.departure, plan.destination, plan.alternate]
        Task.detached { [weak self] in
            let grounding = Self.buildEFBGrounding(ident: ident, routeIdents: routeIdents, endpointAirports: endpoints)
            await MainActor.run {
                guard let self, self.efbGroundingEpoch == epoch, let plan = self.flightPlan else { return }
                self.efbGroundingCache = (ident, plan, grounding)
            }
        }
    }

    /// Build the EFB command grounding from CIFP + the filed route/endpoints. Pure + nonisolated so
    /// it runs off the main actor (a single CIFP procedures scan is split into SID/STAR in one pass).
    /// Every loop is statically bounded (rule 2); idents are uppercased + de-duped (Set/insert).
    nonisolated static func buildEFBGrounding(ident: String, routeIdents: [String],
                                              endpointAirports: [String]) -> ATCCommandParser.Grounding {
        var fixes = Set<String>()
        if !ident.isEmpty {
            for fix in CIFP.fixes(airport: ident).prefix(1024) { fixes.insert(fix.uppercased()) }
        }
        for id in routeIdents.prefix(256) where !id.isEmpty { fixes.insert(id.uppercased()) }

        var airports = Set<String>()
        for icao in endpointAirports.prefix(3) where !icao.isEmpty { airports.insert(icao.uppercased()) }

        var sids: [String] = [], stars: [String] = []
        var seenSid = Set<String>(), seenStar = Set<String>()
        if !ident.isEmpty {
            for proc in CIFP.procedures(airport: ident).prefix(2048) {   // ONE scan, split by kind
                if proc.kind == "SID", seenSid.insert(proc.ident).inserted { sids.append(proc.ident) }
                else if proc.kind == "STAR", seenStar.insert(proc.ident).inserted { stars.append(proc.ident) }
            }
        }
        assert(fixes.allSatisfy { !$0.isEmpty }, "known fixes must be non-empty (malformed CIFP/route row?)")
        assert(sids.allSatisfy { !$0.isEmpty } && stars.allSatisfy { !$0.isEmpty }, "procedure idents must be non-empty")
        return ATCCommandParser.Grounding(fixes: fixes, airports: airports, sids: sids, stars: stars)
    }

    /// The filed callsign spelled as NORMALIZED spoken tokens via the knowledge base (airline telephony +
    /// spelled tail) — an extra full-form variant for `OwnshipIdentity` (esp. airline callsigns, whose
    /// telephony name it can't derive alone). Empty when the live knowledge base isn't available yet.
    private func ownshipSpokenTokens(_ callsign: String) -> [String] {
        guard let knowledge = liveContext?.knowledge else { return [] }
        let spoken = ATCContext.spokenCallsign(callsign, knowledge: knowledge)
        guard !spoken.isEmpty else { return [] }
        let toks = ATCNormalize.normalize(spoken).split(separator: " ").map(String.init)
        return toks.count <= ATCCommandParser.maxCallsignTokens ? toks : []
    }

    /// The words that BEGIN any callsign (airline telephony first-words + "november" + GA type words) —
    /// used by the positional binding to find where the NEXT aircraft is addressed. Empty-safe.
    private func efbAirlineStarts() -> Set<String> {
        guard let knowledge = liveContext?.knowledge else { return ["november"] }
        return efbCallsignStarts(knowledge)
    }

    /// The words that begin a callsign — airline telephony first-words + "november" + GA type words. Used
    /// to detect where each aircraft is addressed. Statically capped (rule 2).
    private func efbCallsignStarts(_ knowledge: ATCKnowledgeBase) -> Set<String> {
        var starts: Set<String> = ["november"]
        for name in knowledge.airlineTelephony.values.prefix(8192) {
            if let head = name.lowercased().split(separator: " ").first { starts.insert(String(head)) }
        }
        for word in SlotSnap.gaCallsignWords.prefix(256) { starts.insert(word) }
        return starts
    }

    /// Load the coded procedure identified by (kind, ARINC ident) at the active airport (EFB SID/STAR
    /// clearance). Picks the first matching procedure; no-op if none. Bounded lookup (rule 2).
    private func loadProcedureByIdent(kind: String, ident: String) {
        guard !ident.isEmpty else { return }
        let apt = liveContext?.airportIdent ?? (airport.isEmpty ? "" : airport)
        guard !apt.isEmpty else { return }
        for proc in CIFP.procedures(airport: apt).prefix(2048) where proc.kind == kind && proc.ident == ident {
            loadProcedure(proc); return
        }
    }

    /// Apply the pending suggestion via existing, reversible mutators, then clear it. The kind switch is
    /// exhaustive (total). Validates there is a suggestion + a non-empty target (rule 7).
    func acceptEFBSuggestion() {
        guard let suggestion = efbSuggestion else { return }
        guard !suggestion.command.target.isEmpty else { efbSuggestion = nil; return }
        switch suggestion.command.kind {
        case .directTo:        directTo(suggestion.command.target)
        case .clearedApproach: loadApproachForRunway(suggestion.command.target)
        case .loadSID:         loadProcedureByIdent(kind: "SID", ident: suggestion.command.target)
        case .loadStar:        loadProcedureByIdent(kind: "STAR", ident: suggestion.command.target)
        }
        Haptics.impact(.medium)
        efbSuggestion = nil
    }

    /// Discard the pending suggestion without acting.
    func dismissEFBSuggestion() { efbSuggestion = nil }

    // MARK: ForeFlight hand-off (offline URL scheme + .fpl share)

    /// Accept the pending suggestion AND hand the amended plan to ForeFlight (the chip's one-tap
    /// "Accept ➔ ForeFlight" action). The hand-off fires only when accepting actually CHANGED the
    /// plan — a SID/STAR/approach accept silently no-ops when no CIFP procedure matches at the
    /// active airport, and switching the pilot into ForeFlight then would misrepresent the
    /// clearance as loaded. Falls back to a plain accept when the integration is off.
    func acceptEFBSuggestionSendingToForeFlight() {
        guard efbSuggestion != nil else { return }                        // state check (rule 7)
        guard offersForeFlight else { acceptEFBSuggestion(); return }     // integration off → plain accept
        let before = flightPlan
        acceptEFBSuggestion()
        guard ForeFlightExport.shouldHandoff(before: before, after: flightPlan) else { return }
        // openInForeFlight can still decline (a changed plan can serialize to <2 tokens, e.g. a
        // direct-to with no departure filed). The accept — this button's primary job — already
        // happened; staying in-app is the correct quiet outcome for an unsendable route.
        openInForeFlight()
    }

    /// Open ForeFlight with the current filed plan on its Maps view (offline app-to-app URL scheme;
    /// no network involved). No-op when nothing is filed or the plan serializes to fewer than two
    /// route tokens — a single point is not worth switching apps for.
    func openInForeFlight() {
        guard let plan = flightPlan, !plan.isEmpty else { return }        // state check (rule 7)
        guard let url = ForeFlightExport.url(for: plan) else { return }
        UIApplication.shared.open(url)                                    // backgrounds CommSight; capture
    }                                                                     // pauses/resumes via handleScenePhase

    /// Write the resolved plan as a Garmin `.fpl` in the temp directory for the share sheet
    /// ("Copy to ForeFlight"), or nil when nothing is filed / nothing resolves. The export is the
    /// SENDABLE plan (approach slot + orphaned procedures dropped — see
    /// `ForeFlightExport.sendablePlan`). Resolution touches the nav DB + CIFP (SQLite), so it runs
    /// off-main (a cold nav DB parses a few MB — same detached pattern as `prefetchRouteCharts`).
    func writeFPLFile() async -> URL? {
        guard let plan = flightPlan, !plan.isEmpty else { return nil }    // state check (rule 7)
        let sendable = ForeFlightExport.sendablePlan(plan)
        let name = [plan.departure, plan.destination].filter { !$0.isEmpty }.joined(separator: " ")
        let url: URL? = await Task.detached(priority: .utility) {
            _ = NavDatabase.count                                         // warm the nav DB off-main
            let legs = ProcedureRoute.resolve(sendable)
            let xml = ForeFlightExport.fplXML(for: legs, routeName: name.isEmpty ? "CommSight Route" : name)
            guard !xml.isEmpty else { return nil }                        // unresolvable plan → no file
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent("CommSight Route.fpl")
            do { try xml.write(to: dest, atomically: true, encoding: .utf8) } catch { return nil }
            return dest
        }.value
        guard !Task.isCancelled else { return nil }   // a newer plan superseded this build (.task id changed)
        return url
    }

    /// Load the coded approach for `runway` at the active airport into the flight plan (EFB "cleared for
    /// the approach"). Picks the first IAP whose runway matches; no-op if none. Bounded lookup (rule 2).
    private func loadApproachForRunway(_ runway: String) {
        guard !runway.isEmpty else { return }
        let ident = liveContext?.airportIdent ?? (airport.isEmpty ? "" : airport)
        guard !ident.isEmpty else { return }
        let want = SlotSnap.parseDesignator(runway)
        guard !want.num.isEmpty else { return }
        for proc in CIFP.procedures(airport: ident).prefix(2048) where proc.kind == "IAP" {
            let have = SlotSnap.parseDesignator(proc.runway)
            if have.num == want.num, have.suffix == want.suffix { loadProcedure(proc); return }
        }
    }

    // MARK: Loaded procedures (Phase 5 — SID / STAR / approach into the active flight plan)

    /// Load a coded procedure into the flight plan so its legs draw as the active route and its fixes
    /// ground the corrector. Captures the fix idents now (bounded, deduped). Validates the input (rule 7).
    func loadProcedure(_ proc: CIFPProcedure) {
        guard !proc.ident.isEmpty, !proc.airport.isEmpty else { return }
        var fixes: [String] = []
        var seen = Set<String>()
        for leg in CIFP.legs(procedureID: proc.id).prefix(256) {   // statically bounded
            let f = leg.fix.uppercased()
            if !f.isEmpty, !f.hasPrefix("RW"), seen.insert(f).inserted { fixes.append(f) }
        }
        let loaded = LoadedProcedure(airport: proc.airport, kind: proc.kind, ident: proc.ident,
                                     name: proc.name, runway: proc.runway, transition: proc.transition, fixes: fixes)
        editPlan { $0.loadProcedure(loaded) }
        previewedProcedure = nil          // it's part of the route now, not just a preview
    }

    /// Remove a loaded procedure by kind ("SID"/"STAR"/"IAP", or "" for all).
    func clearLoadedProcedure(kind: String) { editPlan { $0.clearProcedure(kind: kind) } }

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

    // MARK: Flight-plan strip (live editing — no Save button)

    /// Commit the strip's free-form route string to the filed plan: "KMSP GEP GOPHR1 KORD" parses
    /// into departure / enroute / destination (`FlightPlan.parseRoute`, the same tolerant grammar
    /// as the old paste box). Everything else on the plan (callsign, aircraft, altitude, loaded
    /// procedures) is preserved. Mirrors the old editor's side effect: an empty live-feed airport
    /// context is prefilled from the departure so the corrector grounds immediately.
    func commitRouteString(_ text: String) {
        let parsed = FlightPlan.parseRoute(text)
        editPlan { p in
            p.departure = parsed.departure ?? ""
            p.destination = parsed.destination ?? ""
            p.route = parsed.route
            p.savedAt = Date()
            p.reconcileProceduresWithEndpoints()   // typed edit re-anchors → stale procedures drop
        }
        if airport.isEmpty, let dep = parsed.departure, !dep.isEmpty { airport = dep }
    }

    /// Set the planned cruise altitude from the strip's altitude box (nil clears it).
    func setCruiseAltitude(_ feet: Int?) {
        let bounded = feet.map { min(max($0, 0), 60_000) }                // sanity bound (rule 7)
        editPlan { $0.cruiseAltitudeFt = (bounded ?? 0) > 0 ? bounded : nil }
    }

    /// Set the alternate airport from the strip's alternate box (empty clears it).
    func setAlternate(_ ident: String) {
        let id = ident.trimmingCharacters(in: .whitespaces).uppercased()
        guard id.count <= 8 else { return }                               // sanity bound (rule 7)
        editPlan { $0.alternate = id }
    }

    /// The saved aircraft matching the filed callsign (drives the strip chip's checkmark + the
    /// trip-stats performance numbers).
    var selectedAircraft: AircraftProfile? {
        guard let callsign = flightPlan?.callsign, !callsign.isEmpty else { return nil }
        return aircraftProfiles.first { $0.callsign.caseInsensitiveCompare(callsign) == .orderedSame }
    }

    /// Fly `profile`: copy its callsign/type into the filed plan (the single source the EFB
    /// ownship gate + corrector grounding read) and refresh the stats its performance drives.
    func selectAircraft(_ profile: AircraftProfile) {
        guard !profile.isEmpty else { return }                            // param check (rule 7)
        editPlan { p in
            p.callsign = profile.callsign.uppercased()
            p.aircraftType = profile.type
        }
        refreshTripStats()                                                // perf numbers changed
    }

    /// Add or update a profile (matched by id), then fly it. Bounded by the store cap — a NEW
    /// profile at the cap is rejected outright (not silently selected-but-unsaved, which would
    /// leave the plan's callsign pointing at a profile that doesn't exist).
    func saveAircraft(_ profile: AircraftProfile) {
        guard !profile.isEmpty else { return }                            // param check (rule 7)
        if let i = aircraftProfiles.firstIndex(where: { $0.id == profile.id }) {
            aircraftProfiles[i] = profile
        } else if aircraftProfiles.count < AircraftStore.maxProfiles {
            aircraftProfiles.append(profile)
        } else {
            return                                                        // hangar full → reject whole save
        }
        selectAircraft(profile)
    }

    /// Remove a profile from the hangar (the filed plan's callsign is left as-is — the plan, not
    /// the hangar, is the source of truth for the current flight). Stats refresh because the
    /// deleted profile's cruise/burn numbers may have been feeding ETE/FUEL.
    func deleteAircraft(_ profile: AircraftProfile) {
        aircraftProfiles.removeAll { $0.id == profile.id }
        refreshTripStats()
    }

    /// Recompute the trip-stats row OFF-MAIN (route resolution parses the nav DB / CIFP). Epoch
    /// discards a superseded async build (same pattern as `refreshEFBGrounding`); it is bumped
    /// BEFORE the empty-plan early-out so clearing the plan also invalidates any build in flight.
    /// Distance is computed over the SENDABLE plan (approach + orphaned procedures dropped) so
    /// DIST matches the route actually handed to ForeFlight — the raw plan would add the coded
    /// approach INCLUDING its missed-approach segment to the total.
    func refreshTripStats() {
        tripStatsEpoch += 1
        guard let plan = flightPlan, !plan.isEmpty else { tripStats = nil; return }
        let epoch = tripStatsEpoch
        let sendable = ForeFlightExport.sendablePlan(plan)
        let kts = selectedAircraft?.cruiseKts
        let gph = selectedAircraft?.burnGPH
        Task {
            let stats = await Task.detached(priority: .utility) {
                _ = NavDatabase.count                                     // warm the nav DB off-main
                let points = ProcedureRoute.resolve(sendable).map(\.coord)
                return TripStats.compute(points: points, cruiseKts: kts, burnGPH: gph)
            }.value
            guard epoch == tripStatsEpoch else { return }                 // superseded → discard
            tripStats = stats
        }
    }

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

    // MARK: NASA EONET natural hazards

    /// Whether the EONET poller should run now: hazard awareness is ON, and there is somewhere for
    /// it to matter — a live map showing the layer, the full-screen route map, or a filed plan
    /// (route alerts). Foreground-only and paused under thermal pressure (the map is paused there
    /// anyway). Everything is gated on `showHazards` so a pilot who never opts in never generates
    /// NASA traffic.
    private var eonetActive: Bool {
        scenePhaseActive && !thermalSerious && showHazards &&
            (mapBackgroundEnabled || showRouteMap || flightPlan != nil)
    }

    /// Reconcile the EONET poller (single edge-triggered call — see `EONETService.sync`). In
    /// `--demo-hazards` screenshot mode the poller is held off so the seeded snapshot survives.
    func syncEONET() {
        let active = eonetActive && !demoHazardsMode
        let service = eonetService
        Task { await service?.sync(enabled: active) }
    }

    /// Poll the live FAA TFR feed while the layer is on + there's a foregrounded map to show it on.
    private var tfrActive: Bool {
        scenePhaseActive && !thermalSerious && showTFRs &&
            (mapBackgroundEnabled || showRouteMap || flightPlan != nil)
    }
    func syncTFRs() {
        let active = tfrActive
        let service = tfrService
        Task { await service?.sync(enabled: active) }
    }

    /// EONET published a snapshot: mirror it into the UI state. The map hosts observe
    /// `hazardEvents` and diff their overlays; `hazardsUpdatedAt` drives the staleness note.
    /// Unlike traffic, a late callback is harmless — hazards are context, not corrector input.
    private func applyHazards(_ events: [EONETEvent], snapshotAt: Date) {
        hazardEvents = events
        hazardsUpdatedAt = snapshotAt == .distantPast ? nil : snapshotAt
        refreshHazardAlert()
    }

    /// Recompute the route/vicinity hazard banner OFF the main actor (the corridor math scans
    /// events × route segments and the route resolve hits SQLite), epoch-guarded like
    /// `syncGrounding` so a superseded recompute that lands late is dropped.
    func refreshHazardAlert() {
        hazardAlertEpoch += 1
        let epoch = hazardAlertEpoch
        guard showHazards, !hazardEvents.isEmpty else { hazardAlert = nil; return }
        let events = hazardEvents
        let ownship: Coord? = (stratuxGPS?.hasFix == true) ? stratuxGPS?.coordinate : nil
        let dismissed = hazardDismissedIDs
        let planRoute = flightPlan?.fullRoute ?? []
        Task.detached(priority: .utility) { [weak self] in
            let route = planRoute.isEmpty ? [] : RouteResolver.resolve(planRoute).points.map(\.coord)
            let alert = HazardCorridor.alert(events: events, route: route, ownship: ownship)
            let filtered = HazardAlert(
                routeHits: alert.routeHits.filter { !dismissed.contains($0.eventID) },
                vicinityHits: alert.vicinityHits.filter { !dismissed.contains($0.eventID) })
            // Publish on main (AppModel is not actor-isolated) — same hop as the service callbacks.
            Task { @MainActor in self?.applyHazardAlert(filtered, epoch: epoch) }
        }
    }

    private func applyHazardAlert(_ alert: HazardAlert, epoch: Int) {
        guard hazardAlertEpoch == epoch else { return }   // a newer recompute/clear won
        hazardAlert = alert.isEmpty ? nil : alert
    }

    /// X on the hazard banner: silence exactly these events until the plan changes (a NEW nearby
    /// event still alerts — only what the pilot has seen is muted). Bumps the epoch so an in-flight
    /// `refreshHazardAlert` (which captured the pre-dismiss `hazardDismissedIDs`) can't land and
    /// republish the banner we just cleared.
    func dismissHazardAlert() {
        guard let alert = hazardAlert else { return }
        for h in alert.routeHits.prefix(HazardCorridor.maxHits) { hazardDismissedIDs.insert(h.eventID) }
        for h in alert.vicinityHits.prefix(HazardCorridor.maxHits) { hazardDismissedIDs.insert(h.eventID) }
        hazardAlertEpoch += 1
        hazardAlert = nil
    }

    /// "Details" on the hazard banner: open the hits in the tap-to-identify panel (the chooser when
    /// there are several, straight into the card for one) — the same flow as tapping the map.
    func showHazardAlertDetails() {
        guard let alert = hazardAlert else { return }
        var objects: [IdentifiedObject] = []
        for h in (alert.routeHits + alert.vicinityHits).prefix(HazardCorridor.maxHits) {
            guard let ev = hazardEvents.first(where: { $0.id == h.eventID }) else { continue }
            objects.append(IdentifiedObject(kind: .hazard, ident: ev.title, coord: ev.point,
                                            onRoute: false, hazard: ev))
        }
        guard !objects.isEmpty else { return }
        widgetStore.mapProbe = MapProbeResult(id: "hazard-\(UUID().uuidString)", objects: objects)
    }

    /// Ownship moved: recompute the vicinity check once it has moved a meaningful distance (a ~1 Hz
    /// GPS fix must not rescan 400 events × the route every tick).
    private func maybeRefreshHazardAlertForMovement() {
        guard showHazards, let here = stratuxGPS?.coordinate else { return }
        if let last = lastHazardAlertCenter, Geo.nmBetween(last, here) < Self.hazardRecomputeNm { return }
        lastHazardAlertCenter = here
        refreshHazardAlert()
    }

    /// The center for the 30 NM query: the typed airport's coordinate, or nil when blank/unknown (→ no
    /// polling). QW1: no longer defaults to KDFW when blank — pulling Dallas traffic into the correction
    /// prompt of a KBOS (or any) feed injects wrong-facility aircraft, the same wrong-airport bias QW1
    /// removed from the decoder prompt. Device GPS will sit ahead of this later.
    private func facilityCoordinate() -> Coord? {
        airport.isEmpty ? nil : AirportCoordinates.coordinate(icao: airport)
    }

    // MARK: GPS-vicinity grounding (in-cockpit feeds)

    /// Ownship position for vicinity grounding: the Stratux GPS fix (from the always-on Stratux link,
    /// so it's available for a mic/USB session too, not just the Stratux audio source). nil when there's
    /// no usable fix. Device CLLocation is the natural follow-up here for a phone-mic-only cockpit setup.
    private func groundingCoordinate() -> Coord? {
        guard let gps = stratuxGPS, gps.hasFix else { return nil }
        return gps.coordinate
    }

    /// Re-resolve the surrounding-vicinity corrector grounding and push it into the running session —
    /// the in-cockpit analogue of `syncTraffic`. HARD (deterministic SlotSnap) grounds on the single
    /// nearest airport within the terminal-area radius; SOFT (LLM/Whisper procedures union) spans the
    /// whole vicinity. Only for a running in-cockpit (GPS) session; the LiveATC feed keeps its typed
    /// airport and replay has no location, so both CLEAR any vicinity grounding here. Deduped by ownship
    /// movement (a 1 Hz fix doesn't rescan the ~90k-ident nav table every tick) and epoch-guarded so a
    /// stale off-main resolve that lands late is dropped. Called on GPS movement, start, and stop.
    func syncGrounding(force: Bool = false) {
        guard session != nil, isRunning, groundingSource?.isInCockpit == true,
              let here = groundingCoordinate() else {
            // Not a running in-cockpit GPS session (or no fix yet) → drop any vicinity grounding so the
            // typed path (LiveATC) / no-grounding (replay / GPS-less) governs, and re-arm the dedup.
            if lastGroundingCenter != nil {
                lastGroundingCenter = nil
                groundingEpoch += 1
                session?.clearGroundingAirports()
            }
            return
        }
        // Only rescan once ownship has moved a meaningful distance (or on a forced resync at start).
        if !force, let last = lastGroundingCenter, Geo.nmBetween(last, here) < Self.groundingRecomputeNm {
            return
        }
        lastGroundingCenter = here
        groundingEpoch += 1
        let epoch = groundingEpoch
        let store = groundingStore
        // Resolve OFF the main actor — `nearbyRanked` scans the whole nav table + hits CIFP sqlite.
        Task.detached(priority: .utility) {
            let ranked = await store.nearbyRanked(lat: here.lat, lon: here.lon,
                                                  radiusNm: Self.vicinityRadiusNm,
                                                  limit: Self.vicinityAirportCap)
            await MainActor.run { [weak self] in
                guard let self, self.groundingEpoch == epoch else { return }   // a newer resolve/clear won
                let soft = ranked.map(\.data)
                // HARD grounding only when the nearest airport is close enough to be operationally
                // relevant (terminal area) — beyond that we're en route and a deterministic runway/freq
                // snap to an overflown field would only widen the false-snap surface. SOFT still spans all.
                let hard = ranked.first.flatMap { $0.distanceNm <= Self.hardGroundingRadiusNm ? $0.data : nil }
                self.session?.setGroundingAirports(hard: hard, soft: soft)
            }
        }
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
            syncEONET()
            syncTFRs()
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
            syncEONET()
            syncTFRs()
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
            // Mark the request in flight and snapshot what it is FOR (M4). The dialog is async: a
            // model swap (new session), a Stop, backgrounding, or a source re-pick can all happen
            // while it sits open. `.starting` is otherwise unused; it is the currency token the
            // completion re-checks so a stale grant can't start capture on changed state.
            status = .starting
            detail = "Waiting for microphone permission…"
            let requested = source
            AVAudioApplication.requestRecordPermission { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    guard granted else {
                        self.status = .error
                        self.detail = "Microphone access denied. Enable it in Settings › CommSight › Microphone."
                        return
                    }
                    // Abort SILENTLY if anything moved under the dialog — the user's later action
                    // (swap / Stop / background / re-pick) already put the app where it wants to be.
                    guard Self.captureRequestStillCurrent(sessionMatches: self.session === session,
                                                          status: self.status, sceneActive: self.scenePhaseActive,
                                                          source: self.source, requested: requested) else { return }
                    self.beginCapture(session: session, resuming: resuming)
                }
            }
            return
        }
        beginCapture(session: session, resuming: resuming)
    }

    /// Pure currency predicate for a returning mic-permission grant (M4). Capture may proceed only
    /// if the SAME session is still current, the request is still the in-flight `.starting` one, the
    /// scene is active, and the source hasn't been re-picked. Pure + nonisolated so it is unit-tested
    /// without the (untestable) system permission dialog.
    nonisolated static func captureRequestStillCurrent(sessionMatches: Bool, status: SessionStatus,
                                                       sceneActive: Bool, source: SourceKind,
                                                       requested: SourceKind) -> Bool {
        sessionMatches && status == .starting && sceneActive && source == requested
    }

    /// Apply a thermal-state change to `thermalSerious` with EXIT hysteresis (M7). Entering serious
    /// is immediate — protect transcription now. Leaving waits out `thermalExitDwell` of sustained
    /// cooling so a device oscillating at the threshold doesn't destroy + rebuild the map on every
    /// flip; a cancellable single-flight task (cancelled on any re-entry) guarantees exactly one
    /// pending clear, and it re-checks the LIVE thermal state at fire time.
    private func applyThermal(serious: Bool) {
        if serious {
            thermalClearTask?.cancel(); thermalClearTask = nil
            thermalSerious = true
        } else {
            guard thermalSerious, thermalClearTask == nil else { return }
            thermalClearTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: Self.thermalExitDwell)
                guard !Task.isCancelled, let self else { return }
                // Re-check the live state — a re-entry during the dwell cancels this task, but guard
                // anyway against a spurious clear if the device is still hot.
                let stillHot = ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
                if !stillHot { self.thermalSerious = false }
                self.thermalClearTask = nil
            }
        }
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
        // Transient capture notices (interruption paused / mic resumed) — detail line only, the
        // run stays live. Terminal problems keep going through `micFailure` above.
        let micNotice: @Sendable (String) -> Void = { [weak self] msg in
            Task { @MainActor in self?.detail = msg }
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
            src = DeviceAudioSource(preferUSB: false, onFailure: micFailure, onNotice: micNotice)
        case .usbAudio:
            src = DeviceAudioSource(preferUSB: true, onFailure: micFailure, onNotice: micNotice)
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
        session.start(source: src, label: source.rawValue, clearHistory: !resuming,
                      // Transient pipeline notices (failed decode, runaway noise) → the detail
                      // line, status stays .live (the Stratux onTrouble pattern).
                      onTrouble: { [weak self] msg in Task { @MainActor in self?.detail = msg } })
        if !resuming { callsignFilter = nil }   // a fresh transcript replaces history → drop a stale filter
        sourceLabel = source.rawValue
        detail = "Transcribing."
        syncTraffic()   // a live session started → the session-coupled ADS-B poller may begin (Stratux is independent)
        // Grounding follows the RUNNING source (settled here), not the picker. In-cockpit → resolve the
        // GPS vicinity now if a fix is ready (else it lands on the next GPS tick); LiveATC/replay → clear.
        groundingSource = source
        syncGrounding(force: true)
    }

    func stop() {
        // Stop pressed WHILE the mic-permission dialog is open (status .starting, no run yet):
        // session.stop() would no-op on a never-started session, leaving isRunning stuck true. Move
        // to .stopped so the pending grant's currency check (status == .starting) aborts (M4).
        if status == .starting { status = .stopped }
        // The session releases the audio session itself (on Stop and on a natural end); the demo
        // path never activated one, so nothing to release here.
        if let session { session.stop() } else { status = .stopped }
        detail = "Stopped."
        syncTraffic()   // no live session → stop the session-coupled ADS-B poller (an enabled Stratux link keeps streaming)
        groundingSource = nil
        syncGrounding()   // no running in-cockpit source → drop any vicinity grounding
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
        let predecessor = loadTask   // chain anchor: a (possibly still-compiling) superseded load
        loadTask = Task {
            // Serialize CoreML compiles: cancellation cannot interrupt an in-flight WhisperKit
            // compile, so wait for the superseded load to actually RETURN before starting ours —
            // two multi-GB compiles resident at once can OOM-kill the app. The chain is strictly
            // linear (each task awaits only its immediate predecessor): no cycle, no deadlock; the
            // predecessor's own generation guard makes it bail promptly once its compile returns.
            if let predecessor { await predecessor.value }
            guard modelSwapGeneration == gen else { return }   // superseded while we queued
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
        // Cancel but KEEP the reference: the next switch chains on `loadTask` to serialize CoreML
        // compiles — nil-ing it here would let that switch compile while the abandoned (cancelled
        // but non-interruptible) compile is still resident, re-opening the two-compiles OOM.
        loadTask?.cancel()
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

        let predecessor = loadTask   // chain anchor: the (possibly still-compiling) superseded load
        loadTask = Task {
            // Serialize CoreML compiles (see beginModelLoad): await the superseded load's actual
            // return before starting this one, so two heavy compiles never coexist in memory.
            if let predecessor { await predecessor.value }
            guard modelSwapGeneration == gen else { return }   // superseded while we queued
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
            // Demo has no live acoustic clustering, so fuse content-only (affinity unknown) — the
            // same mapping the live path uses, so the sample renders real ATC/callsign chips.
            let lbl = TurnRoleTagger.classify(r.display, knowledge: .shared)
            r.role = lbl.role
            r.roleConfidence = lbl.confidence
            let fused = SpeakerFusion.fuse(ownRole: lbl.role, affinity: .unknown, callsign: r.callsign)
            r.roleFused = fused.roleFused
            r.speakerLabel = fused.label
            r.fusedFrom = fused.from
            return r
        }
        for r in records { stats.add(r) }
        status = .live
        detail = "Transcribing."
        proofOfLife = ProofOfLifeResult(passed: true, activeModel: "small", meanWER: 0.091,
                                        realtimeSpeed: 12.5, snippets: [], error: nil)
    }
}
