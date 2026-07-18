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
        scenePhase != .background && !model.showRouteMap
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
        .onReceive(model.deviceLocation.$coord) { deviceCoord = $0 }
        .onReceive(model.deviceLocation.$courseDeg) { deviceCourse = $0 }
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
                    let x = min(max(a.tr.x - 24, 36), geo.size.width - 36)
                    let y = min(max(a.tr.y + 24, 130), geo.size.height - 96)   // clear top bars + bottom tab bar
                    PlateCornerSettingsButton(opacity: s.opacity)
                        .environmentObject(model)
                        .position(x: x, y: y)
                }
            }
        }
        .overlay(alignment: .top) { chartStatusPill }
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
            })
    }
    #endif

    /// A small status pill when the FAA chart can't draw yet (download in progress / failed / zoomed out),
    /// so a slow or absent pack reads as an ACTIONABLE state instead of a silent blank (the build-63 IFR-low
    /// confusion). Engine-agnostic — `store.phase` is set by ChartStore regardless of MapLibre vs MKMapView.
    @ViewBuilder private var chartStatusPill: some View {
        if live {
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
        .padding(.top, 150)   // clear the top chrome (TopBar + input/flight-plan strips)
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
