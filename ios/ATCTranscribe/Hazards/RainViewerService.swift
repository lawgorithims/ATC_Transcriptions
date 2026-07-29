import Foundation

/// One radar frame: a tile-URL template + its timestamp + whether it's an observed past frame or a
/// forecast (nowcast) frame. Used to animate the storm's movement (past → now → forecast).
struct RadarFrame: Equatable {
    let template: String       // "…/{z}/{x}/{y}/…png"
    let time: Date
    let isForecast: Bool
}

/// The map's visible extent, in degrees — the area whose radar tiles are warmed first. Deliberately
/// UIKit-free so the tile math stays pure and unit-testable (the hosts convert their own region type).
struct RadarRegion: Equatable {
    let centerLat, centerLon, latSpan, lonSpan: Double

    /// A slippy tile address.
    struct Tile: Equatable, Hashable { let z: Int, x: Int, y: Int }

    /// Whether the map moved far enough to be worth re-warming: a re-prefetch on every 0.4 s settle
    /// while the pilot drags would hammer the network for tiles that scroll off a moment later.
    /// "Far enough" = a shift of more than a third of the span, or a zoom change beyond ±50%.
    func differsMeaningfully(from o: RadarRegion) -> Bool {
        let dLat = abs(centerLat - o.centerLat), dLon = abs(centerLon - o.centerLon)
        if dLat > o.latSpan / 3 || dLon > o.lonSpan / 3 { return true }
        let zoomRatio = latSpan / max(o.latSpan, 1e-9)
        return zoomRatio > 1.5 || zoomRatio < 0.66
    }
}

/// Live precipitation-radar tiles from RainViewer (free, no API key). RainViewer's tile path carries the
/// FRAME TIMESTAMP and rolls over every ~10 min, so we can't hardcode a `{z}/{x}/{y}` template — we fetch
/// `weather-maps.json` for the frame list (last ~2 h observed + ~30 min nowcast), then publish a standard
/// raster template both map engines can consume. Refreshed on a timer only while the layer is on +
/// foregrounded (no idle cost). The frames drive a scrub-able loop so the pilot can see + step through the
/// weather's movement, and a light representative-tile prefetch reports a buffering % and makes the loop
/// play smoothly the first time.
@MainActor final class RainViewerService: ObservableObject {
    /// The template the map should draw RIGHT NOW — the selected frame. Bridged to both map engines. nil
    /// when off / not yet fetched.
    @Published private(set) var tileTemplate: String?
    /// True when the LAST fetch failed AND we have nothing to show (drives the "radar unavailable" pill).
    @Published private(set) var failed = false
    /// Whether the loop animation is currently playing.
    @Published private(set) var animating = false
    /// The ordered frames (observed past first, then forecast) — the scrubber's ticks.
    @Published private(set) var frames: [RadarFrame] = []
    /// Index of the frame currently shown (into `frames`) — the scrubber's position.
    @Published private(set) var currentIndex = 0
    /// A short label for the current frame relative to now: "−40 min", "now", "+20 min", or "".
    @Published private(set) var frameLabel = ""
    /// Loop buffering progress (0…1) while prefetching a representative tile per frame; nil when idle/done.
    @Published private(set) var bufferProgress: Double?

    /// True once ≥2 frames are loaded (the animation control is meaningful).
    var canAnimate: Bool { frames.count >= 2 }
    /// The index of the newest OBSERVED (non-forecast) frame — the "now" anchor for the loop + labels.
    private(set) var nowIndex = 0
    /// Map center the host last reported, used to pick a representative tile to prefetch (nil → CONUS).
    /// Superseded by `prefetchRegion` when the map has reported a visible region — the pilot is often
    /// looking AHEAD of the aircraft (or at another field entirely), and the radar they need warmed is
    /// the radar on screen, not the radar overhead.
    var prefetchCenter: (lat: Double, lon: Double)?

    /// The map's current visible region. Set from the engines' visible-region callback, so the prefetch
    /// warms the tiles actually on screen, nearest-to-center first.
    var prefetchRegion: RadarRegion?

    /// Attribution required by RainViewer's free tier.
    static let attribution = "Radar: RainViewer"

    private var scrubbing = false                          // a manual scrub pins the frame across refreshes
    private var lastPrefetchNewest: Date?                  // frames already warmed → don't re-prefetch/re-flash
    private var lastPrefetchRegion: RadarRegion?           // view already warmed → only re-warm on a real move
    private var didFirstBuffer = false                     // show the buffering % only on the FIRST pass
    private var refreshTask: Task<Void, Never>?
    private var animTask: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    private static let refreshSeconds: UInt64 = 300        // frames update ~every 10 min; refresh every 5
    private static let retrySeconds: UInt64 = 15           // faster retry while we have NOTHING to show yet
    private static let frameNanos: UInt64 = 500_000_000    // 0.5 s per frame while animating
    private static let holdNanos: UInt64 = 1_400_000_000   // pause on the newest frame each loop

    /// Edge-triggered: start refreshing when the layer turns on, stop + clear when off (idle cost = zero).
    func setEnabled(_ on: Bool) { if on { start() } else { stop() } }

    /// Play / pause the past→now→forecast loop. No-op if there aren't enough frames. PAUSING snaps the map
    /// back to the live "now" frame — a moving-map precip overlay must not sit frozen on a forecast frame
    /// when the pilot just stops the loop (to hold a specific frame they drag the SLIDER, which pins it).
    func toggleAnimation() {
        guard canAnimate else { return }
        if animating { resetToNow() } else { startAnimation() }
    }

    /// Manually jump to a frame (the scrubber) — pauses the auto-loop and pins the frame across refreshes.
    func scrub(to index: Int) {
        guard !frames.isEmpty else { return }
        stopAnimation()
        scrubbing = true
        apply(index: max(0, min(index, frames.count - 1)))
    }

    /// Snap the scrubber back to "now" and resume live refresh-follows-newest behaviour.
    func resetToNow() {
        stopAnimation()
        scrubbing = false
        if frames.indices.contains(nowIndex) { apply(index: nowIndex) }
    }

    private func start() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {                            // bounded by cancellation (rule 2)
                await self?.refresh()
                let interval = await (self?.tileTemplate == nil) ? Self.retrySeconds : Self.refreshSeconds
                try? await Task.sleep(nanoseconds: interval * 1_000_000_000)
            }
        }
    }
    private func stop() {
        refreshTask?.cancel(); refreshTask = nil
        stopAnimation()
        prefetchTask?.cancel(); prefetchTask = nil
        frames = []; scrubbing = false; frameLabel = ""; bufferProgress = nil
        lastPrefetchNewest = nil; lastPrefetchRegion = nil; didFirstBuffer = false
        tileTemplate = nil; failed = false; currentIndex = 0
    }

    private func refresh() async {
        guard let url = URL(string: "https://api.rainviewer.com/public/weather-maps.json") else { return }
        var req = URLRequest(url: url); req.timeoutInterval = 12
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else {
            failed = (tileTemplate == nil); return
        }
        // The layer may have been turned OFF while this fetch was in flight — stop() already cleared state,
        // so bail instead of re-populating tileTemplate/frames and spawning a prefetch for a stopped service.
        if Task.isCancelled { return }
        let list = Self.radarFrames(from: data)
        guard let newest = list.last(where: { !$0.isForecast }) ?? list.last else {
            failed = (tileTemplate == nil); return                // keep the last good frame on failure
        }
        frames = list
        nowIndex = list.firstIndex(of: newest) ?? max(0, list.count - 1)
        failed = false
        if !animating && !scrubbing { apply(index: nowIndex) }    // follow "now" unless the pilot took control
        else { apply(index: min(currentIndex, list.count - 1)) }  // keep the pinned/animating position valid
        prefetch()
    }

    /// Set the shown frame + derive the template & label. Single choke point so tileTemplate/label never drift.
    private func apply(index: Int) {
        guard frames.indices.contains(index) else { return }
        currentIndex = index
        tileTemplate = frames[index].template
        frameLabel = Self.label(for: frames[index])
    }

    // MARK: animation

    private func startAnimation() {
        guard animTask == nil, frames.count >= 2 else { return }
        animating = true
        scrubbing = false
        var i = 0
        animTask = Task { [weak self] in
            while !Task.isCancelled {                              // bounded by cancellation (rule 2)
                guard let n = await self?.frames.count, n >= 2 else { return }
                let idx = i % n
                await MainActor.run { self?.apply(index: idx) }
                let hold = await (self?.nowIndex == idx) ? Self.holdNanos : Self.frameNanos
                try? await Task.sleep(nanoseconds: hold)
                i = (i + 1) % max(n, 1)
            }
        }
    }

    private func stopAnimation() {
        animTask?.cancel(); animTask = nil
        animating = false
    }

    /// "−40 min" / "now" / "+20 min" for a frame relative to the current wall clock (rounded to 10 min).
    private static func label(for f: RadarFrame) -> String {
        let deltaMin = Int((f.time.timeIntervalSinceNow / 60).rounded())
        if abs(deltaMin) <= 5 { return "now" }
        return deltaMin < 0 ? "−\(-deltaMin) min" : "+\(deltaMin) min"
    }

    // MARK: prefetch (buffer % + smoother first loop)

    /// Warm the tiles the pilot is LOOKING AT, so the radar on screen fills in first and the loop plays
    /// smoothly. Ordering is the whole point:
    ///
    ///   1. the CURRENT frame's viewport cover, nearest-to-center first — what is on screen right now;
    ///   2. then the remaining frames, one center tile each, so the animation still has something warm.
    ///
    /// Pass 2 is deliberately thin: a full cover × ~13 frames would be a hundred requests every rollover,
    /// and MapLibre fetches whatever the visible frame actually needs on its own. Runs only when the frame
    /// set changed OR the map moved meaningfully, and shows the % only on the first pass, so the corner
    /// pill never re-flashes over already-live radar.
    private func prefetch() {
        let list = frames
        guard let newest = list.last?.time else { prefetchTask?.cancel(); bufferProgress = nil; return }
        let region = prefetchRegion
        let movedEnough = region != nil && (lastPrefetchRegion.map { region!.differsMeaningfully(from: $0) } ?? true)
        // ⚠️ Decide BEFORE cancelling. The first version cancelled the in-flight warm and THEN hit
        // this no-op guard, killing a healthy prefetch and stranding bufferProgress at a partial %
        // forever (the pill's "Radar loop 43%" with nothing happening behind it).
        guard newest != lastPrefetchNewest || movedEnough else { return }   // same frames, same view → done
        prefetchTask?.cancel()
        lastPrefetchNewest = newest
        lastPrefetchRegion = region
        let showPct = !didFirstBuffer
        // Where to warm: the visible region when the map has reported one, else the aircraft, else CONUS.
        let viewport: [RadarRegion.Tile]
        if let region {
            viewport = Self.viewportTiles(region)
        } else {
            let t = Self.representativeTile(center: prefetchCenter)
            viewport = [RadarRegion.Tile(z: t.z, x: t.x, y: t.y)]
        }
        let centerTile = viewport.first ?? RadarRegion.Tile(z: 4, x: 0, y: 0)
        let current = frames.indices.contains(currentIndex) ? frames[currentIndex] : list[0]
        // The work list, in priority order: the visible frame's whole cover, then one tile per other frame.
        var jobs: [(template: String, tile: RadarRegion.Tile)] = viewport.map { (current.template, $0) }
        for f in list where f != current { jobs.append((f.template, centerTile)) }
        if showPct { bufferProgress = 0 }
        prefetchTask = Task { [weak self] in
            var done = 0
            for job in jobs {                                     // bounded: viewport ≤ 9 + frames (rule 2)
                if Task.isCancelled { return }
                let url = job.template
                    .replacingOccurrences(of: "{z}", with: "\(job.tile.z)")
                    .replacingOccurrences(of: "{x}", with: "\(job.tile.x)")
                    .replacingOccurrences(of: "{y}", with: "\(job.tile.y)")
                if let u = URL(string: url) {
                    var r = URLRequest(url: u); r.timeoutInterval = 10
                    _ = try? await URLSession.shared.data(for: r)  // warms URLCache; result ignored
                }
                if Task.isCancelled { return }                    // don't write a stale % after a newer prefetch reset it
                done += 1
                if showPct {
                    let frac = Double(done) / Double(jobs.count)
                    await MainActor.run { self?.bufferProgress = frac < 1 ? frac : nil }
                }
            }
            await MainActor.run { self?.didFirstBuffer = true; self?.bufferProgress = nil }
        }
    }

    /// The map moved (or zoomed) — re-warm around the new view if it moved far enough to matter. Called
    /// from the engines' debounced visible-region settle, so a drag re-warms once it comes to rest.
    func viewportChanged(_ region: RadarRegion) {
        prefetchRegion = region
        guard refreshTask != nil, !frames.isEmpty else { return }   // layer off / nothing fetched yet
        prefetch()
    }

    /// A single slippy tile covering the given center (z6 regional), or a CONUS overview (z4) with no center.
    nonisolated static func representativeTile(center: (lat: Double, lon: Double)?) -> (z: Int, x: Int, y: Int) {
        let z = center == nil ? 4 : 6
        let lat = center?.lat ?? 39.5, lon = center?.lon ?? -98.35     // geographic center of CONUS
        return tile(lat: lat, lon: lon, z: z)
    }

    /// Slippy-tile address of a coordinate, clamped to the pyramid. Web-Mercator, so latitude is clamped
    /// to ±85.05° — `tan` blows up at the poles and RainViewer has no data there anyway.
    nonisolated static func tile(lat: Double, lon: Double, z: Int) -> (z: Int, x: Int, y: Int) {
        let n = Double(1 << z)
        let clampedLat = min(max(lat, -85.05), 85.05)
        let x = Int(floor((lon + 180.0) / 360.0 * n))
        let latRad = clampedLat * .pi / 180
        let y = Int(floor((1 - log(tan(latRad) + 1 / cos(latRad)) / .pi) / 2 * n))
        let cap = (1 << z) - 1
        return (z, min(max(x, 0), cap), min(max(y, 0), cap))
    }

    /// RainViewer's free tier serves a "Zoom Level Not Supported" placeholder past z7 (the raster layer
    /// caps there too and overzooms), so tiles are never requested deeper than this.
    static let maxRadarZoom = 7

    /// The tiles covering `region`, **nearest-to-center first** and bounded — the tiles the pilot is
    /// actually looking at, in the order they matter. Zoom is chosen so the cover stays small: start at
    /// the deepest allowed level and back off until the cover fits in `maxTiles`, so a tight view gets
    /// sharp regional tiles and a continental view gets a couple of coarse ones instead of hundreds.
    ///
    /// Pure + nonisolated so it is unit-tested without a map or a network.
    nonisolated static func viewportTiles(_ region: RadarRegion, maxTiles: Int = 9) -> [RadarRegion.Tile] {
        assert(maxTiles > 0, "viewportTiles: maxTiles must be positive")
        guard region.latSpan > 0, region.lonSpan > 0, maxTiles > 0 else {
            let t = tile(lat: region.centerLat, lon: region.centerLon, z: 4)
            return [RadarRegion.Tile(z: t.z, x: t.x, y: t.y)]
        }
        let minLat = region.centerLat - region.latSpan / 2, maxLat = region.centerLat + region.latSpan / 2
        let minLon = region.centerLon - region.lonSpan / 2, maxLon = region.centerLon + region.lonSpan / 2
        var z = maxRadarZoom
        while z > 0 {                                                  // bounded: z is strictly decreasing
            assert(z <= maxRadarZoom, "viewportTiles: zoom out of range")
            // y grows southward, so the NORTH edge gives the low y.
            let tl = tile(lat: maxLat, lon: minLon, z: z), br = tile(lat: minLat, lon: maxLon, z: z)
            let wide = br.x >= tl.x ? (br.x - tl.x + 1) : (1 << z)      // antimeridian span → whole row
            let tall = br.y - tl.y + 1
            if wide * tall <= maxTiles { return ordered(tl: tl, br: br, wide: wide, region: region, z: z) }
            z -= 1
        }
        let t = tile(lat: region.centerLat, lon: region.centerLon, z: 0)
        return [RadarRegion.Tile(z: t.z, x: t.x, y: t.y)]
    }

    /// The cover rectangle, sorted by distance from the region's center tile so the middle of the screen
    /// fills first (a pilot reads the weather under the aircraft before the corners).
    private nonisolated static func ordered(tl: (z: Int, x: Int, y: Int), br: (z: Int, x: Int, y: Int),
                                            wide: Int, region: RadarRegion, z: Int) -> [RadarRegion.Tile] {
        let c = tile(lat: region.centerLat, lon: region.centerLon, z: z)
        let cap = 1 << z
        var out: [RadarRegion.Tile] = []
        var dy = 0
        while tl.y + dy <= br.y {                                      // bounded by the cover height
            assert(out.count <= 4096, "viewportTiles: cover unbounded")
            var dx = 0
            while dx < wide {                                          // bounded by the cover width
                out.append(RadarRegion.Tile(z: z, x: (tl.x + dx) % cap, y: tl.y + dy))
                dx += 1
            }
            dy += 1
        }
        return out.sorted { a, b in
            // Compare on the x-wrap-aware ring distance so a cover straddling the antimeridian still
            // orders outward from the center rather than treating x=0 and x=cap-1 as far apart.
            func d(_ t: RadarRegion.Tile) -> Int {
                let raw = abs(t.x - c.x)
                return min(raw, cap - raw) + abs(t.y - c.y)
            }
            return d(a) < d(b)
        }
    }

    // MARK: parsing (pure / testable)

    /// Parse RainViewer's weather-maps.json → the newest radar frame's `{z}/{x}/{y}` PNG template. Pure so
    /// it's unit-testable. color=2 (universal blue), options 1_1 (smoothed + show snow), 256px tiles.
    nonisolated static func latestRadarTemplate(from data: Data) -> String? {
        guard let m = try? JSONDecoder().decode(WeatherMaps.self, from: data) else { return nil }
        guard let frame = m.radar.nowcast?.last ?? m.radar.past.last else { return nil }   // prefer the nowcast tip
        assert(!m.host.isEmpty && !frame.path.isEmpty, "RainViewer: empty host/path")
        return "\(m.host)\(frame.path)/256/{z}/{x}/{y}/2/1_1.png"
    }

    /// Parse the FULL ordered frame list (observed past then forecast nowcast) for the loop animation.
    nonisolated static func radarFrames(from data: Data) -> [RadarFrame] {
        guard let m = try? JSONDecoder().decode(WeatherMaps.self, from: data), !m.host.isEmpty else { return [] }
        func make(_ fs: [WeatherMaps.Frame], forecast: Bool) -> [RadarFrame] {
            fs.compactMap { f in
                guard !f.path.isEmpty else { return nil }
                return RadarFrame(template: "\(m.host)\(f.path)/256/{z}/{x}/{y}/2/1_1.png",
                                  time: Date(timeIntervalSince1970: TimeInterval(f.time)), isForecast: forecast)
            }
        }
        return make(m.radar.past, forecast: false) + make(m.radar.nowcast ?? [], forecast: true)
    }

    private struct WeatherMaps: Decodable {
        let host: String
        let radar: Radar
        struct Radar: Decodable { let past: [Frame]; let nowcast: [Frame]? }
        struct Frame: Decodable { let path: String; let time: Int }
    }
}
