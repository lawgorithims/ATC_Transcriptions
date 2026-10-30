import SwiftUI

/// App entry point. Owns the `AppModel` (appearance + session state) and hands it to
/// the console as an environment object.
@main
struct ATCTranscribeApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var downloads = ModelDownloadManager()
    @StateObject private var notes = NotesStore()
    @StateObject private var metars = MetarStore()
    @StateObject private var forecasts = ForecastStore()
    @StateObject private var tafs = TafStore()
    @StateObject private var battery = BatteryDiagnostics()   // opt-in on-device energy telemetry
    // What the pilot has paid for. A singleton (the non-view download singletons must read it too)
    // observed here so the view tree re-renders on a change — see EntitlementStore for why it is
    // deliberately NOT hung off AppModel.
    @StateObject private var entitlements = EntitlementStore.shared
    @StateObject private var cloudSync = CloudSyncHost()      // logbook + notes across the pilot's devices
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if canImport(MapLibre)
        // Before ANY map exists, and never anywhere later — see MapLibreAmbientCache.
        MapLibreAmbientCache.disable()
        #endif
    }

    /// The MapLibre map is now the app's PRIMARY Map-tab engine (toggle: Settings → General → Map engine),
    /// so the old full-screen standalone globe screen is a debug-only harness reachable ONLY via the explicit
    /// `--maplibre` launch arg. The former `atc.experimentalMapLibreGlobe` UserDefault trigger is retired so a
    /// value left over from an earlier test can't hijack the whole app instead of showing the tab UI.
    private var showMapLibrePrototype: Bool {
        ProcessInfo.processInfo.arguments.contains("--maplibre")
    }

    var body: some Scene {
        WindowGroup {
            #if canImport(MapLibre)
            if showMapLibrePrototype {
                // Migration milestone 1: our real offline FAA tiles + filed route on the MapLibre globe.
                MapLibreChartScreen(model: model, onClose: {
                    UserDefaults.standard.set(false, forKey: "atc.experimentalMapLibreGlobe")
                })
            } else {
                appRoot
            }
            #else
            appRoot
            #endif
        }
    }

    private var appRoot: some View {
            RootTabView()                               // Transcript · Map · Plates · Airports · Notes · Logbook
                .environmentObject(model)
                .environmentObject(model.widgetStore)   // isolated widget-layout/probe store (see WidgetStore)
                .environmentObject(model.flightRecorder) // REC control + GPS bar + map breadcrumb observe this
                .environmentObject(model.logbook)       // saved flights (the Logbook tab)
                .environmentObject(downloads)
                .environmentObject(notes)               // hand-written notes library (PencilKit)
                .environmentObject(metars)              // live METAR + flight category for airport captions
                .environmentObject(forecasts)           // NWS 7-day outlook for the airport weather tab
                .environmentObject(tafs)                // TAF (Terminal Aerodrome Forecast) sub-tab
                .environmentObject(battery)             // battery/energy diagnostics
                .environmentObject(entitlements)        // tier/capability gate (see EntitlementStore)
                .onAppear {
                    // Tag each battery sample with what the app is doing (transcription/map/GPS/Stratux).
                    battery.snapshotProvider = { [weak model] in model?.batterySnapshot ?? .placeholder }
                }
                .onChange(of: scenePhase) { _, phase in
                    battery.setForegrounded(phase == .active)
                    if phase == .active {
                        // Re-resolve on foreground: a subscription can lapse, renew or be refunded
                        // while the app is backgrounded, and from M3 StoreKit reports that here.
                        entitlements.refresh()
                        // And a sync pass, because the other device's edits land while this one was
                        // in the bag. A no-op unless Features.cloudSync is on.
                        Task { await cloudSync.syncNow() }
                    }
                }
                .task {
                    // Built here rather than as a @StateObject because it needs the two stores — see
                    // CloudSyncHost. Does nothing at all in a build without the cloud-sync gate.
                    await cloudSync.start(logbook: model.logbook, notes: notes)
                }
                // "Open in CommSight" from ForeFlight's share sheet (a Garmin .fpl) imports the route.
                .onOpenURL { url in
                    guard url.isFileURL else { return }
                    _ = model.importFPL(url)
                }
    }
}
