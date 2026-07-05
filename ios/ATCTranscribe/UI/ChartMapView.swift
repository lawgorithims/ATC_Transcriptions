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
        var localURL: URL {
            let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("charts", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir.appendingPathComponent("\(id).mbtiles")
        }
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

// MARK: - Store (catalog + route + free-pan download)

/// Fetches the catalog and loads chart packs on demand: the packs a filed route crosses (up front,
/// ungated) plus the packs under wherever the map is panned/zoomed (free-pan, gated so we never
/// mass-download when zoomed out). Readers **accumulate** for the current layer; switching layers
/// resets them. Downloads are de-duped and concurrency-safe (all state mutated on the main actor).
@MainActor final class ChartStore: ObservableObject {
    enum Phase: Equatable { case idle, loadingCatalog, downloading, ready, empty, zoomOut, failed(String) }
    @Published var phase: Phase = .idle
    @Published private(set) var readers: [MBTilesReader] = []

    private var catalog: ChartCatalog?
    private var cache: [String: MBTilesReader] = [:]     // packId -> reader (all layers, memoised)
    private var loadedIDs: Set<String> = []              // packs shown for the CURRENT layer
    private var inFlight: Set<String> = []               // packs being downloaded right now
    private var layer: ChartLayer = .sectional

    /// Widest angular span (°) at which free-pan will auto-load — beyond this you're too zoomed out to
    /// read a chart and would grab many packs, so we wait for you to zoom in.
    private let autoLoadSpanLimit = 7.0

    private func ensureCatalog() async -> Bool {
        if catalog != nil { return true }
        if phase != .loadingCatalog { phase = .loadingCatalog }
        do {
            let (data, resp) = try await URLSession.shared.data(from: ChartCatalog.url)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            catalog = try JSONDecoder().decode(ChartCatalog.self, from: data)
            return true
        } catch {
            phase = .failed(error.localizedDescription)
            return false
        }
    }

    /// Switch layer (or initial load): reset the loaded set and pull the packs the route crosses.
    func setLayer(_ newLayer: ChartLayer, routeRect: MKMapRect?) async {
        layer = newLayer
        loadedIDs.removeAll()
        readers = []
        guard newLayer.isRaster else { phase = .ready; return }
        guard await ensureCatalog() else { return }
        guard layer == newLayer else { return }             // a newer layer switch superseded us
        if let routeRect {
            await load(intersecting: routeRect, gated: false)   // whole route corridor, up front
        } else {
            phase = .empty
        }
    }

    /// Free-pan: ensure the packs under the visible region are loaded (gated by zoom/scope so panning
    /// around at a wide zoom doesn't mass-download).
    func ensureVisible(_ rect: MKMapRect, layer visibleLayer: ChartLayer) async {
        guard visibleLayer == layer, layer.isRaster, await ensureCatalog() else { return }
        guard visibleLayer == layer else { return }
        await load(intersecting: rect, gated: true)
    }

    private func load(intersecting rect: MKMapRect, gated: Bool) async {
        guard let catalog else { return }
        if gated {
            let span = MKCoordinateRegion(rect).span
            if span.latitudeDelta > autoLoadSpanLimit || span.longitudeDelta > autoLoadSpanLimit {
                if readers.isEmpty, inFlight.isEmpty { phase = .zoomOut }
                return
            }
        }
        var todo = layer.entries(catalog).filter {
            $0.mapRect.intersects(rect) && !loadedIDs.contains($0.id) && !inFlight.contains($0.id)
        }
        if gated, todo.count > 6 { todo = Array(todo.prefix(6)) }   // safety cap on a single pan
        guard !todo.isEmpty else {
            if inFlight.isEmpty { phase = readers.isEmpty ? (gated ? .zoomOut : .empty) : .ready }
            return
        }
        todo.forEach { inFlight.insert($0.id) }                     // reserve before any await (atomic on main)
        phase = .downloading
        let activeLayer = layer
        for e in todo {
            var reader = cache[e.id] ?? MBTilesReader(path: e.localURL.path)
            if reader == nil { reader = await downloadPack(e) }
            inFlight.remove(e.id)
            // Only surface the pack if the user is still on this layer and it isn't already shown.
            if let reader, layer == activeLayer, !loadedIDs.contains(e.id) {
                cache[e.id] = reader
                loadedIDs.insert(e.id)
                readers.append(reader)                             // incremental → the map adds this overlay
            } else if let reader {
                cache[e.id] = reader                               // keep the download for later, don't show
            }
        }
        if inFlight.isEmpty { phase = readers.isEmpty ? (gated ? .zoomOut : .empty) : .ready }
    }

    private func downloadPack(_ e: ChartCatalog.Entry) async -> MBTilesReader? {
        do {
            let (tmp, resp) = try await URLSession.shared.download(from: e.remote)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            try? FileManager.default.removeItem(at: e.localURL)
            try FileManager.default.moveItem(at: tmp, to: e.localURL)
            return MBTilesReader(path: e.localURL.path)
        } catch { return nil }
    }
}

// MARK: - MKMapView chart view

/// The chart map: the selected base layer (one or more seamless FAA raster packs, or Apple's map) with
/// the filed route (magenta line + waypoints), your aircraft's live position (device GPS + Stratux),
/// and ADS-B traffic. As you pan/zoom, `onVisibleRegion` asks the store to load the charts under the
/// new area (free-pan). Uses `MKMapView` (SwiftUI's `Map` can't host tile overlays).
struct ChartMapView: UIViewRepresentable {
    let layer: ChartLayer
    let readers: [MBTilesReader]
    let route: [ResolvedLeg]
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
        }

        // Incrementally reconcile the raster overlays to `readers` (they accumulate as you pan).
        let want = Set(readers.map(ObjectIdentifier.init))
        for (rid, ov) in c.overlays where !want.contains(rid) { mv.removeOverlay(ov); c.overlays[rid] = nil }
        for r in readers {
            let rid = ObjectIdentifier(r)
            guard c.overlays[rid] == nil else { continue }
            let ov = MBTilesTileOverlay(reader: r)
            if let ro = c.routeOverlay { mv.insertOverlay(ov, below: ro) } else { mv.addOverlay(ov, level: .aboveLabels) }
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
            } else if let center = ChartLayer.launchCenter {
                mv.setRegion(MKCoordinateRegion(center: center, span: MKCoordinateSpan(latitudeDelta: 1.4, longitudeDelta: 1.4)), animated: false)
                c.didFrame = true
            }
        }
        c.syncDynamic(mv, aircraft: model.aircraft, ownship: model.stratuxGPS?.coordinate)
    }

    final class Coordinator: NSObject, MKMapViewDelegate, CLLocationManagerDelegate {
        var overlays: [ObjectIdentifier: MBTilesTileOverlay] = [:]
        var routeOverlay: MKPolyline?
        var routeAdded = false
        var didFrame = false
        var onVisibleRegion: ((MKMapRect) -> Void)?
        private var regionDebounce: DispatchWorkItem?
        private var dynamic: [MKAnnotation] = []
        private let loc = CLLocationManager()

        func requestLocation() {
            loc.delegate = self
            if loc.authorizationStatus == .notDetermined { loc.requestWhenInUseAuthorization() }
        }
        func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {}

        /// Free-pan trigger: debounce so we act once the map settles, then ask the store to load the
        /// packs under the new region.
        func mapView(_ mv: MKMapView, regionDidChangeAnimated animated: Bool) {
            regionDebounce?.cancel()
            let rect = mv.visibleMapRect
            let cb = onVisibleRegion
            let work = DispatchWorkItem { cb?(rect) }
            regionDebounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        }

        func mapView(_ mv: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tile = overlay as? MKTileOverlay { return MKTileOverlayRenderer(tileOverlay: tile) }
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

        func syncDynamic(_ mv: MKMapView, aircraft: [Aircraft], ownship: Coord?) {
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

// MARK: - Presented sheet (layer switcher + route/free-pan download + chart)

/// Entry point for the chart: a layer switcher (VFR sectional, IFR low, standard, satellite) and the
/// chart map below. FAA layers load the packs your route crosses up front, and more as you pan/zoom —
/// each cached for offline. Reached from the route map's layers menu; also openable via `--open-chart`.
struct ChartSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = ChartStore()
    @State private var route: [ResolvedLeg] = []
    @State private var layer: ChartLayer = .sectional

    private var routeRect: MKMapRect? {
        let pts = route.map { MKMapPoint($0.coord.clCoordinate) }
        guard let f = pts.first else { return nil }
        var r = MKMapRect(origin: f, size: MKMapSize(width: 0, height: 0))
        for p in pts.dropFirst() { r = r.union(MKMapRect(origin: p, size: MKMapSize(width: 0, height: 0))) }
        return r
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                ChartMapView(layer: layer, readers: store.readers, route: route,
                             onVisibleRegion: { rect in Task { await store.ensureVisible(rect, layer: layer) } },
                             model: model)
                    .ignoresSafeArea(edges: .bottom)
                VStack(spacing: 8) { switcher; statusPill }.padding(.top, 8)
            }
            .navigationTitle("Chart")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { Haptics.impact(.light); dismiss() }.accessibilityIdentifier("chart-done")
                }
            }
        }
        .task {
            if let o = ChartLayer.launchOverride { layer = o }
            await Task.detached(priority: .userInitiated) { _ = NavDatabase.count }.value
            route = RouteResolver.resolve(model.flightPlan?.fullRoute ?? []).points
            await store.setLayer(layer, routeRect: routeRect)
        }
        .onChange(of: layer) { _, new in Task { await store.setLayer(new, routeRect: routeRect) } }
    }

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
                .onTapGesture { Task { await store.setLayer(layer, routeRect: routeRect) } }
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
}

fileprivate extension Coord {
    var clCoordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
}
