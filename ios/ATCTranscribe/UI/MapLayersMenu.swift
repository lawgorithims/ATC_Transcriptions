import SwiftUI

/// The top-bar map icon's menu: pick the base chart layer, toggle overlays, and flip the live-map
/// master switch. All state (`chartLayer` / `showAirspace` / `showNearby` / `showHazards` /
/// `showWxRadar` / `mapBackgroundEnabled`) is persisted on `AppModel`, so this menu and the
/// always-on home map stay in sync.
struct MapLayersMenu: View {
    @EnvironmentObject var model: AppModel
    var iconSize: CGFloat = 19

    private static let relative = RelativeDateTimeFormatter()

    var body: some View {
        Menu {
            Picker("Base map", selection: $model.chartLayer) {
                ForEach(ChartLayer.allCases) { Text($0.title).tag($0) }
            }
            Divider()
            Toggle(isOn: $model.showAirspace) { Label("Class B/C/D airspace", systemImage: "hexagon") }
            Toggle(isOn: $model.showNearby) { Label("Nearby navaids & airports", systemImage: "mappin.and.ellipse") }
            Toggle(isOn: $model.showHazards) { Label("Natural hazards (NASA)", systemImage: "flame") }
            if model.showHazards, let at = model.hazardsUpdatedAt {
                Text("Hazards updated \(Self.relative.localizedString(for: at, relativeTo: Date()))")
            }
            Toggle(isOn: $model.showWxRadar) { Label("Weather radar — coming soon", systemImage: "cloud.rain") }
                .disabled(true)
            Divider()
            Toggle(isOn: $model.mapBackgroundEnabled) { Label("Live map background", systemImage: "map") }
        } label: {
            Image(systemName: "square.3.layers.3d")
                .font(.system(size: iconSize))
                .frame(width: 30, height: 30)
        }
        .accessibilityIdentifier("map-layers-menu")
        .accessibilityLabel("Map layers")
    }
}
