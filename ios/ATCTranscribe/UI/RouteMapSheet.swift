import SwiftUI
import MapKit

/// The flight-plan map: the filed route drawn as the classic **magenta line** through its waypoints
/// (departure, VORs, RNAV fixes, destination — resolved by `RouteResolver` against the bundled nav DB +
/// `AirportCoordinates`) over a **selectable base layer** — the self-hosted FAA **VFR sectional** /
/// **IFR-low** raster charts (cached offline) or Apple's standard/satellite map — plus Class B/C/D
/// **airspace** outlines and nearby navaids/airports (bundled DB), **live ADS-B traffic**, and the
/// Stratux **ownship**. The raster packs the route crosses load up front and more as you pan/zoom (each
/// cached for offline via `ChartLibrary`); the layer choice is remembered across opens. Built on
/// `MKMapView` via `ChartMapView` (SwiftUI's `Map` can't host chart tiles). Reads existing state only —
/// no capture/pipeline/traffic changes.
struct RouteMapSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    // The per-sheet display store reads packs from the app-lifetime shared cache (`ChartLibrary.shared`),
    // which is warmed + prefetched at launch — so opening the map does no network round-trip in the
    // common case.
    @StateObject private var store = ChartStore(library: ChartLibrary.shared)
    @State private var route: [ResolvedLeg] = []
    @State private var unresolved: [String] = []
    @State private var totalNM: Double = 0
    // Seed from the remembered layer (or a `--chart-layer` launch override) so the map opens on the
    // user's last-used chart; `.onChange` writes any switch back to `model.chartLayer`.
    @State private var layer: ChartLayer = ChartLayer.launchOverride ?? AppModel.savedChartLayer
    @State private var showAirspace = true
    @State private var showNearby = true
    @State private var showRouteInfo = false
    @State private var loading = true
    @State private var probe: MapProbeResult?     // objects under the last tap → info/actions sheet
    @State private var showSearch = false
    @State private var searchSeed = ""            // `--search` screenshot affordance
    @State private var focus: Coord?              // recenter the map on a search result

    private static let routeMagenta = Color(red: 0.92, green: 0.10, blue: 0.55)

    /// Per-leg rects the raster packs are selected against — shared with background prefetch via `ChartGeo`.
    private var routeRects: [MKMapRect] { ChartGeo.routeRects(route) }

    var body: some View {
        let p = model.palette
        NavigationStack {
            ZStack(alignment: .top) {
                ChartMapView(layer: layer, readers: store.readers, route: route,
                             showAirspace: showAirspace, showNearby: showNearby,
                             initialCenter: model.stratuxGPS?.coordinate,
                             onVisibleRegion: { rect in Task { await store.ensureVisible(rect, layer: layer) } },
                             onTapObjects: { objs in
                                 guard !objs.isEmpty else { return }
                                 Haptics.impact(.light)
                                 probe = MapProbeResult(id: UUID().uuidString, objects: objs)
                             },
                             focus: focus,
                             model: model)
                    .ignoresSafeArea(edges: .bottom)
                VStack(spacing: 8) { switcher; statusPill }.padding(.top, 8)
            }
            .overlay(alignment: .center) {
                if loading {
                    ProgressView("Plotting route…")
                        .padding(14).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .safeAreaInset(edge: .bottom) { legend(p) }
            .navigationTitle("Route map")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { Haptics.impact(.light); dismiss() }
                        .accessibilityIdentifier("route-map-done")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { Haptics.impact(.light); showSearch = true } label: { Image(systemName: "magnifyingglass") }
                        .accessibilityIdentifier("route-map-search").accessibilityLabel("Search")
                }
                ToolbarItem(placement: .primaryAction) { layersMenu }
            }
            .sheet(isPresented: $showRouteInfo) { routeInfoSheet }
            .sheet(isPresented: $showSearch) {
                MapSearchSheet(onPick: pickSearchResult, initialQuery: searchSeed).environmentObject(model)
            }
            .sheet(item: $probe) { result in
                MapObjectSheet(result: result, resolved: route, onCommit: { Task { await buildRoute() } })
                    .environmentObject(model)
            }
        }
        .tint(p.accent)
        .task { applyLaunchEdit(); await buildRoute(); presentLaunchProbe(); presentLaunchSearch() }
        .onChange(of: layer) { _, new in
            model.chartLayer = new                                   // remember the last-used layer
            store.phase = new.isRaster ? .downloading : .ready       // honest during the switch; setLayer refines
            Task { await store.setLayer(new, routeRects: routeRects) }
        }
    }

    // MARK: controls

    private var layersMenu: some View {
        Menu {
            Toggle(isOn: $showAirspace) { Label("Airspace & special use", systemImage: "hexagon") }
            Toggle(isOn: $showNearby) { Label("Nearby navaids & airports", systemImage: "mappin.and.ellipse") }
            Toggle(isOn: $model.showTFRs) { Label("TFRs (FAA, live)", systemImage: "exclamationmark.octagon") }
            Divider()
            Button { Haptics.impact(.light); showRouteInfo = true } label: {
                Label("Route details", systemImage: "list.bullet.rectangle")
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .accessibilityIdentifier("route-map-menu")
        .accessibilityLabel("Map layers")
    }

    /// VFR sectional · IFR low · standard map · satellite. FAA layers are raster charts; standard/satellite
    /// are Apple's base map. The choice persists to `model.chartLayer`.
    private var switcher: some View {
        Picker("Layer", selection: $layer) {
            ForEach(ChartLayer.allCases) { Text($0.short).tag($0) }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.thinMaterial, in: Capsule())
        .padding(.horizontal, 20)
        .accessibilityIdentifier("chart-layer-picker")
    }

    @ViewBuilder private var statusPill: some View {
        switch store.phase {
        case .loadingCatalog:
            pill { ProgressView(); Text("Loading chart index…") }
        case .downloading:
            pill { ProgressView(); Text("Loading charts for this area…") }
        case .zoomOut where layer.isRaster:
            pill { Image(systemName: "plus.magnifyingglass"); Text("Zoom in to load the chart here") }
        case .empty where layer.isRaster:
            pill { Image(systemName: "map"); Text(route.isEmpty ? "Pan and zoom in to load charts" : "No \(layer.title) here") }
        case .failed:
            pill { Image(systemName: "wifi.exclamationmark"); Text("Chart download failed — tap to retry") }
                .onTapGesture { Task { await store.setLayer(layer, routeRects: routeRects) } }
        default:
            EmptyView()
        }
    }

    private func pill<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 8) { content() }
            .font(.caption)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.thinMaterial, in: Capsule())
    }

    // MARK: legend

    // Legend swatch colours — delegate to the map's single source of truth so class + special-use +
    // TFR swatches always match what the overlay actually draws (Restricted red, MOA purple, …).
    private static func airspaceColor(_ cls: String) -> Color {
        Color(uiColor: ChartMapView.Coordinator.airspaceColor(cls))
    }

    private func legend(_ p: Palette) -> some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    legendItem(Self.routeMagenta, "Route", line: true)
                    legendItem(.hex(0xE879F9), "Airport")
                    legendItem(.hex(0x34D399), "VOR")
                    legendItem(.hex(0x60A5FA), "Fix")
                    HStack(spacing: 3) {
                        Image(systemName: "airplane").font(.system(size: 10)).foregroundStyle(.orange)
                        Text("Traffic")
                    }
                    if showAirspace {
                        Divider().frame(height: 11)
                        legendItem(Self.airspaceColor("B"), "Class B", line: true)
                        legendItem(Self.airspaceColor("C"), "Class C", line: true)
                        legendItem(Self.airspaceColor("D"), "Class D", line: true)
                        legendItem(Self.airspaceColor("R"), "Restricted", line: true)
                        legendItem(Self.airspaceColor("P"), "Prohibited", line: true)
                        legendItem(Self.airspaceColor("MOA"), "MOA", line: true)
                        legendItem(Self.airspaceColor("W"), "Warning", line: true)
                        legendItem(Self.airspaceColor("A"), "Alert", line: true)
                    }
                    if model.showTFRs {
                        Divider().frame(height: 11)
                        legendItem(Self.airspaceColor("TFR"), "TFR", line: true)
                    }
                }
            }
            Spacer(minLength: 4)
            statusText(p)
        }
        .font(.system(size: 10)).foregroundStyle(p.text).lineLimit(1)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.thinMaterial)
    }

    @ViewBuilder private func statusText(_ p: Palette) -> some View {
        HStack(spacing: 4) {
            if route.count >= 2 {
                Text("\(Int(totalNM.rounded())) nm").bold()
                if !unresolved.isEmpty { Text("· \(unresolved.count) off").foregroundStyle(p.warn) }
            } else if route.isEmpty && !loading {
                Text("No plan filed").foregroundStyle(p.textDim)
            }
        }
        .fixedSize()
    }

    private func legendItem(_ c: Color, _ label: String, line: Bool = false) -> some View {
        HStack(spacing: 3) {
            if line { RoundedRectangle(cornerRadius: 1).fill(c).frame(width: 14, height: 3) }
            else { Circle().fill(c).frame(width: 8, height: 8) }
            Text(label)
        }
    }

    // MARK: route details sheet

    private struct LegInfo: Identifiable {
        let id: Int
        let from: String, to: String
        let nm: Double, bearing: Double
    }

    private var routeInfoSheet: some View {
        NavigationStack {
            List {
                if route.count >= 2 {
                    Section {
                        ForEach(legInfos()) { li in
                            HStack(spacing: 8) {
                                Text(li.from).monospaced()
                                Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                                Text(li.to).monospaced()
                                Spacer()
                                Text("\(Int(li.nm.rounded())) nm").foregroundStyle(.secondary)
                                Text(String(format: "%03.0f°", li.bearing)).monospaced().foregroundStyle(.secondary)
                            }
                            .font(.system(size: 13))
                        }
                    } header: { Text("Legs") }
                    footer: { Text("Great-circle distance and initial true bearing between filed points.") }
                    Section {
                        HStack { Text("Total distance"); Spacer(); Text("\(Int(totalNM.rounded())) nm").bold() }
                    }
                } else {
                    ContentUnavailableView("No route filed", systemImage: "map",
                                           description: Text("File a flight plan to see leg distances and bearings."))
                }
                if !unresolved.isEmpty {
                    Section("Not located") {
                        Text(unresolved.joined(separator: "   "))
                            .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Route details").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showRouteInfo = false }.accessibilityIdentifier("route-info-done")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .tint(model.palette.accent)
    }

    private func legInfos() -> [LegInfo] {
        guard route.count >= 2 else { return [] }
        return (1..<route.count).map { i in
            let a = route[i - 1].coord, b = route[i].coord
            return LegInfo(id: i, from: route[i - 1].ident, to: route[i].ident,
                           nm: Geo.nmBetween(a, b), bearing: Geo.bearing(a, b))
        }
    }

    /// Screenshot/demo affordance: `--probe-add IDENT` adds a waypoint before the map resolves, to
    /// exercise the edit → route-redraw path without a synthetic touch.
    private func applyLaunchEdit() {
        let a = ProcessInfo.processInfo.arguments
        if let i = a.firstIndex(of: "--probe-add"), i + 1 < a.count { model.addToRoute(a[i + 1]) }
    }

    /// Screenshot/demo affordance: `--probe-ident KBOS` opens the tap-to-identify sheet for that ident
    /// (exercises the info sheet without a synthetic touch). Mirrors `--chart-center`/`--open-chart`.
    private func presentLaunchProbe() {
        let a = ProcessInfo.processInfo.arguments
        guard let i = a.firstIndex(of: "--probe-ident"), i + 1 < a.count else { return }
        let id = a[i + 1].uppercased()
        if let c = UserPoint.parse(id) {          // a "lat,lon" token → user-point sheet
            probe = MapProbeResult(id: "launch-up", objects: [IdentifiedObject(kind: .userPoint, ident: id, coord: c, onRoute: false)])
            return
        }
        guard let c = NavDatabase.resolve(id, near: nil) else { return }
        let obj = IdentifiedObject(kind: MapObjectKind(routeKind: RouteLeg.classify(id)),
                                   ident: id, coord: c, onRoute: model.flightPlan?.contains(id) ?? false)
        probe = MapProbeResult(id: "launch-\(id)", objects: [obj])
    }

    /// Screenshot/demo affordance: `--search Boston` opens the search sheet pre-filled with that query.
    private func presentLaunchSearch() {
        let a = ProcessInfo.processInfo.arguments
        guard let i = a.firstIndex(of: "--search"), i + 1 < a.count else { return }
        searchSeed = a[i + 1]
        showSearch = true
    }

    /// A search result was chosen: dismiss search, center the map on it, then open its info sheet (with a
    /// short delay so the two sheets don't fight over presentation).
    private func pickSearchResult(_ o: IdentifiedObject) {
        showSearch = false
        focus = o.coord
        let obj = IdentifiedObject(kind: o.kind, ident: o.ident, coord: o.coord,
                                   onRoute: model.flightPlan?.contains(o.ident) ?? false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            probe = MapProbeResult(id: "search-\(obj.ident)", objects: [obj])
        }
    }

    // MARK: build

    private func buildRoute() async {
        // Parse the nav table + airspace OFF the main thread (first access triggers the load) so opening
        // the map never janks; `resolve()` is then cheap on the main actor.
        await Task.detached(priority: .userInitiated) { _ = NavDatabase.count; _ = NavDatabase.airspaceCount }.value
        let resolved = RouteResolver.resolve(model.flightPlan?.fullRoute ?? [])
        route = resolved.points
        unresolved = resolved.unresolved
        totalNM = legInfos().reduce(0) { $0 + $1.nm }
        loading = false
        // Load the raster packs the route crosses (up front, pinned). Usually already on disk from the
        // file-time / launch prefetch, so this resolves without a download.
        await store.setLayer(layer, routeRects: routeRects)
    }

    // Great-circle leg distance/bearing live in the shared `Geo` (Core/MapProbe.swift).
}
