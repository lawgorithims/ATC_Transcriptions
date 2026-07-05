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
/// crosses and download only those.
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
/// self-hosted raster charts (route-aware packs downloaded from HuggingFace, then offline).
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
}

// MARK: - Store (catalog + route-aware download)

/// Fetches the catalog, works out which packs a route crosses for the chosen layer, downloads the
/// missing ones (cached for offline), and hands out their `MBTilesReader`s. Readers are memoised, so
/// revisiting a layer/route is instant.
@MainActor final class ChartStore: ObservableObject {
    enum Phase: Equatable { case idle, loadingCatalog, downloading(Int, Int), ready, empty, failed(String) }
    @Published var phase: Phase = .idle
    @Published private(set) var readers: [MBTilesReader] = []
    private var catalog: ChartCatalog?
    private var cache: [String: MBTilesReader] = [:]

    func select(_ layer: ChartLayer, routeRect: MKMapRect?) async {
        if !layer.isRaster { readers = []; phase = .ready; return }               // Apple base map
        if catalog == nil {
            phase = .loadingCatalog
            do {
                let (data, resp) = try await URLSession.shared.data(from: ChartCatalog.url)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                catalog = try JSONDecoder().decode(ChartCatalog.self, from: data)
            } catch { readers = []; phase = .failed(error.localizedDescription); return }
        }
        guard let routeRect else { readers = []; phase = .empty; return }          // no filed route → nothing to pick
        // The corridor: the route's bounding rect grown a bit so charts just off the line still load.
        let pad = MKMapRect(x: routeRect.minX - routeRect.width * 0.2 - 30_000,
                            y: routeRect.minY - routeRect.height * 0.2 - 30_000,
                            width: routeRect.width * 1.4 + 60_000, height: routeRect.height * 1.4 + 60_000)
        let needed = layer.entries(catalog).filter { $0.mapRect.intersects(pad) }
        if needed.isEmpty { readers = []; phase = .empty; return }

        var got: [MBTilesReader] = []
        for (k, e) in needed.enumerated() {
            phase = .downloading(k, needed.count)
            if let r = cache[e.id] ?? MBTilesReader(path: e.localURL.path) { cache[e.id] = r; got.append(r); continue }
            do {
                let (tmp, resp) = try await URLSession.shared.download(from: e.remote)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                try? FileManager.default.removeItem(at: e.localURL)
                try FileManager.default.moveItem(at: tmp, to: e.localURL)
                if let r = MBTilesReader(path: e.localURL.path) { cache[e.id] = r; got.append(r) }
            } catch { /* skip this pack; keep going so a single failure doesn't sink the route */ }
        }
        readers = got
        phase = got.isEmpty ? .failed("Couldn't download charts for this route.") : .ready
    }
}

// MARK: - MKMapView chart view

/// The chart map: the selected base layer (one or more seamless FAA raster packs, or Apple's map) with
/// the filed route (magenta line + waypoints), your aircraft's live position (device GPS + Stratux),
/// and ADS-B traffic. Uses `MKMapView` (SwiftUI's `Map` can't host tile overlays). The raster charts
/// already show airspace/navaids/frequencies, so only the dynamic + route bits are overlaid.
struct ChartMapView: UIViewRepresentable {
    let layer: ChartLayer
    let readers: [MBTilesReader]
    let route: [ResolvedLeg]
    @ObservedObject var model: AppModel

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let mv = MKMapView()
        mv.delegate = context.coordinator
        mv.pointOfInterestFilter = .excludingAll
        mv.showsCompass = true
        mv.showsUserLocation = true                       // "your plane" from the device GPS
        context.coordinator.requestLocation()
        mv.setRegion(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 39, longitude: -96),
                                        span: MKCoordinateSpan(latitudeDelta: 42, longitudeDelta: 55)), animated: false)
        return mv
    }

    func updateUIView(_ mv: MKMapView, context: Context) {
        let c = context.coordinator
        if mv.mapType != layer.mapType { mv.mapType = layer.mapType }

        if !c.routeAdded, route.count >= 2 {              // route resolves after makeUIView
            let coords = route.map { $0.coord.clCoordinate }
            let line = MKPolyline(coordinates: coords, count: coords.count)
            mv.addOverlay(line, level: .aboveLabels)
            c.routeOverlay = line
            mv.addAnnotations(route.map { WaypointAnnotation($0) })
            c.routeAdded = true
        }

        let ids = Set(readers.map(ObjectIdentifier.init))
        if ids != c.chartReaderIDs {                      // packs/layer changed → swap raster overlays
            c.chartOverlays.forEach { mv.removeOverlay($0) }
            c.chartOverlays = readers.map { MBTilesTileOverlay(reader: $0) }
            for ov in c.chartOverlays {                   // keep charts beneath the route line
                if let ro = c.routeOverlay { mv.insertOverlay(ov, below: ro) } else { mv.addOverlay(ov, level: .aboveLabels) }
            }
            c.chartReaderIDs = ids
        }

        if !c.didFrame {
            if route.count >= 2 {
                let coords = route.map { $0.coord.clCoordinate }
                mv.setVisibleMapRect(MKPolyline(coordinates: coords, count: coords.count).boundingMapRect,
                                     edgePadding: .init(top: 90, left: 40, bottom: 96, right: 40), animated: false)
                c.didFrame = true
            } else if let first = readers.first {
                mv.setVisibleMapRect(first.bounds, edgePadding: .init(top: 24, left: 24, bottom: 24, right: 24), animated: false)
                c.didFrame = true
            }
        }
        c.syncDynamic(mv, aircraft: model.aircraft, ownship: model.stratuxGPS?.coordinate)
    }

    final class Coordinator: NSObject, MKMapViewDelegate, CLLocationManagerDelegate {
        var chartOverlays: [MBTilesTileOverlay] = []
        var chartReaderIDs: Set<ObjectIdentifier> = []
        var routeOverlay: MKPolyline?
        var routeAdded = false
        var didFrame = false
        private var dynamic: [MKAnnotation] = []
        private let loc = CLLocationManager()

        func requestLocation() {
            loc.delegate = self
            if loc.authorizationStatus == .notDetermined { loc.requestWhenInUseAuthorization() }
        }
        func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {}

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

        /// A glyph on a filled, ringed disc so it reads clearly on any chart (a bare tinted symbol
        /// renders dark / washes out over the busy raster).
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

// MARK: - Presented sheet (layer switcher + route-aware download + chart)

/// Entry point for the chart: a layer switcher (VFR sectional, IFR low, standard, satellite) and the
/// chart map below. FAA layers download the packs the filed route crosses on first use (cached for
/// offline). Reached from the route map's layers menu; also openable via `--open-chart`.
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
                ChartMapView(layer: layer, readers: store.readers, route: route, model: model)
                    .ignoresSafeArea(edges: .bottom)
                VStack(spacing: 8) {
                    switcher
                    statusPill
                }
                .padding(.top, 8)
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
            await store.select(layer, routeRect: routeRect)
        }
        .onChange(of: layer) { _, new in Task { await store.select(new, routeRect: routeRect) } }
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
        case .downloading(let k, let n):
            pill { ProgressView(); Text("Downloading charts (\(k + 1)/\(n))…") }
        case .empty where layer.isRaster:
            pill { Image(systemName: route.isEmpty ? "point.topleft.down.to.point.bottomright.curvepath" : "map")
                   Text(route.isEmpty ? "File a flight plan to load its charts" : "No \(layer.title) covers this route yet") }
        case .failed(let m):
            pill { Image(systemName: "wifi.exclamationmark"); Text("Chart download failed").font(.caption.bold()) }
                .onTapGesture { Task { await store.select(layer, routeRect: routeRect) } }
                .help(m)
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
