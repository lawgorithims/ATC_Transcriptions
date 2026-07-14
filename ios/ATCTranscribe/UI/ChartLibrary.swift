import Foundation
import MapKit
import CoreLocation
import Network

// MARK: - Shared chart cache + prefetch service

/// App-lifetime shared chart cache, owned by `AppModel`. It pulls the catalog fetch, the
/// on-disk pack cache, and background downloading OUT of the per-sheet `ChartStore` so charts
/// can be **warmed and prefetched before the map is ever opened** — which is what removes the
/// open-the-map-and-wait delay. The per-sheet `ChartStore` still owns the live MapKit reader set
/// and its memory eviction; it now asks this library for the (already-warm) catalog and reads the
/// (already-on-disk) packs, so opening the chart does no network round-trip in the common case.
///
/// Lives in `UI/` (not `Core/`) on purpose: it depends on the UI-only chart types
/// (`ChartCatalog`, `ChartLayer`, `MBTilesReader`) and on MapKit/UIKit, none of which the
/// Foundation-only `ATCKitProbe` macOS target compiles.
@MainActor
final class ChartLibrary: ObservableObject {
    /// App-lifetime singleton. `AppModel` drives its prefetch; the map sheet's per-open `ChartStore`
    /// reads packs from it. A single instance means the catalog is warmed once and the on-disk cache is
    /// shared across every map open.
    static let shared = ChartLibrary()

    private(set) var catalog: ChartCatalog?
    private(set) var cycle = ""

    /// Progress of an explicit "download all US charts" run, for the Settings UI.
    enum BulkDownload: Equatable {
        case idle, running(done: Int, total: Int), finished(added: Int), failed(String)
        var isRunning: Bool { if case .running = self { return true }; return false }
    }
    @Published var bulk: BulkDownload = .idle
    /// Total bytes of chart packs currently on disk (drives the "stored on device" readout).
    @Published private(set) var cachedBytes: Int = 0
    /// Pack ids currently downloading via the per-region Downloads page (drives per-row spinners).
    @Published private(set) var downloadingIDs: Set<String> = []

    private var inFlight: Set<String> = []
    private var warming: Task<Bool, Never>?
    private var bulkTask: Task<Void, Never>?
    private let location = OneShotLocation()

    /// Pack ids the user explicitly downloaded for offline use — **pinned**: exempt from the LRU cap so a
    /// full-country download is never silently evicted. Persisted and keyed to the chart cycle.
    private var pinned: Set<String> = []
    private let pinnedKey = "atc.pinnedCharts"
    private let pinnedCycleKey = "atc.pinnedChartsCycle"

    /// Modest ceiling on the *incidental* on-disk pack cache (route/around-me prefetch + free-pan) for the
    /// current cycle. Pinned offline downloads don't count against it. Old cycles are pruned outright;
    /// within a cycle we LRU-evict non-pinned packs by file date so free-panning can't silently fill the device.
    private let diskBudgetBytes = 600 * 1024 * 1024

    // MARK: Catalog

    /// Fetch the pack catalog once per launch (coalesced across concurrent callers) so opening the
    /// map costs no round-trip. Returns whether a catalog is available.
    @discardableResult
    func warm() async -> Bool {
        if catalog != nil { return true }
        if let w = warming { return await w.value }
        let task = Task { [weak self] () -> Bool in
            do {
                let (data, resp) = try await URLSession.shared.data(from: ChartCatalog.url)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return false }
                let cat = try JSONDecoder().decode(ChartCatalog.self, from: data)
                guard let self else { return false }
                self.catalog = cat
                self.cycle = cat.cycle
                self.pruneOldCycleFiles()
                self.loadPinned()
                self.refreshCachedBytes()
                return true
            } catch { return false }
        }
        warming = task
        let ok = await task.value
        warming = nil
        return ok
    }

    // MARK: On-disk cache

    private var dir: URL {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("charts", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// On-disk name carries the AIRAC cycle so a new cycle can't be served from a stale cached file.
    func localURL(_ e: ChartCatalog.Entry) -> URL {
        dir.appendingPathComponent("\(e.id)-\(cycle).mbtiles")
    }

    /// A pack is considered cached once its file is on disk — the download path only leaves a file
    /// there after an integrity check, so presence is a safe signal (no per-call SQLite open).
    func isCached(_ e: ChartCatalog.Entry) -> Bool {
        FileManager.default.fileExists(atPath: localURL(e).path)
    }

    /// Delete cached packs from previous cycles so the pilot never reads an expired chart off disk.
    private func pruneOldCycleFiles() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for f in files where f.pathExtension == "mbtiles" && !f.lastPathComponent.hasSuffix("-\(cycle).mbtiles") {
            try? FileManager.default.removeItem(at: f)
        }
    }

    /// Ensure a pack is on disk, downloading it if missing. Integrity-checked (openable + has tile
    /// rows) before it's kept. Returns the on-disk URL, or nil on failure.
    @discardableResult
    func ensureOnDisk(_ e: ChartCatalog.Entry) async -> URL? {
        let dst = localURL(e)
        if FileManager.default.fileExists(atPath: dst.path) { return dst }   // verified at write time
        guard let remote = e.remote else { return nil }   // malformed path (L13) → pack simply unavailable
        do {
            let (tmp, resp) = try await URLSession.shared.download(from: remote)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            try? FileManager.default.removeItem(at: dst)
            try FileManager.default.moveItem(at: tmp, to: dst)
            guard let r = MBTilesReader(path: dst.path), r.hasTiles else {   // integrity: openable + has tiles
                try? FileManager.default.removeItem(at: dst)
                return nil
            }
            _ = r                                                           // reader closes on deinit
            return dst
        } catch { return nil }
    }

    // MARK: Prefetch

    /// Catalog entries for `layer` whose bounds intersect any of `rects`.
    func packsCovering(_ rects: [MKMapRect], layer: ChartLayer) -> [ChartCatalog.Entry] {
        guard let catalog else { return [] }
        return layer.entries(catalog).filter { e in rects.contains { e.mapRect.intersects($0) } }
    }

    /// Background prefetch: download not-yet-cached packs covering `rects` for each raster layer,
    /// de-duped against in-flight downloads and **bounded by `cap` per call** so a wide area can
    /// never mass-download the country. Silently no-ops when offline / catalog unavailable.
    func prefetch(rects: [MKMapRect], layers: [ChartLayer], cap: Int = 8) async {
        guard !rects.isEmpty, await warm() else { return }
        for layer in layers where layer.isRaster {
            var todo = packsCovering(rects, layer: layer).filter { !isCached($0) && !inFlight.contains($0.id) }
            if todo.count > cap { todo = Array(todo.prefix(cap)) }
            for e in todo {
                inFlight.insert(e.id)
                _ = await ensureOnDisk(e)
                inFlight.remove(e.id)
            }
        }
        enforceDiskBudget()
    }

    /// Prefetch the packs around a single position (device GPS / Stratux fix) — used on app open so
    /// the charts for where you are are already on disk by the time you open the map.
    func prefetchAround(_ c: Coord, radiusNM: Double = 60, layers: [ChartLayer], cap: Int = 6) async {
        await prefetch(rects: [ChartGeo.rect(around: c, radiusNM: radiusNM)], layers: layers, cap: cap)
    }

    // MARK: Location

    /// The best available fix for startup prefetch: the Stratux fix when connected, else a single
    /// device-GPS fix. Returns nil when no fix is available or location permission is denied.
    func nearestFix(preferring stratux: Coord?) async -> Coord? {
        if let stratux { return stratux }
        return await location.fix()
    }

    // MARK: Disk budget (LRU by file date)

    /// Keep the current-cycle pack cache under `diskBudgetBytes` by deleting the oldest files first.
    /// Deleting a pack a live reader still has open is safe on iOS (the fd stays valid until closed);
    /// the file simply re-downloads next time it's needed.
    private func enforceDiskBudget() {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys) else { return }
        // Pinned offline downloads are exempt — only the incidental cache is bounded.
        var packs = files.filter { $0.pathExtension == "mbtiles" && !isPinnedFile($0) }
        func size(_ u: URL) -> Int { (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        func date(_ u: URL) -> Date { (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        var total = packs.reduce(0) { $0 + size($1) }
        guard total > diskBudgetBytes else { return }
        packs.sort { date($0) < date($1) }                                  // oldest (least-recently-downloaded) first
        for f in packs {
            if total <= diskBudgetBytes { break }
            let sz = size(f)
            try? FileManager.default.removeItem(at: f)
            total -= sz
        }
        refreshCachedBytes()
    }

    // MARK: Offline "download all US charts"

    /// Total on-disk size of all chart packs (drives the "stored on device" readout).
    func refreshCachedBytes() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { cachedBytes = 0; return }
        cachedBytes = files.filter { $0.pathExtension == "mbtiles" }
            .reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    /// Catalog bytes for the given raster layers (the full download size), and the not-yet-cached remainder.
    func totalBytes(_ layers: [ChartLayer]) -> Int { entries(for: layers).reduce(0) { $0 + $1.bytes } }
    func remainingBytes(_ layers: [ChartLayer]) -> Int { entries(for: layers).filter { !isCached($0) }.reduce(0) { $0 + $1.bytes } }
    func packCount(_ layers: [ChartLayer]) -> Int { entries(for: layers).count }

    private func entries(for layers: [ChartLayer]) -> [ChartCatalog.Entry] {
        guard let catalog else { return [] }
        return layers.filter { $0.isRaster }.flatMap { $0.entries(catalog) }
    }

    /// Start downloading every US pack for the chosen layers (idempotent — skips what's already on disk).
    /// Downloaded packs are **pinned** so the LRU cap never evicts them. No-op while one is already running.
    func startBulkDownload(layers: [ChartLayer]) {
        guard bulkTask == nil else { return }
        bulkTask = Task { await self.runBulk(layers: layers) }
    }

    func cancelBulkDownload() {
        bulkTask?.cancel()
        bulkTask = nil
        bulk = .idle
    }

    private func runBulk(layers: [ChartLayer]) async {
        guard await warm() else { bulk = .failed("Chart index unavailable"); bulkTask = nil; return }
        let all = entries(for: layers)
        let total = all.count
        var done = 0, added = 0
        bulk = .running(done: 0, total: total)
        for e in all {
            if Task.isCancelled { bulk = .idle; bulkTask = nil; return }
            var ok = isCached(e)
            if !ok, await ensureOnDisk(e) != nil { ok = true; added += 1 }
            if ok { pinned.insert(e.id); savePinned() }      // persist each so a mid-download kill keeps its pins
            done += 1
            bulk = .running(done: done, total: total)
            refreshCachedBytes()
        }
        bulk = .finished(added: added)
        bulkTask = nil
    }

    // MARK: Per-region (single-pack) offline download — the Downloads page

    /// Whether a pack was deliberately downloaded for offline use (pinned, LRU-exempt) vs incidental cache.
    func isPinned(_ e: ChartCatalog.Entry) -> Bool { pinned.contains(e.id) }

    /// Download one pack for offline use and pin it (exempt from the LRU cap). Idempotent; safe to call
    /// on an already-cached pack (just pins it). Returns whether the pack is on disk afterwards.
    @discardableResult
    func download(_ e: ChartCatalog.Entry) async -> Bool {
        guard !downloadingIDs.contains(e.id) else { return isCached(e) }
        downloadingIDs.insert(e.id)
        defer { downloadingIDs.remove(e.id) }
        var ok = isCached(e)
        if !ok { ok = await ensureOnDisk(e) != nil }
        if ok { pinned.insert(e.id); savePinned(); refreshCachedBytes() }
        return ok
    }

    /// Remove one downloaded pack and unpin it.
    func remove(_ e: ChartCatalog.Entry) {
        try? FileManager.default.removeItem(at: localURL(e))
        pinned.remove(e.id); savePinned(); refreshCachedBytes()
    }

    /// Delete every cached pack (incidental + pinned offline downloads) and clear the pins — the
    /// "remove downloaded charts" action.
    func removeAllCachedCharts() {
        if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for f in files where f.pathExtension == "mbtiles" { try? FileManager.default.removeItem(at: f) }
        }
        pinned.removeAll(); savePinned(); refreshCachedBytes()
        if case .finished = bulk { bulk = .idle }
    }

    /// True when the current network path is cellular / a personal hotspot (so the UI can confirm before a
    /// ~2 GB bulk download). One-shot: reads the first path update, then tears the monitor down.
    func isExpensiveConnection() async -> Bool {
        await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            let monitor = NWPathMonitor()
            let box = ResumeOnce(c)
            monitor.pathUpdateHandler = { path in
                box.fire(path.isExpensive || path.usesInterfaceType(.cellular))
                monitor.cancel()
            }
            monitor.start(queue: DispatchQueue(label: "chartlib.path"))
        }
    }

    // MARK: Pinned-pack persistence

    private func isPinnedFile(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        let suffix = "-\(cycle).mbtiles"
        guard name.hasSuffix(suffix) else { return false }
        return pinned.contains(String(name.dropLast(suffix.count)))
    }

    private func loadPinned() {
        // Pins are cycle-specific — a new cycle's files are different, so drop stale pins.
        if UserDefaults.standard.string(forKey: pinnedCycleKey) == cycle {
            pinned = Set(UserDefaults.standard.stringArray(forKey: pinnedKey) ?? [])
        } else {
            pinned = []
        }
    }

    private func savePinned() {
        UserDefaults.standard.set(Array(pinned), forKey: pinnedKey)
        UserDefaults.standard.set(cycle, forKey: pinnedCycleKey)
    }
}

/// Resumes a continuation at most once, even if `NWPathMonitor` reports several path updates.
private final class ResumeOnce: @unchecked Sendable {
    private var cont: CheckedContinuation<Bool, Never>?
    private let lock = NSLock()
    init(_ c: CheckedContinuation<Bool, Never>) { cont = c }
    func fire(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        cont?.resume(returning: value); cont = nil
    }
}

// MARK: - Route / location geometry helpers (shared by the map sheet and prefetch)

/// Map-rect helpers used both by the chart map (framing / free-pan) and by background prefetch,
/// so route-corridor and around-me selection use identical geometry.
enum ChartGeo {
    /// Per-leg rects (a pack is selected if it intersects any) — tighter than the whole-route
    /// bounding box on a diagonal route, and non-degenerate for a single-fix route. Mirrors the
    /// selection the chart map uses so prefetch and on-open loading agree on which packs a route needs.
    static func routeRects(_ points: [ResolvedLeg]) -> [MKMapRect] {
        let pts = points.map { MKMapPoint(CLLocationCoordinate2D(latitude: $0.coord.lat, longitude: $0.coord.lon)) }
        guard let f = pts.first else { return [] }
        let eps: Double = 5_000        // map points — gives a single point some area so intersects() works
        if pts.count == 1 { return [MKMapRect(x: f.x - eps, y: f.y - eps, width: 2 * eps, height: 2 * eps)] }
        return (1..<pts.count).map { i in
            let a = pts[i - 1], b = pts[i]
            return MKMapRect(x: min(a.x, b.x) - eps, y: min(a.y, b.y) - eps,
                             width: abs(a.x - b.x) + 2 * eps, height: abs(a.y - b.y) + 2 * eps)
        }
    }

    /// A square rect of `radiusNM` nautical miles around a coordinate (device / Stratux position).
    static func rect(around c: Coord, radiusNM: Double) -> MKMapRect {
        let center = MKMapPoint(CLLocationCoordinate2D(latitude: c.lat, longitude: c.lon))
        let d = radiusNM * 1852.0 * MKMapPointsPerMeterAtLatitude(c.lat)     // NM → metres → map points
        return MKMapRect(x: center.x - d, y: center.y - d, width: 2 * d, height: 2 * d)
    }
}

// MARK: - One-shot device location

/// A single device-GPS fix for background prefetch. Not main-actor isolated: `CLLocationManager`
/// delivers its callbacks on the thread that created it (the main thread here), and the project's
/// Swift 5 language mode doesn't enforce actor isolation on the delegate protocol. Requests are
/// coalesced — only one fix is in flight at a time.
///
/// It deliberately **does not raise a permission prompt**: a background launch/foreground prefetch
/// should be silent. It only reads location that's already authorized; the map view
/// (`ChartMapView.Coordinator.requestLocation`) is what asks for permission when the map is opened, so
/// once the pilot has used the map, later launches can prefetch around their position.
final class OneShotLocation: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var cont: CheckedContinuation<Coord?, Never>?

    override init() {
        super.init()
        manager.delegate = self
    }

    /// One-shot fix, or nil if location isn't already authorized / no fix arrives. Extra callers while a
    /// request is in flight get nil rather than hijacking the pending continuation.
    func fix() async -> Coord? {
        if cont != nil { return nil }
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: break
        default: return nil                                                 // not yet granted — stay silent
        }
        return await withCheckedContinuation { c in
            cont = c
            manager.requestLocation()
        }
    }

    private func finish(_ coord: Coord?) {
        guard let c = cont else { return }
        cont = nil
        c.resume(returning: coord)
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard let l = locs.last else { finish(nil); return }
        finish(Coord(lat: l.coordinate.latitude, lon: l.coordinate.longitude))
    }

    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        finish(nil)
    }
}
