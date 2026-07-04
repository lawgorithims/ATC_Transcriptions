import SwiftUI
import MapKit

/// One polygon ring ready for MapKit — an airspace can be several concentric shelves, so a single
/// `Airspace` expands into several of these. Pre-flattened off-main in `refreshOverlays` so the map's
/// content builder is one flat `ForEach` (nested `ForEach` in `MapContentBuilder` is fragile).
private struct AirspaceRing: Identifiable {
    let id: String
    let cls: String
    let coords: [CLLocationCoordinate2D]
}

/// Full-screen route map: the filed flight plan drawn as the classic **magenta line** through its
/// waypoints (departure, VORs, RNAV fixes, destination — resolved by `RouteResolver` against the
/// bundled nav DB + `AirportCoordinates`), an offline **aviation layer** (Class B/C/D airspace outlines
/// + nearby navaids/airports, both from the bundled DB), **live ADS-B traffic** (`model.aircraft`), and
/// the Stratux **ownship** when the link has a fix. Pinch-zoom / pan are native MapKit (iOS 17 `Map`);
/// the context layers refresh to whatever's in view. Reads existing state only — no capture/pipeline/
/// traffic changes. Route points that can't be located are noted in the legend / route details.
struct RouteMapSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var camera: MapCameraPosition = .automatic
    @State private var route: [ResolvedLeg] = []
    @State private var unresolved: [String] = []
    @State private var routeIdents: Set<String> = []
    @State private var totalNM: Double = 0
    @State private var hybrid = false
    @State private var loading = true

    @State private var showAirspace = true
    @State private var showNearby = true
    @State private var showRouteInfo = false
    @State private var visibleRings: [AirspaceRing] = []
    @State private var visibleNearby: [NavPoint] = []
    @State private var currentRegion: MKCoordinateRegion?

    private static let routeMagenta = Color(red: 0.92, green: 0.10, blue: 0.55)
    private static let conus = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 39, longitude: -98),
        span: MKCoordinateSpan(latitudeDelta: 42, longitudeDelta: 55))

    var body: some View {
        let p = model.palette
        NavigationStack {
            Map(position: $camera) {
                airspaceContent
                nearbyContent
                routeContent
                trafficContent
                ownshipContent
            }
            .mapStyle(hybrid ? .hybrid(elevation: .flat)
                             : .standard(elevation: .flat, pointsOfInterest: .excludingAll))
            .mapControls { MapCompass(); MapScaleView() }
            .onMapCameraChange(frequency: .onEnd) { ctx in
                currentRegion = ctx.region
                refreshOverlays(region: ctx.region)
            }
            .onChange(of: showAirspace) { _, _ in if let r = currentRegion { refreshOverlays(region: r) } }
            .onChange(of: showNearby) { _, _ in if let r = currentRegion { refreshOverlays(region: r) } }
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
                ToolbarItem(placement: .primaryAction) { layersMenu }
            }
            .sheet(isPresented: $showRouteInfo) { routeInfoSheet }
        }
        .tint(p.accent)
        .task { await buildRoute() }
    }

    private var layersMenu: some View {
        Menu {
            Toggle(isOn: $showAirspace) { Label("Class B/C/D airspace", systemImage: "hexagon") }
            Toggle(isOn: $showNearby) { Label("Nearby navaids & airports", systemImage: "mappin.and.ellipse") }
            Divider()
            Picker("Map style", selection: $hybrid) {
                Label("Standard", systemImage: "map").tag(false)
                Label("Satellite", systemImage: "globe.americas.fill").tag(true)
            }
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

    // MARK: map content

    @MapContentBuilder private var airspaceContent: some MapContent {
        ForEach(visibleRings) { r in
            MapPolygon(coordinates: r.coords)
                .stroke(Self.airspaceColor(r.cls), style: Self.airspaceStroke(r.cls))
                .foregroundStyle(Self.airspaceColor(r.cls).opacity(0.05))
        }
    }

    @MapContentBuilder private var nearbyContent: some MapContent {
        ForEach(visibleNearby) { np in
            Annotation("", coordinate: np.coord.clCoordinate, anchor: .center) { nearbyMarker(np) }
        }
    }

    @MapContentBuilder private var routeContent: some MapContent {
        if route.count >= 2 {
            MapPolyline(coordinates: route.map { $0.coord.clCoordinate })
                .stroke(Self.routeMagenta, style: StrokeStyle(lineWidth: 3, lineJoin: .round))
        }
        ForEach(route) { leg in
            Annotation("", coordinate: leg.coord.clCoordinate, anchor: .center) {
                waypointMarker(leg)   // ident is drawn inside the marker
            }
        }
    }

    @MapContentBuilder private var trafficContent: some MapContent {
        ForEach(model.aircraft.filter { $0.coordinate != nil }) { ac in
            Annotation("", coordinate: ac.coordinate!.clCoordinate, anchor: .center) {
                trafficMarker(ac)   // callsign is drawn inside the marker
            }
        }
    }

    @MapContentBuilder private var ownshipContent: some MapContent {
        if let own = model.stratuxGPS?.coordinate {
            Annotation("", coordinate: own.clCoordinate, anchor: .center) { ownshipMarker }
        }
    }

    // MARK: markers

    private func waypointMarker(_ leg: ResolvedLeg) -> some View {
        VStack(spacing: 2) {
            Text(leg.ident)
                .font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(.white)
                .padding(.horizontal, 3).padding(.vertical, 1)
                .background(.black.opacity(0.55), in: Capsule())
            Circle().fill(color(leg.kind)).frame(width: 9, height: 9)
                .overlay(Circle().stroke(.white, lineWidth: 1.5))
        }
    }

    /// Context navaid/airport — deliberately smaller & dimmer than a filed waypoint or traffic, and a
    /// distinct glyph (teal hexagon = navaid, magenta ring = airport) so it doesn't read as either.
    private func nearbyMarker(_ np: NavPoint) -> some View {
        VStack(spacing: 0) {
            Group {
                if np.kind == .airport {
                    Circle().stroke(Color.hex(0xE879F9).opacity(0.9), lineWidth: 1.5).frame(width: 7, height: 7)
                } else {
                    Image(systemName: "hexagon")
                        .font(.system(size: 8)).foregroundStyle(Color.hex(0x34D399).opacity(0.9))
                }
            }
            Text(np.ident)
                .font(.system(size: 7, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.8))
                .padding(.horizontal, 2).background(.black.opacity(0.35), in: Capsule())
        }
    }

    private func trafficMarker(_ ac: Aircraft) -> some View {
        VStack(spacing: 1) {
            Image(systemName: "airplane")
                .font(.system(size: 14)).foregroundStyle(.orange)
                .rotationEffect(.degrees((ac.trackDeg ?? 0) - 90))   // SF airplane points E(90°); align 0°=N
                .shadow(radius: 1)
            if let label = ac.label {
                Text(label).font(.system(size: 8, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 3).background(.black.opacity(0.55), in: Capsule())
            }
        }
    }

    private var ownshipMarker: some View {
        Image(systemName: "location.north.circle.fill")
            .font(.system(size: 22)).foregroundStyle(.cyan)
            .background(Circle().fill(.black.opacity(0.45))).shadow(radius: 2)
    }

    private func color(_ kind: RouteKind) -> Color {
        switch kind {
        case .airport:  return .hex(0xE879F9)
        case .vor:      return .hex(0x34D399)
        case .waypoint: return .hex(0x60A5FA)
        case .airway:   return .hex(0xF5C451)
        case .other:    return .white
        }
    }

    // Sectional-style airspace colours: Class B solid blue, Class C solid magenta, Class D dashed blue.
    private static func airspaceColor(_ cls: String) -> Color {
        switch cls {
        case "C":  return .hex(0xC2185B)
        default:   return .hex(0x2F6FED)   // B and D
        }
    }

    private static func airspaceStroke(_ cls: String) -> StrokeStyle {
        cls == "D" ? StrokeStyle(lineWidth: 1.2, dash: [4, 3]) : StrokeStyle(lineWidth: 1.5)
    }

    // MARK: legend

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
                           nm: Self.nmBetween(a, b), bearing: Self.bearing(a, b))
        }
    }

    // MARK: build

    private func buildRoute() async {
        // Parse the ~3 MB nav table + airspace OFF the main thread (first NavDatabase access triggers the
        // load), so opening the map never janks; resolve() is then cheap on the main actor.
        await Task.detached(priority: .userInitiated) { _ = NavDatabase.count; _ = NavDatabase.airspaceCount }.value
        let resolved = RouteResolver.resolve(model.flightPlan?.fullRoute ?? [])
        route = resolved.points
        unresolved = resolved.unresolved
        routeIdents = Set(resolved.points.map { $0.ident })
        totalNM = legInfos().reduce(0) { $0 + $1.nm }

        var pts = resolved.points.map { $0.coord.clCoordinate }
        if let own = model.stratuxGPS?.coordinate { pts.append(own.clCoordinate) }
        if pts.isEmpty { pts = model.aircraft.compactMap { $0.coordinate?.clCoordinate } }
        let region = boundingRegion(pts) ?? Self.conus
        camera = .region(region)
        currentRegion = region
        loading = false
        refreshOverlays(region: region)
    }

    /// Recompute the in-view context layers (airspace outlines + nearby navaids/airports) for a settled
    /// region. Runs off-main (the nearby scan walks the full ~90k-ident table). Airspace hides when
    /// zoomed out past regional scale, and nearby markers hide when zoomed out past ~5.5° so the map
    /// stays legible; both cap their counts to keep MapKit snappy.
    private func refreshOverlays(region: MKCoordinateRegion) {
        let bb = BBox(region, margin: 0.15)
        let wantAir = showAirspace && region.span.latitudeDelta < 14
        let wantNear = showNearby && region.span.latitudeDelta < 5.5
        let idents = routeIdents
        Task {
            let (rings, near) = await Task.detached(priority: .userInitiated) {
                () -> ([AirspaceRing], [NavPoint]) in
                var rings: [AirspaceRing] = []
                if wantAir {
                    let order: [String: Int] = ["B": 0, "C": 1, "D": 2]
                    let asp = NavDatabase.airspaces(intersecting: bb)
                        .sorted { (order[$0.cls] ?? 9, $0.name) < (order[$1.cls] ?? 9, $1.name) }
                    building: for a in asp {
                        for (j, ring) in a.rings.enumerated() {
                            rings.append(AirspaceRing(id: "\(a.id)-\(j)", cls: a.cls,
                                                      coords: ring.map { $0.clCoordinate }))
                            if rings.count >= 260 { break building }
                        }
                    }
                }
                let near: [NavPoint] = wantNear
                    ? NavDatabase.nearby(bb, limit: 160).filter { !idents.contains($0.ident) }
                    : []
                return (rings, near)
            }.value
            visibleRings = rings
            visibleNearby = near
        }
    }

    private func boundingRegion(_ coords: [CLLocationCoordinate2D]) -> MKCoordinateRegion? {
        guard let first = coords.first else { return nil }
        var minLat = first.latitude, maxLat = first.latitude
        var minLon = first.longitude, maxLon = first.longitude
        for c in coords {
            minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
        }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
        let span = MKCoordinateSpan(latitudeDelta: max(0.4, (maxLat - minLat) * 1.4),
                                    longitudeDelta: max(0.4, (maxLon - minLon) * 1.4))
        return MKCoordinateRegion(center: center, span: span)
    }

    // MARK: geo

    private static func nmBetween(_ a: Coord, _ b: Coord) -> Double {
        let R = 3440.065   // Earth radius in nautical miles
        let la1 = a.lat * .pi / 180, la2 = b.lat * .pi / 180
        let dLa = (b.lat - a.lat) * .pi / 180, dLo = (b.lon - a.lon) * .pi / 180
        let h = sin(dLa / 2) * sin(dLa / 2) + cos(la1) * cos(la2) * sin(dLo / 2) * sin(dLo / 2)
        return 2 * R * asin(min(1, sqrt(h)))
    }

    private static func bearing(_ a: Coord, _ b: Coord) -> Double {
        let la1 = a.lat * .pi / 180, la2 = b.lat * .pi / 180
        let dLo = (b.lon - a.lon) * .pi / 180
        let y = sin(dLo) * cos(la2)
        let x = cos(la1) * sin(la2) - sin(la1) * cos(la2) * cos(dLo)
        let brg = atan2(y, x) * 180 / .pi
        return brg < 0 ? brg + 360 : brg
    }
}

fileprivate extension Coord {
    var clCoordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
}

fileprivate extension BBox {
    /// The visible region grown by `margin` (a fraction of the span) so context layers extend a little
    /// past the screen edge and don't pop in during a pan.
    init(_ r: MKCoordinateRegion, margin: Double) {
        let dLat = r.span.latitudeDelta * (0.5 + margin)
        let dLon = r.span.longitudeDelta * (0.5 + margin)
        self.init(minLat: r.center.latitude - dLat, minLon: r.center.longitude - dLon,
                  maxLat: r.center.latitude + dLat, maxLon: r.center.longitude + dLon)
    }
}
