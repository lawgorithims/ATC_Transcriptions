import SwiftUI

/// The top-bar map icon — opens a two-column panel: Column A picks the base chart layer, Column B toggles
/// the overlays + map controls. Replaces the old single-column dropdown (which had grown cluttered). All
/// state is persisted on `AppModel` (+ the zoom-controls @AppStorage), so this panel and the always-on home
/// map stay in sync.
struct MapLayersMenu: View {
    @EnvironmentObject var model: AppModel
    var iconSize: CGFloat = 19
    @State private var show = false
    /// ⚠️ READ HERE, IN THE TOP BAR, AND HANDED TO THE PANEL — because this is the app window's own
    /// environment and the panel's is not. A popover is sized to its content and gets a size class to
    /// match, so an iPad popover reads back `.compact`; measured on an iPad Pro 13-inch, a first cut
    /// of the compact layout that asked from inside the panel collapsed it to one 316pt column on a
    /// 1,032pt window. `AppModel.isCompactWindow` records the same answer for callers with no view in
    /// the window, and its doc note has the sheet version of this trap.
    @Environment(\.horizontalSizeClass) private var hSize

    var body: some View {
        Button { show = true } label: {
            Image(systemName: "square.3.layers.3d")
                .font(.system(size: iconSize))
                .frame(width: 30, height: 30)
        }
        .accessibilityIdentifier("map-layers-menu")
        .accessibilityLabel("Map layers")
        .popover(isPresented: $show) {
            MapLayersPanel(compact: hSize == .compact).environmentObject(model)
        }
    }
}

/// The layers/overlays panel: two columns (Base map | Overlays & controls) where there is room for
/// two, one scrolling column on a phone, which there never was.
struct MapLayersPanel: View {
    /// Whether the app WINDOW is compact-width. Deliberately a parameter and not an environment
    /// read: see the note at `MapLayersMenu.hSize` — inside the popover the answer is wrong.
    let compact: Bool
    @EnvironmentObject var model: AppModel
    @AppStorage("atc.map.zoomControls") private var showZoomControls = true
    /// Observed so the "Clear rulers" row appears and counts correctly without reopening the menu.
    @ObservedObject private var rulerStore = MapRulerStore.shared

    // ⚠️ THE TWO-COLUMN PANEL IS WIDER THAN AN iPHONE, AND HAD BEEN SINCE IT WAS WRITTEN. 190 + 258
    // plus the divider, the two 14pt gutters and 16pt of padding each side comes to about 510pt of
    // content; an iPhone 17 Pro window is 402pt and an iPhone SE 375pt. A popover cannot shrink
    // below its content's minimum and does not scroll sideways, so on a phone the panel was clipped
    // at BOTH edges — "IFR sectional" read "FR sectional", and every overlay switch, which sits at
    // the right edge of its row, was sliced in half with its centre off the screen. A pilot could
    // see the switches and could not reliably work them, and nothing on the panel said why.
    //
    // `DataActivityPanel` carries the same note after the same mistake in the same place: the
    // MINIMUM is the one dimension that must be sized for the smallest screen, not for the device
    // the panel was designed on. Two columns of real content cannot be made to fit 375pt, so at
    // compact width they become one.
    private static let baseColumnWidth: CGFloat = 190
    private static let overlayColumnWidth: CGFloat = 258
    /// The single compact column. 284 + 32pt of padding is 316pt, which clears the narrowest iPhone
    /// by 59pt — margin the popover spends on its own shadow and arrow, and the reason the switches
    /// are hittable rather than merely visible.
    private static let compactColumnWidth: CGFloat = 284
    /// Narrowest window the compact layout is sized for (iPhone SE / mini). Not a device check — it
    /// is only here so `panelWidth` can assert that what it returns actually fits.
    private static let narrowestPhoneWidth: CGFloat = 375

    var body: some View {
        let p = model.palette
        columns(p)
            .padding(16)
            // ⚠️ THIS CAP IS WHAT DECIDES HOW MUCH OF THE OVERLAY LIST A PILOT CAN SEE AT ONCE, and it is
            // set to "as much of it as the device will give" rather than to a number someone liked.
            // Measured on a 13-inch iPad (1,376 pt of height) with the default layers on, the overlays
            // column is about 2,000 pt tall — every live layer carries an explanatory note while it is
            // ON — so it ALWAYS scrolls, and the only question this cap settles is how much of it a
            // pilot reaches without scrolling. There is no scroll affordance on the clipped edge, so
            // whatever falls past it looks like the end of the list rather than the middle of it.
            //
            // That has now broken two UI tests, and each break was a pilot-facing fact first. At 460 the
            // list appeared to end at Thunderstorm alert, hiding Winds aloft, Route-out-of-glide,
            // Where-not-to-go, the LZ rows, declutter and the map buttons (`WindOverlayUITests`, which
            // flips `layer-wind`). At 860, four lines added to the thunderstorm note were enough to push
            // Where-not-to-go off the bottom — and XCUITest's coordinate tap on a row below the fold is
            // silently DROPPED, which in the log reads exactly like a dead binding (`AvoidLayerUITests`).
            // Hence 1,100, which still clears the tab bar on the tallest iPad; every smaller device is
            // clamped to its own available space by the system.
            //
            // A row is not safe merely because it fits today. The real fix is fewer words on this panel.
            .frame(minWidth: Self.panelWidth(compact: compact), minHeight: 300, maxHeight: 1_100)
            .background(p.bg)
            .presentationCompactAdaptation(.popover)
    }

    /// The popover's minimum width for a size class, and the proof that it fits the screen.
    ///
    /// Rule 7: the caller is a layout that cannot fail visibly, so the bounds are asserted here where
    /// a debug build will stop on them, rather than discovered on a phone by a pilot.
    private static func panelWidth(compact: Bool) -> CGFloat {
        let padding: CGFloat = 32                      // .padding(16) on both sides
        let w = compact ? compactColumnWidth + padding : baseColumnWidth + overlayColumnWidth + padding
        assert(w > 0, "panelWidth: degenerate panel width")
        assert(!compact || w <= narrowestPhoneWidth,
               "panelWidth: the compact panel is \(w)pt and would be clipped on a \(narrowestPhoneWidth)pt phone")
        return w
    }

    /// The same two sections in both arrangements. The compact one stacks them in ONE scroll view
    /// because two columns of this content do not fit a phone; see the note on the column widths.
    @ViewBuilder private func columns(_ p: Palette) -> some View {
        if compact {
            ScrollView {
                VStack(alignment: .leading, spacing: 11) {
                    baseSection(p)
                    Divider().padding(.vertical, 2)
                    overlaySection(p)
                }
                .padding(.trailing, 2)
            }
            .frame(width: Self.compactColumnWidth)
        } else {
            HStack(alignment: .top, spacing: 14) {
                // COLUMN A — base map (single selection).
                VStack(alignment: .leading, spacing: 0) {
                    baseSection(p)
                    Spacer(minLength: 0)
                }
                .frame(width: Self.baseColumnWidth)

                Divider()

                // COLUMN B — overlays + controls (toggles).
                ScrollView {
                    overlaySection(p)
                        .padding(.trailing, 2)
                }
                .frame(width: Self.overlayColumnWidth)
            }
        }
    }

    /// Base map — single selection.
    private func baseSection(_ p: Palette) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            header("Base map", p)
            ForEach(ChartLayer.allCases) { layer in baseRow(layer, p) }
        }
    }

    /// Overlays + map controls — the long half, which scrolls at every width.
    private func overlaySection(_ p: Palette) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            header("Overlays", p)
            // The toggles below stay live in Dark mode — they still control airports, traffic,
            // weather and TFRs — but the mode overrides TWO of them downward (airways, and the
            // off-route navaids/fixes half of Nearby; airspace was deliberately taken back out of
            // that set). Saying so beats disabling the rows, which would look like the pilot's
            // saved preferences were lost.
            if model.chartLayer == .smartDark {
                Text("Dark (minimal) hides airways and off-route navaids. Airspace, TFRs, traffic, weather, your route and any plate on the map all stay on.")
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
            layerToggle($model.convectiveAlertsEnabled, "Thunderstorm alert",
                        "cloud.bolt.rain", p, id: "layer-convective")
            if model.convectiveAlertsEnabled {
                // ⚠️ THIS NOTE GOT SHORTER WHEN THE MAP LAYER WAS ADDED, NOT LONGER, AND THAT
                // WAS DELIBERATE. Every live layer in this panel carries prose like this, the
                // column already runs to about two and a half screenfuls on a 13-inch iPad, and
                // the last four lines added here pushed a row below the fold where XCUITest's
                // taps on it were silently dropped. The parenthetical about where the wind comes
                // from and the full product names paid for the new clause: a pilot reading this
                // needs to know what the layer does and draws, not which model the fetch uses.
                Text("Warns when your track will enter a thunderstorm, or pass within "
                     + "\(Int(ConvectiveAlert.avoidNm)) NM of one, allowing for its tops, its "
                     + "movement and how old the report is. Overflying is quiet only once you "
                     + "clear the top by the AIM margin: 1,000 ft per 10 kt of wind up there, "
                     + "never under "
                     + "\(Int(ConvectiveAlert.overflightClearanceFt / 1_000)),000 ft. Outlines "
                     + "each cell on the map with its tops and heading. Reads Convective "
                     + "SIGMETs, CWAs and NWS warnings.")
                    .font(.dsLabelS).foregroundStyle(p.textDim)
                    .padding(.leading, 30)
                    .accessibilityIdentifier("layers-convective-note")
            }
            // The other half of the storm alert, and the half that finds what nobody reported.
            layerToggle($model.radarStormCellsEnabled, "Storm alert from radar echo tops",
                        "antenna.radiowaves.left.and.right", p, id: "layer-radarcells")
            if model.radarStormCellsEnabled {
                Text("Finds thunderstorms that carry no bulletin at all, by measuring how high "
                     + "the radar echo reaches (NOAA MRMS). Gives a measured top per cell "
                     + "instead of one figure for a whole area. Costs about 360 KB each refresh "
                     + "— roughly 4 MB an hour — and needs your position to know where to look.")
                    .font(.dsLabelS).foregroundStyle(p.textDim)
                    .padding(.leading, 30)
                    .accessibilityIdentifier("layers-radarcells-note")
            }
            layerToggle($model.showWindAloft, "Winds aloft (animated)", "wind", p, id: "layer-wind")
            // Striped stretches of the FILED route with no runway in glide at the filed
            // altitude — the map half of the flight-plan strip's OUT OF GLIDE cell.
            layerToggle($model.showRouteGlideGaps, "Route out of glide of any runway",
                        "exclamationmark.triangle", p, id: "layer-glide-gaps")

            // The national "where not to go" map. For every pilot: it never names a place to
            // land, which is the line the off-field landability layer crossed.
            layerToggle($model.showAvoidMap, "Where not to go", "nosign", p, id: "layer-avoid")
            if model.showAvoidMap {
                layerToggle($model.showAvoidCover, "Also shade trees, water and built-up areas",
                            "square.dashed", p, id: "layer-avoid-cover")
                AvoidLegend(palette: p, theme: model.theme, showCover: model.showAvoidCover)
                if !model.useMapLibreMap {
                    Text("Draws only on the new GPU map — Settings › Map engine.")
                        .font(.dsLabelS).foregroundStyle(p.warn)
                        .padding(.leading, 30)
                        .accessibilityIdentifier("layers-avoid-engine")
                }
            }

            // Off-field landability — DEVELOPER-ONLY AGAIN as of build 110. It was un-gated
            // once packs became downloadable; the first ground-truth test then found it
            // offering solar farms and orchards as landing candidates and ranking town edges
            // above farmland (see `AppModel.showLZRisk`). The glide-energy bands are the half
            // the evidence supports, and they stay here for every pilot.
            Group {
                if model.offFieldLayerAvailable {
                    layerToggle($model.showLZRisk, "Off-field landability (developer)",
                                "square.grid.3x3.square", p, id: "layer-lz")
                }
                layerToggle($model.showLZEnergy, "Glide energy bands",
                            "scope", p, id: "layer-lz-energy")
                Text("ADVISORY ONLY — how far a glide reaches over terrain from where you are "
                     + "now. It is not a landing recommendation, and wind, turns and a "
                     + "windmilling propeller all shorten a real glide.")
                    .font(.dsLabelS).foregroundStyle(p.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("layers-lz-note")
                if model.offFieldLayerAvailable {
                    Text("Landability shading is a developer preview: it is built from 30 m "
                         + "land cover and cannot see wires, fences, ditches, orchards or solar "
                         + "farms. Absence of a depicted hazard is not evidence none is there.")
                        .font(.dsLabelS).foregroundStyle(p.warn)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("layers-lz-dev-note")
                }
                // Opens the ranked list. DELIBERATELY NOT on the emergency button: that
                // already raises NRST, and a runway beats a field every time.
                if model.lzRiskVisible {
                    Button {
                        Haptics.impact(.light)
                        model.widgetStore.reveal(.landable)
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "list.number").font(.dsLabelS)
                            Text("Show reachable ground, ranked").font(.dsLabel)
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(p.accent)
                    }
                    .buttonStyle(.plainHaptic)
                    .accessibilityIdentifier("layer-lz-list")
                }
                // Which packs answered, or why none did — only where the shading can draw.
                if model.lzRiskVisible, !model.lzPackStatus.isEmpty {
                    Text("Landability data: \(model.lzPackStatus)")
                        .font(.dsLabelS).foregroundStyle(p.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("layers-lz-status")
                }
                // The energy layer's own honesty line: whether wind was applied, whether
                // terrain coverage was lost, whose glide ratio, and how far it reaches — or
                // WHY there is no footprint. A live layer that silently draws nothing is
                // indistinguishable from a broken one.
                if model.showLZEnergy, !model.lzEnergyStatus.isEmpty {
                    Text("Glide energy: \(model.lzEnergyStatus)")
                        .font(.dsLabelS).foregroundStyle(p.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("layers-lz-energy-status")
                }
            }

            Divider().padding(.vertical, 2)

            header("Declutter", p)
            layerToggle($model.declutter, "Hide airways & off-route navaids",
                        "eye.slash", p, id: "layer-declutter")
            // Say what it can and cannot do. On the FAA raster charts the fixes, V-routes and VOR
            // roses are PRINTED INTO the chart image, so hiding the app's own copy of them leaves
            // the printed original and the map looks much the same — that is a property of the
            // charts, not a failure of the switch, and a pilot who is not told will read it as
            // broken. It does the whole job on Satellite, which has no printed chart under it.
            Text(model.chartLayer == .smartDark
                 ? "Already on: Dark (minimal) hides these regardless."
                 : (model.chartLayer.isRaster
                    ? "Little effect on FAA charts — their fixes and airways are printed into the chart itself. Full effect on Satellite and Dark."
                    : "Nothing else is hidden: airspace, TFRs, traffic, weather, terrain and your route all stay."))
                .font(.dsLabelS).foregroundStyle(p.textDim)
                .accessibilityIdentifier("layers-declutter-note")

            Button {
                Haptics.impact(.light)
                model.resetMapView()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "arrow.counterclockwise").font(.dsLabelS)
                    Text("Reset view").font(.dsLabel)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(p.accent)
            }
            .buttonStyle(.plainHaptic)
            .accessibilityIdentifier("layer-reset")
            Text("Clears declutter and re-centres on you. Your layer choices are left alone — "
                 + "the defaults are not your set, so restoring them would flip layers you chose.")
                .font(.dsLabelS).foregroundStyle(p.textDim)

            Divider().padding(.vertical, 2)

            header("Map controls", p)
            layerToggle($showZoomControls, "Map buttons (zoom, north, center)", "plus.magnifyingglass", p, id: "layer-zoom-controls")

            // THE RULER'S ONLY DISCOVERABLE SURFACE. Everything about rulers is a gesture, so
            // without this the feature is invisible to anyone not told about it, and a pilot
            // who laid one down by accident has no way to find out how to get rid of it. The
            // row states the gestures and offers the escape hatch; it is not a mode switch —
            // there is no mode, which is the point.
            Text("Ruler — tap with two fingers to measure between them: distance, time and "
                 + "bearing. Two fingers on a ruler move or resize it, and letting go freezes "
                 + "it. Double-tap the chart to clear them all.")
                .font(.dsLabelS).foregroundStyle(p.textDim)
                .fixedSize(horizontal: false, vertical: true)
            if !rulerStore.isEmpty {
                Button {
                    Haptics.impact(.light)
                    rulerStore.clear()
                } label: {
                    Label("Clear \(rulerStore.rulers.count) ruler\(rulerStore.rulers.count == 1 ? "" : "s")",
                          systemImage: "ruler")
                        .font(.callout).foregroundStyle(p.accent)
                }
                .accessibilityIdentifier("layer-clear-rulers")
            }

            // Wind sprite appearance — only worth showing while the layer is actually up.
            if model.showWindAloft {
                Divider().padding(.vertical, 2)
                header("Wind sprites", p)
                Picker("Colour", selection: $model.windPalette) {
                    ForEach(WindRamp.Palette.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu).tint(p.accent)
                .accessibilityIdentifier("wind-palette-picker")
                Text("Automatic uses speed colours (blue→violet), or red-only at night and on the Dark base. A fixed colour trades that for contrast: speed then rides brightness.")
                    .font(.dsLabelS).foregroundStyle(p.textDim)
                HStack(spacing: 9) {
                    Image(systemName: "smallcircle.filled.circle").font(.dsLabel).foregroundStyle(p.textDim)
                    Slider(value: $model.windSizeScale, in: 0.5...3.0)
                        .tint(p.accent)
                        .accessibilityIdentifier("wind-size-slider")
                        .accessibilityLabel("Wind sprite size")
                    Image(systemName: "circle.circle.fill").font(.dsLabel).foregroundStyle(p.textDim)
                }
                HStack(spacing: 9) {
                    Image(systemName: "circle.lefthalf.filled").font(.dsLabel).foregroundStyle(p.textDim)
                    Slider(value: $model.windOpacityScale, in: 0.6...1.8)
                        .tint(p.accent)
                        .accessibilityIdentifier("wind-contrast-slider")
                        .accessibilityLabel("Wind sprite contrast")
                    Image(systemName: "circle.fill").font(.dsLabel).foregroundStyle(p.textDim)
                }
                Text("Size and contrast. The overlay is deliberately translucent so the chart reads through it — turn contrast up only as far as the airway and airspace labels underneath stay legible.")
                    .font(.dsLabelS).foregroundStyle(p.textDim)
            }

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
