import SwiftUI

/// App entry point. The full console UI (themes, status pills, transcript,
/// sidebar, settings) is ported from `server/static/*` in a later phase; for now
/// this hosts a skeleton `ConsoleView` so the project builds and runs end-to-end.
@main
struct ATCTranscribeApp: App {
    var body: some Scene {
        WindowGroup {
            ConsoleView()
        }
    }
}
