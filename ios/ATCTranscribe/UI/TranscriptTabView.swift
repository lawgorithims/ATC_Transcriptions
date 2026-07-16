import SwiftUI

/// The "Transcript" bottom tab (far left): the live ATC transcript given the WHOLE page — the same
/// `TranscriptCard` used in the floating widget and the compact bottom card, expanded edge-to-edge.
/// Content renders only while the tab is selected (opacity switch in RootTabView) so it costs nothing
/// behind the map. Capture is still started/stopped from the Map tab's power button; this is the reading
/// surface.
struct TranscriptTabView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            if model.selectedTab == .transcript {
                content
            } else {
                Color.clear
            }
        }
    }

    private var content: some View {
        let p = model.palette
        return VStack(spacing: 0) {
            // The same control surface as the Map tab (source/input strip toggle, flight plan, search,
            // theme, START/STOP power, settings) — the transcript is where a session is watched, so its
            // controls must be reachable here without bouncing back to the map.
            TopBar()
            if model.showInputBar { InputBar().transition(ConsoleView.barTransition) }
            TranscriptCard()
                .environment(\.floatingSurface, true)  // no card chrome — fill the page, we own the bg
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(p.bg.ignoresSafeArea())
        .preferredColorScheme(model.theme == .day ? .light : .dark)
    }
}
