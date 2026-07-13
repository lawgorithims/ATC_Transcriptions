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
    /// Stable per-pack id (the .mbtiles filename) — the shared tile cache keys on this, so a pack
    /// that is evicted and later re-opened reuses its already-decoded tiles instead of re-fetching.
    let packID: String

    init?(path: String) {
        packID = (path as NSString).lastPathComponent
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
    /// How many zoom levels past the pack's own max we keep drawing by upscaling (Issue 1 — overzoom).
    /// Without this, MapKit stops requesting tiles above `reader.maxZoom` and the chart vanishes to the
    /// bare Apple base map when you zoom in past the data. 5 levels keeps the sectional/IFR chart
    /// visible (progressively softer) all the way in.
    static let overzoomLevels = 5

    /// SHARED, process-wide cache of ready-to-render tile PNGs, keyed "packID/z/x/y" (L11 + Issue 2).
    /// Shared (not per-overlay) so a pack that is evicted on a fast pan and re-opened when you pan back
    /// reuses its decoded tiles instantly instead of re-decoding/re-upscaling — killing the re-tile
    /// flicker. NSCache is thread-safe for MapKit's background tile queues and self-evicts under
    /// memory pressure; the single global budget bounds memory regardless of how many packs are mounted.
    private static let tileCache: NSCache<NSString, NSData> = {
        let c = NSCache<NSString, NSData>()
        c.totalCostLimit = 128 * 1024 * 1024   // ~128 MB of decoded tiles across all packs
        return c
    }()

    init(reader: MBTilesReader) {
        self.reader = reader
        self.transcode = (reader.format == "webp")
        super.init(urlTemplate: nil)
        canReplaceMapContent = false
        tileSize = CGSize(width: 256, height: 256)
        minimumZ = reader.minZoom
        maximumZ = min(reader.maxZoom + Self.overzoomLevels, 22)
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        // Fast reject: this pack covers only its own region, but with many packs mounted (Issue 2)
        // MapKit asks every overlay for every visible tile. Skip a SQLite hit for tiles outside our
        // bounds so the non-matching packs stay O(1).
        guard Self.tileRect(z: path.z, x: path.x, y: path.y).intersects(reader.bounds) else {
            result(nil, nil); return
        }
        let key = "\(reader.packID)/\(path.z)/\(path.x)/\(path.y)" as NSString
        if let hit = Self.tileCache.object(forKey: key) { result(hit as Data, nil); return }

        let data: Data?
        if path.z <= reader.maxZoom {
            if let raw = reader.tileData(z: path.z, x: path.x, y: path.y) {
                data = transcode ? (UIImage(data: raw)?.pngData() ?? raw) : raw   // MapKit renders PNG/JPEG natively
            } else {
                data = nil
            }
        } else {
            data = overzoomedTile(z: path.z, x: path.x, y: path.y)   // upscale the deepest available tile
        }
        if let data {
            Self.tileCache.setObject(data as NSData, forKey: key, cost: data.count)
            result(data, nil)
        } else {
            result(nil, nil)
        }
    }

    /// Zoomed in past the pack's data: take the deepest ancestor tile that DOES exist, crop the
    /// sub-region this tile covers, and scale it up to 256×256 (Issue 1). Bounded to `overzoomLevels`.
    private func overzoomedTile(z: Int, x: Int, y: Int) -> Data? {
        let src = Self.overzoomSource(z: z, x: x, y: y, maxZoom: reader.maxZoom)
        guard let src, let raw = reader.tileData(z: reader.maxZoom, x: src.ax, y: src.ay),
              let img = UIImage(data: raw) else { return nil }
        let tile: CGFloat = 256
        let fmt = UIGraphicsImageRendererFormat.default(); fmt.scale = 1; fmt.opaque = false
        let out = UIGraphicsImageRenderer(size: CGSize(width: tile, height: tile), format: fmt).image { _ in
            // Draw the whole source scaled so its (ox, oy, sub, sub) sub-rect fills the 256×256 output.
            let draw = tile / CGFloat(src.sub)                      // == scale factor
            let size = CGSize(width: img.size.width * draw, height: img.size.height * draw)
            img.draw(in: CGRect(x: -CGFloat(src.ox) * draw, y: -CGFloat(src.oy) * draw,
                                width: size.width, height: size.height))
        }
        return out.pngData()
    }

    /// Pure overzoom math (unit-tested): which ancestor tile at `maxZoom` a deeper (z,x,y) tile falls
    /// in, and the sub-rectangle (in the source's 256-pt space) it covers. Returns nil if not deeper.
    static func overzoomSource(z: Int, x: Int, y: Int, maxZoom: Int) -> (ax: Int, ay: Int, sub: Double, ox: Double, oy: Double)? {
        let dz = z - maxZoom
        guard dz > 0, dz <= overzoomLevels + 2 else { return nil }
        let scale = 1 << dz                                         // tiles per ancestor edge
        let sub = 256.0 / Double(scale)                            // sub-tile size in source pixels
        return (ax: x >> dz, ay: y >> dz, sub: sub,
                ox: Double(x % scale) * sub, oy: Double(y % scale) * sub)
    }

    /// The MKMapRect a tile path covers — used for the fast out-of-bounds reject.
    static func tileRect(z: Int, x: Int, y: Int) -> MKMapRect {
        let side = MKMapSize.world.width / Double(1 << z)
        return MKMapRect(x: Double(x) * side, y: Double(y) * side, width: side, height: side)
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
        /// The download URL for this pack, or nil for a malformed `path` (L13). A path with spaces or
        /// other URL-reserved characters falls back to percent-encoding; only genuinely un-encodable
        /// input yields nil — which routes through the existing pack-unavailable path (no crash).
        var remote: URL? {
            let raw = "\(ChartCatalog.base)/\(path)"
            return URL(string: raw) ?? raw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed).flatMap(URL.init)
        }
    }

    static let base = "https://huggingface.co/datasets/SingularityUS/faa-charts/resolve/main"
    static let url = URL(string: "\(base)/index.json")!
}

/// The map camera the user last settled on (M7): plain doubles + a timestamp, held transiently on
/// AppModel so a thermal teardown/rebuild of the whole `ChartMapView` restores the pilot's pan/zoom
/// instead of snapping back to the default framing. Deliberately NOT persisted — a fresh launch
/// should frame the route, and a stale (30 min+) camera is discarded.
struct SavedMapCamera: Equatable {
    let centerLat, centerLon, latDelta, lonDelta: Double
    let savedAt: Date

    init(rect: MKMapRect, now: Date) {
        let region = MKCoordinateRegion(rect)
        centerLat = region.center.latitude
        centerLon = region.center.longitude
        latDelta = region.span.latitudeDelta
        lonDelta = region.span.longitudeDelta
        savedAt = now
    }

    var region: MKCoordinateRegion {
        MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: centerLat, longitude: centerLon),
                           span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lonDelta))
    }

    /// A saved camera is restorable only within `maxAge` (30 min) of being set — a rebuild moments
    /// after a thermal blip restores; returning to a hours-old session re-frames the route instead.
    static let maxAge: TimeInterval = 30 * 60
    static func cameraIsFresh(savedAt: Date, now: Date) -> Bool {
        let age = now.timeIntervalSince(savedAt)
        return age >= 0 && age < maxAge
    }
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
    private var touch: [String: Int] = [:]        // last-used tick per pack — LRU eviction order
    private var touchTick = 0

    private let autoLoadSpanLimit = 7.0           // ° — beyond this (zoomed out) free-pan waits
    private let keepHalo = 1.5                     // keep packs within this many view-widths of the view
    // Keep a GENEROUS working set of packs mounted (Issue 2): a pack is only closed once we exceed
    // this many, and then the least-recently-used first — so a fast pan (and a pan back) reuses the
    // still-open packs instead of removing + re-adding overlays, which blanked the chart and made it
    // re-tile. The shared MBTilesTileOverlay tile cache means even a genuinely re-opened pack redraws
    // instantly. Memory stays bounded: readers are lightweight SQLite handles and MapKit renders only
    // visible overlays; the tile cache has its own global budget.
    private let maxLoaded = 24

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
        loaded.removeAll(); pinned.removeAll(); inFlight.removeAll(); touch.removeAll(); publish()
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

    /// Bound memory WITHOUT churning the working set (Issue 2). First mark every in-view pack as
    /// freshly used; then, only if we're over `maxLoaded`, close the least-recently-used packs that
    /// are neither pinned (on the route) nor within the keep-halo of the current view. Under the cap
    /// nothing is closed and no `publish()` fires — so panning around never removes + re-adds
    /// overlays (which blanked the chart and forced a re-tile).
    private func evict(near rects: [MKMapRect]) {
        for (id, pair) in loaded where rects.contains(where: { pair.entry.mapRect.intersects($0) }) {
            touchTick += 1; touch[id] = touchTick
        }
        guard loaded.count > maxLoaded else { return }
        let halos = rects.map { inflated($0, by: keepHalo) }
        let evictable = loaded.filter { pair in
            !pinned.contains(pair.key) && !halos.contains(where: { pair.value.entry.mapRect.intersects($0) })
        }.map(\.key)
        guard !evictable.isEmpty else { return }
        let overflow = loaded.count - maxLoaded
        assert(overflow > 0, "evict only trims when over the cap")
        let toClose = evictable.sorted { (touch[$0] ?? 0) < (touch[$1] ?? 0) }.prefix(overflow)   // LRU first
        for id in toClose { loaded[id] = nil; touch[id] = nil }   // readers deinit → sqlite3_close
        publish()
    }
}

// MARK: - MKMapView chart view

/// The unified flight-plan map: the selected base layer (one or more seamless FAA raster packs, or
/// Apple's map) with the filed route (magenta line + waypoints), airspace outlines (Class B/C/D + special
/// use) and nearby navaids/airports (bundled nav DB), your aircraft's live position (device GPS + Stratux), and
/// ADS-B traffic. As you pan/zoom, `onVisibleRegion` asks the store to load the charts under the new
/// area (free-pan) and the context layers refresh to what's in view. Uses `MKMapView` (SwiftUI's `Map`
/// can't host tile overlays).
struct ChartMapView: UIViewRepresentable {
    let layer: ChartLayer
    let readers: [MBTilesReader]
    let route: [ResolvedLeg]
    var procedure: [ResolvedLeg] = []                // a previewed coded procedure (approach/SID/STAR), georeferenced
    let showAirspace: Bool
    let showNearby: Bool
    let initialCenter: Coord?        // frame here when there's no filed route (device / Stratux position)
    let onVisibleRegion: (MKMapRect) -> Void
    let onTapObjects: ([IdentifiedObject]) -> Void   // tap / long-press → ranked objects there (empty = nothing)
    let focus: Coord?                                // recenter here when it changes (search result)
    var restoreCamera: SavedMapCamera? = nil         // M7: re-frame to the user's last pan/zoom after a thermal rebuild
    var plateOverlay: PlateOverlayState? = nil       // a hand-aligned approach plate superimposed on the map
    @ObservedObject var model: AppModel

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let mv = MKMapView()
        mv.delegate = context.coordinator
        mv.pointOfInterestFilter = .excludingAll
        mv.showsCompass = true
        mv.showsUserLocation = true
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.delegate = context.coordinator           // coexist with MapKit's own pan/zoom recognizers
        mv.addGestureRecognizer(tap)
        let hold = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleLongPress(_:)))
        hold.delegate = context.coordinator
        mv.addGestureRecognizer(hold)
        context.coordinator.requestLocation()
        mv.setRegion(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 39, longitude: -96),
                                        span: MKCoordinateSpan(latitudeDelta: 42, longitudeDelta: 55)), animated: false)
        return mv
    }

    func updateUIView(_ mv: MKMapView, context: Context) {
        let c = context.coordinator
        c.onVisibleRegion = onVisibleRegion
        c.onTapObjects = onTapObjects
        c.routeLegs = route                               // hit-test source for filed waypoints
        c.routeIdents = Set(route.map { $0.ident })
        if mv.mapType != layer.mapType { mv.mapType = layer.mapType }

        // Reconcile the route line + waypoint markers whenever the filed route changes (initial resolve,
        // or a tap-to-edit add/insert/remove) — remove the old, draw the new.
        let routeKey = route.map { "\($0.ident)|\($0.coord.lat),\($0.coord.lon)" }
        if routeKey != c.lastRouteKey {
            c.lastRouteKey = routeKey
            if let ro = c.routeOverlay { mv.removeOverlay(ro); c.routeOverlay = nil }
            mv.removeAnnotations(c.waypointAnnotations); c.waypointAnnotations = []
            if route.count >= 2 {
                let coords = route.map { $0.coord.clCoordinate }
                let line = MKPolyline(coordinates: coords, count: coords.count)
                mv.addOverlay(line, level: .aboveLabels)
                c.routeOverlay = line
            }
            if !route.isEmpty {
                let wps = route.map { WaypointAnnotation($0) }
                mv.addAnnotations(wps); c.waypointAnnotations = wps
            }
        }

        // Reconcile the previewed coded procedure (approach/SID/STAR) — a cyan georeferenced line through
        // its fixes with labeled markers — whenever the selected procedure changes.
        let procKey = procedure.map { "\($0.ident)|\($0.coord.lat),\($0.coord.lon)" }
        if procKey != c.lastProcKey {
            c.lastProcKey = procKey
            if let po = c.procedureOverlay { mv.removeOverlay(po); c.procedureOverlay = nil }
            mv.removeAnnotations(c.procedureFixes); c.procedureFixes = []
            if procedure.count >= 2 {
                let coords = procedure.map { $0.coord.clCoordinate }
                let line = MKPolyline(coordinates: coords, count: coords.count)
                mv.addOverlay(line, level: .aboveLabels)
                c.procedureOverlay = line
            }
            if !procedure.isEmpty {
                let fixes = procedure.map { ProcedureFixAnnotation($0) }
                mv.addAnnotations(fixes); c.procedureFixes = fixes
                // Frame the procedure when it first appears — and claim `didFrame` so the initial
                // route-framing pass below (which runs once the async route resolves) doesn't snap the
                // view back to the whole route and clobber this.
                if procedure.count >= 2 {
                    var r = MKCoordinateRegion(MKPolyline(coordinates: procedure.map { $0.coord.clCoordinate }, count: procedure.count).boundingMapRect)
                    r.span.latitudeDelta = min(max(r.span.latitudeDelta * 1.4, 0.15), 3)
                    r.span.longitudeDelta = min(max(r.span.longitudeDelta * 1.4, 0.15), 3)
                    mv.setRegion(r, animated: true)
                    c.didFrame = true
                }
            }
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

        // Reconcile the superimposed plate. Rebuild the MKOverlay only when the PLACEMENT changes
        // (opacity-only changes still need a rebuild since the renderer reads it, but the geoKey
        // guards against churn on unrelated re-renders). Drawn above the chart tiles + route.
        reconcilePlate(mv, c)

        if !c.didFrame {
            // M7: after a thermal teardown rebuilt this view, restore the user's last pan/zoom FIRST
            // (a fresh launch has no saved camera → falls through to route/launch framing; a stale
            // one is discarded so an hours-later return re-frames the route).
            if let cam = restoreCamera, SavedMapCamera.cameraIsFresh(savedAt: cam.savedAt, now: Date()) {
                mv.setRegion(cam.region, animated: false)
                c.didFrame = true
            } else if route.count >= 2 {
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

        if let f = focus, f != c.lastFocus {          // center on a search result
            c.lastFocus = f
            mv.setRegion(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: f.lat, longitude: f.lon),
                                            span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5)), animated: true)
        }

        c.syncDynamic(mv, aircraft: model.aircraft, ownship: model.stratuxGPS?.coordinate)
        c.syncHazards(mv, events: model.showHazards ? model.hazardEvents : [])
        c.syncTFRs(mv, tfrs: model.showTFRs ? model.tfrs : [])
    }

    /// Reconcile the superimposed plate overlay. Rebuild the MKOverlay only when the PLACEMENT
    /// (center/size/rotation) changes — an opacity-only change updates the existing renderer in place,
    /// so dragging the opacity slider never removes + re-adds the image (which would flicker).
    private func reconcilePlate(_ mv: MKMapView, _ c: Coordinator) {
        guard let s = plateOverlay else {
            if let old = c.plateOverlayObj { mv.removeOverlay(old); c.plateOverlayObj = nil; c.plateKey = nil }
            return
        }
        if c.plateKey != s.geoKey {
            if let old = c.plateOverlayObj { mv.removeOverlay(old) }
            let o = PlateImageOverlay(state: s)
            mv.addOverlay(o, level: .aboveLabels)   // over the chart tiles + route, under the annotation labels
            c.plateOverlayObj = o
            c.plateKey = s.geoKey
        } else if let o = c.plateOverlayObj, o.opacity != s.opacity {
            o.opacity = s.opacity
            (mv.renderer(for: o) as? PlateOverlayRenderer)?.setNeedsDisplay()
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate, CLLocationManagerDelegate, UIGestureRecognizerDelegate {
        var overlays: [ObjectIdentifier: MBTilesTileOverlay] = [:]
        var plateOverlayObj: PlateImageOverlay?     // the superimposed plate, if any
        var plateKey: String?                       // geometry identity — rebuild only when placement changes
        var routeOverlay: MKPolyline?
        var waypointAnnotations: [WaypointAnnotation] = []
        var lastRouteKey: [String] = []
        var procedureOverlay: MKPolyline?
        var procedureFixes: [ProcedureFixAnnotation] = []
        var lastProcKey: [String] = []
        var routeIdents: Set<String> = []
        var didFrame = false
        var didContext = false
        var showAirspace = true
        var showNearby = true
        var routeLegs: [ResolvedLeg] = []
        var lastFocus: Coord?
        var onVisibleRegion: ((MKMapRect) -> Void)?
        var onTapObjects: (([IdentifiedObject]) -> Void)?
        private var regionDebounce: DispatchWorkItem?
        private var trafficByKey: [String: TrafficAnnotation] = [:]  // keyed by Aircraft.hex (stable id) — diff, don't rebuild (L10)
        private var ownshipAnn: OwnshipAnnotation?
        private var airspaceByKey: [String: MKPolygon] = [:]        // keyed so a settle diffs, never redraws all
        private var airspaceClass: [ObjectIdentifier: String] = [:]
        private var airspaceLabelByKey: [String: AirspaceLabelAnnotation] = [:]   // altitude blocks, diffed like polygons
        // NASA EONET hazard layer — diffed like airspace/traffic; the reconcile lives in
        // HazardMapLayer.swift (stored properties can't move into the extension).
        var hazardAnnByKey: [String: HazardAnnotation] = [:]
        var hazardPolyByKey: [String: MKPolygon] = [:]
        var hazardTrackByKey: [String: MKPolyline] = [:]
        var hazardOverlayCategory: [ObjectIdentifier: EONETCategory] = [:]
        var hazardEventsByID: [String: EONETEvent] = [:]
        // Live FAA TFR layer — diffed like the hazard layer; reconcile lives in TFRMapLayer.swift.
        var tfrPolyByKey: [String: MKPolygon] = [:]
        var tfrLabelByKey: [String: AirspaceLabelAnnotation] = [:]     // altitude blocks, reusing the airspace annotation
        var tfrOverlayIDs: Set<ObjectIdentifier> = []                  // marks a polygon as a TFR for the renderer
        var tfrByID: [String: TFR] = [:]                              // the full TFR for the tap probe + change detection
        private var nearbyByKey: [String: NearbyAnnotation] = [:]   // keyed by NavPoint.id for the same reason
        private var contextGen = 0                                  // drops stale async refreshes (rapid panning)
        private var probeGen = 0                                    // drops a superseded tap probe (L12) — double-tap debounce
        private let loc = CLLocationManager()

        func requestLocation() {
            loc.delegate = self
            if loc.authorizationStatus == .notDetermined { loc.requestWhenInUseAuthorization() }
        }
        func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {}

        // Let the tap recognizer coexist with MapKit's built-in pan/zoom recognizers.
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        @objc func handleTap(_ gr: UITapGestureRecognizer) {
            guard let mv = gr.view as? MKMapView else { return }
            beginProbe(at: gr.location(in: mv), in: mv, radius: 24, userPoint: false)
        }

        @objc func handleLongPress(_ gr: UILongPressGestureRecognizer) {
            guard gr.state == .began, let mv = gr.view as? MKMapView else { return }
            beginProbe(at: gr.location(in: mv), in: mv, radius: 40, userPoint: true)   // press = drop a point
        }

        /// ForeFlight-style identify, split so the SLOW part runs OFF the main thread (L12). `beginProbe`
        /// does only the cheap main-actor screen math (point→coordinate, the search box), then hops the
        /// full-table `NavDatabase.nearby` scan + airspace containment off-main; `rankProbe` returns to
        /// the main actor to finish the screen-distance ranking and deliver the result. A generation
        /// counter drops a superseded probe — which also debounces a rapid double-tap to a single sheet.
        private func beginProbe(at pt: CGPoint, in mv: MKMapView, radius: Double, userPoint: Bool) {
            let ll = mv.convert(pt, toCoordinateFrom: mv)
            let here = Coord(lat: ll.latitude, lon: ll.longitude)
            // Search box: the degree-span of ~2.5× the radius around the point, floored so a zoomed-in
            // view still has a non-degenerate box.
            let off = mv.convert(CGPoint(x: pt.x + radius * 2.5, y: pt.y + radius * 2.5), toCoordinateFrom: mv)
            let dLat = max(abs(ll.latitude - off.latitude), 0.002)
            let dLon = max(abs(ll.longitude - off.longitude), 0.002)
            let box = BBox(minLat: ll.latitude - dLat, minLon: ll.longitude - dLon,
                           maxLat: ll.latitude + dLat, maxLon: ll.longitude + dLon)
            probeGen &+= 1
            let gen = probeGen
            let wantAir = showAirspace   // gate airspace/SUA containment on the layer toggle, like hazards/TFRs
            Task.detached { [weak self] in
                let nearby = NavDatabase.nearby(box, types: [0, 1, 2], limit: 40)        // full-table scan — off main
                let airspaces = wantAir ? NavDatabase.airspaces(intersecting: box).filter { $0.containsCoord(here) } : []
                await MainActor.run {
                    guard let self, self.probeGen == gen else { return }   // a newer tap superseded this one
                    self.rankProbe(pt: pt, here: here, radius: radius, userPoint: userPoint,
                                   nearby: nearby, airspaces: airspaces, in: mv)
                }
            }
        }

        /// Finish the probe on the main actor: rank the point features (filed waypoints, the off-main
        /// navaid/airport/fix hits, live traffic) by ON-SCREEN distance, then append the containing
        /// airspaces and (for a long-press) the droppable user point first — orderings preserved verbatim.
        private func rankProbe(pt: CGPoint, here: Coord, radius: Double, userPoint: Bool,
                               nearby: [NavPoint], airspaces: [Airspace], in mv: MKMapView) {
            func screenDist(_ c: Coord) -> Double {
                let p = mv.convert(CLLocationCoordinate2D(latitude: c.lat, longitude: c.lon), toPointTo: mv)
                return Double(hypot(p.x - pt.x, p.y - pt.y))
            }
            var cands: [(object: IdentifiedObject, distance: Double)] = []
            var seen = Set<String>()

            for leg in routeLegs {                                    // filed waypoints (authoritative onRoute)
                let k = MapObjectKind(routeKind: leg.kind)
                cands.append((IdentifiedObject(kind: k, ident: leg.ident, coord: leg.coord, onRoute: true), screenDist(leg.coord)))
                seen.insert("\(k.rawValue)|\(leg.ident)")
            }
            for np in nearby {                                        // airports/navaids/fixes near the point
                let k = MapObjectKind(routeKind: np.kind)
                let key = "\(k.rawValue)|\(np.ident)"
                if seen.contains(key) { continue }
                seen.insert(key)
                cands.append((IdentifiedObject(kind: k, ident: np.ident, coord: np.coord,
                                               onRoute: routeIdents.contains(np.ident)), screenDist(np.coord)))
            }
            for a in trafficByKey.values {                                      // live traffic (L10)
                let c = Coord(lat: a.coordinate.latitude, lon: a.coordinate.longitude)
                cands.append((IdentifiedObject(kind: .traffic, ident: a.title ?? "Traffic", coord: c, onRoute: false, traffic: nil),
                              screenDist(c)))
            }
            for h in hazardAnnByKey.values {                                    // NASA EONET hazard markers
                let c = Coord(lat: h.coordinate.latitude, lon: h.coordinate.longitude)
                cands.append((IdentifiedObject(kind: .hazard, ident: h.title ?? "Hazard", coord: c,
                                               onRoute: false, hazard: hazardEventsByID[h.eventID]),
                              screenDist(c)))
            }

            var results = MapProbe.rank(cands, within: radius)
            for asp in airspaces {   // "you're inside Class B" — containment already filtered off-main
                results.append(IdentifiedObject(kind: .airspace, ident: asp.name, coord: here, onRoute: false, airspace: asp))
            }
            for ev in hazardEventsByID.values where ev.polygon.count >= 3 {   // inside a hazard perimeter
                guard Geo.pointInRing(here, ev.polygon),
                      !results.contains(where: { $0.hazard?.id == ev.id }) else { continue }
                results.append(IdentifiedObject(kind: .hazard, ident: ev.title, coord: ev.point,
                                                onRoute: false, hazard: ev))
            }
            for t in tfrByID.values where t.polygon.count >= 3 {              // inside a TFR boundary
                guard Geo.pointInRing(here, t.polygon),
                      !results.contains(where: { $0.tfr?.id == t.id }) else { continue }
                results.append(IdentifiedObject(kind: .tfr, ident: t.id, coord: t.labelCoord ?? here,
                                                onRoute: false, tfr: t))
            }
            if userPoint {   // long-press: offer the exact pressed coordinate as a droppable waypoint, first
                results.insert(IdentifiedObject(kind: .userPoint, ident: UserPoint.token(here), coord: here, onRoute: false), at: 0)
            }
            onTapObjects?(results)
        }

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

        /// Recompute the in-view context layers (airspace outlines [Class B/C/D + special use] + nearby navaids/airports)
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
            contextGen &+= 1
            let gen = contextGen
            Task { [weak self, weak mv] in
                let out = await Task.detached(priority: .userInitiated) {
                    () -> (rings: [(key: String, coords: [CLLocationCoordinate2D], cls: String)],
                           labels: [(key: String, coord: CLLocationCoordinate2D, ceil: String, floor: String, cls: String)],
                           near: [NavPoint]) in
                    var rings: [(key: String, coords: [CLLocationCoordinate2D], cls: String)] = []
                    var labels: [(key: String, coord: CLLocationCoordinate2D, ceil: String, floor: String, cls: String)] = []
                    if wantAir {
                        // Draw the most safety-critical first so the 260-ring cap never drops a P/R area.
                        let order: [String: Int] = ["TFR": 0, "P": 1, "R": 2, "B": 3, "C": 4, "W": 5, "MOA": 6, "A": 7, "D": 8]
                        let asp = NavDatabase.airspaces(intersecting: bb)
                            .sorted { (order[$0.cls] ?? 9, $0.name) < (order[$1.cls] ?? 9, $1.name) }
                        building: for a in asp {
                            for (j, ring) in a.rings.enumerated() {
                                rings.append((key: "\(a.id)-\(j)",
                                              coords: ring.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) },
                                              cls: a.cls))
                                if rings.count >= 260 { break building }
                            }
                        }
                        // Altitude blocks only once zoomed in enough to be legible; placed on each area's
                        // top edge (its northernmost vertex).
                        if scale < 7 {
                            for a in asp where labels.count < 140 {
                                guard let top = a.rings.flatMap({ $0 }).max(by: { $0.lat < $1.lat }) else { continue }
                                labels.append((key: "\(a.id)",
                                               coord: CLLocationCoordinate2D(latitude: top.lat, longitude: top.lon),
                                               ceil: AirspaceLabelAnnotation.altText(a.ceilingFt),
                                               floor: AirspaceLabelAnnotation.altText(a.floorFt), cls: a.cls))
                            }
                        }
                    }
                    let near: [NavPoint] = wantNear
                        ? NavDatabase.nearby(bb, limit: 160).filter { !idents.contains($0.ident) }
                        : []
                    return (rings, labels, near)
                }.value
                guard let self, let mv, gen == self.contextGen else { return }   // a newer refresh superseded us
                self.applyAirspace(out.rings, to: mv)
                self.applyAirspaceLabels(out.labels, to: mv)
                self.applyNearby(out.near, to: mv)
            }
        }

        /// Diff the airspace polygons against what's already drawn — keep in-view ones untouched (no
        /// flicker on pan), remove those that left, add those that entered. Inserted below the route line
        /// so the magenta route stays on top; class is tracked in a side map for the renderer.
        private func applyAirspace(_ rings: [(key: String, coords: [CLLocationCoordinate2D], cls: String)], to mv: MKMapView) {
            let wanted = Set(rings.map(\.key))
            for (key, poly) in airspaceByKey where !wanted.contains(key) {
                mv.removeOverlay(poly); airspaceClass[ObjectIdentifier(poly)] = nil; airspaceByKey[key] = nil
            }
            for r in rings where airspaceByKey[r.key] == nil {
                let p = MKPolygon(coordinates: r.coords, count: r.coords.count)
                airspaceClass[ObjectIdentifier(p)] = r.cls
                airspaceByKey[r.key] = p
                if let ro = routeOverlay { mv.insertOverlay(p, below: ro) } else { mv.addOverlay(p, level: .aboveLabels) }
            }
        }

        /// Diff the airspace altitude blocks like the polygons — keep in-view ones, add/remove the rest.
        private func applyAirspaceLabels(
            _ labels: [(key: String, coord: CLLocationCoordinate2D, ceil: String, floor: String, cls: String)],
            to mv: MKMapView) {
            let wanted = Set(labels.map(\.key))
            let gone = airspaceLabelByKey.filter { !wanted.contains($0.key) }
            if !gone.isEmpty { mv.removeAnnotations(Array(gone.values)); gone.keys.forEach { airspaceLabelByKey[$0] = nil } }
            var added: [AirspaceLabelAnnotation] = []
            for l in labels where airspaceLabelByKey[l.key] == nil {
                let a = AirspaceLabelAnnotation(coord: l.coord, ceiling: l.ceil, floor: l.floor,
                                                color: Self.airspaceColor(l.cls))
                airspaceLabelByKey[l.key] = a; added.append(a)
            }
            if !added.isEmpty { mv.addAnnotations(added) }
        }

        /// Same incremental diff for nearby navaids/airports — annotations that stay in view are never
        /// removed/re-added, so they don't blink as you scroll.
        private func applyNearby(_ near: [NavPoint], to mv: MKMapView) {
            let wanted = Set(near.map(\.id))
            let gone = nearbyByKey.filter { !wanted.contains($0.key) }
            if !gone.isEmpty { mv.removeAnnotations(Array(gone.values)); gone.keys.forEach { nearbyByKey[$0] = nil } }
            var added: [NearbyAnnotation] = []
            for np in near where nearbyByKey[np.id] == nil {
                let a = NearbyAnnotation(np); nearbyByKey[np.id] = a; added.append(a)
            }
            if !added.isEmpty { mv.addAnnotations(added) }
        }

        // Airspace colours by class/type. Class B/D blue, C magenta (sectional style); Special Use gets
        // aeronautical hazard colours — Prohibited/Restricted/Warning red family, MOA purple, Alert amber.
        static func airspaceColor(_ cls: String) -> UIColor {
            switch cls {
            case "C":   return UIColor(red: 0.76, green: 0.09, blue: 0.36, alpha: 1)   // Class C magenta
            case "TFR": return UIColor(red: 0.97, green: 0.08, blue: 0.20, alpha: 1)   // TFR vivid red
            case "R":   return UIColor(red: 0.86, green: 0.13, blue: 0.13, alpha: 1)   // Restricted red
            case "P":   return UIColor(red: 0.63, green: 0.00, blue: 0.00, alpha: 1)   // Prohibited dark red
            case "W":   return UIColor(red: 0.91, green: 0.34, blue: 0.11, alpha: 1)   // Warning red-orange
            case "A":   return UIColor(red: 0.80, green: 0.60, blue: 0.00, alpha: 1)   // Alert amber
            case "MOA": return UIColor(red: 0.56, green: 0.22, blue: 0.78, alpha: 1)   // MOA purple
            default:    return UIColor(red: 0.18, green: 0.44, blue: 0.93, alpha: 1)   // Class B/D blue
            }
        }
        /// Special-use types get a heavier, filled treatment so they read as restrictions, not class rings.
        static func isSpecialUse(_ cls: String) -> Bool { ["TFR", "R", "P", "W", "A", "MOA"].contains(cls) }

        func mapView(_ mv: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let plate = overlay as? PlateImageOverlay { return PlateOverlayRenderer(plate) }
            if let tile = overlay as? MKTileOverlay { return MKTileOverlayRenderer(tileOverlay: tile) }
            // EONET hazards first — identity-keyed so a hazard polygon is never mistaken for airspace.
            if let cat = hazardOverlayCategory[ObjectIdentifier(overlay)] {
                let color = HazardAnnotation.tint(cat)
                if let poly = overlay as? MKPolygon {
                    let r = MKPolygonRenderer(polygon: poly)
                    r.strokeColor = color
                    r.lineWidth = 1.5
                    r.fillColor = color.withAlphaComponent(0.12)
                    return r
                }
                if let line = overlay as? MKPolyline {                // storm track — dashed
                    let r = MKPolylineRenderer(polyline: line)
                    r.strokeColor = color
                    r.lineWidth = 2
                    r.lineDashPattern = [6, 4]
                    return r
                }
            }
            // Live TFRs next — identity-keyed like hazards so a TFR polygon is never mistaken for airspace.
            if tfrOverlayIDs.contains(ObjectIdentifier(overlay)), let poly = overlay as? MKPolygon {
                let color = Self.airspaceColor("TFR")
                let r = MKPolygonRenderer(polygon: poly)
                r.strokeColor = color
                r.lineWidth = 2.4                                  // bold restriction outline
                r.fillColor = color.withAlphaComponent(0.18)
                return r
            }
            if let poly = overlay as? MKPolygon {
                let cls = airspaceClass[ObjectIdentifier(poly)] ?? "D"
                let color = Self.airspaceColor(cls)
                let r = MKPolygonRenderer(polygon: poly)
                r.strokeColor = color
                if Self.isSpecialUse(cls) {                        // restrictions: bolder outline + more fill
                    r.lineWidth = (cls == "R" || cls == "P" || cls == "TFR") ? 2.4 : 1.8
                    if cls == "MOA" || cls == "A" { r.lineDashPattern = [7, 4] }   // advisory areas dashed
                    r.fillColor = color.withAlphaComponent((cls == "P" || cls == "TFR") ? 0.18 : 0.10)
                } else {
                    r.lineWidth = cls == "D" ? 1.2 : 1.5
                    if cls == "D" { r.lineDashPattern = [4, 3] }
                    r.fillColor = color.withAlphaComponent(0.05)
                }
                return r
            }
            if let line = overlay as? MKPolyline {
                let r = MKPolylineRenderer(polyline: line)
                if line === procedureOverlay {                    // previewed procedure — cyan dashed
                    r.strokeColor = UIColor(red: 0.16, green: 0.78, blue: 0.94, alpha: 1)
                    r.lineWidth = 3
                    r.lineDashPattern = [8, 5]
                } else {                                          // filed route — magenta solid
                    r.strokeColor = UIColor(red: 0.92, green: 0.10, blue: 0.55, alpha: 1)
                    r.lineWidth = 3
                }
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
            case is ProcedureFixAnnotation:
                let v = mv.dequeueReusableAnnotationView(withIdentifier: "proc") as? MKMarkerAnnotationView
                    ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: "proc")
                v.annotation = annotation
                v.markerTintColor = UIColor(red: 0.16, green: 0.78, blue: 0.94, alpha: 1)
                v.glyphText = "◇"; v.displayPriority = .required; v.titleVisibility = .adaptive; v.animatesWhenAdded = false
                return v
            case let n as NearbyAnnotation:
                let v = mv.dequeueReusableAnnotationView(withIdentifier: "near") as? NearbyMarkerView
                    ?? NearbyMarkerView(annotation: annotation, reuseIdentifier: "near")
                v.annotation = annotation
                v.configure(ident: n.ident, isAirport: n.isAirport)
                return v
            case let a as AirspaceLabelAnnotation:
                let v = mv.dequeueReusableAnnotationView(withIdentifier: "asplbl") as? AirspaceLabelView
                    ?? AirspaceLabelView(annotation: annotation, reuseIdentifier: "asplbl")
                v.annotation = annotation
                v.configure(a)
                return v
            case let t as TrafficAnnotation:
                let v = mv.dequeueReusableAnnotationView(withIdentifier: "tfc") ?? MKAnnotationView(annotation: annotation, reuseIdentifier: "tfc")
                v.annotation = annotation; v.image = Self.traffic
                v.transform = CGAffineTransform(rotationAngle: CGFloat((t.track - 90) * .pi / 180))
                return v
            case let h as HazardAnnotation:
                let v = mv.dequeueReusableAnnotationView(withIdentifier: "haz") as? MKMarkerAnnotationView
                    ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: "haz")
                v.annotation = annotation
                v.markerTintColor = HazardAnnotation.tint(h.category)
                v.glyphImage = UIImage(systemName: h.category.glyph)
                v.displayPriority = .defaultHigh; v.titleVisibility = .adaptive; v.animatesWhenAdded = false
                return v
            case is OwnshipAnnotation:
                let v = mv.dequeueReusableAnnotationView(withIdentifier: "own") ?? MKAnnotationView(annotation: annotation, reuseIdentifier: "own")
                v.annotation = annotation; v.image = Self.ownPlane
                return v
            default: return nil
            }
        }

        /// Reconcile traffic/ownship IN PLACE, keyed on each aircraft's stable hex id (L10): survivors
        /// get a KVO `coordinate` write (MapKit animates the marker gliding to its new position) and a
        /// refreshed title/heading, departed aircraft are removed, and new ones added. The old code
        /// removed + re-added EVERY annotation whenever any aircraft moved, so the whole field blinked
        /// each ADS-B tick. Incoming is bounded (rule 2) and de-duped by hex.
        func syncDynamic(_ mv: MKMapView, aircraft: [Aircraft], ownship: Coord?) {
            var incoming: [String: Aircraft] = [:]
            var order: [String] = []
            for ac in aircraft.prefix(128) {                       // bound the field (rule 2)
                guard ac.coordinate != nil, !ac.hex.isEmpty, incoming[ac.hex] == nil else { continue }
                incoming[ac.hex] = ac; order.append(ac.hex)
            }
            let plan = TrafficReconcile.plan(existing: Set(trafficByKey.keys), incoming: order)
            for hex in plan.remove {                               // departed
                if let a = trafficByKey.removeValue(forKey: hex) { mv.removeAnnotation(a) }
            }
            for hex in plan.update {                               // survivors — move + refresh in place
                guard let a = trafficByKey[hex], let ac = incoming[hex], let c = ac.coordinate else { continue }
                a.coordinate = c.clCoordinate                      // @objc dynamic → animated glide
                a.title = ac.label
                let newTrack = ac.trackDeg ?? 0
                if a.track != newTrack {
                    a.track = newTrack
                    // On-screen view: rotate now. Off-screen: viewFor applies a fresh transform on reuse.
                    if let v = mv.view(for: a) {
                        v.transform = CGAffineTransform(rotationAngle: CGFloat((newTrack - 90) * .pi / 180))
                    }
                }
            }
            for hex in plan.add {                                  // new arrivals
                guard let ac = incoming[hex], let c = ac.coordinate else { continue }
                let a = TrafficAnnotation(); a.coordinate = c.clCoordinate; a.title = ac.label; a.track = ac.trackDeg ?? 0
                trafficByKey[hex] = a; mv.addAnnotation(a)
            }
            if let ownship {                                       // ownship: move in place, or add once
                if let a = ownshipAnn { a.coordinate = ownship.clCoordinate }
                else { let a = OwnshipAnnotation(); a.coordinate = ownship.clCoordinate; ownshipAnn = a; mv.addAnnotation(a) }
            } else if let a = ownshipAnn { mv.removeAnnotation(a); ownshipAnn = nil }
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
        if UserPoint.isUserPoint(leg.ident) {           // a dropped user waypoint — short coord label, own glyph
            title = UserPoint.label(leg.ident)
            tint = UIColor(red: 0.98, green: 0.65, blue: 0.14, alpha: 1)   // amber
            glyph = "◆"
            return
        }
        title = leg.ident
        switch leg.kind {
        case .airport:  tint = UIColor(red: 0.91, green: 0.47, blue: 0.98, alpha: 1); glyph = "A"
        case .vor:      tint = UIColor(red: 0.20, green: 0.83, blue: 0.60, alpha: 1); glyph = "V"
        case .waypoint: tint = UIColor(red: 0.38, green: 0.65, blue: 0.98, alpha: 1); glyph = "F"
        default:        tint = .lightGray; glyph = "•"
        }
    }
}

/// A fix on a previewed coded procedure (approach/SID/STAR) — a cyan labeled marker.
final class ProcedureFixAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let title: String?
    init(_ leg: ResolvedLeg) {
        coordinate = leg.coord.clCoordinate
        title = leg.ident
    }
}

final class TrafficAnnotation: NSObject, MKAnnotation {
    @objc dynamic var coordinate = CLLocationCoordinate2D()
    var title: String?
    var track: Double = 0
}

/// Pure set-diff for the live-traffic reconcile (L10) — which hex keys to add / remove / update
/// in place — extracted from the MapKit-bound coordinator so it is unit-testable. `incoming` is
/// assumed already de-duped and ordered; `remove` is sorted for deterministic output.
enum TrafficReconcile {
    struct Plan: Equatable {
        var add: [String]
        var remove: [String]
        var update: [String]
    }
    static func plan(existing: Set<String>, incoming: [String]) -> Plan {
        let incomingSet = Set(incoming)
        var add: [String] = [], update: [String] = []
        for hex in incoming {                       // preserve incoming order for add/update
            if existing.contains(hex) { update.append(hex) } else { add.append(hex) }
        }
        let remove = existing.filter { !incomingSet.contains($0) }.sorted()
        return Plan(add: add, remove: remove, update: update)
    }
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

/// The altitude block for an airspace, placed on its top edge — ceiling over floor, in the airspace's
/// colour (chart convention). Decorative / non-selectable.
final class AirspaceLabelAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let ceiling: String
    let floor: String
    let color: UIColor
    init(coord: CLLocationCoordinate2D, ceiling: String, floor: String, color: UIColor) {
        self.coordinate = coord; self.ceiling = ceiling; self.floor = floor; self.color = color
    }
    /// Feet → the compact chart form: SFC / UNL / hundreds of feet / FLxxx.
    static func altText(_ ft: Int?) -> String {
        guard let ft else { return "—" }
        if ft >= 99_999 { return "UNL" }
        if ft <= 0 { return "SFC" }
        if ft >= 18_000 { return "FL\(ft / 100)" }
        return "\(ft / 100)"
    }
}

/// Ceiling-over-floor altitude block on a dark pill, coloured to the airspace type.
final class AirspaceLabelView: MKAnnotationView {
    private let label = UILabel()
    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: 46, height: 24)
        label.frame = bounds
        label.numberOfLines = 2
        label.textAlignment = .center
        label.font = .monospacedDigitSystemFont(ofSize: 8, weight: .bold)
        label.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        label.layer.cornerRadius = 3
        label.layer.masksToBounds = true
        addSubview(label)
        displayPriority = .defaultLow      // yields to route waypoints / traffic
        collisionMode = .circle
        isEnabled = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(_ a: AirspaceLabelAnnotation) {
        let s = NSMutableAttributedString(string: "\(a.ceiling)\n\(a.floor)")
        s.addAttribute(.foregroundColor, value: a.color, range: NSRange(location: 0, length: s.length))
        label.attributedText = s
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
