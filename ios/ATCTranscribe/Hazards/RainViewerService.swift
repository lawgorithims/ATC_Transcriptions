import Foundation

/// Live precipitation-radar tiles from RainViewer (free, no API key). RainViewer's tile path carries the
/// FRAME TIMESTAMP and rolls over every ~10 min, so we can't hardcode a `{z}/{x}/{y}` template — we fetch
/// `weather-maps.json` to get the latest frame's path, then publish a standard raster template both map
/// engines can consume. Refreshed on a timer only while the layer is on + foregrounded (no idle cost).
@MainActor final class RainViewerService: ObservableObject {
    /// The current radar raster URL template ("…/{z}/{x}/{y}/…png"), or nil when off / not yet fetched.
    @Published private(set) var tileTemplate: String?
    /// Attribution required by RainViewer's free tier.
    static let attribution = "Radar: RainViewer"

    private var refreshTask: Task<Void, Never>?
    private static let refreshSeconds: UInt64 = 300         // frames update ~every 10 min; refresh every 5

    /// Edge-triggered: start refreshing when the layer turns on, stop + clear when off (idle cost = zero).
    func setEnabled(_ on: Bool) {
        if on { start() } else { stop() }
    }

    private func start() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {                            // bounded by cancellation (rule 2)
                await self?.refresh()
                try? await Task.sleep(nanoseconds: Self.refreshSeconds * 1_000_000_000)
            }
        }
    }
    private func stop() { refreshTask?.cancel(); refreshTask = nil; tileTemplate = nil }

    private func refresh() async {
        guard let url = URL(string: "https://api.rainviewer.com/public/weather-maps.json") else { return }
        var req = URLRequest(url: url); req.timeoutInterval = 12
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let template = Self.latestRadarTemplate(from: data) else { return }   // keep the last good on failure
        tileTemplate = template
    }

    /// Parse RainViewer's weather-maps.json → the newest radar frame's `{z}/{x}/{y}` PNG template. Pure so
    /// it's unit-testable. color=2 (universal blue), options 1_1 (smoothed + show snow), 256px tiles.
    nonisolated static func latestRadarTemplate(from data: Data) -> String? {
        guard let m = try? JSONDecoder().decode(WeatherMaps.self, from: data) else { return nil }
        guard let frame = m.radar.nowcast?.last ?? m.radar.past.last else { return nil }   // prefer the nowcast tip
        assert(!m.host.isEmpty && !frame.path.isEmpty, "RainViewer: empty host/path")
        return "\(m.host)\(frame.path)/256/{z}/{x}/{y}/2/1_1.png"
    }

    private struct WeatherMaps: Decodable {
        let host: String
        let radar: Radar
        struct Radar: Decodable { let past: [Frame]; let nowcast: [Frame]? }
        struct Frame: Decodable { let path: String }
    }
}
