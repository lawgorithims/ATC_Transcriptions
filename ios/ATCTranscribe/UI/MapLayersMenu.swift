import SwiftUI

/// The top-bar map icon's menu: pick the base chart layer, toggle overlays, and flip the live-map
/// master switch. All state (`chartLayer` / `showAirspace` / `showNearby` / `showHazards` /
/// `showSmoke` / `showWxRadar` / `mapBackgroundEnabled`) is persisted on `AppModel`, so this menu and
/// the always-on home map stay in sync.
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
            Toggle(isOn: $model.showAirspace) { Label("Airspace & special use", systemImage: "hexagon") }
            Toggle(isOn: $model.showNearby) { Label("Nearby navaids & airports", systemImage: "mappin.and.ellipse") }
            Toggle(isOn: $model.showTFRs) { Label("TFRs (FAA, live)", systemImage: "exclamationmark.octagon") }
            if model.showTFRs {
                switch model.tfrStatus {
                case .error: Text("TFR feed unavailable — check connection")
                default:
                    if let at = model.tfrsUpdatedAt {
                        Text("\(model.tfrs.count) TFRs, updated \(Self.relative.localizedString(for: at, relativeTo: Date()))")
                    } else {
                        Text("Loading TFRs…")
                    }
                }
            }
            Toggle(isOn: $model.showHazards) { Label("Natural hazards (NASA)", systemImage: "flame") }
            if model.showHazards, let at = model.hazardsUpdatedAt {
                Text("Hazards updated \(Self.relative.localizedString(for: at, relativeTo: Date()))")
            }
            Toggle(isOn: $model.showSmoke) { Label("Smoke & satellite (NASA)", systemImage: "smoke") }
            if model.showSmoke {
                Text("NASA satellite · imagery \(GIBSTileOverlay.priorUTCDay(from: Date())) UTC — context, not current weather")
            }
            Toggle(isOn: $model.showWxRadar) { Label("Weather radar — coming soon", systemImage: "cloud.rain") }
                .disabled(true)
            Divider()
            Toggle(isOn: $model.terrain3DEnabled) { Label("3D terrain (Map/Satellite)", systemImage: "mountain.2") }
            if model.terrain3DEnabled {
                Text("Realistic 3D relief on the Apple base maps. Uses more power — turn off if the device warms up.")
            }
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
