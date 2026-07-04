import SwiftUI
import MapKit
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
        canReplaceMapContent = false           // let the muted base map show through transparent edges
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

// MARK: - Chart pack download (HuggingFace → on-device cache)

/// A downloadable chart pack. Fetched once from the public HuggingFace dataset over HTTPS and cached
/// in Caches/ for offline use. (v1 ships the New York sectional, which covers the demo routes; the
/// pack picker by route is the next step.)
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
    var isDownloaded: Bool { FileManager.default.fileExists(atPath: localURL.path) }

    static let newYork = ChartPack(
        id: "New_York_SEC", title: "New York sectional",
        remote: URL(string: "https://huggingface.co/datasets/SingularityUS/faa-charts/resolve/main/sectional/New_York_SEC.mbtiles")!)
}

@MainActor final class ChartStore: ObservableObject {
    enum Phase: Equatable { case idle, downloading, ready, failed(String) }
    @Published var phase: Phase = .idle
    private(set) var reader: MBTilesReader?

    func load(_ pack: ChartPack) async {
        if let r = MBTilesReader(path: pack.localURL.path) { reader = r; phase = .ready; return }   // cached
        phase = .downloading
        do {
            let (tmp, resp) = try await URLSession.shared.download(from: pack.remote)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            try? FileManager.default.removeItem(at: pack.localURL)
            try FileManager.default.moveItem(at: tmp, to: pack.localURL)
            guard let r = MBTilesReader(path: pack.localURL.path) else { throw URLError(.cannotOpenFile) }
            reader = r; phase = .ready
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

// MARK: - MKMapView chart view

/// Full raster-chart map: the FAA sectional tiles as the base layer with the filed route (magenta line
/// + waypoints) and live ADS-B traffic + Stratux ownship drawn on top. Uses `MKMapView` (SwiftUI's
/// `Map` can't host a tile overlay). The chart raster already shows airspace/navaids/frequencies, so we
/// only overlay the dynamic + route bits.
struct ChartMapView: UIViewRepresentable {
    let route: [ResolvedLeg]
    let reader: MBTilesReader
    @ObservedObject var model: AppModel

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let mv = MKMapView()
        mv.delegate = context.coordinator
        mv.mapType = .mutedStandard
        mv.pointOfInterestFilter = .excludingAll
        mv.showsCompass = true

        let overlay = MBTilesTileOverlay(reader: reader)
        mv.addOverlay(overlay, level: .aboveLabels)

        if route.count >= 2 {
            let coords = route.map { $0.coord.clCoordinate }
            let line = MKPolyline(coordinates: coords, count: coords.count)
            mv.addOverlay(line, level: .aboveLabels)
            mv.addAnnotations(route.map { WaypointAnnotation($0) })
            let rect = line.boundingMapRect
            mv.setVisibleMapRect(rect, edgePadding: .init(top: 70, left: 40, bottom: 90, right: 40), animated: false)
        } else {
            mv.setVisibleMapRect(overlay.chartBounds, edgePadding: .init(top: 20, left: 20, bottom: 20, right: 20), animated: false)
        }
        return mv
    }

    func updateUIView(_ mv: MKMapView, context: Context) {
        context.coordinator.syncDynamic(mv, aircraft: model.aircraft, ownship: model.stratuxGPS?.coordinate)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        private var dynamic: [MKAnnotation] = []

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
            switch annotation {
            case let w as WaypointAnnotation:
                let v = mv.dequeueReusableAnnotationView(withIdentifier: "wp") as? MKMarkerAnnotationView
                    ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: "wp")
                v.annotation = annotation
                v.markerTintColor = w.tint
                v.glyphText = w.glyph
                v.displayPriority = .required
                v.titleVisibility = .adaptive
                return v
            case let t as TrafficAnnotation:
                let v = mv.dequeueReusableAnnotationView(withIdentifier: "tfc")
                    ?? MKAnnotationView(annotation: annotation, reuseIdentifier: "tfc")
                v.annotation = annotation
                v.image = Self.plane
                v.transform = CGAffineTransform(rotationAngle: CGFloat((t.track - 90) * .pi / 180))
                v.centerOffset = .zero
                return v
            case is OwnshipAnnotation:
                let v = mv.dequeueReusableAnnotationView(withIdentifier: "own")
                    ?? MKAnnotationView(annotation: annotation, reuseIdentifier: "own")
                v.annotation = annotation
                v.image = Self.ownship
                return v
            default:
                return nil
            }
        }

        /// Replace the live layer (traffic + ownship) each SwiftUI update; the route/waypoints are static.
        func syncDynamic(_ mv: MKMapView, aircraft: [Aircraft], ownship: Coord?) {
            mv.removeAnnotations(dynamic)
            dynamic.removeAll()
            for ac in aircraft {
                guard let c = ac.coordinate else { continue }
                let a = TrafficAnnotation()
                a.coordinate = c.clCoordinate
                a.title = ac.label
                a.track = ac.trackDeg ?? 0
                dynamic.append(a)
            }
            if let ownship {
                let a = OwnshipAnnotation(); a.coordinate = ownship.clCoordinate; dynamic.append(a)
            }
            mv.addAnnotations(dynamic)
        }

        static let plane: UIImage? = UIImage(systemName: "airplane")?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
            .withTintColor(.orange, renderingMode: .alwaysOriginal)
        static let ownship: UIImage? = UIImage(systemName: "location.north.circle.fill")?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: 22))
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

// MARK: - Presented sheet (download gate → chart)

/// Entry point for the raster chart: downloads the pack from HuggingFace on first use (cached
/// thereafter for offline), then shows the chart. Reached from the route map's layers menu.
struct ChartSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = ChartStore()
    @State private var route: [ResolvedLeg] = []
    private let pack = ChartPack.newYork

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("FAA sectional chart")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { Haptics.impact(.light); dismiss() }
                            .accessibilityIdentifier("chart-done")
                    }
                }
        }
        .task {
            // Resolve the filed route off-main (first NavDatabase touch parses the table), then fetch
            // the chart pack. Self-contained so the chart can also be opened directly.
            await Task.detached(priority: .userInitiated) { _ = NavDatabase.count }.value
            route = RouteResolver.resolve(model.flightPlan?.fullRoute ?? []).points
            await store.load(pack)
        }
    }

    @ViewBuilder private var content: some View {
        switch store.phase {
        case .ready where store.reader != nil:
            ChartMapView(route: route, reader: store.reader!, model: model)
                .ignoresSafeArea(edges: .bottom)
        case .failed(let msg):
            ContentUnavailableView {
                Label("Chart unavailable", systemImage: "wifi.exclamationmark")
            } description: {
                Text("Couldn't download the \(pack.title). Connect to the internet once to cache it for offline use.\n\n\(msg)")
            } actions: {
                Button("Try again") { Task { await store.load(pack) } }.buttonStyle(.borderedProminent)
            }
        default:
            VStack(spacing: 14) {
                ProgressView()
                Text("Downloading \(pack.title)…").font(.callout).foregroundStyle(.secondary)
                Text("One-time download, then it works offline in the cockpit.")
                    .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
            }.padding(32)
        }
    }
}

fileprivate extension Coord {
    var clCoordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
}
