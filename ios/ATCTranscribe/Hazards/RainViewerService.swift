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
/// `weather-maps.json` for the frame list (last ~2 h of observed + ~30 min of nowcast), then publish a
/// standard raster template both map engines can consume. Refreshed on a timer only while the layer is on
/// + foregrounded (no idle cost). The frames also drive an optional loop animation so the pilot can see
/// which way the weather is moving.
@MainActor final class RainViewerService: ObservableObject {
    /// The template the map should draw RIGHT NOW — the newest frame at rest, or the current animation
    /// frame while looping. Bridged to both map engines. nil when off / not yet fetched.
    @Published private(set) var tileTemplate: String?
    /// True when the LAST fetch failed AND we have nothing to show (drives the "radar unavailable" pill —
    /// a failure with a last-good template keeps showing the old frame instead).
    @Published private(set) var failed = false
    /// Whether the loop animation is currently playing.
    @Published private(set) var animating = false
    /// A short label for the frame on screen, relative to now: "−40 min", "now", "+20 min", or "".
    @Published private(set) var frameLabel = ""
    /// True once ≥2 frames are loaded (the animation control is meaningful).
    @Published private(set) var canAnimate = false

    /// Attribution required by RainViewer's free tier.
    static let attribution = "Radar: RainViewer"

    private var frames: [RadarFrame] = []
    private var nowFrameIndex = 0                            // index of the newest OBSERVED (past) frame
    private var animIndex = 0
    private var refreshTask: Task<Void, Never>?
    private var animTask: Task<Void, Never>?
    private static let refreshSeconds: UInt64 = 300         // frames update ~every 10 min; refresh every 5
    private static let retrySeconds: UInt64 = 15            // faster retry while we have NOTHING to show yet
    private static let frameNanos: UInt64 = 500_000_000     // 0.5 s per frame while animating
    private static let holdNanos: UInt64 = 1_400_000_000    // pause on the newest frame each loop

    /// Edge-triggered: start refreshing when the layer turns on, stop + clear when off (idle cost = zero).
    func setEnabled(_ on: Bool) {
        if on { start() } else { stop() }
    }

    /// Play / pause the past→now→forecast loop. No-op if there aren't enough frames.
    func toggleAnimation() {
        guard canAnimate else { return }
        if animating { stopAnimation(resetToNow: true) } else { startAnimation() }
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
        stopAnimation(resetToNow: false)
        frames = []; canAnimate = false; frameLabel = ""
        tileTemplate = nil; failed = false
    }

    private func refresh() async {
        guard let url = URL(string: "https://api.rainviewer.com/public/weather-maps.json") else { return }
        var req = URLRequest(url: url); req.timeoutInterval = 12
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else {
            failed = (tileTemplate == nil); return
        }
        let list = Self.radarFrames(from: data)
        guard let newest = list.last(where: { !$0.isForecast }) ?? list.last else {
            failed = (tileTemplate == nil); return                // keep the last good frame on failure
        }
        frames = list
        nowFrameIndex = list.firstIndex(of: newest) ?? max(0, list.count - 1)
        canAnimate = list.count >= 2
        failed = false
        if animating {                                            // keep looping across a refresh
            animIndex = min(animIndex, list.count - 1)
        } else {
            tileTemplate = newest.template                        // at rest → show "now"
            frameLabel = ""
        }
    }

    // MARK: animation

    private func startAnimation() {
        guard animTask == nil, frames.count >= 2 else { return }
        animating = true
        animIndex = 0
        animTask = Task { [weak self] in
            while !Task.isCancelled {                              // bounded by cancellation (rule 2)
                guard let advance = await self?.showAnimationFrame() else { return }
                try? await Task.sleep(nanoseconds: advance)
            }
        }
    }

    /// Show the current animation frame + advance the index; returns how long to hold it. Longest hold on the
    /// newest observed frame so the loop reads as "…building up to now, then a peek at the forecast."
    private func showAnimationFrame() -> UInt64 {
        guard !frames.isEmpty else { return Self.frameNanos }
        let i = min(animIndex, frames.count - 1)
        let f = frames[i]
        tileTemplate = f.template
        frameLabel = Self.label(for: f)
        let hold = (i == nowFrameIndex) ? Self.holdNanos : Self.frameNanos
        animIndex = (i + 1) % frames.count
        return hold
    }

    private func stopAnimation(resetToNow: Bool) {
        animTask?.cancel(); animTask = nil
        animating = false
        if resetToNow, frames.indices.contains(nowFrameIndex) {
            tileTemplate = frames[nowFrameIndex].template
            frameLabel = ""
        }
    }

    /// "−40 min" / "now" / "+20 min" for a frame relative to the current wall clock (rounded to 10 min).
    private static func label(for f: RadarFrame) -> String {
        let deltaMin = Int((f.time.timeIntervalSinceNow / 60).rounded())
        if abs(deltaMin) <= 5 { return "now" }
        return deltaMin < 0 ? "−\(-deltaMin) min" : "+\(deltaMin) min"
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
