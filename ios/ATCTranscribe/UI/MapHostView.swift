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

    struct PlateAnchors: Equatable { var tl: CGPoint; var tr: CGPoint }

    /// Show the live map only when it's worth the power — paused when truly backgrounded (a transient
    /// `.inactive`, e.g. a permission alert, must NOT blank it) or when the full-screen route map is
    /// covering it (no point running two MKMapViews at once). NOT gated on thermal — the map must never
    /// disappear on the pilot; heat is handled by flattening terrain + pausing network layers instead.
    private var live: Bool {
        model.mapBackgroundEnabled && scenePhase != .background && !model.showRouteMap
    }

    var body: some View {
        Group {
            if live {
                ChartMapView(layer: model.chartLayer, readers: store.readers, route: route,
                             procedure: model.previewedProcedureLegs,   // resolved once off-main in AppModel (L8)
                             showAirspace: model.showAirspace, showNearby: model.showNearby,
                             initialCenter: model.stratuxGPS?.coordinate,
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
                                 // Most emissions arrive from inside updateUIView (a view-update
                                 // context) where SwiftUI DISCARDS state writes — defer a tick, and
                                 // only publish real changes so a static map doesn't re-render.
                                 let mapped = pts.map { PlateAnchors(tl: $0.0, tr: $0.1) }
                                 Task { @MainActor in
                                     if plateAnchors != mapped { plateAnchors = mapped }
                                 }
                             },
                             model: model)
            } else if !model.mapBackgroundEnabled {
                // The user's own "map background off" toggle — the only non-transient reason to stand
                // down (backgrounded / route-map-covering just pause rendering with nothing to show).
                model.palette.bg
                    .overlay {
                        VStack(spacing: 6) {
                            Image(systemName: "map").font(.title2).foregroundStyle(model.palette.textDim)
                            Text("Map background off").font(.caption).foregroundStyle(model.palette.textDim)
                        }
                    }
            } else {
                model.palette.bg   // transiently covered (route map / background) — plain, no message
            }
        }
        .ignoresSafeArea()
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
        .task { await buildRoute() }
        .onChange(of: model.flightPlan) { _, _ in Task { await buildRoute() } }      // edits redraw the route
        .onChange(of: model.chartLayer) { _, new in
            Task { await store.setLayer(new, routeRects: ChartGeo.routeRects(route)) }
        }
    }

    private func buildRoute() async {
        await Task.detached(priority: .userInitiated) { _ = NavDatabase.count; _ = NavDatabase.airspaceCount }.value
        // Draw the full path INCLUDING any loaded SID / STAR / approach (their coded legs), not just the
        // filed departure→enroute→destination — see `ProcedureRoute`.
        route = model.flightPlan.map { ProcedureRoute.resolve($0) } ?? []
        await store.setLayer(model.chartLayer, routeRects: ChartGeo.routeRects(route))
    }
}
