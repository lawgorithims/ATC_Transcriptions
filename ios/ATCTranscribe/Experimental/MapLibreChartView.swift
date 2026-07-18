// EXPERIMENTAL — branch experimental/maplibre-migration. DO NOT MERGE.
//
// Milestone 1 of the MKMapView→MapLibre migration ("tiles + route first"): render our ACTUAL offline FAA
// chart tiles + the filed route on the MapLibre globe. Tiles come from the same `MBTilesReader`s / `ChartStore`
// the production map uses, bridged to MapLibre via the loopback `MBTilesHTTPServer`. An OSM raster sits
// underneath as an ONLINE-ONLY backdrop; the FAA sectional (offline packs) draws on top wherever downloaded.
// EXPERIMENTAL caveat: offline in the cockpit only the FAA-covered regions + the #0b1a2b background render
// (the OSM backdrop needs connectivity) — a bundled low-zoom base is a pre-ship TODO before this leaves spike.
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
    var ownship: CLLocationCoordinate2D? = nil
    var ownshipCourse: Double? = nil
    var traffic: [Aircraft] = []
    var tfrs: [TFR] = []
    var showTFRs: Bool = false
    var plateOverlay: PlateOverlayState? = nil
    var routeIdents: Set<String> = []
    var onTapObjects: ([IdentifiedObject]) -> Void = { _ in }

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
        // Tap = identify; long-press = drop a user waypoint (MapLibre has no built-in long-press → free).
        map.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator,
                                                        action: #selector(Coordinator.handleTap(_:))))
        map.addGestureRecognizer(UILongPressGestureRecognizer(target: context.coordinator,
                                                              action: #selector(Coordinator.handleLongPress(_:))))
        context.coordinator.attach(map)
        return map
    }

    func updateUIView(_ uiView: MLNMapView, context: Context) {
        let c = context.coordinator
        c.onTapObjects = onTapObjects
        c.routeIdents = routeIdents
        c.updateRoute(routeCoords, on: uiView)
        c.updateOwnship(ownship, course: ownshipCourse, on: uiView)
        c.updateTraffic(traffic, on: uiView)
        c.updateTFRs(showTFRs ? tfrs : [], on: uiView)
        c.updatePlate(plateOverlay, on: uiView)
    }

    static func dismantleUIView(_ uiView: MLNMapView, coordinator: Coordinator) { coordinator.teardown() }

    // MARK: coordinator

    final class Coordinator: NSObject, MLNMapViewDelegate {
        let store: ChartStore
        let server: MBTilesHTTPServer
        private var routeCoords: [CLLocationCoordinate2D]
        private weak var map: MLNMapView?
        private var overlayGen = 0                 // drops stale async overlay refreshes (mirrors contextGen)
        private var wantFixes = false              // hysteretic GPS-fix visibility (show scale<2.2, hide >2.7)
        var onTapObjects: (([IdentifiedObject]) -> Void)?
        var routeIdents: Set<String> = []
        var tfrByID: [String: TFR] = [:]           // full TFRs, recovered from a tapped feature's "id"
        private var cachedTFRs: [TFR] = []         // applied at didFinishLoading if the style wasn't ready yet
        private var plateState: PlateOverlayState? // last plate applied; diffed against below to avoid churn
        private var plateKey: String?
        private var plateOpacity: Double?
        private var plateInverted: Bool?
        private var plateImageKey: String?         // "pdf|inverted" — refresh the raster on a plate SWAP, not just invert
        private var serverPort: UInt16 = 0         // bound loopback port, delivered async by the tile server
        private var serverHadReaders = false       // false→true transition forces the initial FAA source re-add
        private var regionDebounce: DispatchWorkItem?  // coalesces a burst of region-settle events (pan/zoom)

        init(store: ChartStore, routeCoords: [CLLocationCoordinate2D]) {
            self.store = store
            self.routeCoords = routeCoords
            self.server = MBTilesHTTPServer()          // packs are pushed in via setReaders (main actor)
            super.init()
        }

        func attach(_ map: MLNMapView) {
            self.map = map
            // Start the loopback tile server WITHOUT blocking the main thread; install the style only once the
            // listener binds a port (the port is the sole thing writeStyle needs). A failed bind delivers 0.
            server.start { [weak self, weak map] port in
                guard let self, let map, port > 0 else { return }
                self.serverPort = port
                map.styleURL = Self.writeStyle(port: port)
            }
        }

        /// Cancel the pending region-settle work and stop the loopback server (called from dismantleUIView).
        func teardown() { regionDebounce?.cancel(); regionDebounce = nil; server.stop() }

        // MARK: style + layers

        private static func writeStyle(port: UInt16) -> URL? {
            // Base OSM raster (online-only backdrop) + our FAA sectional raster from the loopback server. Only
            // ever called with a bound port (>0), so both the tile and glyph URLs are always connectable.
            assert(port > 0, "writeStyle requires a bound loopback port")
            let style = """
            {
              "version": 8,
              "projection": { "type": "globe" },
              "glyphs": "http://127.0.0.1:\(port)/font/{fontstack}/{range}.pbf",
              "sources": {
                "osm": { "type": "raster", "tiles": ["https://tile.openstreetmap.org/{z}/{x}/{y}.png"],
                         "tileSize": 256, "maxzoom": 18, "attribution": "© OpenStreetMap" },
                "faa": { "type": "raster", "tiles": ["http://127.0.0.1:\(port)/{z}/{x}/{y}"],
                         "tileSize": 256, "maxzoom": 16, "attribution": "FAA charts (offline pack)" }
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
            setupOverlayLayers(style)            // airspace/airways/nav + TFR/route/traffic/ownship (empty)
            updateRoute(routeCoords, on: mapView)
            ensureVisiblePacks(mapView)
            refreshOverlays(mapView)
            // Re-apply anything updateUIView cached before the style finished loading (same idiom as route).
            updateOwnship(lastOwnship, course: lastOwnCourse, on: mapView)
            updateTraffic(lastTraffic, on: mapView)
            updateTFRs(cachedTFRs, on: mapView)
            updatePlate(plateState, on: mapView)
        }

        /// Load the chart packs under the region the user settles on (as MapHostView does), so panning the
        /// globe pulls in coverage; and refresh the vector overlays for the new region. DEBOUNCED 0.4s (like
        /// the production MK coordinator) so a momentum pan / pinch burst coalesces to ONE pack-load + overlay
        /// refresh instead of firing redundant network downloads + off-main DB scans on every settle.
        func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) {
            regionDebounce?.cancel()
            let work = DispatchWorkItem { [weak self, weak mapView] in
                guard let self, let mapView else { return }
                self.ensureVisiblePacks(mapView)
                self.refreshOverlays(mapView)
            }
            regionDebounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        }

        // MARK: airspace + airways overlays (milestone 2)

        /// Create the persistent overlay sources + layers ONCE (empty). Per-region refresh only mutates
        /// `source.shape` — so we never remove a source a layer still uses (MapLibre would throw). Stacking:
        /// airways below airspace below route, all above the FAA/OSM rasters.
        private func setupOverlayLayers(_ style: MLNStyle) {
            setupAirwayAirspaceLayers(style)   // airways-line + airspace fill/outline (below labels)
            setupLabelLayers(style)            // airway idents + airspace altitude blocks (SDF text)
            setupNavLayers(style)              // FAA nav glyphs + idents
            setupDynamicLayers(style)          // TFR/route/traffic/ownship (empty; driven by updateUIView)
        }

        /// Airways line + airspace fill/outline, stacked bottom-most of the vector context.
        private func setupAirwayAirspaceLayers(_ style: MLNStyle) {
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
        }

        /// TEXT LABELS (need the bundled SDF glyphs, wired via the style's "glyphs" URL): airway idents +
        /// airspace altitude blocks. The airway label reuses the already-added "airways" source.
        private func setupLabelLayers(_ style: MLNStyle) {
            guard let awySrc = style.source(withIdentifier: "airways") as? MLNShapeSource else { return }
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

        /// NAV SYMBOLS — FAA glyphs (VOR/VORTAC/NDB/fix/airport) as an icon-image layer with the ident
        /// below, above airspace so navaids read clearly. Reuses the app's exact symbols.
        private func setupNavLayers(_ style: MLNStyle) {
            registerNavImages(style)
            let navSrc = MLNShapeSource(identifier: "nav", shape: nil, options: nil)
            style.addSource(navSrc)
            let nav = MLNSymbolStyleLayer(identifier: "nav-sym", source: navSrc)
            nav.iconImageName = NSExpression(forKeyPath: "glyph")       // "nav-vor" / "nav-fix" / … set per feature
            nav.iconAllowsOverlap = NSExpression(forConstantValue: false)
            nav.text = NSExpression(forKeyPath: "ident")
            nav.textFontNames = NSExpression(forConstantValue: ["Arial Bold"])
            nav.textFontSize = NSExpression(forConstantValue: 9)
            nav.textColor = NSExpression(forConstantValue: UIColor.white)
            nav.textHaloColor = NSExpression(forConstantValue: UIColor.black.withAlphaComponent(0.85))
            nav.textHaloWidth = NSExpression(forConstantValue: 1.2)
            nav.textAnchor = NSExpression(forConstantValue: "top")      // ident under the glyph
            nav.textOffset = NSExpression(forConstantValue: NSValue(cgVector: CGVector(dx: 0, dy: 0.9)))
            nav.textOptional = NSExpression(forConstantValue: true)     // drop the ident before the glyph on collision
            nav.minimumZoomLevel = 5.5
            style.addLayer(nav)
        }

        /// TFR + route + traffic + ownship layers (empty; driven by updateUIView, not by region). Stacked on
        /// top of the static context so the route/traffic/ownship read above everything (as MK annotations do).
        private func setupDynamicLayers(_ style: MLNStyle) {
            let red = ChartMapView.Coordinator.airspaceColor("TFR")     // #F71433 — reuse, no hand-typed hex
            let tfrSrc = MLNShapeSource(identifier: "tfr", shape: nil, options: nil); style.addSource(tfrSrc)
            let tfrFill = MLNFillStyleLayer(identifier: "tfr-fill", source: tfrSrc)   // no minzoom: TFRs show at any zoom
            tfrFill.fillColor = NSExpression(forConstantValue: red); tfrFill.fillOpacity = NSExpression(forConstantValue: 0.18)
            style.addLayer(tfrFill)
            let tfrLine = MLNLineStyleLayer(identifier: "tfr-outline", source: tfrSrc)
            tfrLine.lineColor = NSExpression(forConstantValue: red); tfrLine.lineWidth = NSExpression(forConstantValue: 2.4)
            tfrLine.lineCap = NSExpression(forConstantValue: "round"); tfrLine.lineJoin = NSExpression(forConstantValue: "round")
            style.addLayer(tfrLine)
            let tfrLblSrc = MLNShapeSource(identifier: "tfr-labels", shape: nil, options: nil); style.addSource(tfrLblSrc)
            let tfrLbl = MLNSymbolStyleLayer(identifier: "tfr-label", source: tfrLblSrc)
            tfrLbl.text = NSExpression(forKeyPath: "alt"); tfrLbl.textFontNames = NSExpression(forConstantValue: ["Arial Bold"])
            tfrLbl.textFontSize = NSExpression(forConstantValue: 9); tfrLbl.textColor = NSExpression(forConstantValue: red)
            tfrLbl.textHaloColor = NSExpression(forConstantValue: UIColor.black.withAlphaComponent(0.6))
            tfrLbl.textHaloWidth = NSExpression(forConstantValue: 1.2); tfrLbl.textLineHeight = NSExpression(forConstantValue: 1.0)
            tfrLbl.minimumZoomLevel = 5.0
            style.addLayer(tfrLbl)

            // Route (persistent source so ownship/traffic can sit above it).
            let routeSrc = MLNShapeSource(identifier: "route", shape: nil, options: nil); style.addSource(routeSrc)
            let route = MLNLineStyleLayer(identifier: "route-line", source: routeSrc)
            route.lineColor = NSExpression(forConstantValue: UIColor(red: 0.95, green: 0.24, blue: 0.62, alpha: 1))
            route.lineWidth = NSExpression(forConstantValue: 3.0)
            route.lineCap = NSExpression(forConstantValue: "round"); route.lineJoin = NSExpression(forConstantValue: "round")
            style.addLayer(route)

            style.setImage(ChartMapView.Coordinator.traffic, forName: "own-traffic")
            style.setImage(ChartMapView.Coordinator.ownPlane, forName: "own-ship")
            let trafficSrc = MLNShapeSource(identifier: "traffic", shape: nil, options: nil); style.addSource(trafficSrc)
            let traffic = MLNSymbolStyleLayer(identifier: "traffic-sym", source: trafficSrc)
            traffic.iconImageName = NSExpression(forConstantValue: "own-traffic")
            traffic.iconRotation = NSExpression(forKeyPath: "rot")          // pre-baked (track - 90)
            traffic.iconRotationAlignment = NSExpression(forConstantValue: "map")
            traffic.iconAllowsOverlap = NSExpression(forConstantValue: true)   // traffic must never collide away
            traffic.iconIgnoresPlacement = NSExpression(forConstantValue: true)
            style.addLayer(traffic)
            let ownSrc = MLNShapeSource(identifier: "ownship", shape: nil, options: nil); style.addSource(ownSrc)
            let own = MLNSymbolStyleLayer(identifier: "ownship-sym", source: ownSrc)
            own.iconImageName = NSExpression(forConstantValue: "own-ship")
            own.iconRotation = NSExpression(forKeyPath: "rot")             // pre-baked (course - 90)
            own.iconRotationAlignment = NSExpression(forConstantValue: "map")
            own.iconAllowsOverlap = NSExpression(forConstantValue: true)
            own.iconIgnoresPlacement = NSExpression(forConstantValue: true)
            style.addLayer(own)
        }

        /// Register the FAA nav glyphs (reusing the app's exact NearbyMarkerView drawings) under the names
        /// the layer's `iconImageName` expression selects per feature. Idempotent.
        private func registerNavImages(_ style: MLNStyle) {
            let images: [String: UIImage] = [
                "nav-airport": NearbyMarkerView.airportGlyphImage,
                "nav-fix": NearbyMarkerView.fixGlyphImage,
                "nav-vor": NearbyMarkerView.navaidGlyph("VOR"),
                "nav-vortac": NearbyMarkerView.navaidGlyph("VORTAC"),
                "nav-vordme": NearbyMarkerView.navaidGlyph("VOR-DME"),
                "nav-ndb": NearbyMarkerView.navaidGlyph("NDB"),
                "nav-ndbdme": NearbyMarkerView.navaidGlyph("NDB-DME"),
                "nav-tacan": NearbyMarkerView.navaidGlyph("TACAN"),
                "nav-dme": NearbyMarkerView.navaidGlyph("DME"),
            ]
            assert(images.count == 9, "expected 9 nav glyphs")
            assert(images.values.allSatisfy { $0.size.width > 0 }, "a nav glyph failed to render")
            for (name, img) in images { style.setImage(img, forName: name) }   // bounded (rule 2)
        }

        /// The registered image name for a nav point, mirroring NearbyMarkerView.navaidGlyph's classification.
        static func glyphName(_ np: NavPoint) -> String {
            switch np.kind {
            case .airport: return "nav-airport"
            case .vor:     return navGlyph(forType: NavMeta.navaid(np.ident)?.type ?? "VOR")
            default:       return "nav-fix"
            }
        }

        /// Pure classification of a navaid's FAA type string → glyph name. Extracted from glyphName so it's
        /// unit-testable with NO NavMeta/DB dependency. Order matters: TACAN and the *DME combinations are
        /// checked before the plain-VOR fallback (a TACAN/DME must NOT imply a VOR glyph).
        static func navGlyph(forType rawType: String) -> String {
            let t = rawType.uppercased()
            if t == "TACAN" { return "nav-tacan" }
            if t.contains("VORTAC") { return "nav-vortac" }
            if t.contains("NDB"), t.contains("DME") { return "nav-ndbdme" }
            if t.contains("NDB") { return "nav-ndb" }
            if t == "DME" { return "nav-dme" }
            if t.contains("DME") { return "nav-vordme" }
            return "nav-vor"
        }

        /// Query the vector overlays for the settled region OFF-MAIN (gated on angular scale, exactly like
        /// refreshContext), then set the features on the persistent sources on the main actor. Orchestrator
        /// only — the per-overlay feature building lives in the bounded static builders below (rule 4).
        private func refreshOverlays(_ mapView: MLNMapView) {
            let b = mapView.visibleCoordinateBounds
            guard b.ne.latitude > b.sw.latitude, b.ne.longitude > b.sw.longitude else { return }  // antimeridian/degenerate
            // Visible span in degrees. Mirror the production MK gate max(latΔ, lonΔ·cos(lat)) — a lat-only
            // scale UNDER-estimates the span in landscape (the common iPad-in-cockpit orientation, where the
            // longitude span dominates), which would flood the map with nav/fix/airway features + labels the
            // production map suppresses at that zoom.
            let latD = b.ne.latitude - b.sw.latitude
            let lonD = b.ne.longitude - b.sw.longitude
            let midLat = (b.ne.latitude + b.sw.latitude) * 0.5
            let scale = max(latD, lonD * cos(midLat * .pi / 180))
            assert(scale > 0, "refreshOverlays: non-positive scale")
            assert(overlayGen >= 0, "refreshOverlays: generation underflow")
            let m = 0.15
            let bb = BBox(minLat: b.sw.latitude - latD * m, minLon: b.sw.longitude - lonD * m,
                          maxLat: b.ne.latitude + latD * m, maxLon: b.ne.longitude + lonD * m)
            if scale < 2.2 { wantFixes = true } else if scale > 2.7 { wantFixes = false }   // hysteresis dead band
            let wantAir = scale < 14, wantLbl = scale < 7, wantAwy = scale < 9, wantNear = scale < 5.5
            let showFixes = wantNear && wantFixes
            overlayGen += 1
            let gen = overlayGen
            Task { @MainActor in
                let f = await Task.detached(priority: .userInitiated) {
                    () -> (asp: [MLNPolygonFeature], lbl: [MLNPointFeature], awy: [MLNPolylineFeature], nav: [MLNPointFeature]) in
                    let a = Coordinator.airspaceFeatures(bb, want: wantAir, labels: wantLbl)
                    return (a.polys, a.labels, Coordinator.airwayFeatures(bb, want: wantAwy),
                            Coordinator.navFeatures(bb, near: wantNear, fixes: showFixes))
                }.value
                guard gen == self.overlayGen, let style = mapView.style else { return }
                (style.source(withIdentifier: "airspace") as? MLNShapeSource)?.shape = MLNShapeCollectionFeature(shapes: f.asp)
                (style.source(withIdentifier: "airspace-labels") as? MLNShapeSource)?.shape = MLNShapeCollectionFeature(shapes: f.lbl)
                (style.source(withIdentifier: "airways") as? MLNShapeSource)?.shape = MLNShapeCollectionFeature(shapes: f.awy)
                (style.source(withIdentifier: "nav") as? MLNShapeSource)?.shape = MLNShapeCollectionFeature(shapes: f.nav)
            }
        }

        /// Airspace polygons (1 per ring, "cls" attr) + altitude-block points, capped + safety-sorted like
        /// refreshContext. nonisolated (runs in the detached task). Bounded loops (rule 2), >=2 assertions.
        static func airspaceFeatures(_ bb: BBox, want: Bool, labels: Bool) -> (polys: [MLNPolygonFeature], labels: [MLNPointFeature]) {
            assert(bb.minLat <= bb.maxLat && bb.minLon <= bb.maxLon, "airspaceFeatures: degenerate box")
            guard want else { return ([], []) }
            let order: [String: Int] = ["TFR": 0, "P": 1, "R": 2, "B": 3, "C": 4, "W": 5, "MOA": 6, "A": 7, "D": 8]
            let list = NavDatabase.airspaces(intersecting: bb)
                .sorted { (order[$0.cls] ?? 9, $0.name) < (order[$1.cls] ?? 9, $1.name) }
            var polys: [MLNPolygonFeature] = []
            building: for a in list {
                for ring in a.rings {                                      // bounded by the 260 cap
                    var c = ring.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
                    let f = MLNPolygonFeature(coordinates: &c, count: UInt(c.count))
                    var at: [String: Any] = ["cls": a.cls, "name": a.name]   // name/floor/ceiling for the tap card
                    if let fl = a.floorFt { at["floorFt"] = fl }
                    if let cl = a.ceilingFt { at["ceilingFt"] = cl }         // omit nil ints (MLN attrs reject NSNull)
                    f.attributes = at
                    polys.append(f)
                    if polys.count >= 260 { break building }
                }
            }
            var lbls: [MLNPointFeature] = []
            if labels {
                for a in list where lbls.count < 140 {                     // bounded (rule 2)
                    guard let top = a.rings.flatMap({ $0 }).max(by: { $0.lat < $1.lat }) else { continue }
                    let f = MLNPointFeature()
                    f.coordinate = CLLocationCoordinate2D(latitude: top.lat, longitude: top.lon)
                    f.attributes = ["cls": a.cls,
                                    "alt": "\(AirspaceLabelAnnotation.altText(a.ceilingFt))\n\(AirspaceLabelAnnotation.altText(a.floorFt))"]
                    lbls.append(f)
                }
            }
            assert(polys.count <= 260 && lbls.count <= 140, "airspaceFeatures: caps exceeded")
            return (polys, lbls)
        }

        /// One polyline per already-split airway run. nonisolated. Bounded by Airways.inRegion's own caps.
        static func airwayFeatures(_ bb: BBox, want: Bool) -> [MLNPolylineFeature] {
            assert(bb.minLat <= bb.maxLat, "airwayFeatures: degenerate box")
            guard want else { return [] }
            var out: [MLNPolylineFeature] = []
            for seg in Airways.inRegion(bb) where seg.points.count >= 2 {   // bounded (Airways caps at 80 idents)
                var c = seg.points.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
                let f = MLNPolylineFeature(coordinates: &c, count: UInt(c.count))
                f.attributes = ["ident": seg.ident, "area": seg.area]      // for the future tap card
                out.append(f)
            }
            assert(out.count <= 4096, "airwayFeatures: unexpectedly many runs")
            return out
        }

        /// Nearby airports/navaids (+ terminal/approach fixes when zoomed in), one point each carrying its
        /// FAA-glyph name + ident. Deduped by ident. nonisolated. Bounded by the query limits (rule 2).
        static func navFeatures(_ bb: BBox, near: Bool, fixes: Bool) -> [MLNPointFeature] {
            assert(bb.minLat <= bb.maxLat, "navFeatures: degenerate box")
            guard near else { return [] }
            var out: [MLNPointFeature] = []
            var seen = Set<String>()
            for np in NavDatabase.nearby(bb, types: [0, 1], limit: 160) where seen.insert(np.ident).inserted {
                out.append(navFeature(np))
            }
            if fixes {
                for np in NavDatabase.nearby(bb, types: [2], limit: 90) where seen.insert(np.ident).inserted {
                    out.append(navFeature(np))
                }
                for np in CIFP.terminalFixes(inRegion: bb, limit: 120) where seen.insert(np.ident).inserted {
                    out.append(navFeature(np))
                }
            }
            assert(out.count <= 370, "navFeatures: exceeded the combined query cap")
            return out
        }
        private static func navFeature(_ np: NavPoint) -> MLNPointFeature {
            let f = MLNPointFeature()
            f.coordinate = CLLocationCoordinate2D(latitude: np.coord.lat, longitude: np.coord.lon)
            f.attributes = ["glyph": glyphName(np), "ident": np.ident]
            return f
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
                // Re-add the FAA source so MapLibre re-requests tiles it 404'd while the server had no packs.
                // Fire it on the FIRST empty→non-empty transition too (not just a per-call count delta): the
                // screen may prefetch the route corridor before the style finishes loading, so by didFinishLoading
                // the readers are already populated and a delta-only gate would leave the chart blank at launch.
                let becameNonEmpty = !serverHadReaders && !store.readers.isEmpty
                serverHadReaders = !store.readers.isEmpty
                if (store.readers.count != before || becameNonEmpty), serverPort > 0, let style = mapView.style {
                    // ORDER MATTERS: MapLibre throws if you remove a source still used by a layer — remove the
                    // LAYER first, then the source.
                    if let faaLayer = style.layer(withIdentifier: "faa") { style.removeLayer(faaLayer) }
                    if let src = style.source(withIdentifier: "faa") { style.removeSource(src) }
                    // Cap the source maxzoom at the mounted packs' real max so MapLibre clamps requests (the
                    // server also overzooms past it), instead of the hardcoded 16 that spammed 404s past ~z11.
                    let faaMax = store.readers.map(\.maxZoom).max() ?? 16
                    let fresh = MLNRasterTileSource(identifier: "faa",
                        tileURLTemplates: ["http://127.0.0.1:\(serverPort)/{z}/{x}/{y}"],
                        options: [.tileSize: 256,
                                  .maximumZoomLevel: NSNumber(value: faaMax + MBTilesTileOverlay.overzoomLevels)])
                    style.addSource(fresh)
                    // INSERT the raster at the BOTTOM (below the first vector layer) so a pack re-mount never
                    // lifts the chart above the airspace/nav/plate overlays.
                    let faaRaster = MLNRasterStyleLayer(identifier: "faa", source: fresh)
                    if let bottom = style.layer(withIdentifier: "airways-line") {
                        style.insertLayer(faaRaster, below: bottom)
                    } else {
                        style.addLayer(faaRaster)
                    }
                }
            }
        }

        // MARK: route line

        func updateRoute(_ coords: [CLLocationCoordinate2D], on mapView: MLNMapView) {
            routeCoords = coords
            guard let src = mapView.style?.source(withIdentifier: "route") as? MLNShapeSource else { return }
            let sig = coords.map { "\(Self.q($0.latitude)),\(Self.q($0.longitude))" }.joined(separator: "|")
            guard sig != appliedRouteSig else { return }                 // unchanged → skip the re-tessellation
            appliedRouteSig = sig
            guard coords.count >= 2 else { src.shape = nil; return }
            var c = coords
            src.shape = MLNPolylineFeature(coordinates: &c, count: UInt(c.count))
        }

        // MARK: ownship + traffic (milestone 5)

        private var lastOwnship: CLLocationCoordinate2D?
        private var lastOwnCourse: Double?
        private var lastTraffic: [Aircraft] = []
        // Last-APPLIED signatures — early-return guards so an unrelated AppModel publish (e.g. the audio VU
        // meter, ~10-30×/s) can't re-tessellate + re-upload unchanged route/ownship/traffic/TFR geometry.
        // These are the map inputs' identity, distinct from the last-INPUT caches above (which exist so
        // didFinishLoading can re-apply). Set ONLY after a real apply, so the first post-style apply still runs.
        private var appliedRouteSig: String?
        private var appliedOwnSig: String?
        private var appliedTrafficSig: String?
        private var appliedTFRSig: String?
        static func q(_ v: Double) -> Int { Int((v * 100_000).rounded()) }   // ~1 m quantization, kills float jitter

        /// A single static ownship marker (no pulsing showsUserLocation dot — we render our own). The SF
        /// "airplane" glyph draws nose-EAST, so rot = course - 90 to make the nose point along the heading.
        func updateOwnship(_ coord: CLLocationCoordinate2D?, course: Double?, on map: MLNMapView) {
            lastOwnship = coord; lastOwnCourse = course
            guard let src = map.style?.source(withIdentifier: "ownship") as? MLNShapeSource else { return }
            let sig = coord.map { "\(Self.q($0.latitude)),\(Self.q($0.longitude)),\(Int((course ?? 0).rounded()))" } ?? "nil"
            guard sig != appliedOwnSig else { return }
            appliedOwnSig = sig
            guard let coord else { src.shape = nil; return }             // no fix → hide (MK removes the annotation)
            let f = MLNPointFeature(); f.coordinate = coord
            f.attributes = ["rot": (course.map { $0 - 90 } ?? 0)]
            src.shape = f
        }

        /// Live ADS-B/Stratux traffic, deduped by ICAO hex, rotated by track. Bounded (rule 2).
        func updateTraffic(_ aircraft: [Aircraft], on map: MLNMapView) {
            lastTraffic = aircraft
            guard let src = map.style?.source(withIdentifier: "traffic") as? MLNShapeSource else { return }
            var seen = Set<String>(); var out: [MLNPointFeature] = []; var sigs: [String] = []
            for ac in aircraft.prefix(128) {                             // bounded (rule 2)
                guard let c = ac.coordinate, !ac.hex.isEmpty, seen.insert(ac.hex).inserted else { continue }
                let f = MLNPointFeature()
                f.coordinate = CLLocationCoordinate2D(latitude: c.lat, longitude: c.lon)
                f.attributes = ["rot": (ac.trackDeg ?? 0) - 90, "hex": ac.hex, "label": ac.label ?? "Traffic"]
                out.append(f)
                sigs.append("\(ac.hex):\(Self.q(c.lat)),\(Self.q(c.lon)),\(Int((ac.trackDeg ?? 0).rounded()))")
            }
            assert(out.count <= 128, "updateTraffic: field bound exceeded")
            assert(seen.count == out.count, "updateTraffic: dedup/emit mismatch")
            let sig = sigs.sorted().joined(separator: "|")               // order-independent snapshot identity
            guard sig != appliedTrafficSig else { return }
            appliedTrafficSig = sig
            src.shape = MLNShapeCollectionFeature(shapes: out)
        }

        // MARK: live TFRs (milestone 6)

        func updateTFRs(_ tfrs: [TFR], on map: MLNMapView) {
            cachedTFRs = tfrs
            tfrByID = Dictionary(tfrs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            guard let style = map.style else { return }                  // style not up yet → didFinishLoading re-applies
            let sig = tfrs.map { "\($0.id):\($0.polygon.count):\($0.ceilingFt ?? -1):\($0.floorFt ?? -1)" }
                .sorted().joined(separator: "|")
            guard sig != appliedTFRSig else { return }                   // unchanged TFR set → skip rebuild
            appliedTFRSig = sig
            let f = Coordinator.tfrFeatures(tfrs)
            (style.source(withIdentifier: "tfr") as? MLNShapeSource)?.shape = MLNShapeCollectionFeature(shapes: f.polys)
            (style.source(withIdentifier: "tfr-labels") as? MLNShapeSource)?.shape = MLNShapeCollectionFeature(shapes: f.labels)
        }

        /// One polygon per TFR (single ring) + an altitude-block point. nonisolated; bounded; >=2 assertions.
        static func tfrFeatures(_ tfrs: [TFR]) -> (polys: [MLNPolygonFeature], labels: [MLNPointFeature]) {
            assert(tfrs.count <= 4096, "tfrFeatures: absurd TFR count")
            var polys: [MLNPolygonFeature] = []; var lbls: [MLNPointFeature] = []
            for t in tfrs.prefix(400) where t.polygon.count >= 3 {       // bounded + ring guard (TFRMapLayer)
                var c = t.polygon.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
                let f = MLNPolygonFeature(coordinates: &c, count: UInt(c.count))
                f.attributes = ["id": t.id, "cls": "TFR"]
                polys.append(f)
                if let top = t.labelCoord {
                    let p = MLNPointFeature(); p.coordinate = CLLocationCoordinate2D(latitude: top.lat, longitude: top.lon)
                    p.attributes = ["alt": "\(AirspaceLabelAnnotation.altText(t.ceilingFt))\n\(AirspaceLabelAnnotation.altText(t.floorFt))"]
                    lbls.append(p)
                }
            }
            assert(polys.count <= 400, "tfrFeatures: cap exceeded")
            return (polys, lbls)
        }

        // MARK: georeferenced plate overlay (milestone 7)

        /// Add / update-in-place / remove the overlaid approach plate as an MLNImageSource (a warped raster
        /// from the 4 geo corners). rasterOpacity + image swap are honored GPU props — no rebuild, no mask
        /// hack (the layer covers the context labels via z-order, yet stays BELOW ownship/traffic).
        func updatePlate(_ s: PlateOverlayState?, on map: MLNMapView) {
            plateState = s
            guard let style = map.style else { return }
            assert(Thread.isMainThread, "updatePlate off the main thread")
            guard let s else {
                if let l = style.layer(withIdentifier: "plate-raster") { style.removeLayer(l) }
                if let src = style.source(withIdentifier: "plate") { style.removeSource(src) }
                plateKey = nil; plateOpacity = nil; plateInverted = nil; plateImageKey = nil; return
            }
            assert((0.0...1.0).contains(s.opacity), "plate opacity out of range")
            // The plate's RENDERED-bitmap identity: pdf selects the page, inverted selects normal/night render.
            // geoKey is PLACEMENT-only, so without this the raster would go stale on a plate SWAP (a pilot would
            // see the WRONG approach chart warped onto the new airport's footprint) — a safety-critical bug.
            let imgKey = "\(s.pdf)|\(s.inverted)"
            if let src = style.source(withIdentifier: "plate") as? MLNImageSource,
               let layer = style.layer(withIdentifier: "plate-raster") as? MLNRasterStyleLayer {
                if plateKey != s.geoKey { src.coordinates = Coordinator.plateQuad(s) }
                if plateImageKey != imgKey { src.image = s.displayImage }   // refresh on plate swap OR invert
                if plateOpacity != s.opacity { layer.rasterOpacity = NSExpression(forConstantValue: s.opacity) }
            } else {
                let src = MLNImageSource(identifier: "plate", coordinateQuad: Coordinator.plateQuad(s), image: s.displayImage)
                style.addSource(src)
                let layer = MLNRasterStyleLayer(identifier: "plate-raster", source: src)
                layer.rasterOpacity = NSExpression(forConstantValue: s.opacity)
                layer.rasterOpacityTransition = MLNTransition(duration: 0, delay: 0)   // slider must be instant
                // Insert BELOW traffic/ownship so the 70%-opaque plate never washes out the ownship chevron
                // (MK draws annotations above overlays; without this the port inverts that safety-critical order).
                // Still above nav/airway/airspace labels (created earlier), so it covers the context labels.
                if let above = style.layer(withIdentifier: "traffic-sym") {
                    style.insertLayer(layer, below: above)
                } else {
                    style.addLayer(layer)
                }
            }
            plateKey = s.geoKey; plateOpacity = s.opacity; plateInverted = s.inverted; plateImageKey = imgKey
        }

        /// The 4 geo corners as an MLNCoordinateQuad {topLeft, bottomLeft, bottomRight, topRight}.
        static func plateQuad(_ s: PlateOverlayState) -> MLNCoordinateQuad {
            func corner(_ dx: Double, _ dy: Double) -> CLLocationCoordinate2D {
                PlatePlacement.corner(centerLat: s.centerLat, centerLon: s.centerLon,
                                      widthMeters: s.widthMeters, heightMeters: s.heightMeters,
                                      rotationDeg: s.rotationDeg, dxSign: dx, dySign: dy)
            }
            return MLNCoordinateQuadMake(corner(-1, 1), corner(-1, -1), corner(1, -1), corner(1, 1))
        }

        // MARK: tap-to-identify (milestone 8)

        @objc func handleTap(_ gr: UITapGestureRecognizer) {
            guard let mv = map, gr.state == .ended else { return }
            probe(at: gr.location(in: mv), in: mv, radius: 24, userPoint: false)
        }
        @objc func handleLongPress(_ gr: UILongPressGestureRecognizer) {
            guard gr.state == .began, let mv = map else { return }
            probe(at: gr.location(in: mv), in: mv, radius: 40, userPoint: true)
        }

        /// Identify what's under the finger and present the same object card. Navaids/airports/fixes come
        /// from a DB box-scan (NOT the rendered nav-sym layer) so collision-suppressed / below-min-zoom
        /// symbols the pilot still sees on the FAA raster stay identifiable — mirroring the production probe.
        /// Airways/airspace/TFR/traffic are geometric, so MapLibre's rendered-feature hit-test is legitimate.
        /// Main-actor + synchronous (one tap = one small SQLite query — no continuous-scan jank concern).
        private func probe(at pt: CGPoint, in mv: MLNMapView, radius: CGFloat, userPoint: Bool) {
            assert(radius > 0, "probe: non-positive radius")
            let ll = mv.convert(pt, toCoordinateFrom: mv)
            let here = Coord(lat: ll.latitude, lon: ll.longitude)
            let rect = CGRect(x: pt.x - radius, y: pt.y - radius, width: radius * 2, height: radius * 2)
            func dist(_ c: CLLocationCoordinate2D) -> Double { let s = mv.convert(c, toPointTo: mv); return Double(hypot(s.x - pt.x, s.y - pt.y)) }
            func dist(_ c: Coord) -> Double { dist(CLLocationCoordinate2D(latitude: c.lat, longitude: c.lon)) }
            var cands: [(object: IdentifiedObject, distance: Double)] = []
            // Navaids/airports/fixes: DB scan over a box ~2.5× the tap radius (matches beginProbe), ranked by
            // ON-SCREEN distance so collision-hidden symbols are found. Deduped by ident.
            let off = mv.convert(CGPoint(x: pt.x + radius * 2.5, y: pt.y + radius * 2.5), toCoordinateFrom: mv)
            let dLat = max(abs(ll.latitude - off.latitude), 0.002), dLon = max(abs(ll.longitude - off.longitude), 0.002)
            let box = BBox(minLat: ll.latitude - dLat, minLon: ll.longitude - dLon,
                           maxLat: ll.latitude + dLat, maxLon: ll.longitude + dLon)
            var seen = Set<String>()
            for np in NavDatabase.nearby(box, types: [0, 1, 2], limit: 40) where seen.insert(np.ident).inserted {
                cands.append((IdentifiedObject(kind: MapObjectKind(routeKind: np.kind), ident: np.ident,
                                               coord: np.coord, onRoute: routeIdents.contains(np.ident)), dist(np.coord)))
            }
            // Live ADS-B/Stratux traffic under the finger — the traffic-sym layer (always rendered:
            // iconAllowsOverlap). ident = the "label" attr so MapObjectView resolves the live Aircraft.
            for f in mv.visibleFeatures(in: rect, styleLayerIdentifiers: ["traffic-sym"]) {
                guard let label = f.attributes["label"] as? String else { continue }
                let c = (f as? MLNPointFeature)?.coordinate ?? ll
                cands.append((IdentifiedObject(kind: .traffic, ident: label,
                                               coord: Coord(lat: c.latitude, lon: c.longitude), onRoute: false), dist(c)))
            }
            for f in mv.visibleFeatures(in: rect, styleLayerIdentifiers: ["airways-line"]) {
                guard let id = f.attributes["ident"] as? String else { continue }
                cands.append((IdentifiedObject(kind: .airway, ident: id, coord: here, onRoute: false,
                                               airwayArea: (f.attributes["area"] as? String) ?? "USA"), 0))
            }
            var results = MapProbe.rank(cands, within: Double(radius))
            for f in mv.visibleFeatures(in: rect, styleLayerIdentifiers: ["airspace-fill"]) {
                guard let cls = f.attributes["cls"] as? String, let name = f.attributes["name"] as? String else { continue }
                let asp = Airspace(id: 0, cls: cls, name: name,
                                   floorFt: (f.attributes["floorFt"] as? NSNumber)?.intValue,
                                   ceilingFt: (f.attributes["ceilingFt"] as? NSNumber)?.intValue,
                                   bb: BBox(minLat: here.lat, minLon: here.lon, maxLat: here.lat, maxLon: here.lon), rings: [])
                if !results.contains(where: { $0.kind == .airspace && $0.ident == name }) {
                    results.append(IdentifiedObject(kind: .airspace, ident: name, coord: here, onRoute: false, airspace: asp))
                }
            }
            for f in mv.visibleFeatures(in: rect, styleLayerIdentifiers: ["tfr-fill"]) {
                guard let id = f.attributes["id"] as? String, let t = tfrByID[id] else { continue }
                if !results.contains(where: { $0.tfr?.id == id }) {
                    results.append(IdentifiedObject(kind: .tfr, ident: id, coord: t.labelCoord ?? here, onRoute: false, tfr: t))
                }
            }
            if userPoint { results.insert(IdentifiedObject(kind: .userPoint, ident: UserPoint.token(here), coord: here, onRoute: false), at: 0) }
            guard !results.isEmpty else { return }
            onTapObjects?(results)
        }
    }
}

/// Full-screen host: owns a ChartStore, downloads the route corridor, and shows the globe chart with an
/// EXPERIMENTAL banner + ✕. Uses the app's filed plan if present, else a demo route.
struct MapLibreChartScreen: View {
    @ObservedObject var model: AppModel                 // re-render body on plate/tfr/aircraft @Published changes
    var onClose: (() -> Void)?
    @StateObject private var store = ChartStore(library: ChartLibrary.shared)
    @StateObject private var metars = MetarStore()      // the tapped-object card's env objects (may stay empty)
    @StateObject private var forecasts = ForecastStore()
    @StateObject private var tafs = TafStore()
    @State private var didLoad = false
    // Device GPS is a NESTED ObservableObject that doesn't republish the parent — bridge it like MapHostView.
    @State private var deviceCoord: Coord?
    @State private var deviceCourse: Double?
    @State private var probe: MapProbeResult?           // the tapped object(s) → object card sheet

    private var ownship: CLLocationCoordinate2D? {
        let c = model.stratuxGPS?.coordinate ?? deviceCoord
        return c.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
    }
    private var ownshipCourse: Double? { model.stratuxGPS?.coordinate == nil ? deviceCourse : nil }

    /// Only substitute the demo corridor when there's genuinely NO plan. A real filed plan wins even if it
    /// resolves to <2 legs — updateRoute then draws no line (count>=2 guard) rather than fabricating a
    /// Boston→JFK→DCA route and flagging KBOS/KJFK/KDCA as "on route" on a flight display (wrong data).
    private var legs: [ResolvedLeg] {
        guard let plan = model.flightPlan, !plan.isEmpty else { return Self.demoLegs }
        return ProcedureRoute.resolve(plan)
    }

    var body: some View {
        // Resolve the route ONCE per body eval (ProcedureRoute.resolve is not free) — was computed twice
        // via the old routeCoords + routeIdents properties on every @Published republish.
        let legs = self.legs
        let routeCoords = legs.map { CLLocationCoordinate2D(latitude: $0.coord.lat, longitude: $0.coord.lon) }
        return ZStack(alignment: .topLeading) {
            MapLibreChartView(store: store, routeCoords: routeCoords,
                              ownship: ownship, ownshipCourse: ownshipCourse,
                              traffic: model.aircraft, tfrs: model.tfrs, showTFRs: model.showTFRs,
                              plateOverlay: model.plateOverlay,
                              routeIdents: Set(legs.map { $0.ident }),
                              onTapObjects: { objs in
                                  guard !objs.isEmpty else { return }
                                  Haptics.impact(.light)
                                  probe = MapProbeResult(id: UUID().uuidString, objects: objs)
                              })
                .ignoresSafeArea()
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
                Text("FAA tiles + route + airspace/airways + nav symbols + ownship/traffic + TFR + plate + tap. 1:1 port.")
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
        .onAppear { model.deviceLocation.start() }
        .onReceive(model.deviceLocation.$coord) { deviceCoord = $0 }
        .onReceive(model.deviceLocation.$courseDeg) { deviceCourse = $0 }
        .sheet(item: $probe) { p in
            MapObjectSheet(result: p)
                .environmentObject(model)
                .environmentObject(metars)
                .environmentObject(forecasts)
                .environmentObject(tafs)
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
