import SwiftUI
import MapKit

/// Full-screen route map: the filed flight plan drawn as the classic **magenta line** through its
/// waypoints (departure, VORs, RNAV fixes, destination — resolved by `RouteResolver` against the
/// bundled nav DB + `AirportCoordinates`), **live ADS-B traffic** (`model.aircraft`), and the Stratux
/// **ownship** when the link has a fix. Pinch-zoom / pan are native MapKit (iOS 17 `Map`). Reads
/// existing state only — no capture/pipeline/traffic changes. Route points that can't be located are
/// noted in the legend.
struct RouteMapSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var camera: MapCameraPosition = .automatic
    @State private var route: [ResolvedLeg] = []
    @State private var unresolved: [String] = []
    @State private var hybrid = false
    @State private var loading = true

    private static let routeMagenta = Color(red: 0.92, green: 0.10, blue: 0.55)
    private static let conus = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 39, longitude: -98),
        span: MKCoordinateSpan(latitudeDelta: 42, longitudeDelta: 55))

    var body: some View {
        let p = model.palette
        NavigationStack {
            Map(position: $camera) {
                routeContent
                trafficContent
                ownshipContent
            }
            .mapStyle(hybrid ? .hybrid(elevation: .flat)
                             : .standard(elevation: .flat, pointsOfInterest: .excludingAll))
            .annotationTitles(.hidden)          // labels are drawn inside each annotation's content
            .mapControls { MapCompass(); MapScaleView() }
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
                    Button { Haptics.impact(.light); hybrid.toggle() } label: {
                        Image(systemName: hybrid ? "map" : "globe.americas.fill")
                    }
                    .accessibilityLabel("Toggle map style")
                }
            }
        }
        .tint(p.accent)
        .task { await buildRoute() }
    }

    // MARK: map content

    @MapContentBuilder private var routeContent: some MapContent {
        if route.count >= 2 {
            MapPolyline(coordinates: route.map { $0.coord.clCoordinate })
                .stroke(Self.routeMagenta, style: StrokeStyle(lineWidth: 3, lineJoin: .round))
        }
        ForEach(route) { leg in
            Annotation(leg.ident, coordinate: leg.coord.clCoordinate, anchor: .center) {
                waypointMarker(leg)
            }
        }
    }

    @MapContentBuilder private var trafficContent: some MapContent {
        ForEach(model.aircraft) { ac in
            if let c = ac.coordinate {
                Annotation(ac.label ?? ac.hex, coordinate: c.clCoordinate, anchor: .center) {
                    trafficMarker(ac)
                }
            }
        }
    }

    @MapContentBuilder private var ownshipContent: some MapContent {
        if let own = model.stratuxGPS?.coordinate {
            Annotation("Ownship", coordinate: own.clCoordinate, anchor: .center) { ownshipMarker }
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

    // MARK: legend

    private func legend(_ p: Palette) -> some View {
        HStack(spacing: 10) {
            legendItem(Self.routeMagenta, "Route", line: true)
            legendItem(.hex(0xE879F9), "Airport")
            legendItem(.hex(0x34D399), "VOR")
            legendItem(.hex(0x60A5FA), "Fix")
            HStack(spacing: 3) {
                Image(systemName: "airplane").font(.system(size: 10)).foregroundStyle(.orange)
                Text("Traffic")
            }
            Spacer(minLength: 4)
            if !unresolved.isEmpty {
                Text("\(unresolved.count) not located").foregroundStyle(p.warn)
            } else if route.isEmpty && !loading {
                Text("No flight plan filed").foregroundStyle(p.textDim)
            }
        }
        .font(.system(size: 10)).foregroundStyle(p.text).lineLimit(1)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.thinMaterial)
    }

    private func legendItem(_ c: Color, _ label: String, line: Bool = false) -> some View {
        HStack(spacing: 3) {
            if line { RoundedRectangle(cornerRadius: 1).fill(c).frame(width: 14, height: 3) }
            else { Circle().fill(c).frame(width: 8, height: 8) }
            Text(label)
        }
    }

    // MARK: build

    private func buildRoute() async {
        // Parse the ~2.8 MB nav table OFF the main thread (first NavDatabase access triggers the load),
        // so opening the map never janks; resolve() is then cheap on the main actor.
        await Task.detached(priority: .userInitiated) { _ = NavDatabase.count }.value
        let resolved = RouteResolver.resolve(model.flightPlan?.fullRoute ?? [])
        route = resolved.points
        unresolved = resolved.unresolved

        var pts = resolved.points.map { $0.coord.clCoordinate }
        if let own = model.stratuxGPS?.coordinate { pts.append(own.clCoordinate) }
        if pts.isEmpty { pts = model.aircraft.compactMap { $0.coordinate?.clCoordinate } }
        camera = .region(boundingRegion(pts) ?? Self.conus)
        loading = false
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
}

fileprivate extension Coord {
    var clCoordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
}
