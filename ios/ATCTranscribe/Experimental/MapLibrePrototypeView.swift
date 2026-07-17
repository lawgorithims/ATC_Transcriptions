// EXPERIMENTAL — branch experimental/maplibre-globe-prototype. DO NOT MERGE.
//
// A throwaway spike evaluating MapLibre Native (an open-source GPU map renderer) as a possible replacement
// for MKMapView. The question we're answering: can a custom GPU renderer give us (a) a 3D GLOBE — which
// MKMapView cannot do — and (b) the on-demand rendering that makes ForeFlight efficient, while still
// consuming our chart tiles and drawing our overlays?
//
// This prototype proves the three things that matter before committing to a migration:
//   1. A globe renders (style `projection: globe`, which MapLibre 6.x supports and MapKit does not).
//   2. Real FAA sectional raster tiles paint on the sphere (via ChartBundle's public XYZ endpoint here;
//      the production path would serve our bundled MBTiles through a local tile provider — see the
//      EXPERIMENTAL_DO_NOT_MERGE.md TODO).
//   3. Vector overlays (a route line + an airspace polygon) render on the globe via the runtime style API,
//      which is the harder open question for our use case.
//
// It is deliberately isolated: it depends on nothing in the app, is reached only behind a flag
// (`--maplibre` launch arg or the `atc.experimentalMapLibreGlobe` default), and touches no shipping code.

#if canImport(MapLibre)
import SwiftUI
import MapLibre
import CoreLocation

struct MapLibrePrototypeView: UIViewRepresentable {
    /// A demo route to draw as a line (defaults to KBOS → KJFK → KDCA). Fed real plan coords later.
    var route: [CLLocationCoordinate2D] = [
        CLLocationCoordinate2D(latitude: 42.3656, longitude: -71.0096),   // KBOS
        CLLocationCoordinate2D(latitude: 40.6413, longitude: -73.7781),   // KJFK
        CLLocationCoordinate2D(latitude: 38.8521, longitude: -77.0377),   // KDCA
    ]

    func makeCoordinator() -> Coordinator { Coordinator(route: route) }

    func makeUIView(context: Context) -> MLNMapView {
        let map = MLNMapView(frame: .zero)
        map.delegate = context.coordinator
        map.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        map.logoView.isHidden = false          // keep attribution visible (spike)
        // Low zoom so the GLOBE curvature is obvious (MapLibre eases toward flat Mercator as you zoom in).
        map.setCenter(CLLocationCoordinate2D(latitude: 38.0, longitude: -95.0), zoomLevel: 2.2, animated: false)
        // Load a v8 style with the GLOBE projection + a FAA sectional raster source, from a temp file
        // (styleURL is supported across every MapLibre version; inline styleJSON is not).
        if let url = Self.writeStyleJSON() { map.styleURL = url }
        return map
    }

    func updateUIView(_ uiView: MLNMapView, context: Context) {}

    // MARK: style

    /// A minimal MapLibre GL style: globe projection + one raster layer of real FAA sectionals.
    private static func writeStyleJSON() -> URL? {
        let style = """
        {
          "version": 8,
          "projection": { "type": "globe" },
          "sources": {
            "basemap": {
              "type": "raster",
              "tiles": ["https://tile.openstreetmap.org/{z}/{x}/{y}.png"],
              "tileSize": 256,
              "maxzoom": 18,
              "attribution": "© OpenStreetMap contributors (prototype basemap)"
            }
          },
          "layers": [
            { "id": "bg", "type": "background", "paint": { "background-color": "#0b1a2b" } },
            { "id": "basemap-layer", "type": "raster", "source": "basemap" }
          ]
        }
        """
        // NOTE: this demo uses OpenStreetMap raster so the globe renders on any network. The AVIATION swap
        // is one line — replace the tiles URL above with the FAA sectional endpoint, e.g.
        //   "https://wms.chartbundle.com/tms/1.0.0/sec/{z}/{x}/{y}.png?origin=nw"  (maxzoom 12)
        // and ultimately our own bundled/offline MBTiles via a local tile provider (see the DO-NOT-MERGE doc).
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("maplibre-globe-proto.json")
        do { try style.write(to: url, atomically: true, encoding: .utf8); return url }
        catch { return nil }
    }

    // MARK: delegate — add the vector overlays once the style has loaded

    final class Coordinator: NSObject, MLNMapViewDelegate {
        private let route: [CLLocationCoordinate2D]
        init(route: [CLLocationCoordinate2D]) { self.route = route }

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            addRoute(to: style)
            addDemoAirspace(to: style)
        }

        /// Magenta route polyline (proves line overlays render on the sphere).
        private func addRoute(to style: MLNStyle) {
            guard route.count >= 2 else { return }
            var coords = route
            let line = MLNPolylineFeature(coordinates: &coords, count: UInt(coords.count))
            let source = MLNShapeSource(identifier: "proto-route", shape: line, options: nil)
            style.addSource(source)
            let layer = MLNLineStyleLayer(identifier: "proto-route-line", source: source)
            layer.lineColor = NSExpression(forConstantValue: UIColor(red: 0.95, green: 0.24, blue: 0.62, alpha: 1))
            layer.lineWidth = NSExpression(forConstantValue: 3.0)
            layer.lineCap = NSExpression(forConstantValue: "round")
            layer.lineJoin = NSExpression(forConstantValue: "round")
            style.addLayer(layer)
        }

        /// A demo Class-B-ish polygon over NYC (proves fill overlays render on the sphere).
        private func addDemoAirspace(to style: MLNStyle) {
            var ring = [
                CLLocationCoordinate2D(latitude: 41.0, longitude: -74.4),
                CLLocationCoordinate2D(latitude: 41.0, longitude: -73.4),
                CLLocationCoordinate2D(latitude: 40.4, longitude: -73.4),
                CLLocationCoordinate2D(latitude: 40.4, longitude: -74.4),
            ]
            let poly = MLNPolygonFeature(coordinates: &ring, count: UInt(ring.count))
            let source = MLNShapeSource(identifier: "proto-airspace", shape: poly, options: nil)
            style.addSource(source)
            let fill = MLNFillStyleLayer(identifier: "proto-airspace-fill", source: source)
            fill.fillColor = NSExpression(forConstantValue: UIColor(red: 0.18, green: 0.44, blue: 0.93, alpha: 1))
            fill.fillOpacity = NSExpression(forConstantValue: 0.18)
            fill.fillOutlineColor = NSExpression(forConstantValue: UIColor(red: 0.18, green: 0.44, blue: 0.93, alpha: 1))
            style.addLayer(fill)
        }
    }
}

/// Full-screen host with a dismiss control + a caption so the spike is obviously experimental.
struct MapLibrePrototypeScreen: View {
    var onClose: (() -> Void)?
    var body: some View {
        ZStack(alignment: .topLeading) {
            MapLibrePrototypeView().ignoresSafeArea()
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("EXPERIMENTAL · MapLibre globe")
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
                Text("Globe + FAA sectionals + route/airspace overlays. Prototype tile source; not for merge.")
                    .font(.caption2).foregroundStyle(.white.opacity(0.85))
            }
            .padding(12)
            .background(.black.opacity(0.35))
        }
    }
}
#endif
