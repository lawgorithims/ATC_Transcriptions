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
/// (which our mosaics use — ~10× smaller) is transcoded to PNG per tile via `UIImage`.
final class MBTilesTileOverlay: MKTileOverlay {
    private let reader: MBTilesReader
    private let transcode: Bool
    let chartBounds: MKMapRect

    init(reader: MBTilesReader) {
        self.reader = reader
        self.transcode = (reader.format == "webp")
        self.chartBounds = reader.bounds
        super.init(urlTemplate: nil)
        canReplaceMapContent = false           // let the base map show through transparent chart edges
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

// MARK: - Chart layers & packs

/// A selectable base layer for the chart map. `standard`/`satellite` are Apple's base map; the FAA
/// layers are our self-hosted raster charts (downloaded once from HuggingFace, then offline).
enum ChartLayer: String, CaseIterable, Identifiable {
    case sectional, ifrLow, standard, satellite
    var id: String { rawValue }
    var short: String {
        switch self {
        case .sectional: return "VFR"
        case .ifrLow:    return "IFR"
        case .standard:  return "Map"
        case .satellite: return "Sat"
        }
    }
    var title: String {
        switch self {
        case .sectional: return "VFR sectional"
        case .ifrLow:    return "IFR low"
        case .standard:  return "Standard map"
        case .satellite: return "Satellite"
        }
    }
    var pack: ChartPack? {
        switch self {
        case .sectional: return .sectionalNE
        case .ifrLow:    return .ifrLowNE
        default:         return nil
        }
    }
    var mapType: MKMapType {
        switch self {
        case .satellite: return .hybrid
        case .standard:  return .standard
        default:         return .mutedStandard      // dim base under the raster chart
        }
    }
    /// Screenshot/demo: `--chart-layer vfr|ifr|std|sat` opens the chart on that layer.
    static var launchOverride: ChartLayer? {
        let a = ProcessInfo.processInfo.arguments
        guard let i = a.firstIndex(of: "--chart-layer"), i + 1 < a.count else { return nil }
        switch a[i + 1] {
        case "ifr": return .ifrLow
        case "sat": return .satellite
        case "std": return .standard
        case "vfr": return .sectional
        default:    return nil
        }
    }
}

/// A downloadable chart pack — fetched once from the public HuggingFace dataset over HTTPS and cached
/// in Caches/ for offline use. (v1 ships Northeast packs covering the demo routes; route-aware pack
/// selection is the next step.)
struct ChartPack: Identifiable {
    let id: String
    let title: String
    let remote: URL
    var localURL: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("charts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(id).mbtiles")
    }

    private static let base = "https://huggingface.co/datasets/SingularityUS/faa-charts/resolve/main"
    static let sectionalNE = ChartPack(id: "New_York_SEC", title: "New York sectional",
                                       remote: URL(string: "\(base)/sectional/New_York_SEC.mbtiles")!)
    static let ifrLowNE = ChartPack(id: "IFR_Low_NE", title: "IFR low (Northeast)",
                                    remote: URL(string: "\(base)/ifr/IFR_Low_NE.mbtiles")!)
}

/// Downloads + caches chart packs and hands out `MBTilesReader`s. Readers are memoised per pack, so
/// switching back to a layer is instant.
@MainActor final class ChartStore: ObservableObject {
    enum Phase: Equatable { case ready, downloading, failed(String) }
    @Published var phase: Phase = .ready
    @Published private(set) var reader: MBTilesReader?      // nil == plain base map (standard/satellite)
    private var cache: [String: MBTilesReader] = [:]

    func select(_ pack: ChartPack?) async {
        guard let pack else { reader = nil; phase = .ready; return }
        if let r = cache[pack.id] ?? MBTilesReader(path: pack.localURL.path) {
            cache[pack.id] = r; reader = r; phase = .ready; return
        }
        phase = .downloading; reader = nil
        do {
            let (tmp, resp) = try await URLSession.shared.download(from: pack.remote)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            try? FileManager.default.removeItem(at: pack.localURL)
            try FileManager.default.moveItem(at: tmp, to: pack.localURL)
            guard let r = MBTilesReader(path: pack.localURL.path) else { throw URLError(.cannotOpenFile) }
            cache[pack.id] = r; reader = r; phase = .ready
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

// MARK: - MKMapView chart view

/// The chart map itself: the selected base layer (FAA raster chart or Apple map) with the filed route
/// (magenta line + waypoints), your aircraft's live position (device GPS + Stratux), and ADS-B traffic.
/// Uses `MKMapView` (SwiftUI's `Map` can't host a tile overlay). The raster chart already shows
/// airspace/navaids/frequencies, so only the dynamic + route bits are overlaid on top.
struct ChartMapView: UIViewRepresentable {
    let layer: ChartLayer
    let reader: MBTilesReader?
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

        if route.count >= 2 {
            let coords = route.map { $0.coord.clCoordinate }
            let line = MKPolyline(coordinates: coords, count: coords.count)
            mv.addOverlay(line, level: .aboveLabels)       // route stays above the chart (chart inserted at 0)
            mv.addAnnotations(route.map { WaypointAnnotation($0) })
            mv.setVisibleMapRect(line.boundingMapRect,
                                 edgePadding: .init(top: 90, left: 40, bottom: 96, right: 40), animated: false)
        } else if let reader {
            mv.setVisibleMapRect(reader.bounds, edgePadding: .init(top: 24, left: 24, bottom: 24, right: 24), animated: false)
        }
        return mv
    }

    func updateUIView(_ mv: MKMapView, context: Context) {
        let c = context.coordinator
        if mv.mapType != layer.mapType { mv.mapType = layer.mapType }
        if c.chartReader !== reader {                      // layer changed → swap the raster overlay
            if let old = c.chartOverlay { mv.removeOverlay(old); c.chartOverlay = nil }
            if let reader {
                let ov = MBTilesTileOverlay(reader: reader)
                mv.insertOverlay(ov, at: 0, level: .aboveLabels)   // beneath the route line
                c.chartOverlay = ov
            }
            c.chartReader = reader
        }
        c.syncDynamic(mv, aircraft: model.aircraft, ownship: model.stratuxGPS?.coordinate)
    }

    final class Coordinator: NSObject, MKMapViewDelegate, CLLocationManagerDelegate {
        var chartOverlay: MBTilesTileOverlay?
        var chartReader: MBTilesReader?
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
                r.strokeColor = UIColor(red: 0.92, green: 0.10, blue: 0.55, alpha: 1)   // GPS magenta
                r.lineWidth = 3
                return r
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mv: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is MKUserLocation {              // your plane (device GPS)
                let v = mv.dequeueReusableAnnotationView(withIdentifier: "me")
                    ?? MKAnnotationView(annotation: annotation, reuseIdentifier: "me")
                v.annotation = annotation
                v.image = Self.ownPlane
                v.transform = CGAffineTransform(rotationAngle: CGFloat(((mv.userLocation.location?.course ?? -1) < 0
                                                ? 0 : (mv.userLocation.location!.course - 90)) * .pi / 180))
                return v
            }
            switch annotation {
            case let w as WaypointAnnotation:
                let v = mv.dequeueReusableAnnotationView(withIdentifier: "wp") as? MKMarkerAnnotationView
                    ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: "wp")
                v.annotation = annotation
                v.markerTintColor = w.tint
                v.glyphText = w.glyph
                v.displayPriority = .required
                v.titleVisibility = .adaptive
                v.animatesWhenAdded = false
                return v
            case let t as TrafficAnnotation:
                let v = mv.dequeueReusableAnnotationView(withIdentifier: "tfc")
                    ?? MKAnnotationView(annotation: annotation, reuseIdentifier: "tfc")
                v.annotation = annotation
                v.image = Self.traffic
                v.transform = CGAffineTransform(rotationAngle: CGFloat((t.track - 90) * .pi / 180))
                return v
            case is OwnshipAnnotation:                     // Stratux GPS (when the device has no fix)
                let v = mv.dequeueReusableAnnotationView(withIdentifier: "own")
                    ?? MKAnnotationView(annotation: annotation, reuseIdentifier: "own")
                v.annotation = annotation
                v.image = Self.ownPlane
                return v
            default:
                return nil
            }
        }

        func syncDynamic(_ mv: MKMapView, aircraft: [Aircraft], ownship: Coord?) {
            mv.removeAnnotations(dynamic)
            dynamic.removeAll()
            for ac in aircraft {
                guard let c = ac.coordinate else { continue }
                let a = TrafficAnnotation(); a.coordinate = c.clCoordinate; a.title = ac.label; a.track = ac.trackDeg ?? 0
                dynamic.append(a)
            }
            if let ownship { let a = OwnshipAnnotation(); a.coordinate = ownship.clCoordinate; dynamic.append(a) }
            mv.addAnnotations(dynamic)
        }

        static let traffic: UIImage? = UIImage(systemName: "airplane")?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
            .withTintColor(.orange, renderingMode: .alwaysOriginal)
        static let ownPlane: UIImage? = UIImage(systemName: "airplane")?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: 20, weight: .bold))
            .withTintColor(.systemCyan, renderingMode: .alwaysOriginal)
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

// MARK: - Presented sheet (layer switcher + download gate + chart)

/// Entry point for the chart: a layer switcher across the top (VFR sectional, IFR low, standard,
/// satellite), the route resolved from the filed plan, and the chart map below. FAA layers download
/// their pack from HuggingFace on first use (cached for offline). Reached from the route map's layers
/// menu; also openable via `--open-chart`.
struct ChartSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = ChartStore()
    @State private var route: [ResolvedLeg] = []
    @State private var layer: ChartLayer = .sectional

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                map
                switcher
                if case .downloading = store.phase { banner("Downloading \(layer.title) chart…", spin: true) }
                if case .failed(let m) = store.phase { failed(m) }
            }
            .navigationTitle("Chart")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { Haptics.impact(.light); dismiss() }
                        .accessibilityIdentifier("chart-done")
                }
            }
        }
        .task {
            if let o = ChartLayer.launchOverride { layer = o }
            await Task.detached(priority: .userInitiated) { _ = NavDatabase.count }.value
            route = RouteResolver.resolve(model.flightPlan?.fullRoute ?? []).points
            await store.select(layer.pack)
        }
        .onChange(of: layer) { _, new in Task { await store.select(new.pack) } }
    }

    private var map: some View {
        ChartMapView(layer: layer, reader: store.reader, route: route, model: model)
            .ignoresSafeArea(edges: .bottom)
    }

    private var switcher: some View {
        Picker("Layer", selection: $layer) {
            ForEach(ChartLayer.allCases) { l in Text(l.short).tag(l) }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.thinMaterial, in: Capsule())
        .padding(.horizontal, 20).padding(.top, 8)
        .accessibilityIdentifier("chart-layer-picker")
    }

    private func banner(_ text: String, spin: Bool) -> some View {
        HStack(spacing: 8) {
            if spin { ProgressView() }
            Text(text).font(.caption)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.thinMaterial, in: Capsule())
        .padding(.top, 56)
    }

    private func failed(_ msg: String) -> some View {
        ContentUnavailableView {
            Label("\(layer.title) unavailable", systemImage: "wifi.exclamationmark")
        } description: {
            Text("Connect to the internet once to download this chart for offline use.")
        } actions: {
            Button("Try again") { Task { await store.select(layer.pack) } }.buttonStyle(.borderedProminent)
        }
        .padding(.top, 80)
    }
}

fileprivate extension Coord {
    var clCoordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
}
