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
        // Frame the route if we have one, else CONUS. Zoom 7 keeps the visible span under the ~7° gate so
        // airway/airspace-altitude labels render (they're hidden when zoomed further out — chart convention).
        if let c = routeCoords.first {
            map.setCenter(c, zoomLevel: 7.0, animated: false)
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
        private var overlayGen = 0                 // drops stale async overlay refreshes (mirrors contextGen)

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
              "glyphs": "http://127.0.0.1:\(port)/font/{fontstack}/{range}.pbf",
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
            setupOverlayLayers(style)            // airways + airspace layers (empty; filled per region)
            updateRoute(routeCoords, on: mapView)   // route added last → sits above airspace
            ensureVisiblePacks(mapView)
            refreshOverlays(mapView)
        }

        /// Load the chart packs under the region the user settles on (as MapHostView does), so panning the
        /// globe pulls in coverage; and refresh the vector overlays for the new region.
        func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) {
            ensureVisiblePacks(mapView)
            refreshOverlays(mapView)
        }

        // MARK: airspace + airways overlays (milestone 2)

        /// Create the persistent overlay sources + layers ONCE (empty). Per-region refresh only mutates
        /// `source.shape` — so we never remove a source a layer still uses (MapLibre would throw). Stacking:
        /// airways below airspace below route, all above the FAA/OSM rasters.
        private func setupOverlayLayers(_ style: MLNStyle) {
            let awySrc = MLNShapeSource(identifier: "airways", shape: nil, options: nil)
            style.addSource(awySrc)
            let awy = MLNLineStyleLayer(identifier: "airways-line", source: awySrc)
            awy.lineColor = NSExpression(forConstantValue: UIColor(red: 0.42, green: 0.58, blue: 0.86, alpha: 0.75))
            awy.lineWidth = NSExpression(forConstantValue: 1.6)
            awy.lineCap = NSExpression(forConstantValue: "round"); awy.lineJoin = NSExpression(forConstantValue: "round")
            awy.minimumZoomLevel = 4.5              // the scale<9 gate
            style.addLayer(awy)

            let aspSrc = MLNShapeSource(identifier: "airspace", shape: nil, options: nil)
            style.addSource(aspSrc)
            let fill = MLNFillStyleLayer(identifier: "airspace-fill", source: aspSrc)
            fill.fillColor = Self.aspColorExpr()
            fill.fillOpacity = Self.aspOpacityExpr()
            fill.minimumZoomLevel = 4.0
            style.addLayer(fill)
            let outline = MLNLineStyleLayer(identifier: "airspace-outline", source: aspSrc)
            outline.lineColor = Self.aspColorExpr()
            outline.lineWidth = Self.aspWidthExpr()
            outline.lineCap = NSExpression(forConstantValue: "round"); outline.lineJoin = NSExpression(forConstantValue: "round")
            outline.minimumZoomLevel = 4.0
            style.addLayer(outline)

            // TEXT LABELS (need the bundled SDF glyphs, wired via the style's "glyphs" URL).
            // Airway idents — one per run, placed along the line centre (white text, slate-blue halo).
            let awyLabel = MLNSymbolStyleLayer(identifier: "airways-label", source: awySrc)
            awyLabel.text = NSExpression(forKeyPath: "ident")
            awyLabel.symbolPlacement = NSExpression(forConstantValue: "line-center")
            awyLabel.textFontNames = NSExpression(forConstantValue: ["Arial Bold"])
            awyLabel.textFontSize = NSExpression(forConstantValue: 10)
            awyLabel.textColor = NSExpression(forConstantValue: UIColor.white)
            awyLabel.textHaloColor = NSExpression(forConstantValue: UIColor(red: 0.42, green: 0.58, blue: 0.86, alpha: 0.9))
            awyLabel.textHaloWidth = NSExpression(forConstantValue: 1.4)
            awyLabel.minimumZoomLevel = 5.0
            awyLabel.symbolSortKey = NSExpression(forConstantValue: 1)   // yields to everything else
            style.addLayer(awyLabel)

            // Airspace altitude blocks (ceiling over floor) — its own point source at each area's north edge.
            let aspLabelSrc = MLNShapeSource(identifier: "airspace-labels", shape: nil, options: nil)
            style.addSource(aspLabelSrc)
            let aspLabel = MLNSymbolStyleLayer(identifier: "airspace-label", source: aspLabelSrc)
            aspLabel.text = NSExpression(forKeyPath: "alt")             // two lines: "\(ceil)\n\(floor)"
            aspLabel.textFontNames = NSExpression(forConstantValue: ["Arial Bold"])
            aspLabel.textFontSize = NSExpression(forConstantValue: 9)
            aspLabel.textColor = Self.aspColorExpr()                    // class colour, like AirspaceLabelView
            aspLabel.textHaloColor = NSExpression(forConstantValue: UIColor.black.withAlphaComponent(0.6))
            aspLabel.textHaloWidth = NSExpression(forConstantValue: 1.2)
            aspLabel.textLineHeight = NSExpression(forConstantValue: 1.0)
            aspLabel.minimumZoomLevel = 5.0
            style.addLayer(aspLabel)
        }

        /// Query airspace + airways for the settled region OFF-MAIN (gated on angular scale, exactly like
        /// refreshContext), then set the features on the persistent sources on the main actor.
        private func refreshOverlays(_ mapView: MLNMapView) {
            let b = mapView.visibleCoordinateBounds
            guard b.ne.latitude > b.sw.latitude, b.ne.longitude > b.sw.longitude else { return }   // antimeridian/degenerate
            let scale = b.ne.latitude - b.sw.latitude          // latitude span in degrees (matches the MK gate)
            let m = 0.15
            let dLat = (b.ne.latitude - b.sw.latitude) * m, dLon = (b.ne.longitude - b.sw.longitude) * m
            let bb = BBox(minLat: b.sw.latitude - dLat, minLon: b.sw.longitude - dLon,
                          maxLat: b.ne.latitude + dLat, maxLon: b.ne.longitude + dLon)
            let wantAir = scale < 14, wantLbl = scale < 7, wantAwy = scale < 9
            overlayGen += 1
            let gen = overlayGen
            Task { @MainActor in
                let feats = await Task.detached(priority: .userInitiated) {
                    () -> ([MLNPolygonFeature], [MLNPointFeature], [MLNPolylineFeature]) in
                    var asp: [MLNPolygonFeature] = []
                    var lbl: [MLNPointFeature] = []
                    if wantAir {
                        let order: [String: Int] = ["TFR": 0, "P": 1, "R": 2, "B": 3, "C": 4, "W": 5, "MOA": 6, "A": 7, "D": 8]
                        let list = NavDatabase.airspaces(intersecting: bb)
                            .sorted { (order[$0.cls] ?? 9, $0.name) < (order[$1.cls] ?? 9, $1.name) }
                        building: for a in list {
                            for ring in a.rings {                          // bounded by the 260 cap below
                                var c = ring.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
                                let f = MLNPolygonFeature(coordinates: &c, count: UInt(c.count))
                                f.attributes = ["cls": a.cls]              // drives fill/line color, opacity, width
                                asp.append(f)
                                if asp.count >= 260 { break building }
                            }
                        }
                        if wantLbl {                                       // altitude blocks (scale<7, cap 140)
                            for a in list where lbl.count < 140 {
                                guard let top = a.rings.flatMap({ $0 }).max(by: { $0.lat < $1.lat }) else { continue }
                                let f = MLNPointFeature()
                                f.coordinate = CLLocationCoordinate2D(latitude: top.lat, longitude: top.lon)
                                f.attributes = ["cls": a.cls,
                                                "alt": "\(AirspaceLabelAnnotation.altText(a.ceilingFt))\n\(AirspaceLabelAnnotation.altText(a.floorFt))"]
                                lbl.append(f)
                            }
                        }
                    }
                    var awy: [MLNPolylineFeature] = []
                    if wantAwy {
                        for seg in Airways.inRegion(bb) where seg.points.count >= 2 {   // already split into runs
                            var c = seg.points.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
                            let f = MLNPolylineFeature(coordinates: &c, count: UInt(c.count))
                            f.attributes = ["ident": seg.ident, "area": seg.area]       // for the future tap card
                            awy.append(f)
                        }
                    }
                    return (asp, lbl, awy)
                }.value
                guard gen == overlayGen, let style = mapView.style else { return }
                (style.source(withIdentifier: "airspace") as? MLNShapeSource)?.shape = MLNShapeCollectionFeature(shapes: feats.0)
                (style.source(withIdentifier: "airspace-labels") as? MLNShapeSource)?.shape = MLNShapeCollectionFeature(shapes: feats.1)
                (style.source(withIdentifier: "airways") as? MLNShapeSource)?.shape = MLNShapeCollectionFeature(shapes: feats.2)
            }
        }

        /// "#RRGGBB" from the app's canonical `airspaceColor` (reused verbatim — no hand-typed hex).
        private static func hex(_ cls: String) -> String {
            var r: CGFloat = 0, g: CGFloat = 0, bl: CGFloat = 0, a: CGFloat = 0
            ChartMapView.Coordinator.airspaceColor(cls).getRed(&r, green: &g, blue: &bl, alpha: &a)
            return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(bl * 255))
        }
        // Data-driven paint props keyed on the "cls" feature attribute (default covers B & D — chart blue).
        private static func aspColorExpr() -> NSExpression {
            NSExpression(mglJSONObject: ["match", ["get", "cls"],
                "C", hex("C"), "TFR", hex("TFR"), "R", hex("R"), "P", hex("P"),
                "W", hex("W"), "A", hex("A"), "MOA", hex("MOA"), hex("B")])
        }
        private static func aspOpacityExpr() -> NSExpression {
            NSExpression(mglJSONObject: ["match", ["get", "cls"],
                "P", 0.18, "TFR", 0.18, "R", 0.10, "W", 0.10, "A", 0.10, "MOA", 0.10, 0.05])
        }
        private static func aspWidthExpr() -> NSExpression {
            NSExpression(mglJSONObject: ["match", ["get", "cls"],
                "R", 2.4, "P", 2.4, "TFR", 2.4, "W", 1.8, "A", 1.8, "MOA", 1.8, "B", 1.5, "C", 1.5, 1.2])
        }

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
                Text("FAA tiles + route + airspace/airways + labels on MapLibre. Migration milestone 3.")
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
