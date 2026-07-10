import SwiftUI
import MapKit
import CoreLocation
import SQLite3
import UIKit

// MARK: - Local MBTiles reader

/// Reads XYZ tiles straight out of a local MBTiles (SQLite) file — the **offline** chart source, so
/// the chart works in the cockpit with no signal. MBTiles store rows in TMS (y from the bottom), so
/// we flip the incoming XYZ y. Opened read-only + full-mutex so MapKit's concurrent tile loads are
/// safe on the one connection. Built by `charts/build_chart.sh`; distributed via the HuggingFace
/// dataset `SingularityUS/faa-charts` and cached on-device.
final class MBTilesReader {
    private var db: OpaquePointer?
    let format: String
    let minZoom: Int
    let maxZoom: Int
    let bounds: MKMapRect

    init?(path: String) {
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if db != nil { sqlite3_close(db) }
            return nil
        }
        var meta: [String: String] = [:]
        var st: OpaquePointer?
        if sqlite3_prepare_v2(db, "select name,value from metadata", -1, &st, nil) == SQLITE_OK {
            while sqlite3_step(st) == SQLITE_ROW {
                if let k = sqlite3_column_text(st, 0), let v = sqlite3_column_text(st, 1) {
                    meta[String(cString: k)] = String(cString: v)
                }
            }
        }
        sqlite3_finalize(st)
        format = (meta["format"] ?? "png").lowercased()
        minZoom = Int(meta["minzoom"] ?? "") ?? 0
        maxZoom = Int(meta["maxzoom"] ?? "") ?? 16
        if let b = meta["bounds"]?.split(separator: ",").compactMap({ Double($0) }), b.count == 4 {
            let sw = MKMapPoint(CLLocationCoordinate2D(latitude: b[1], longitude: b[0]))
            let ne = MKMapPoint(CLLocationCoordinate2D(latitude: b[3], longitude: b[2]))
            bounds = MKMapRect(x: min(sw.x, ne.x), y: min(sw.y, ne.y),
                               width: abs(ne.x - sw.x), height: abs(ne.y - sw.y))
        } else {
            bounds = .world
        }
    }

    /// Integrity check used after a download — a truncated-but-openable SQLite has no tile rows.
    var hasTiles: Bool {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "select 1 from tiles limit 1", -1, &st, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(st) }
        return sqlite3_step(st) == SQLITE_ROW
    }

    func tileData(z: Int, x: Int, y: Int) -> Data? {
        let tmsY = (1 << z) - 1 - y
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db,
              "select tile_data from tiles where zoom_level=? and tile_column=? and tile_row=?",
              -1, &st, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_int(st, 1, Int32(z)); sqlite3_bind_int(st, 2, Int32(x)); sqlite3_bind_int(st, 3, Int32(tmsY))
        guard sqlite3_step(st) == SQLITE_ROW, let blob = sqlite3_column_blob(st, 0) else { return nil }
        return Data(bytes: blob, count: Int(sqlite3_column_bytes(st, 0)))
    }

    deinit { if db != nil { sqlite3_close(db) } }
}

/// Feeds tiles from an `MBTilesReader` into MapKit. MapKit renders PNG/JPEG tile data natively; WEBP
/// (which our packs use — ~10× smaller) is transcoded to PNG per tile via `UIImage`.
final class MBTilesTileOverlay: MKTileOverlay {
    private let reader: MBTilesReader
    private let transcode: Bool
    init(reader: MBTilesReader) {
        self.reader = reader
        self.transcode = (reader.format == "webp")
        super.init(urlTemplate: nil)
        canReplaceMapContent = false
        tileSize = CGSize(width: 256, height: 256)
        minimumZ = reader.minZoom
        maximumZ = reader.maxZoom
    }
    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        guard let raw = reader.tileData(z: path.z, x: path.x, y: path.y) else { result(nil, nil); return }
        if transcode, let png = UIImage(data: raw)?.pngData() { result(png, nil) }
        else { result(raw, nil) }
    }
}

// MARK: - Catalog (manifest of all packs) + layers

/// The manifest of every published chart pack (built by `charts/build_all_packs.sh`), fetched once
/// from HuggingFace. Each entry carries its geographic bounds so the app can pick the packs a route
/// crosses — or the packs under wherever you've panned — and download only those.
struct ChartCatalog: Decodable {
    let cycle: String
    let sectional: [Entry]
    let ifrLow: [Entry]

    struct Entry: Decodable, Identifiable, Hashable {
        let id: String
        let bounds: [Double]        // [west, south, east, north]
        let bytes: Int
        let path: String            // e.g. "sectional/New_York_SEC.mbtiles"

        static func == (a: Entry, b: Entry) -> Bool { a.id == b.id }
        func hash(into h: inout Hasher) { h.combine(id) }

        var mapRect: MKMapRect {
            guard bounds.count == 4 else { return .world }
            let sw = MKMapPoint(CLLocationCoordinate2D(latitude: bounds[1], longitude: bounds[0]))
            let ne = MKMapPoint(CLLocationCoordinate2D(latitude: bounds[3], longitude: bounds[2]))
            return MKMapRect(x: min(sw.x, ne.x), y: min(sw.y, ne.y), width: abs(ne.x - sw.x), height: abs(ne.y - sw.y))
        }
        var remote: URL { URL(string: "\(ChartCatalog.base)/\(path)")! }
    }

    static let base = "https://huggingface.co/datasets/SingularityUS/faa-charts/resolve/main"
    static let url = URL(string: "\(base)/index.json")!
}

/// A selectable base layer. `standard`/`satellite` are Apple's base map; the FAA layers are our
/// self-hosted raster charts (packs downloaded on demand from HuggingFace, then offline).
enum ChartLayer: String, CaseIterable, Identifiable {
    case sectional, ifrLow, standard, satellite
    var id: String { rawValue }
    var short: String {
        switch self { case .sectional: return "VFR"; case .ifrLow: return "IFR"; case .standard: return "Map"; case .satellite: return "Sat" }
    }
    var title: String {
        switch self { case .sectional: return "VFR sectional"; case .ifrLow: return "IFR low"; case .standard: return "Standard map"; case .satellite: return "Satellite" }
    }
    var mapType: MKMapType {
        switch self { case .satellite: return .hybrid; case .standard: return .standard; default: return .mutedStandard }
    }
    var isRaster: Bool { self == .sectional || self == .ifrLow }
    func entries(_ cat: ChartCatalog?) -> [ChartCatalog.Entry] {
        switch self { case .sectional: return cat?.sectional ?? []; case .ifrLow: return cat?.ifrLow ?? []; default: return [] }
    }
    /// Screenshot/demo: `--chart-layer vfr|ifr|std|sat` opens the chart on that layer.
    static var launchOverride: ChartLayer? {
        let a = ProcessInfo.processInfo.arguments
        guard let i = a.firstIndex(of: "--chart-layer"), i + 1 < a.count else { return nil }
        switch a[i + 1] { case "ifr": return .ifrLow; case "sat": return .satellite; case "std": return .standard; case "vfr": return .sectional; default: return nil }
    }
    /// Screenshot/demo: `--chart-center lat,lon` opens the chart framed there (tests free-pan loading
    /// with no filed route).
    static var launchCenter: CLLocationCoordinate2D? {
        let a = ProcessInfo.processInfo.arguments
        guard let i = a.firstIndex(of: "--chart-center"), i + 1 < a.count else { return nil }
        let p = a[i + 1].split(separator: ",").compactMap { Double($0) }
        guard p.count == 2 else { return nil }
        return CLLocationCoordinate2D(latitude: p[0], longitude: p[1])
    }
}

/// Grow a map rect by `f`× its size on every side (used for the "keep loaded" halo around the view).
private func inflated(_ r: MKMapRect, by f: Double) -> MKMapRect {
    MKMapRect(x: r.minX - r.width * f, y: r.minY - r.height * f, width: r.width * (1 + 2 * f), height: r.height * (1 + 2 * f))
}

// MARK: - Store (catalog + route + free-pan download, bounded)

/// Per-sheet display store: opens the MapKit tile readers for the packs a route crosses (up front,
/// ungated, pinned) plus the packs under wherever the map is panned/zoomed (free-pan, gated so we
/// never mass-download when zoomed out), and evicts readers that drift far from the view and aren't on
/// the route (their SQLite connection closes) to bound memory. The catalog fetch, the on-disk pack
/// cache, and downloading live in the shared `ChartLibrary` (warmed/prefetched before the map opens),
/// so this store mostly opens already-on-disk packs with no network. All state mutated on the main actor.
@MainActor final class ChartStore: ObservableObject {
    enum Phase: Equatable { case idle, loadingCatalog, downloading, ready, empty, zoomOut, failed(String) }
    @Published var phase: Phase = .idle
    @Published private(set) var readers: [MBTilesReader] = []

    private let library: ChartLibrary
    private var loaded: [String: (entry: ChartCatalog.Entry, reader: MBTilesReader)] = [:]  // current layer
    private var pinned: Set<String> = []          // route-corridor packs — never evicted
    private var inFlight: Set<String> = []
    private var layer: ChartLayer = .sectional

    private let autoLoadSpanLimit = 7.0           // ° — beyond this (zoomed out) free-pan waits
    private let keepHalo = 1.0                     // keep packs within this many view-widths of the view

    init(library: ChartLibrary) { self.library = library }

    private func publish() { readers = loaded.values.map { $0.reader } }

    /// Warm the shared catalog — usually already warm from launch, so this is a fast no-op path.
    private func ensureCatalog() async -> Bool {
        if library.catalog != nil { return true }
        if phase != .loadingCatalog { phase = .loadingCatalog }
        if await library.warm() { return true }
        phase = .failed("Chart index unavailable")
        return false
    }

    /// Switch layer (or initial load): reset all per-layer state and pull the packs the route crosses.
    func setLayer(_ newLayer: ChartLayer, routeRects: [MKMapRect]) async {
        layer = newLayer
        loaded.removeAll(); pinned.removeAll(); inFlight.removeAll(); publish()
        guard newLayer.isRaster else { phase = .ready; return }
        guard await ensureCatalog(), layer == newLayer else { return }
        if !routeRects.isEmpty {
            await load(rects: routeRects, gated: false, pin: true)   // route corridor, up front, pinned
        } else {
            phase = .empty
        }
    }

    /// Free-pan: ensure the packs under the visible region are loaded (gated by zoom/scope so panning
    /// around at a wide zoom doesn't mass-download), and evict packs that have drifted away.
    func ensureVisible(_ rect: MKMapRect, layer visibleLayer: ChartLayer) async {
        guard visibleLayer == layer, layer.isRaster, await ensureCatalog(), visibleLayer == layer else { return }
        await load(rects: [rect], gated: true, pin: false)
    }

    private func load(rects: [MKMapRect], gated: Bool, pin: Bool) async {
        guard let catalog = library.catalog, let primary = rects.first else { return }
        let activeLayer = layer
        if gated {
            let span = MKCoordinateRegion(primary).span
            if span.latitudeDelta > autoLoadSpanLimit || span.longitudeDelta > autoLoadSpanLimit {
                evict(near: rects)
                if loaded.isEmpty, inFlight.isEmpty, layer == activeLayer { phase = .zoomOut }
                return
            }
        }
        var todo = layer.entries(catalog).filter { e in
            loaded[e.id] == nil && !inFlight.contains(e.id) && rects.contains { e.mapRect.intersects($0) }
        }
        // Load in batches of 6 so a single pan never mass-downloads; if truncated we self-drive the rest.
        let truncated = gated && todo.count > 6
        if truncated { todo = Array(todo.prefix(6)) }
        guard !todo.isEmpty else {
            evict(near: rects)
            if inFlight.isEmpty, layer == activeLayer { phase = loaded.isEmpty ? (gated ? .zoomOut : .empty) : .ready }
            return
        }
        todo.forEach { inFlight.insert($0.id) }
        phase = .downloading
        var anyFailed = false
        for e in todo {
            if layer != activeLayer { return }                 // a layer switch superseded us — abort
            var reader = MBTilesReader(path: library.localURL(e).path)   // cached-on-disk hit (prefetched → instant)
            if reader == nil, let url = await library.ensureOnDisk(e) { reader = MBTilesReader(path: url.path) }
            inFlight.remove(e.id)
            if let reader, layer == activeLayer, loaded[e.id] == nil {
                loaded[e.id] = (e, reader)
                if pin { pinned.insert(e.id) }
                publish()
            } else if reader == nil {
                anyFailed = true
            }
        }
        evict(near: rects)
        // A stationary map fires no more regionDidChange, so drive the next batch ourselves until the
        // region is fully served (dedup shrinks todo by 6 each pass → terminates).
        if truncated, layer == activeLayer {
            await load(rects: rects, gated: gated, pin: pin)
            return
        }
        if inFlight.isEmpty, layer == activeLayer {
            phase = !loaded.isEmpty ? .ready : (anyFailed ? .failed("Chart download failed") : (gated ? .zoomOut : .empty))
        }
    }

    /// Bound memory: close packs that are neither pinned (on the route) nor near the current view.
    private func evict(near rects: [MKMapRect]) {
        let halos = rects.map { inflated($0, by: keepHalo) }
        let stale = loaded.filter { pair in
            !pinned.contains(pair.key) && !halos.contains(where: { pair.value.entry.mapRect.intersects($0) })
        }.map { $0.key }
        guard !stale.isEmpty else { return }
        for id in stale { loaded[id] = nil }                    // readers deinit → sqlite3_close
        publish()
    }
}

// MARK: - MKMapView chart view

/// The unified flight-plan map: the selected base layer (one or more seamless FAA raster packs, or
/// Apple's map) with the filed route (magenta line + waypoints), Class B/C/D airspace outlines and
/// nearby navaids/airports (bundled nav DB), your aircraft's live position (device GPS + Stratux), and
/// ADS-B traffic. As you pan/zoom, `onVisibleRegion` asks the store to load the charts under the new
/// area (free-pan) and the context layers refresh to what's in view. Uses `MKMapView` (SwiftUI's `Map`
/// can't host tile overlays).
struct ChartMapView: UIViewRepresentable {
    let layer: ChartLayer
    let readers: [MBTilesReader]
    let route: [ResolvedLeg]
    let showAirspace: Bool
    let showNearby: Bool
    let initialCenter: Coord?        // frame here when there's no filed route (device / Stratux position)
    let onVisibleRegion: (MKMapRect) -> Void
    @ObservedObject var model: AppModel

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let mv = MKMapView()
        mv.delegate = context.coordinator
        mv.pointOfInterestFilter = .excludingAll
        mv.showsCompass = true
        mv.showsUserLocation = true
        context.coordinator.requestLocation()
        mv.setRegion(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 39, longitude: -96),
                                        span: MKCoordinateSpan(latitudeDelta: 42, longitudeDelta: 55)), animated: false)
        return mv
    }

    func updateUIView(_ mv: MKMapView, context: Context) {
        let c = context.coordinator
        c.onVisibleRegion = onVisibleRegion
        if mv.mapType != layer.mapType { mv.mapType = layer.mapType }

        if !c.routeAdded, route.count >= 2 {              // route resolves after makeUIView
            let coords = route.map { $0.coord.clCoordinate }
            let line = MKPolyline(coordinates: coords, count: coords.count)
            mv.addOverlay(line, level: .aboveLabels)
            c.routeOverlay = line
            mv.addAnnotations(route.map { WaypointAnnotation($0) })
            c.routeAdded = true
            c.routeIdents = Set(route.map { $0.ident })   // so nearby context skips filed waypoints
        }

        // Incrementally reconcile the raster overlays to `readers` (they come and go as you pan). Tiles
        // sit at the bottom of the label level so airspace outlines + the route line draw over the chart.
        let want = Set(readers.map(ObjectIdentifier.init))
        for (rid, ov) in c.overlays where !want.contains(rid) { mv.removeOverlay(ov); c.overlays[rid] = nil }
        for r in readers {
            let rid = ObjectIdentifier(r)
            guard c.overlays[rid] == nil else { continue }
            let ov = MBTilesTileOverlay(reader: r)
            mv.insertOverlay(ov, at: 0, level: .aboveLabels)
            c.overlays[rid] = ov
        }

        if !c.didFrame {
            if route.count >= 2 {
                let coords = route.map { $0.coord.clCoordinate }
                var region = MKCoordinateRegion(MKPolyline(coordinates: coords, count: coords.count).boundingMapRect)
                region.span.latitudeDelta = min(region.span.latitudeDelta * 1.3 + 0.1, 4.5)
                region.span.longitudeDelta = min(region.span.longitudeDelta * 1.3 + 0.1, 5.0)
                mv.setRegion(region, animated: false)
                c.didFrame = true
            } else if let center = ChartLayer.launchCenter ?? initialCenter?.clCoordinate {
                mv.setRegion(MKCoordinateRegion(center: center, span: MKCoordinateSpan(latitudeDelta: 1.4, longitudeDelta: 1.4)), animated: false)
                c.didFrame = true
            }
        }

        // Context layers refresh when a toggle changes (region changes refresh via the delegate); the
        // first pass forces one so airspace/nearby appear without waiting for a pan.
        if c.showAirspace != showAirspace || c.showNearby != showNearby || !c.didContext {
            c.showAirspace = showAirspace; c.showNearby = showNearby; c.didContext = true
            c.refreshContext(mv)
        }

        c.syncDynamic(mv, aircraft: model.aircraft, ownship: model.stratuxGPS?.coordinate)
    }

    final class Coordinator: NSObject, MKMapViewDelegate, CLLocationManagerDelegate {
        var overlays: [ObjectIdentifier: MBTilesTileOverlay] = [:]
        var routeOverlay: MKPolyline?
        var routeAdded = false
        var routeIdents: Set<String> = []
        var didFrame = false
        var didContext = false
        var showAirspace = true
        var showNearby = true
        var onVisibleRegion: ((MKMapRect) -> Void)?
        private var regionDebounce: DispatchWorkItem?
        private var dynamic: [MKAnnotation] = []
        private var airspace: [MKPolygon] = []
        private var airspaceClass: [ObjectIdentifier: String] = [:]
        private var nearby: [NearbyAnnotation] = []
        private var lastTrafficKey: [String] = []
        private var lastOwnship: CLLocationCoordinate2D?
        private let loc = CLLocationManager()

        func requestLocation() {
            loc.delegate = self
            if loc.authorizationStatus == .notDetermined { loc.requestWhenInUseAuthorization() }
        }
        func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {}

        /// With no filed route to frame, center on the device GPS fix once it arrives (Stratux, when
        /// connected, frames immediately via `initialCenter`).
        func mapView(_ mv: MKMapView, didUpdate userLocation: MKUserLocation) {
            guard !didFrame, routeOverlay == nil, let c = userLocation.location?.coordinate else { return }
            mv.setRegion(MKCoordinateRegion(center: c, span: MKCoordinateSpan(latitudeDelta: 1.4, longitudeDelta: 1.4)), animated: false)
            didFrame = true
        }

        /// Free-pan trigger: debounce so we act once the map settles, then ask the store to load the
        /// packs under the new region and refresh the in-view context layers.
        func mapView(_ mv: MKMapView, regionDidChangeAnimated animated: Bool) {
            regionDebounce?.cancel()
            let rect = mv.visibleMapRect
            let cb = onVisibleRegion
            let work = DispatchWorkItem { [weak self, weak mv] in
                cb?(rect)
                if let self, let mv { self.refreshContext(mv) }
            }
            regionDebounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        }

        /// Recompute the in-view context layers (Class B/C/D airspace outlines + nearby navaids/airports)
        /// off-main for the settled region. Gated on angular scale so a zoomed-out view stays legible, and
        /// count-capped to keep MapKit snappy. Mirrors `RouteMapSheet`'s former overlay refresh.
        func refreshContext(_ mv: MKMapView) {
            let region = mv.region
            let scale = max(region.span.latitudeDelta,
                            region.span.longitudeDelta * cos(region.center.latitude * .pi / 180))
            let wantAir = showAirspace && scale < 14
            let wantNear = showNearby && scale < 5.5
            let bb = BBox(region: region, margin: 0.15)
            let idents = routeIdents
            Task { [weak self, weak mv] in
                let out = await Task.detached(priority: .userInitiated) {
                    () -> (rings: [(coords: [CLLocationCoordinate2D], cls: String)], near: [NavPoint]) in
                    var rings: [(coords: [CLLocationCoordinate2D], cls: String)] = []
                    if wantAir {
                        let order: [String: Int] = ["B": 0, "C": 1, "D": 2]
                        let asp = NavDatabase.airspaces(intersecting: bb)
                            .sorted { (order[$0.cls] ?? 9, $0.name) < (order[$1.cls] ?? 9, $1.name) }
                        building: for a in asp {
                            for ring in a.rings {
                                rings.append((ring.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }, a.cls))
                                if rings.count >= 260 { break building }
                            }
                        }
                    }
                    let near: [NavPoint] = wantNear
                        ? NavDatabase.nearby(bb, limit: 160).filter { !idents.contains($0.ident) }
                        : []
                    return (rings, near)
                }.value
                guard let self, let mv else { return }
                self.applyAirspace(out.rings, to: mv)
                self.applyNearby(out.near, to: mv)
            }
        }

        /// Replace the airspace polygons wholesale (only runs on a settled region). Inserted below the
        /// route line so the magenta route stays on top; class is tracked in a side map for the renderer.
        private func applyAirspace(_ rings: [(coords: [CLLocationCoordinate2D], cls: String)], to mv: MKMapView) {
            for p in airspace { mv.removeOverlay(p); airspaceClass[ObjectIdentifier(p)] = nil }
            airspace.removeAll()
            for r in rings {
                let p = MKPolygon(coordinates: r.coords, count: r.coords.count)
                airspaceClass[ObjectIdentifier(p)] = r.cls
                airspace.append(p)
                if let ro = routeOverlay { mv.insertOverlay(p, below: ro) } else { mv.addOverlay(p, level: .aboveLabels) }
            }
        }

        private func applyNearby(_ near: [NavPoint], to mv: MKMapView) {
            mv.removeAnnotations(nearby)
            nearby = near.map { NearbyAnnotation($0) }
            mv.addAnnotations(nearby)
        }

        // Sectional-style airspace colours: Class C solid magenta; Class B/D blue (D dashed, drawn thinner).
        static func airspaceColor(_ cls: String) -> UIColor {
            cls == "C" ? UIColor(red: 0.76, green: 0.09, blue: 0.36, alpha: 1)
                       : UIColor(red: 0.18, green: 0.44, blue: 0.93, alpha: 1)
        }

        func mapView(_ mv: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tile = overlay as? MKTileOverlay { return MKTileOverlayRenderer(tileOverlay: tile) }
            if let poly = overlay as? MKPolygon {
                let cls = airspaceClass[ObjectIdentifier(poly)] ?? "D"
                let color = Self.airspaceColor(cls)
                let r = MKPolygonRenderer(polygon: poly)
                r.strokeColor = color
                r.lineWidth = cls == "D" ? 1.2 : 1.5
                if cls == "D" { r.lineDashPattern = [4, 3] }
                r.fillColor = color.withAlphaComponent(0.05)
                return r
            }
            if let line = overlay as? MKPolyline {
                let r = MKPolylineRenderer(polyline: line)
                r.strokeColor = UIColor(red: 0.92, green: 0.10, blue: 0.55, alpha: 1)
                r.lineWidth = 3
                return r
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mv: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is MKUserLocation {
                let v = mv.dequeueReusableAnnotationView(withIdentifier: "me")
                    ?? MKAnnotationView(annotation: annotation, reuseIdentifier: "me")
                v.annotation = annotation
                v.image = Self.ownPlane
                let course = mv.userLocation.location?.course ?? -1
                v.transform = course < 0 ? .identity : CGAffineTransform(rotationAngle: CGFloat((course - 90) * .pi / 180))
                return v
            }
            switch annotation {
            case let w as WaypointAnnotation:
                let v = mv.dequeueReusableAnnotationView(withIdentifier: "wp") as? MKMarkerAnnotationView
                    ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: "wp")
                v.annotation = annotation; v.markerTintColor = w.tint; v.glyphText = w.glyph
                v.displayPriority = .required; v.titleVisibility = .adaptive; v.animatesWhenAdded = false
                return v
            case let n as NearbyAnnotation:
                let v = mv.dequeueReusableAnnotationView(withIdentifier: "near") as? NearbyMarkerView
                    ?? NearbyMarkerView(annotation: annotation, reuseIdentifier: "near")
                v.annotation = annotation
                v.configure(ident: n.ident, isAirport: n.isAirport)
                return v
            case let t as TrafficAnnotation:
                let v = mv.dequeueReusableAnnotationView(withIdentifier: "tfc") ?? MKAnnotationView(annotation: annotation, reuseIdentifier: "tfc")
                v.annotation = annotation; v.image = Self.traffic
                v.transform = CGAffineTransform(rotationAngle: CGFloat((t.track - 90) * .pi / 180))
                return v
            case is OwnshipAnnotation:
                let v = mv.dequeueReusableAnnotationView(withIdentifier: "own") ?? MKAnnotationView(annotation: annotation, reuseIdentifier: "own")
                v.annotation = annotation; v.image = Self.ownPlane
                return v
            default: return nil
            }
        }

        /// Rebuild traffic/ownship only when the aircraft/ownship set actually changed — not on every
        /// updateUIView (which also fires as chart packs load in during a pan), so markers don't flicker.
        func syncDynamic(_ mv: MKMapView, aircraft: [Aircraft], ownship: Coord?) {
            let key = aircraft.compactMap { ac -> String? in
                guard let c = ac.coordinate else { return nil }
                return "\(ac.label ?? "")|\(c.lat),\(c.lon)|\(ac.trackDeg ?? 0)"
            }
            let own = ownship.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
            if key == lastTrafficKey, own?.latitude == lastOwnship?.latitude, own?.longitude == lastOwnship?.longitude { return }
            lastTrafficKey = key; lastOwnship = own
            mv.removeAnnotations(dynamic); dynamic.removeAll()
            for ac in aircraft {
                guard let c = ac.coordinate else { continue }
                let a = TrafficAnnotation(); a.coordinate = c.clCoordinate; a.title = ac.label; a.track = ac.trackDeg ?? 0
                dynamic.append(a)
            }
            if let ownship { let a = OwnshipAnnotation(); a.coordinate = ownship.clCoordinate; dynamic.append(a) }
            mv.addAnnotations(dynamic)
        }

        private static func disc(_ symbol: String, fill: UIColor, pt: CGFloat, d: CGFloat) -> UIImage {
            let cfg = UIImage.SymbolConfiguration(pointSize: pt, weight: .black)
            let img = (UIImage(systemName: symbol, withConfiguration: cfg) ?? UIImage())
                .withTintColor(.white, renderingMode: .alwaysOriginal)
            let size = CGSize(width: d, height: d)
            return UIGraphicsImageRenderer(size: size).image { _ in
                let r = CGRect(origin: .zero, size: size).insetBy(dx: 1.5, dy: 1.5)
                fill.setFill(); UIBezierPath(ovalIn: r).fill()
                UIColor.white.withAlphaComponent(0.9).setStroke()
                let ring = UIBezierPath(ovalIn: r); ring.lineWidth = 1.5; ring.stroke()
                img.draw(in: CGRect(x: (d - img.size.width) / 2, y: (d - img.size.height) / 2, width: img.size.width, height: img.size.height))
            }
        }
        static let traffic: UIImage = disc("airplane", fill: .systemOrange, pt: 13, d: 26)
        static let ownPlane: UIImage = disc("airplane", fill: .systemBlue, pt: 16, d: 32)
    }
}

// MARK: - Annotations

final class WaypointAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let title: String?
    let tint: UIColor
    let glyph: String
    init(_ leg: ResolvedLeg) {
        coordinate = leg.coord.clCoordinate
        title = leg.ident
        switch leg.kind {
        case .airport:  tint = UIColor(red: 0.91, green: 0.47, blue: 0.98, alpha: 1); glyph = "A"
        case .vor:      tint = UIColor(red: 0.20, green: 0.83, blue: 0.60, alpha: 1); glyph = "V"
        case .waypoint: tint = UIColor(red: 0.38, green: 0.65, blue: 0.98, alpha: 1); glyph = "F"
        default:        tint = .lightGray; glyph = "•"
        }
    }
}

final class TrafficAnnotation: NSObject, MKAnnotation {
    @objc dynamic var coordinate = CLLocationCoordinate2D()
    var title: String?
    var track: Double = 0
}

final class OwnshipAnnotation: NSObject, MKAnnotation {
    @objc dynamic var coordinate = CLLocationCoordinate2D()
}

/// A bundled navaid / airport plotted for map context (not on the filed route).
final class NearbyAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let ident: String
    let isAirport: Bool
    init(_ np: NavPoint) {
        coordinate = CLLocationCoordinate2D(latitude: np.coord.lat, longitude: np.coord.lon)
        ident = np.ident
        isAirport = np.kind == .airport
    }
}

/// Context navaid/airport marker — deliberately smaller & dimmer than a filed waypoint or traffic, and a
/// distinct glyph (teal hexagon = navaid, magenta ring = airport) so it doesn't read as either. Decorative
/// (non-selectable) and low display priority so it yields to route waypoints and traffic.
final class NearbyMarkerView: MKAnnotationView {
    private let shape = UIImageView()
    private let label = UILabel()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: 48, height: 22)
        shape.frame = CGRect(x: 20, y: 0, width: 8, height: 8)
        addSubview(shape)
        label.frame = CGRect(x: 0, y: 9, width: 48, height: 11)
        label.textAlignment = .center
        label.font = .monospacedSystemFont(ofSize: 7, weight: .medium)
        label.textColor = UIColor.white.withAlphaComponent(0.85)
        label.layer.shadowColor = UIColor.black.cgColor
        label.layer.shadowOpacity = 0.7; label.layer.shadowRadius = 1; label.layer.shadowOffset = .zero
        addSubview(label)
        displayPriority = .defaultLow
        isEnabled = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(ident: String, isAirport: Bool) {
        label.text = ident
        shape.image = isAirport ? Self.airportImg : Self.navaidImg
    }

    private static let navaidImg: UIImage = {
        let d: CGFloat = 8
        return UIGraphicsImageRenderer(size: CGSize(width: d, height: d)).image { _ in
            UIColor(red: 0.20, green: 0.83, blue: 0.60, alpha: 0.9).setStroke()
            let path = UIBezierPath(); let c = CGPoint(x: d / 2, y: d / 2); let r = d / 2 - 0.75
            for i in 0..<6 {
                let a = CGFloat(i) * .pi / 3 - .pi / 2
                let p = CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            path.close(); path.lineWidth = 1.2; path.stroke()
        }
    }()
    private static let airportImg: UIImage = {
        let d: CGFloat = 8
        return UIGraphicsImageRenderer(size: CGSize(width: d, height: d)).image { _ in
            UIColor(red: 0.91, green: 0.47, blue: 0.98, alpha: 0.9).setStroke()
            let ring = UIBezierPath(ovalIn: CGRect(x: 0.75, y: 0.75, width: d - 1.5, height: d - 1.5))
            ring.lineWidth = 1.5; ring.stroke()
        }
    }()
}

extension BBox {
    /// The visible region grown by `margin` (a fraction of the span) so context layers extend a little
    /// past the screen edge and don't pop in during a pan.
    init(region r: MKCoordinateRegion, margin: Double) {
        let dLat = r.span.latitudeDelta * (0.5 + margin)
        let dLon = r.span.longitudeDelta * (0.5 + margin)
        self.init(minLat: r.center.latitude - dLat, minLon: r.center.longitude - dLon,
                  maxLat: r.center.latitude + dLat, maxLon: r.center.longitude + dLon)
    }
}

fileprivate extension Coord {
    var clCoordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
}
