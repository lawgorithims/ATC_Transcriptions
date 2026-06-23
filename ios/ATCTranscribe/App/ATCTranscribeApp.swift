import SwiftUI

/// App entry point. Owns the `AppModel` (appearance + session state) and hands it to
/// the console as an environment object.
@main
struct ATCTranscribeApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ConsoleView()
                .environmentObject(model)
        }
    }
}
