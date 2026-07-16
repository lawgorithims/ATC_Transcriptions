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
        // The plate-adjust control bar floats at the bottom while a plate is superimposed (both layouts).
        .overlay(alignment: .bottom) {
            if let s = model.plateOverlay {
                PlateControlBar(state: s, palette: model.palette)
                    .environmentObject(model)
                    .padding(.horizontal, 12).padding(.bottom, 10)
                    .frame(maxWidth: 520)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.plateOverlay?.name)
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
