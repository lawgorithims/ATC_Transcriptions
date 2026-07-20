import SwiftUI
import MapKit

/// The always-present home-screen map background. Lifts the map-owning half of `RouteMapSheet`: it draws
/// the filed route + FAA/Apple base layer + airspace/nearby/traffic via `ChartMapView`, resolves the
/// route with `RouteResolver`, and routes taps to `widgets.mapProbe` (which drives the object side panel /
/// sheet — a sibling in `ConsoleView`'s ZStack). Layer + overlay choices come from persisted `AppModel`
/// state so the top-bar layers menu and this map stay in sync.
///
/// Battery: the live map renders only when enabled + foregrounded + not hidden behind the full-screen
/// route map. It is NEVER torn down for thermal reasons — losing the whole moving map is a dangerous
/// failure mode in the cockpit. Heat is shed gracefully instead (the terrain flattens under
/// `thermalSerious`, and the network map layers pause) while the map itself stays up.
struct MapHostView: View {
    @EnvironmentObject var model: AppModel
    /// Plain reference (NOT observed): the map only WRITES the tapped-object probe here — it must not
    /// re-render / re-reconcile just because a widget's layout changed.
    let widgets: WidgetStore
    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var store = ChartStore(library: ChartLibrary.shared)
    @State private var route: [ResolvedLeg] = []
    /// The overlaid plate's top-corner screen-points (streamed from the map's region callbacks) — the
    /// SwiftUI ✕ / opacity controls are positioned here so they ride the plate itself.
    @State private var plateAnchors: PlateAnchors?
    // Device-GPS ownship, bridged from `model.deviceLocation` (a nested ObservableObject that doesn't
    // republish the parent) so a fix change re-renders the map. Stratux is preferred when connected.
    @State private var deviceCoord: Coord?
    @State private var deviceCourse: Double?
    /// The flight recorder's breadcrumb, bridged from the nested recorder (like deviceCoord). Append-only
    /// during a recording, [] otherwise — the maps guard on its COUNT so it doesn't re-tessellate per tick.
    @State private var breadcrumb: [Coord] = []
    /// The live precipitation-radar tile URL, bridged from RainViewerService — the ONE radar value the map
    /// ENGINES consume. The corner status pill + the loop scrubber observe the service directly (see
    /// `RadarStatusPill` / `RadarLoopBar`), so they don't need per-field @State bridges here.
    @State private var radarTemplate: String?

    struct PlateAnchors: Equatable { var tl: CGPoint; var tr: CGPoint }

    /// Show the live map unless it's genuinely pointless: only paused when truly backgrounded (a transient
    /// `.inactive`, e.g. a permission alert, must NOT blank it) or when the full-screen route map is
    /// covering it (no point running two MKMapViews at once). NOT gated on thermal — the map must never
    /// disappear on the pilot; heat is handled by flattening terrain + pausing network layers instead.
    ///
    /// The map is NEVER blanked by the "Live map background" toggle. With the toggle off (the battery
    /// default) an FAA raster simply REPLACES the Apple base within its coverage (MBTilesTileOverlay:
    /// canReplaceMapContent + a `reader.bounds` boundingMapRect so the fringe never goes blank); an
    /// Apple-only layer (Map/Satellite) has no raster and just renders the base. Either way the pilot
    /// always has a moving map — the toggle only chooses whether the Apple base draws UNDER the chart.
    private var live: Bool {
        // Render the map ONLY when it's the front tab. It's kept MOUNTED behind the ZStack, but a live
        // MKMapView / MapLibre map burns CPU/GPU even at opacity 0 behind another tab (the real-flight
        // battery data showed ~0.6 core still spent on the transcript tab). GPS + the flight recorder run
        // independently (started once in onAppear, read directly), so pausing the render doesn't stop them;
        // the camera restores from lastMapCamera on return. Still never gated on THERMAL — heat is handled
        // by flattening terrain, not by blanking the map on the pilot.
        scenePhase != .background && !model.showRouteMap && model.selectedTab == .map
    }

    var body: some View {
        Group {
            if live {
                mapContent
            } else {
                // Not live only when backgrounded or the full-screen route map is covering us — both
                // transient, nothing to show. (The map is never intentionally blanked anymore.)
                model.palette.bg
            }
        }
        .ignoresSafeArea()
        // Own GPS session for the map's ownship marker (replaces MKMapView's built-in showsUserLocation
        // GPS). Bridged into @State so a fix change re-renders → updateUIView moves the marker. GPS is
        // paused in the background by AppModel.handleScenePhase (battery).
        .onAppear { model.deviceLocation.start() }
        .onReceive(model.deviceLocation.$coord) { c in
            deviceCoord = c
            if let c { model.rainViewer.prefetchCenter = (c.lat, c.lon) }   // aim the radar-loop prefetch nearby
        }
        .onReceive(model.deviceLocation.$courseDeg) { deviceCourse = $0 }
        .onReceive(model.flightRecorder.$trail) { breadcrumb = $0.map { Coord(lat: $0.lat, lon: $0.lon) } }
        .onReceive(model.rainViewer.$tileTemplate) { radarTemplate = $0 }   // feed the map engines the current frame
        // The plate's ✕ / opacity controls ride the PLATE's own top corners (screen-points streamed
        // from the map's region callbacks). SwiftUI-layered — not annotation subviews — so their
        // gestures never fight MapKit's pan recognizer (which cancels UIControl tracking inside
        // annotation views and made a UISlider there feel dead).
        // A single gear button rides the plate's top-right corner; tapping it opens the plate menu (in
        // ConsoleView, dropping from the top). SwiftUI-layered over the map so its tap never fights
        // MapKit's pan recognizer; hidden while the menu is open (the menu carries the controls).
        .overlay {
            // CLAMP the gear into the viewport: it's the ONLY way to reach the plate menu (dim / invert /
            // hide / remove), so if the plate's top-right corner pans or zooms off-screen the gear must
            // still be tappable — it pins to the nearest edge instead of vanishing. Gated on `live` so it
            // isn't stranded over a blank background at stale anchor coords when the map is off.
            if live, let s = model.plateOverlay, let a = plateAnchors, !model.showPlateMenu {
                GeometryReader { geo in
                    // Pin the gear to the plate's EXACT top-right corner (center tucked just inside by a
                    // half-button) and track it 1:1 as the plate pans/zooms. Clamp INSIDE the map chrome —
                    // NOT the physical screen edge — because the gear is the ONLY way to reach the plate
                    // menu: it must never slide under the opaque TopBar/strips (top) or the GPS + tab bar
                    // (bottom), where it would be un-tappable. Within that band it sits exactly on the corner.
                    let m: CGFloat = 18
                    let x = min(max(a.tr.x - m, 40), geo.size.width - 40)
                    let bottomChrome = model.showGPSBar ? 150.0 : 96.0        // GPS bar (when shown) + tab bar
                    let y = min(max(a.tr.y + m, 132), geo.size.height - bottomChrome)   // 132: clear TopBar + strips
                    PlateCornerSettingsButton(opacity: s.opacity)
                        .environmentObject(model)
                        .position(x: x, y: y)
                }
            }
        }
        .overlay(alignment: .top) { statusPills }
        .overlay(alignment: .topTrailing) {
            if live {
                RadarStatusPill(rainViewer: model.rainViewer, widgets: widgets,
                                show: model.showWxRadar, thermalWarm: model.thermalSerious, palette: model.palette)
            }
        }
        .overlay(alignment: .bottom) {
            if live {
                RadarLoopBar(rainViewer: model.rainViewer, widgets: widgets,
                             show: model.showWxRadar, gpsBar: model.showGPSBar, palette: model.palette)
            }
        }
        .task { await buildRoute() }
        .onChange(of: model.flightPlan) { _, _ in Task { await buildRoute() } }      // edits redraw the route
        .onChange(of: model.chartLayer) { _, new in
            Task { await store.setLayer(new, routeRects: ChartGeo.routeRects(route)) }
        }
    }

    /// The map engine: MapLibre (GPU chart, the default) or the classic MKMapView chart. Both slot into the
    /// same chrome — every top-bar/menu/widget interaction reaches the map only via `model` + `widgets.mapProbe`.
    @ViewBuilder private var mapContent: some View {
        #if canImport(MapLibre)
        if model.useMapLibreMap && !model.mapLibreRenderFailed { mapLibreMap } else { chartMapView }
        #else
        chartMapView
        #endif
    }

    private var chartMapView: some View {
        ChartMapView(layer: model.chartLayer, readers: store.readers, route: route,
                     procedure: model.previewedProcedureLegs,   // resolved once off-main in AppModel (L8)
                     breadcrumb: breadcrumb,                     // flight-recorder trail
                     radarTemplate: radarTemplate,               // live precipitation radar
                     showAirspace: model.showAirspace, showNearby: model.showNearby,
                     showAirways: model.showAirways,
                     initialCenter: model.stratuxGPS?.coordinate ?? deviceCoord,
                     ownship: model.stratuxGPS?.coordinate ?? deviceCoord,
                     ownshipCourse: model.stratuxGPS?.coordinate == nil ? deviceCourse : nil,
                     onVisibleRegion: { rect in
                         // Remember where the user settled so a thermal rebuild restores it (M7);
                         // the settle hook is already debounced (0.4 s) in the coordinator.
                         model.lastMapCamera = SavedMapCamera(rect: rect, now: Date())
                         Task { await store.ensureVisible(rect, layer: model.chartLayer) }
                     },
                     onTapObjects: { objs in
                         guard !objs.isEmpty else { return }
                         Haptics.impact(.light)
                         widgets.mapProbe = MapProbeResult(id: UUID().uuidString, objects: objs)
                     },
                     focus: model.mapFocus,
                     restoreCamera: model.lastMapCamera,
                     plateOverlay: model.plateOverlay,
                     onPlateAnchors: { pts in
                         let mapped = pts.map { PlateAnchors(tl: $0.0, tr: $0.1) }
                         Task { @MainActor in
                             if plateAnchors != mapped { plateAnchors = mapped }
                         }
                     },
                     model: model)
    }

    #if canImport(MapLibre)
    /// The MapLibre GPU map fed from the SAME MapHostView state as ChartMapView. Taps route to
    /// `widgets.mapProbe` (NOT a private sheet), so the existing object-card / side-panel flow keeps working.
    /// The single-GPS-owner ownship invariant is preserved: this reuses the shared deviceCoord/deviceCourse
    /// (started + bridged once in body's onAppear/onReceive), and MapLibre draws its own ownship (no
    /// MLNMapView user-location dot / second CLLocationManager).
    private var mapLibreMap: some View {
        MapLibreChartView(
            store: store,
            layer: model.chartLayer,
            routeCoords: route.map { CLLocationCoordinate2D(latitude: $0.coord.lat, longitude: $0.coord.lon) },
            breadcrumbCoords: breadcrumb.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) },
            radarTemplate: radarTemplate,
            ownship: (model.stratuxGPS?.coordinate ?? deviceCoord).map {
                CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)
            },
            ownshipCourse: model.stratuxGPS?.coordinate == nil ? deviceCourse : nil,
            traffic: model.aircraft,
            tfrs: model.tfrs,
            showTFRs: model.showTFRs,
            showAirspace: model.showAirspace,
            showNearby: model.showNearby,
            showAirways: model.showAirways,
            plateOverlay: model.plateOverlay,
            routeIdents: Set(route.map { $0.ident }),
            initialCenter: model.stratuxGPS?.coordinate ?? deviceCoord,
            focus: model.mapFocus,
            restoreCamera: model.lastMapCamera,
            onTapObjects: { objs in
                guard !objs.isEmpty else { return }
                Haptics.impact(.light)
                widgets.mapProbe = MapProbeResult(id: UUID().uuidString, objects: objs)
            },
            onPlateAnchors: { pts in
                let mapped = pts.map { PlateAnchors(tl: $0.0, tr: $0.1) }
                Task { @MainActor in
                    if plateAnchors != mapped { plateAnchors = mapped }
                }
            },
            onRenderStalled: {
                // The MapLibre map produced no frames (MLNMapView blank-until-scene-refresh) — fall back to the
                // classic map for this session so the pilot always has a working chart.
                Task { @MainActor in model.mapLibreRenderFailed = true }
            },
            onVisibleRegion: { rect in
                // Persist the pilot's pan/zoom so a background→foreground remount restores it, and so the
                // classic-map fallback lands on the same view (M7 camera contract — parity with ChartMapView).
                model.lastMapCamera = SavedMapCamera(rect: rect, now: Date())
            },
            renderMeter: model.renderMeter)   // battery diagnostics: per-frame counter → map fps
    }
    #endif

    /// The stacked map-status pills (chart / traffic / radar), so a slow or absent feed reads as an
    /// ACTIONABLE state instead of a silent blank — "no planes drawn" must be distinguishable between
    /// "still loading", "feed down", and "genuinely no aircraft nearby" (the pilot's explicit ask).
    @ViewBuilder private var statusPills: some View {
        if live {
            VStack(spacing: 6) {
                chartStatusPill
                trafficStatusPill
            }
            .padding(.top, 150)   // clear the top chrome (TopBar + input/flight-plan strips)
        }
    }

    /// Chart download state — engine-agnostic (`store.phase` is set by ChartStore for both engines).
    @ViewBuilder private var chartStatusPill: some View {
        switch store.phase {
        case .loadingCatalog: statusPill("Loading chart index…", "arrow.down.circle", spin: true)
        case .downloading:    statusPill("Loading charts for this area…", "arrow.down.circle", spin: true)
        case .zoomOut where model.chartLayer.isRaster:
            statusPill("Zoom in to load the chart here", "plus.magnifyingglass")
        case .empty where model.chartLayer.isRaster:
            statusPill(route.isEmpty ? "Pan and zoom in to load charts" : "No \(model.chartLayer.title) charts here", "map")
        case .failed:
            statusPill("Chart download failed — tap to retry", "wifi.exclamationmark")
                .onTapGesture { Task { await store.setLayer(model.chartLayer, routeRects: ChartGeo.routeRects(route)) } }
        default: EmptyView()
        }
    }

    /// Online ADS-B traffic state. Hidden while the Stratux link provides traffic (its own widget shows
    /// status) and once aircraft are actually drawn (the planes are their own evidence).
    @ViewBuilder private var trafficStatusPill: some View {
        if model.adsbStreamingEnabled, !model.stratuxEnabled {
            if case .error = model.adsbStatus {
                statusPill("Traffic unavailable — check connection", "wifi.exclamationmark")
            } else if model.aircraftUpdatedAt == nil {
                if model.presentPosition == nil && model.airport.isEmpty {
                    statusPill("Traffic is waiting for a GPS fix…", "location.slash")
                } else {
                    statusPill("Loading traffic…", "airplane", spin: true)
                }
            } else if model.aircraft.isEmpty {
                statusPill("Traffic live — no aircraft nearby", "airplane")
            }
        }
    }

    private func statusPill(_ text: String, _ icon: String, spin: Bool = false) -> some View {
        HStack(spacing: 8) {
            if spin { ProgressView().controlSize(.small) } else { Image(systemName: icon) }
            Text(text).font(.caption.weight(.medium))
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .foregroundStyle(.primary)
        .shadow(radius: 4)
    }

    private func buildRoute() async {
        // Warm the nav tables off-main so the map's first paint never blocks on a decode — NavMeta too,
        // now that the FAA nav-symbol glyph picks the VOR/VORTAC/NDB shape from NavMeta.navaid(ident).
        await Task.detached(priority: .userInitiated) {
            _ = NavDatabase.count; _ = NavDatabase.airspaceCount; _ = NavMeta.navaidCount
        }.value
        // Draw the full path INCLUDING any loaded SID / STAR / approach (their coded legs), not just the
        // filed departure→enroute→destination — see `ProcedureRoute`.
        route = model.flightPlan.map { ProcedureRoute.resolve($0) } ?? []
        await store.setLayer(model.chartLayer, routeRects: ChartGeo.routeRects(route))
    }
}

/// The weather-radar STATUS chip, pinned to the map's top-trailing CORNER (out of the way of the
/// center-top chart/traffic pills). Shows a buffering %, or the loading / unavailable / paused-when-warm
/// states — and hides once the radar is live + buffered (the loop bar is then the persistent indicator).
/// Shifts inward when a widget is docked as a right side-pane so it's never hidden behind it.
private struct RadarStatusPill: View {
    @ObservedObject var rainViewer: RainViewerService
    @ObservedObject var widgets: WidgetStore
    let show: Bool
    let thermalWarm: Bool
    let palette: Palette

    var body: some View {
        Group {
            if show, let content = state {
                HStack(spacing: 8) {
                    if content.spin { ProgressView().controlSize(.small) } else { Image(systemName: content.icon) }
                    Text(content.text).font(.caption.weight(.medium))
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(.ultraThinMaterial, in: Capsule())
                .foregroundStyle(.primary)
                .shadow(radius: 4)
                .padding(.top, 150)                         // clear the top chrome (TopBar + strips)
                .padding(.trailing, trailingInset)          // clear a docked right side-pane
                .accessibilityIdentifier("radar-status-pill")
            }
        }
    }

    /// Trailing inset so the chip clears a right-docked widget pane (approx its stored/default width).
    private var trailingInset: CGFloat {
        guard widgets.rightPane != nil else { return 12 }
        return (widgets.rightPaneWidth > 0 ? widgets.rightPaneWidth : 320) + 12
    }

    private var state: (text: String, icon: String, spin: Bool)? {
        if let prog = rainViewer.bufferProgress {           // buffering the loop → a real %
            return ("Radar loop \(Int((prog * 100).rounded()))%", "cloud.rain", true)
        }
        if rainViewer.tileTemplate == nil {
            if thermalWarm { return ("Radar paused (device warm)", "thermometer.high", false) }
            if rainViewer.failed { return ("Radar unavailable — retrying", "wifi.exclamationmark", false) }
            return ("Loading radar…", "cloud.rain", true)
        }
        return nil                                          // live + buffered → the loop bar is the indicator
    }
}

/// The weather-radar LOOP scrubber — a docked bar above the GPS bar with play/pause, a time-scale slider to
/// jump between frames (past → now → forecast), and the selected frame's time. Replaces the build-72
/// center-bottom play button. Insets horizontally to clear docked side-panes.
private struct RadarLoopBar: View {
    @ObservedObject var rainViewer: RainViewerService
    @ObservedObject var widgets: WidgetStore
    let show: Bool
    let gpsBar: Bool
    let palette: Palette

    var body: some View {
        Group {
            if show, rainViewer.canAnimate {
                let count = rainViewer.frames.count
                let idx = Binding<Double>(
                    get: { Double(min(rainViewer.currentIndex, max(count - 1, 0))) },
                    set: { rainViewer.scrub(to: Int($0.rounded())) })
                HStack(spacing: 12) {
                    Button {
                        Haptics.impact(.light); rainViewer.toggleAnimation()
                    } label: {
                        Image(systemName: rainViewer.animating ? "pause.fill" : "play.fill")
                            .font(.system(size: 16, weight: .bold)).frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plainHaptic)
                    .accessibilityIdentifier("radar-loop-play")

                    VStack(spacing: 1) {
                        Slider(value: idx, in: 0...Double(max(count - 1, 1)), step: 1)
                            .tint(palette.accent)
                            .accessibilityIdentifier("radar-loop-slider")
                        HStack {
                            Text("past").font(.system(size: 9)).foregroundStyle(palette.textDim)
                            Spacer()
                            Text(rainViewer.frameLabel.isEmpty ? "now" : rainViewer.frameLabel)
                                .font(.caption2.weight(.semibold).monospacedDigit()).foregroundStyle(palette.text)
                            Spacer()
                            Text("forecast").font(.system(size: 9)).foregroundStyle(palette.textDim)
                        }
                    }
                    // Jump back to the live "now" frame.
                    Button { Haptics.impact(.light); rainViewer.resetToNow() } label: {
                        Image(systemName: "clock.arrow.circlepath").font(.system(size: 15, weight: .semibold))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plainHaptic)
                    .accessibilityIdentifier("radar-loop-now")
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .foregroundStyle(.primary)
                .shadow(radius: 4)
                .frame(maxWidth: 460)
                .padding(.horizontal, 16)
                .padding(.leading, widgets.leftPane != nil ? paneWidth(widgets.leftPaneWidth) : 0)
                .padding(.trailing, widgets.rightPane != nil ? paneWidth(widgets.rightPaneWidth) : 0)
                // The map .ignoresSafeArea(), so clear the bottom tab bar (~84) + the GPS bar (~56) when shown.
                .padding(.bottom, gpsBar ? 150 : 96)
                .accessibilityIdentifier("radar-loop-bar")
            }
        }
    }

    private func paneWidth(_ stored: CGFloat) -> CGFloat { stored > 0 ? stored : 320 }
}
