import SwiftUI

/// App entry point. Owns the `AppModel` (appearance + session state) and hands it to
/// the console as an environment object.
@main
struct ATCTranscribeApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var downloads = ModelDownloadManager()
    @StateObject private var notes = NotesStore()

    var body: some Scene {
        WindowGroup {
            RootTabView()                               // Transcript · Map · Plates · Notes bottom tabs
                .environmentObject(model)
                .environmentObject(model.widgetStore)   // isolated widget-layout/probe store (see WidgetStore)
                .environmentObject(downloads)
                .environmentObject(notes)               // hand-written notes library (PencilKit)
        }
    }
}
