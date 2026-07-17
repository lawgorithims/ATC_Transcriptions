// EXPERIMENTAL — branch experimental/maplibre-migration. DO NOT MERGE.
//
// Milestone 1 of the MKMapView→MapLibre migration ("tiles + route first"): render our ACTUAL offline FAA
// chart tiles + the filed route on the MapLibre globe. Tiles come from the same `MBTilesReader`s / `ChartStore`
// the production map uses, bridged to MapLibre via the loopback `MBTilesHTTPServer`. An OSM raster sits
// underneath so the globe is always populated; the FAA sectional draws on top wherever a pack is downloaded.
//
// Still to port in later milestones: airspace / airways / TFR / plate overlays, nearby FAA symbols,
// ownship + traffic, and tap-to-identify. See EXPERIMENTAL_DO_NOT_MERGE.md.

#if canImport(MapLibre)
import SwiftUI
import MapLibre
import MapKit
import CoreLocation

struct MapLibreChartView: UIViewRepresentable {
    let store: ChartStore
    var routeCoords: [CLLocationCoordinate2D]

    func makeCoordinator() -> Coordinator { Coordinator(store: store, routeCoords: routeCoords) }

    func makeUIView(context: Context) -> MLNMapView {
        let map = MLNMapView(frame: .zero)
        map.delegate = context.coordinator
        map.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        // Frame the route if we have one, else CONUS.
        if let c = routeCoords.first {
            map.setCenter(c, zoomLevel: 5.5, animated: false)
        } else {
            map.setCenter(CLLocationCoordinate2D(latitude: 39, longitude: -96), zoomLevel: 3.2, animated: false)
        }
        context.coordinator.attach(map)
        return map
    }

    func updateUIView(_ uiView: MLNMapView, context: Context) {
        context.coordinator.updateRoute(routeCoords, on: uiView)
    }

    static func dismantleUIView(_ uiView: MLNMapView, coordinator: Coordinator) { coordinator.server.stop() }

    // MARK: coordinator

    final class Coordinator: NSObject, MLNMapViewDelegate {
        let store: ChartStore
        let server: MBTilesHTTPServer
        private var routeCoords: [CLLocationCoordinate2D]
        private weak var map: MLNMapView?

        init(store: ChartStore, routeCoords: [CLLocationCoordinate2D]) {
            self.store = store
            self.routeCoords = routeCoords
            self.server = MBTilesHTTPServer()          // packs are pushed in via setReaders (main actor)
            super.init()
            _ = server.start()
        }

        func attach(_ map: MLNMapView) {
            self.map = map
            map.styleURL = Self.writeStyle(port: server.port)
        }

        // MARK: style + layers

        private static func writeStyle(port: UInt16) -> URL? {
            // Base OSM raster (globe always populated) + our FAA sectional raster from the loopback server.
            let faaTiles = port > 0 ? "http://127.0.0.1:\(port)/{z}/{x}/{y}" : "http://127.0.0.1:0/{z}/{x}/{y}"
            let style = """
            {
              "version": 8,
              "projection": { "type": "globe" },
              "sources": {
                "osm": { "type": "raster", "tiles": ["https://tile.openstreetmap.org/{z}/{x}/{y}.png"],
                         "tileSize": 256, "maxzoom": 18, "attribution": "© OpenStreetMap" },
                "faa": { "type": "raster", "tiles": ["\(faaTiles)"], "tileSize": 256, "maxzoom": 16,
                         "attribution": "FAA charts (offline pack)" }
              },
              "layers": [
                { "id": "bg", "type": "background", "paint": { "background-color": "#0b1a2b" } },
                { "id": "osm", "type": "raster", "source": "osm", "paint": { "raster-opacity": 0.55 } },
                { "id": "faa", "type": "raster", "source": "faa" }
              ]
            }
            """
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("maplibre-chart.json")
            do { try style.write(to: url, atomically: true, encoding: .utf8); return url } catch { return nil }
        }

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            updateRoute(routeCoords, on: mapView)
            ensureVisiblePacks(mapView)
        }

        /// Load the chart packs under the region the user settles on (as MapHostView does), so panning the
        /// globe pulls in coverage. Runs off-main inside ChartStore.
        func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) { ensureVisiblePacks(mapView) }

        private func ensureVisiblePacks(_ mapView: MLNMapView) {
            let b = mapView.visibleCoordinateBounds
            let ne = MKMapPoint(b.ne), sw = MKMapPoint(b.sw)
            let rect = MKMapRect(x: min(ne.x, sw.x), y: min(ne.y, sw.y),
                                 width: abs(ne.x - sw.x), height: abs(ne.y - sw.y))
            Task { @MainActor in
                let before = store.readers.count
                await store.ensureVisible(rect, layer: .sectional)
                server.setReaders(store.readers)       // hand the current packs to the tile server
                // If new packs mounted, re-add the FAA source so MapLibre re-requests tiles it 404'd.
                // ORDER MATTERS: MapLibre throws if you remove a source still used by a layer — remove
                // the LAYER first, then the source.
                if store.readers.count != before, let style = mapView.style {
                    if let faaLayer = style.layer(withIdentifier: "faa") { style.removeLayer(faaLayer) }
                    if let src = style.source(withIdentifier: "faa") { style.removeSource(src) }
                    let fresh = MLNRasterTileSource(identifier: "faa",
                        tileURLTemplates: ["http://127.0.0.1:\(server.port)/{z}/{x}/{y}"],
                        options: [.tileSize: 256, .maximumZoomLevel: 16])
                    style.addSource(fresh)
                    style.addLayer(MLNRasterStyleLayer(identifier: "faa", source: fresh))
                }
            }
        }

        // MARK: route line

        func updateRoute(_ coords: [CLLocationCoordinate2D], on mapView: MLNMapView) {
            routeCoords = coords
            guard let style = mapView.style else { return }
            if let oldL = style.layer(withIdentifier: "route-line") { style.removeLayer(oldL) }
            if let old = style.source(withIdentifier: "route") { style.removeSource(old) }
            guard coords.count >= 2 else { return }
            var c = coords
            let line = MLNPolylineFeature(coordinates: &c, count: UInt(c.count))
            let src = MLNShapeSource(identifier: "route", shape: line, options: nil)
            style.addSource(src)
            let layer = MLNLineStyleLayer(identifier: "route-line", source: src)
            layer.lineColor = NSExpression(forConstantValue: UIColor(red: 0.95, green: 0.24, blue: 0.62, alpha: 1))
            layer.lineWidth = NSExpression(forConstantValue: 3.0)
            layer.lineCap = NSExpression(forConstantValue: "round")
            layer.lineJoin = NSExpression(forConstantValue: "round")
            style.addLayer(layer)
        }
    }
}

/// Full-screen host: owns a ChartStore, downloads the route corridor, and shows the globe chart with an
/// EXPERIMENTAL banner + ✕. Uses the app's filed plan if present, else a demo route.
struct MapLibreChartScreen: View {
    let model: AppModel
    var onClose: (() -> Void)?
    @StateObject private var store = ChartStore(library: ChartLibrary.shared)
    @State private var didLoad = false

    private var legs: [ResolvedLeg] {
        if let plan = model.flightPlan, !plan.isEmpty {
            let resolved = ProcedureRoute.resolve(plan)
            if resolved.count >= 2 { return resolved }
        }
        return Self.demoLegs
    }
    private var routeCoords: [CLLocationCoordinate2D] {
        legs.map { CLLocationCoordinate2D(latitude: $0.coord.lat, longitude: $0.coord.lon) }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            MapLibreChartView(store: store, routeCoords: routeCoords).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("EXPERIMENTAL · MapLibre chart")
                        .font(.caption.weight(.bold)).foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.red.opacity(0.85), in: Capsule())
                    Spacer()
                    if let onClose {
                        Button { onClose() } label: {
                            Image(systemName: "xmark.circle.fill").font(.title2).foregroundStyle(.white)
                        }
                    }
                }
                Text("Globe + our offline FAA tiles (where downloaded) + filed route. Migration milestone 1.")
                    .font(.caption2).foregroundStyle(.white.opacity(0.85))
            }
            .padding(12).background(.black.opacity(0.35))
        }
        .task {
            guard !didLoad else { return }
            didLoad = true
            // Pull the sectional packs the route crosses (downloads them if needed) so the FAA layer shows.
            await store.setLayer(.sectional, routeRects: ChartGeo.routeRects(legs))
        }
    }

    /// KBOS → KJFK → KDCA — a demo corridor so the chart has something to download + draw with no plan.
    private static let demoLegs: [ResolvedLeg] = [
        ResolvedLeg(ident: "KBOS", kind: .airport, coord: Coord(lat: 42.3656, lon: -71.0096)),
        ResolvedLeg(ident: "KJFK", kind: .airport, coord: Coord(lat: 40.6413, lon: -73.7781)),
        ResolvedLeg(ident: "KDCA", kind: .airport, coord: Coord(lat: 38.8521, lon: -77.0377)),
    ]
}
#endif
