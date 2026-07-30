import SwiftUI

/// The top-bar map icon — opens a two-column panel: Column A picks the base chart layer, Column B toggles
/// the overlays + map controls. Replaces the old single-column dropdown (which had grown cluttered). All
/// state is persisted on `AppModel` (+ the zoom-controls @AppStorage), so this panel and the always-on home
/// map stay in sync.
struct MapLayersMenu: View {
    @EnvironmentObject var model: AppModel
    var iconSize: CGFloat = 19
    @State private var show = false

    var body: some View {
        Button { show = true } label: {
            Image(systemName: "square.3.layers.3d")
                .font(.system(size: iconSize))
                .frame(width: 30, height: 30)
        }
        .accessibilityIdentifier("map-layers-menu")
        .accessibilityLabel("Map layers")
        .popover(isPresented: $show) {
            MapLayersPanel().environmentObject(model)
        }
    }
}

/// The two-column layers/overlays panel (Base map | Overlays & controls).
struct MapLayersPanel: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("atc.map.zoomControls") private var showZoomControls = true

    var body: some View {
        let p = model.palette
        HStack(alignment: .top, spacing: 14) {
            // COLUMN A — base map (single selection).
            VStack(alignment: .leading, spacing: 3) {
                header("Base map", p)
                ForEach(ChartLayer.allCases) { layer in baseRow(layer, p) }
                Spacer(minLength: 0)
            }
            .frame(width: 190)

            Divider()

            // COLUMN B — overlays + controls (toggles).
            ScrollView {
                VStack(alignment: .leading, spacing: 11) {
                    header("Overlays", p)
                    // The toggles below stay live in Dark mode — they still control airports, traffic,
                    // weather and TFRs — but the mode overrides three of them downward. Saying so beats
                    // disabling the rows, which would look like the pilot's saved preferences were lost.
                    if model.chartLayer == .smartDark {
                        Text("Dark (minimal) hides airways, airspace and off-route navaids. TFRs, traffic, weather and your route stay on.")
                            .font(.dsLabelS).foregroundStyle(p.textDim)
                            .accessibilityIdentifier("layers-smartdark-note")
                    }
                    layerToggle($model.showAirspace, "Airspace & special use", "hexagon", p, id: "layer-airspace")
                    layerToggle($model.showNearby, "Nearby navaids & airports", "mappin.and.ellipse", p, id: "layer-nearby")
                    layerToggle($model.showAirways, "Airways (V / J routes)", "point.topleft.down.to.point.bottomright.curvepath", p, id: "layer-airways")
                    layerToggle($model.showTFRs, "TFRs (FAA, live)", "exclamationmark.octagon", p, id: "layer-tfrs")
                    layerToggle($model.adsbStreamingEnabled, "Traffic (online ADS-B)", "airplane.circle", p, id: "layer-adsb")
                    layerToggle($model.showHazards, "Natural hazards (NASA)", "flame", p, id: "layer-hazards")
                    layerToggle($model.showSmoke, "Smoke & satellite (NASA)", "smoke", p, id: "layer-smoke")
                    layerToggle($model.showWxRadar, "Weather radar (precip)", "cloud.rain", p, id: "layer-radar")

                    Divider().padding(.vertical, 2)

                    header("Map controls", p)
                    layerToggle($showZoomControls, "Map buttons (zoom, north, center)", "plus.magnifyingglass", p, id: "layer-zoom-controls")

                    Divider().padding(.vertical, 2)

                    header("Chart brightness", p)
                    HStack(spacing: 9) {
                        Image(systemName: "sun.min").font(.dsLabel).foregroundStyle(p.textDim)
                        Slider(value: $model.chartBrightness, in: 0.3...1.0)
                            .tint(p.accent)
                            .accessibilityIdentifier("chart-brightness-slider")
                            .accessibilityLabel("Chart brightness")
                        Image(systemName: "sun.max").font(.dsLabel).foregroundStyle(p.textDim)
                    }
                    Text("Dims the FAA chart imagery only — route, traffic, TFRs and labels stay at full strength. Scales the theme's own level (Night is already dimmed).")
                        .font(.dsLabelS).foregroundStyle(p.textDim)
                    // REMOVED with the globe becoming the only engine:
                    //  • "3D terrain" — it only ever drove MKMapConfiguration.elevationStyle on the FLAT
                    //    Apple base; the globe engine has no DEM path, so the switch did nothing on the
                    //    sphere. The elevation DATA it implied is very much alive (Core/TerrainElevation
                    //    + the bundled grid) and now feeds the AGL readout — it is also what a future
                    //    synthetic-vision view would build on, so only the dead toggle went away.
                    //  • "Live map background" — it chose whether the Apple base drew UNDER the FAA
                    //    raster. On the globe the opaque satellite base is always the bottom layer, so
                    //    the switch had no observable effect at all.
                }
                .padding(.trailing, 2)
            }
            .frame(width: 258)
        }
        .padding(16)
        .frame(minWidth: 480, minHeight: 300, maxHeight: 460)
        .background(p.bg)
        .presentationCompactAdaptation(.popover)
    }

    private func header(_ t: String, _ p: Palette) -> some View {
        Text(t.uppercased()).font(.dsLabelSBold).foregroundStyle(p.textDim).tracking(0.7)
            .padding(.bottom, 2)
    }

    private func baseRow(_ layer: ChartLayer, _ p: Palette) -> some View {
        let selected = model.chartLayer == layer
        return Button { model.chartLayer = layer } label: {
            HStack(spacing: 9) {
                Image(systemName: Self.icon(layer)).frame(width: 20)
                    .foregroundStyle(selected ? p.accent : p.textDim)
                Text(layer.title).font(.callout).foregroundStyle(p.text)
                Spacer(minLength: 4)
                if selected { Image(systemName: "checkmark").font(.dsLabelBold).foregroundStyle(p.accent) }
            }
            .padding(.vertical, 7).padding(.horizontal, 8).contentShape(Rectangle())
            .background(selected ? p.accent.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: DS.Radius.r2))
        }
        .buttonStyle(.plainHaptic)
        .accessibilityIdentifier("base-\(layer.rawValue)")
    }

    private func layerToggle(_ b: Binding<Bool>, _ title: String, _ icon: String, _ p: Palette, id: String) -> some View {
        Toggle(isOn: b) { Label(title, systemImage: icon).font(.callout).foregroundStyle(p.text) }
            .toggleStyle(.switch).tint(p.accent)
            .accessibilityIdentifier(id)
    }

    static func icon(_ l: ChartLayer) -> String {
        switch l {
        case .sectional: return "map"
        case .ifrLow:    return "arrow.down.right.circle"
        case .ifrHigh:   return "arrow.up.right.circle"
        case .satellite: return "globe.americas.fill"
        case .smartDark: return "moon.stars.fill"
        }
    }
}
