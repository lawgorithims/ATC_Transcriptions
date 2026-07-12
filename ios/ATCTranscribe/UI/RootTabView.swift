import SwiftUI

/// The app's top-level tabs (a ForeFlight-style bottom bar).
enum RootTab: String, Hashable { case map, plates }

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
            ConsoleView()
                .opacity(model.selectedTab == .map ? 1 : 0)
                .allowsHitTesting(model.selectedTab == .map)
                .accessibilityHidden(model.selectedTab != .map)

            PlatesTabView()
                .opacity(model.selectedTab == .plates ? 1 : 0)
                .allowsHitTesting(model.selectedTab == .plates)
                .accessibilityHidden(model.selectedTab != .plates)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            BottomTabBar(selection: $model.selectedTab, palette: model.palette)
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)   // the bar stays pinned; the search keyboard covers it
        .tint(model.palette.accent)
        .preferredColorScheme(model.theme == .day ? .light : .dark)
        .animation(.easeInOut(duration: 0.15), value: model.selectedTab)
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
            item(.map, icon: "map.fill", label: "Map")
            item(.plates, icon: "doc.text.image", label: "Plates")
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
        .buttonStyle(.plain)
        .accessibilityIdentifier("tab-\(tab.rawValue)")
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
    }
}
