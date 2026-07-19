import SwiftUI

/// The app's top-level tabs (a ForeFlight-style bottom bar), left → right.
enum RootTab: String, Hashable, CaseIterable { case transcript, map, plates, airports, notes, logbook }

/// Root view: a ForeFlight-style bottom tab bar under two full-screen tabs — "Map" (the existing
/// console: transcript, flight plan, floating widgets, live audio) and "Plates" (a searchable FAA
/// chart browser). Both tabs stay alive at once (opacity/hit-test switch, not a teardown) so leaving
/// the map to browse a plate never stops the live session or rebuilds the map. The bar is inset via
/// `safeAreaInset`, so each tab's own controls sit above it while the map stays full-bleed behind it.
///
/// A native `TabView` puts its bar at the TOP on iPad (a segmented pill), which is not what a cockpit
/// EFB wants — hence the hand-rolled bottom bar, matching ForeFlight's page tabs.
struct RootTabView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack {
            // The map/console stays alive at all times (never stop the live session or rebuild the map).
            ConsoleView()
                .opacity(model.selectedTab == .map ? 1 : 0)
                .allowsHitTesting(model.selectedTab == .map)
                .accessibilityHidden(model.selectedTab != .map)

            PlatesTabView()
                .opacity(model.selectedTab == .plates ? 1 : 0)
                .allowsHitTesting(model.selectedTab == .plates)
                .accessibilityHidden(model.selectedTab != .plates)

            // Transcript + Notes render their heavy content only while selected (self-gated) so they
            // cost nothing behind the map — keeps launch cool and memory low.
            TranscriptTabView()
                .opacity(model.selectedTab == .transcript ? 1 : 0)
                .allowsHitTesting(model.selectedTab == .transcript)
                .accessibilityHidden(model.selectedTab != .transcript)

            AirportsTabView()
                .opacity(model.selectedTab == .airports ? 1 : 0)
                .allowsHitTesting(model.selectedTab == .airports)
                .accessibilityHidden(model.selectedTab != .airports)

            NotesTabView()
                .opacity(model.selectedTab == .notes ? 1 : 0)
                .allowsHitTesting(model.selectedTab == .notes)
                .accessibilityHidden(model.selectedTab != .notes)

            LogbookTabView()
                .opacity(model.selectedTab == .logbook ? 1 : 0)
                .allowsHitTesting(model.selectedTab == .logbook)
                .accessibilityHidden(model.selectedTab != .logbook)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // The live GPS bar (when toggled) rides in the SAME bottom inset as the tab bar, just above it —
            // guaranteeing it reserves space and never overlaps the map's bottom widgets or the tab bar.
            VStack(spacing: 0) {
                if model.showGPSBar {
                    GPSBottomBar().transition(.move(edge: .bottom).combined(with: .opacity))
                }
                BottomTabBar(selection: $model.selectedTab, palette: model.palette)
            }
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)   // the bar stays pinned; the search keyboard covers it
        .tint(model.palette.accent)
        .preferredColorScheme(model.theme == .day ? .light : .dark)
        .animation(.easeInOut(duration: 0.15), value: model.selectedTab)
        .animation(.easeInOut(duration: 0.2), value: model.showGPSBar)
    }
}

/// The bottom bar itself: two equal-width items, each an icon over a label, tinted with the accent when
/// active. The surface color bleeds into the home-indicator area (the background layer ignores the
/// bottom safe area) so no map peeks below the bar.
private struct BottomTabBar: View {
    @Binding var selection: RootTab
    let palette: Palette

    var body: some View {
        HStack(spacing: 0) {
            // Angular / geometric glyphs (per feedback — less round).
            item(.transcript, icon: "list.bullet.rectangle.fill", label: "Transcript")
            item(.map, icon: "map.fill", label: "Map")
            item(.plates, icon: "books.vertical.fill", label: "Plates")
            item(.airports, icon: "airplane", label: "Airports")
            item(.notes, icon: "square.and.pencil", label: "Notes")
            item(.logbook, icon: "book.closed.fill", label: "Logbook")
        }
        .padding(.top, 7)
        .padding(.bottom, 3)
        .frame(maxWidth: .infinity)
        .background(
            palette.surface
                .overlay(alignment: .top) { Rectangle().fill(palette.border).frame(height: 0.5) }
                .ignoresSafeArea(.container, edges: .bottom)
        )
    }

    private func item(_ tab: RootTab, icon: String, label: String) -> some View {
        let active = selection == tab
        return Button {
            if selection != tab { Haptics.impact(.light) }
            selection = tab
        } label: {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 22))
                Text(label).font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(active ? palette.accent : palette.textDim)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plainHaptic)
        .accessibilityIdentifier("tab-\(tab.rawValue)")
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
    }
}
