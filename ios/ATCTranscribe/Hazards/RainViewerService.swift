import Foundation

/// One radar frame: a tile-URL template + its timestamp + whether it's an observed past frame or a
/// forecast (nowcast) frame. Used to animate the storm's movement (past → now → forecast).
struct RadarFrame: Equatable {
    let template: String       // "…/{z}/{x}/{y}/…png"
    let time: Date
    let isForecast: Bool
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
    var prefetchCenter: (lat: Double, lon: Double)?

    /// Attribution required by RainViewer's free tier.
    static let attribution = "Radar: RainViewer"

    private var scrubbing = false                          // a manual scrub pins the frame across refreshes
    private var lastPrefetchNewest: Date?                  // frames already warmed → don't re-prefetch/re-flash
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
        lastPrefetchNewest = nil; didFirstBuffer = false
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

    /// Warm one representative tile per frame so the loop plays smoothly the first time and the loading pill
    /// can show a real %. Light: one small tile per frame (~a dozen). Runs only when the FRAME SET actually
    /// changed (not on every 5-min refresh of the same frames), and surfaces the % only on the FIRST pass —
    /// subsequent new-frame warms are silent, so the corner pill never re-flashes over already-live radar.
    private func prefetch() {
        prefetchTask?.cancel()
        let list = frames
        guard let newest = list.last?.time else { bufferProgress = nil; return }
        guard newest != lastPrefetchNewest else { return }        // these exact frames already warmed
        lastPrefetchNewest = newest
        let showPct = !didFirstBuffer
        let (z, x, y) = Self.representativeTile(center: prefetchCenter)
        if showPct { bufferProgress = 0 }
        prefetchTask = Task { [weak self] in
            var done = 0
            for f in list {                                       // bounded by frames.count (rule 2)
                if Task.isCancelled { return }
                let tile = f.template
                    .replacingOccurrences(of: "{z}", with: "\(z)")
                    .replacingOccurrences(of: "{x}", with: "\(x)")
                    .replacingOccurrences(of: "{y}", with: "\(y)")
                if let u = URL(string: tile) {
                    var r = URLRequest(url: u); r.timeoutInterval = 10
                    _ = try? await URLSession.shared.data(for: r)  // warms URLCache; result ignored
                }
                if Task.isCancelled { return }                    // don't write a stale % after a newer prefetch reset it
                done += 1
                if showPct {
                    let frac = Double(done) / Double(list.count)
                    await MainActor.run { self?.bufferProgress = frac < 1 ? frac : nil }
                }
            }
            await MainActor.run { self?.didFirstBuffer = true; self?.bufferProgress = nil }
        }
    }

    /// A single slippy tile covering the given center (z6 regional), or a CONUS overview (z4) with no center.
    nonisolated static func representativeTile(center: (lat: Double, lon: Double)?) -> (z: Int, x: Int, y: Int) {
        let z = center == nil ? 4 : 6
        let lat = center?.lat ?? 39.5, lon = center?.lon ?? -98.35     // geographic center of CONUS
        let n = Double(1 << z)
        let x = Int(floor((lon + 180.0) / 360.0 * n))
        let latRad = lat * .pi / 180
        let y = Int(floor((1 - log(tan(latRad) + 1 / cos(latRad)) / .pi) / 2 * n))
        let cap = (1 << z) - 1
        return (z, min(max(x, 0), cap), min(max(y, 0), cap))
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
