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
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootTabView()                               // Transcript · Map · Plates · Airports · Notes tabs
                .environmentObject(model)
                .environmentObject(model.widgetStore)   // isolated widget-layout/probe store (see WidgetStore)
                .environmentObject(downloads)
                .environmentObject(notes)               // hand-written notes library (PencilKit)
                .environmentObject(metars)              // live METAR + flight category for airport captions
                .environmentObject(forecasts)           // NWS 7-day outlook for the airport weather tab
                .environmentObject(tafs)                // TAF (Terminal Aerodrome Forecast) sub-tab
                .environmentObject(battery)             // battery/energy diagnostics
                .onAppear {
                    // Tag each battery sample with what the app is doing (transcription/map/GPS/Stratux).
                    battery.activityProvider = { [weak model] in model?.batteryActivityTag ?? "—" }
                }
                .onChange(of: scenePhase) { _, phase in battery.setForegrounded(phase == .active) }
                // "Open in CommSight" from ForeFlight's share sheet (a Garmin .fpl) imports the route.
                .onOpenURL { url in
                    guard url.isFileURL else { return }
                    _ = model.importFPL(url)
                }
        }
    }
}
