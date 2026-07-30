import Foundation

/// Network seam so the service's lifecycle is unit-testable without hitting NCEP (a fake in tests,
/// `LiveWindGribFetcher` in the app). Mirrors `TFRFetching`.
protocol WindGribFetching: Sendable {
    /// Returns the response body, or throws. A 404 — the requested cycle/forecast hour is not published —
    /// must throw `WindFetchError.notFound` so the caller can walk back to an older cycle instead of
    /// treating it as an outage.
    func fetch(_ url: URL) async throws -> Data
}

enum WindFetchError: Error, Equatable {
    case notFound
    case badResponse
    case notGrib
}

/// Live fetch from NCEP's NOMADS GRIB filter. The payload is validated by MAGIC BYTES, not just by status
/// code: the filter answers a malformed request with a 200 and an HTML page, and an HTML page decoded as
/// weather is exactly the failure mode that must never reach the map.
struct LiveWindGribFetcher: WindGribFetching {
    func fetch(_ url: URL) async throws -> Data {
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.setValue("CommSight/1.0", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 { throw WindFetchError.notFound }
        guard code == 200 else { throw WindFetchError.badResponse }
        guard WindFetchPlan.looksLikeGrib(data) else { throw WindFetchError.notGrib }
        return data
    }
}

/// The pure, nonisolated half of the winds-aloft fetch: what area to ask NCEP for, which model cycle to
/// try, and what URL that is. Split out of `WindAloftService` (which is `@MainActor`, because it publishes
/// to SwiftUI) so this geometry can be called from the network path and unit-tested with no actor at all.
enum WindFetchPlan {

    /// How many six-hourly cycles to walk back before giving up. NOMADS has been observed serving a cycle
    /// as much as 18 h old, so five covers 30 h of publication lag.
    static let maxCycleAttempts = 5
    /// The deepest forecast hour the 1-hourly dataset publishes.
    static let maxForecastHour = 120

    /// A CONUS-wide default for the first fetch before the map has reported a region.
    static let conus = RadarRegion(centerLat: 39, centerLon: -96, latSpan: 20, lonSpan: 30)

    /// The largest box the GRIB filter is asked for — and therefore also the largest VISIBLE box the
    /// containment test may consider, so "is the held grid big enough" is always a question that can be
    /// answered yes. ~950 KB at 70x35; past this the overlay is faded out entirely.
    static let maxFetchLatSpan = 40.0
    static let maxFetchLonSpan = 60.0

    /// Grid resolution of the GFS 0.25° product. Box edges snap to it so the returned grid lines up with
    /// what was asked for and a one-pixel pan cannot produce a different request.
    static let gridStep = 0.25

    /// The area to download for a given view, plus the visible area it must cover.
    ///
    /// `fetch` is deliberately larger than the screen: the pilot pans constantly, and a box sized to the
    /// viewport would re-download on every drag. It is also clamped at the top end, because the filter's
    /// cost grows with area and a whole-hemisphere request would be both slow and pointless at the zooms
    /// where the overlay draws.
    static func fetchBBox(for region: RadarRegion) -> (fetch: WindBBox, visible: WindBBox) {
        assert(gridStep > 0, "WindFetchPlan: grid step must be positive")
        assert(region.latSpan.isFinite && region.lonSpan.isFinite, "WindFetchPlan: non-finite span")
        // The VISIBLE box is what `needsFetch` asks the held grid to contain, and the fetch box is capped
        // at 40 x 60 degrees — so on a wide view the visible box is LARGER than anything we can fetch and
        // the containment test can never be satisfied: every settle asks for ~1 MB again, forever. Cap the
        // visible box at the same size so the question stays answerable. Nothing is lost by it: past
        // `WindParticleRenderer.cutoffSpan` (45 degrees of longitude) the layer draws NOTHING anyway,
        // because one affine no longer describes the screen — so the area beyond the cap is area the
        // pilot cannot see wind in. Before, that was the exact zoom where it downloaded hardest.
        let visLat = min(max(region.latSpan, 0.5), maxFetchLatSpan)
        let visLon = min(max(region.lonSpan, 0.5), maxFetchLonSpan)
        let visible = clampBox(centerLat: region.centerLat, centerLon: region.centerLon,
                               latSpan: visLat, lonSpan: visLon)
        let padLat = min(max(visLat * 1.6, 15), maxFetchLatSpan)
        let padLon = min(max(visLon * 1.6, 20), maxFetchLonSpan)
        let fetch = clampBox(centerLat: region.centerLat, centerLon: region.centerLon,
                             latSpan: padLat, lonSpan: padLon)
        return (fetch, visible)
    }

    /// Build a grid-snapped box around a centre, clamped to the valid coordinate range. Longitude is
    /// clamped rather than wrapped: the filter cannot express a box crossing the antimeridian, and losing
    /// the far side of the dateline is better than requesting a mirrored grid that samples backwards.
    private static func clampBox(centerLat: Double, centerLon: Double,
                                 latSpan: Double, lonSpan: Double) -> WindBBox {
        assert(latSpan > 0 && lonSpan > 0, "WindFetchPlan: non-positive span")
        assert(gridStep > 0, "WindFetchPlan: grid step must be positive")
        let snapDown = { (v: Double) in (v / gridStep).rounded(.down) * gridStep }
        let snapUp = { (v: Double) in (v / gridStep).rounded(.up) * gridStep }
        let minLat = max(snapDown(centerLat - latSpan / 2), -90)
        let maxLat = min(snapUp(centerLat + latSpan / 2), 90)
        var minLon = snapDown(centerLon - lonSpan / 2)
        var maxLon = snapUp(centerLon + lonSpan / 2)
        if minLon < -180 { maxLon = min(maxLon - minLon - 180, 180); minLon = -180 }
        if maxLon > 180 { minLon = max(minLon - (maxLon - 180), -180); maxLon = 180 }
        return WindBBox(minLat: minLat, minLon: minLon, maxLat: maxLat, maxLon: maxLon)
    }

    /// Candidate (cycle, forecast hour) pairs, newest first. GFS runs at 00/06/12/18Z and publishes hours
    /// after the fact, so the newest cycle whose file exists is unknown up front — hence a bounded walk
    /// rather than a computed guess. The forecast hour is whichever one is valid closest to now.
    static func candidates(now: Date) -> [(cycle: Date, forecastHour: Int)] {
        assert(maxCycleAttempts > 0, "WindFetchPlan: cycle cap must be positive")
        assert(maxForecastHour > 0, "WindFetchPlan: forecast cap must be positive")
        let sixHours: TimeInterval = 6 * 3600
        let floored = (now.timeIntervalSince1970 / sixHours).rounded(.down) * sixHours
        var out: [(Date, Int)] = []
        for step in 0..<maxCycleAttempts {                       // bounded by maxCycleAttempts (rule 2)
            let cycle = Date(timeIntervalSince1970: floored - Double(step) * sixHours)
            let hours = Int((now.timeIntervalSince(cycle) / 3600).rounded())
            guard hours >= 0, hours <= maxForecastHour else { continue }
            out.append((cycle, hours))
        }
        return out
    }

    /// The GRIB-filter URL for one cycle, forecast hour and box.
    ///
    /// OPeNDAP would have been the natural fit for a gridded subset, but NCEP retired it (Service Change
        /// Notice 25-81); `filter_*.pl` is what remains. Encoding is done by hand because `dir` contains
    /// slashes that must survive as `%2F`.
    static func filterURL(cycle: Date, forecastHour: Int, bbox: WindBBox) -> URL? {
        assert(forecastHour >= 0, "WindFetchPlan: negative forecast hour")
        assert(bbox.latSpan > 0 && bbox.lonSpan > 0, "WindFetchPlan: degenerate bbox")
        guard forecastHour <= maxForecastHour, bbox.latSpan > 0, bbox.lonSpan > 0 else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let c = cal.dateComponents([.year, .month, .day, .hour], from: cycle)
        guard let y = c.year, let mo = c.month, let d = c.day, let h = c.hour else { return nil }
        let day = String(format: "%04d%02d%02d", y, mo, d)
        let hh = String(format: "%02d", h)
        let dir = "/gfs.\(day)/\(hh)/atmos"
            .addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: ".-_")))
        guard let dir else { return nil }
        let file = String(format: "gfs.t%@z.pgrb2.0p25.f%03d", hh, forecastHour)
        let levels = WindLevel.allCases.map { "&\($0.gribLevParam)=on" }.joined()
        let box = String(format: "&subregion=&leftlon=%.2f&rightlon=%.2f&bottomlat=%.2f&toplat=%.2f",
                         bbox.minLon, bbox.maxLon, bbox.minLat, bbox.maxLat)
        let query = "dir=\(dir)&file=\(file)&var_UGRD=on&var_VGRD=on\(levels)\(box)"
        return URL(string: "https://nomads.ncep.noaa.gov/cgi-bin/filter_gfs_0p25_1hr.pl?\(query)")
    }

    /// GRIB2 magic bytes — the guard against decoding an HTML error page as weather.
    static func looksLikeGrib(_ data: Data) -> Bool {
        guard data.count > 16 else { return false }
        return data[data.startIndex] == 0x47 && data[data.startIndex + 1] == 0x52
            && data[data.startIndex + 2] == 0x49 && data[data.startIndex + 3] == 0x42
    }
}

/// Winds aloft for the animated wind overlay: GFS 0.25° U/V on ten levels, subset to the visible map area
/// by NCEP's GRIB filter and decoded on device.
///
/// **Why one download carries every level.** The filter charges essentially nothing for extra levels — a
/// 20°×15° box with all ten levels is ~115 KB — so the whole column is fetched at once. That is what makes
/// the altitude slider feel instant: moving it re-reads memory and never touches the network.
///
/// **Why this is event-driven rather than a poller.** The radar rolls over every ten minutes, so
/// `RainViewerService` runs a timer. A GFS cycle publishes every six hours, so a timer would spend all day
/// re-downloading a file that has not changed. Instead a fetch happens when something makes the held data
/// wrong: the layer turns on, the map pans outside the covered box, or the shown forecast hour drifts more
/// than an hour from the wall clock. A slow 15-minute heartbeat exists only to notice that last case while
/// the pilot sits still — without it, an overlay left up for a long leg would quietly freeze on an old hour.
///
/// **Never-clear-on-fail.** A failed fetch keeps the last good field set (and the disk snapshot), matching
/// the TFR and EONET services: stale wind with an honest age on the chip beats an empty map.
///
/// NASA/JPL Power-of-10: bounded cycle walk and bounded loops; no recursion; every input validated with
/// safe recovery; decode runs off the main actor so a 20-message payload never blocks a frame.
@MainActor final class WindAloftService: ObservableObject {

    /// The decoded column for the currently covered area. nil until the first successful fetch or a
    /// restored snapshot. Retained across `setEnabled(false)` so re-enabling the layer is instant.
    @Published private(set) var fieldSet: WindFieldSet?
    /// True while a download/decode is in flight (drives the chip's spinner).
    @Published private(set) var fetching = false
    /// True when the last attempt failed AND there is nothing to show.
    @Published private(set) var failed = false

    /// Attribution + the honest caveat: this is model data, not an official briefing.
    static let attribution = "Winds: NOAA/NCEP GFS. Model forecast — not an official briefing."

    // Hard caps and tuning constants (rule 2: every loop below is bounded by one of these).
    /// Re-fetch once the shown forecast hour is this far from the wall clock.
    static let refetchAge: TimeInterval = 3600
    /// Heartbeat that notices staleness while the map sits still.
    static let heartbeatSeconds: UInt64 = 900
    /// Backoff after a failed attempt: 30 s doubling to a 10-minute ceiling.
    static let backoffBase: TimeInterval = 30
    static let backoffCeiling: TimeInterval = 600

    private let fetcher: WindGribFetching
    private let now: @Sendable () -> Date
    private let cacheDirectory: URL?
    private var enabled = false
    private var region: RadarRegion?
    private var fetchTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var failureStreak = 0
    private var lastAttemptAt: Date?
    private var didLoadSnapshot = false

    init(fetcher: WindGribFetching = LiveWindGribFetcher(),
         now: @escaping @Sendable () -> Date = { Date() },
         cacheDirectory: URL? = nil) {
        self.fetcher = fetcher
        self.now = now
        self.cacheDirectory = cacheDirectory
    }

    // MARK: - lifecycle

    /// Edge-triggered from `AppModel.syncWind()`. Turning the layer on restores the disk snapshot (so an
    /// offline cold start shows something immediately) and fetches if the held data is missing or wrong.
    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        if on {
            loadSnapshotOnce()
            startHeartbeat()
            maybeFetch()
        } else {
            fetchTask?.cancel(); fetchTask = nil
            heartbeatTask?.cancel(); heartbeatTask = nil
            fetching = false
        }
    }

    /// The map settled on a new view. Called from the engines' debounced visible-region callback, so a drag
    /// triggers at most one evaluation once it comes to rest.
    func viewportChanged(_ region: RadarRegion) {
        assert(region.latSpan >= 0, "WindAloftService: negative latitude span")
        assert(region.lonSpan >= 0, "WindAloftService: negative longitude span")
        self.region = region
        guard enabled else { return }
        maybeFetch()
    }

    /// The wind at a coordinate on the selected level — the flight-plan strip's WIND cell and the map's
    /// object card read this. nil when the level or the coordinate is not covered.
    func wind(at lat: Double, lon: Double, level: WindLevel) -> (kt: Float, fromDeg: Float)? {
        guard let f = fieldSet?.field(level),
              let kt = f.speedKt(lat: lat, lon: lon),
              let dir = f.directionFromDeg(lat: lat, lon: lon) else { return nil }
        assert(kt >= 0, "WindAloftService: negative speed")
        assert(dir >= 0 && dir < 360.001, "WindAloftService: direction out of range")
        return (kt, dir)
    }

    // MARK: - fetch decision

    /// Whether the held data no longer answers the question on screen. Pure apart from the clock.
    private func needsFetch() -> Bool {
        guard let set = fieldSet else { return true }
        if let r = region, !set.bbox.contains(WindFetchPlan.fetchBBox(for: r).visible) { return true }
        return abs(now().timeIntervalSince(set.validTime)) > Self.refetchAge
    }

    private func maybeFetch() {
        guard enabled, fetchTask == nil, needsFetch() else { return }
        if let last = lastAttemptAt, failureStreak > 0 {
            let wait = min(Self.backoffBase * pow(2, Double(failureStreak - 1)), Self.backoffCeiling)
            guard now().timeIntervalSince(last) >= wait else { return }
        }
        let box = WindFetchPlan.fetchBBox(for: region ?? WindFetchPlan.conus).fetch
        lastAttemptAt = now()
        fetching = true
        // Clear the handle ONLY if it is still this task's. A cancelled or superseded fetch that blindly
        // nils `fetchTask` releases the single-flight lock held by the fetch that REPLACED it — after
        // which `maybeFetch`'s `fetchTask == nil` guard admits a second concurrent download of the same
        // box, and `fetching` flickers off while one is still running (the chip stops showing progress
        // that is still happening).
        var task: Task<Void, Never>?
        task = Task { [weak self] in
            await self?.run(box: box)
            guard let self, self.fetchTask == task else { return }
            self.fetchTask = nil
            self.fetching = false
        }
        fetchTask = task
    }

    /// Walk candidate cycles newest-first until one yields a decodable payload. A 404 is a miss (that
    /// cycle/hour is not published yet) and moves to the next candidate; any other error aborts the walk so
    /// a network outage does not burn five requests.
    private func run(box: WindBBox) async {
        let candidates = WindFetchPlan.candidates(now: now())
        assert(candidates.count <= WindFetchPlan.maxCycleAttempts, "WindAloftService: candidate walk exceeded its cap")
        assert(!candidates.isEmpty, "WindAloftService: empty candidate walk")
        for c in candidates {                                   // bounded by maxCycleAttempts (rule 2)
            if Task.isCancelled { return }
            guard let url = WindFetchPlan.filterURL(cycle: c.cycle, forecastHour: c.forecastHour, bbox: box) else { continue }
            do {
                let data = try await fetcher.fetch(url)
                guard let set = await Self.decode(data, bbox: box, at: now()) else { continue }
                if Task.isCancelled { return }
                fieldSet = set
                failed = false
                failureStreak = 0
                saveSnapshot(data, bbox: box, at: set.fetchedAt)
                return
            } catch WindFetchError.notFound {
                continue                                        // not published — try an older cycle
            } catch {
                break                                           // transport failure — stop walking
            }
        }
        guard !Task.isCancelled else { return }
        failureStreak = min(failureStreak + 1, 12)              // bounded so the backoff can't overflow
        failed = (fieldSet == nil)
    }

    /// Decode off the main actor: 20 messages of ~39k points each must never run on the frame thread.
    private nonisolated static func decode(_ data: Data, bbox: WindBBox, at when: Date) async -> WindFieldSet? {
        await Task.detached(priority: .userInitiated) {
            let messages = Grib2Decoder.messages(from: data)
            return WindFieldSet.build(from: messages, bbox: bbox, fetchedAt: when)
        }.value
    }

    /// Slow heartbeat so a stationary map still advances through the forecast hours.
    private func startHeartbeat() {
        guard heartbeatTask == nil else { return }
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {                            // bounded by cancellation (rule 2)
                try? await Task.sleep(nanoseconds: Self.heartbeatSeconds * 1_000_000_000)
                guard !Task.isCancelled else { return }
                self?.maybeFetch()
            }
        }
    }

    // MARK: - disk snapshot

    /// `Application Support/Wind/` — NOT `Caches/`, which iOS silently purges (the same reason the chart
    /// and plate stores live there). The raw GRIB is kept rather than a re-encoded form so the decoder
    /// stays the single source of truth for what the bytes mean.
    private struct SnapshotMeta: Codable { let bbox: WindBBox; let at: Date }

    private var snapshotDirectory: URL? {
        if let cacheDirectory { return cacheDirectory }
        let base = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                appropriateFor: nil, create: true)
        guard let dir = base?.appendingPathComponent("Wind", isDirectory: true) else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func loadSnapshotOnce() {
        guard !didLoadSnapshot, fieldSet == nil else { return }
        didLoadSnapshot = true
        guard let dir = snapshotDirectory,
              let metaData = try? Data(contentsOf: dir.appendingPathComponent("meta.json")),
              let meta = try? JSONDecoder().decode(SnapshotMeta.self, from: metaData),
              let grib = try? Data(contentsOf: dir.appendingPathComponent("snapshot.grib2")),
              WindFetchPlan.looksLikeGrib(grib) else { return }
        let when = meta.at
        let box = meta.bbox
        Task { [weak self] in
            guard let set = await Self.decode(grib, bbox: box, at: when) else { return }
            guard let self, self.fieldSet == nil else { return }   // a live fetch already won
            self.fieldSet = set
        }
    }

    private func saveSnapshot(_ grib: Data, bbox: WindBBox, at when: Date) {
        guard let dir = snapshotDirectory,
              let meta = try? JSONEncoder().encode(SnapshotMeta(bbox: bbox, at: when)) else { return }
        try? grib.write(to: dir.appendingPathComponent("snapshot.grib2"), options: .atomic)
        try? meta.write(to: dir.appendingPathComponent("meta.json"), options: .atomic)
    }
}
