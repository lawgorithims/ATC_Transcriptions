import Foundation

/// Download-once, cache-forever airport climatology: three complete calendar years of NASA POWER
/// hourly wind/temperature/pressure for the airport's grid cell, folded into compact histograms
/// (`PowerClimateStats`) and persisted under Application Support/PowerClimate/. POWER is static
/// history (MERRA-2 reanalysis, ~2–3 month archive lag), so a completed pull for a year range is
/// never re-fetched — one ~2 MB download per airport, ever. Follows the
/// `NetworkAirportContextSource` conventions: ephemeral session, fail-soft (nil on any error),
/// atomic writes; plus an in-memory memo and in-flight de-dupe so concurrent opens share one fetch.
actor PowerClimateStore {
    static let shared = PowerClimateStore()
    static let attribution = "Climate data: NASA POWER (MERRA-2)"

    static let maxYears = 3
    static let lagDays = 120                 // safety margin over the MERRA-2 archive lag
    static let maxResponseBytes = 5_000_000
    static let maxMemo = 8

    private let cacheDirectory: URL?         // test override; nil → Application Support/PowerClimate
    private var memo: [String: PowerClimateStats] = [:]
    private var memoOrder: [String] = []
    private var inFlight: [String: Task<PowerClimateStats?, Never>] = [:]

    init(cacheDirectory: URL? = nil) {
        self.cacheDirectory = cacheDirectory
    }

    /// The stats for an airport: memo → exact-range disk cache → network (≤3 sequential year
    /// fetches, `progress(year, of)` per request) → any older cached range as the offline
    /// fallback. nil when offline with nothing cached. Concurrent opens share one task.
    func stats(ident: String, coord: Coord, fieldElevFt: Int?,
               progress: (@Sendable (Int, Int) -> Void)? = nil) async -> PowerClimateStats? {
        assert(!ident.trimmingCharacters(in: .whitespaces).isEmpty, "ident required")
        assert((-90...90).contains(coord.lat) && (-180...180).contains(coord.lon), "coordinate in range")
        let key = ident.trimmingCharacters(in: .whitespaces).uppercased()
        if let hit = memo[key] { return hit }
        if let existing = inFlight[key] { return await existing.value }
        let dir = cacheDirectory
        let task = Task<PowerClimateStats?, Never> {
            await Self.loadOrFetch(ident: key, coord: coord, fieldElevFt: fieldElevFt,
                                   cacheDirectory: dir, progress: progress)
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        if let result { remember(key, result) }
        return result
    }

    private func remember(_ key: String, _ stats: PowerClimateStats) {
        if memo[key] == nil { memoOrder.append(key) }
        memo[key] = stats
        while memoOrder.count > Self.maxMemo, let oldest = memoOrder.first {   // bounded eviction
            memoOrder.removeFirst()
            memo[oldest] = nil
        }
        assert(memo.count <= Self.maxMemo, "memo bounded")
    }

    // MARK: Target years + request URL (pure, unit-tested)

    /// The `maxYears` most recent COMPLETE calendar years safely past the archive lag —
    /// e.g. mid-2026 → [2023, 2024, 2025].
    static func targetYears(now: Date = Date()) -> [Int] {
        let cutoff = now.addingTimeInterval(-Double(lagDays) * 24 * 3600)
        let year = Calendar(identifier: .gregorian).component(.year, from: cutoff)
        assert(year > 2000 && year < 2200, "plausible year")
        let out = Array((year - maxYears)...(year - 1))
        assert(out.count == maxYears, "year span fixed")
        return out
    }

    /// One calendar year of hourly WS10M/WD10M/T2M/PS. `time-standard=LST` is load-bearing: hours
    /// come back in local solar time, so time-of-day stats need no UTC→local conversion.
    static func url(year: Int, lat: Double, lon: Double) -> URL? {
        assert((-90...90).contains(lat) && (-180...180).contains(lon), "coordinate in range")
        assert(year > 2000 && year < 2200, "plausible year")
        var comps = URLComponents(string: "https://power.larc.nasa.gov/api/temporal/hourly/point")
        comps?.queryItems = [
            URLQueryItem(name: "parameters", value: "WS10M,WD10M,T2M,PS"),
            URLQueryItem(name: "community", value: "RE"),
            URLQueryItem(name: "longitude", value: String(format: "%.4f", lon)),
            URLQueryItem(name: "latitude", value: String(format: "%.4f", lat)),
            URLQueryItem(name: "start", value: "\(year)0101"),
            URLQueryItem(name: "end", value: "\(year)1231"),
            URLQueryItem(name: "time-standard", value: "LST"),
            URLQueryItem(name: "format", value: "JSON"),
        ]
        return comps?.url
    }

    // MARK: Year-chunk decode (pure, unit-tested)

    /// The slice of a POWER hourly response we consume. `geometry.coordinates[2]` is the MERRA-2
    /// grid-cell elevation (meters) — needed to correct density altitude to field elevation.
    struct YearChunk: Decodable {
        struct Properties: Decodable { let parameter: [String: [String: Double]] }
        struct Geometry: Decodable { let coordinates: [Double] }
        let properties: Properties
        let geometry: Geometry
        var gridElevationM: Double? { geometry.coordinates.count >= 3 ? geometry.coordinates[2] : nil }
    }

    /// nil for oversized, undecodable, or pathologically-keyed chunks (memory bound, rule 2).
    static func decodeChunk(_ data: Data) -> YearChunk? {
        guard data.count <= maxResponseBytes, !data.isEmpty,
              let chunk = try? JSONDecoder().decode(YearChunk.self, from: data) else { return nil }
        for (_, series) in chunk.properties.parameter where series.count > ClimateMath.maxHourKeys {
            return nil
        }
        assert(chunk.properties.parameter.count <= 16, "response carries the requested params")
        return chunk
    }

    // MARK: Fetch + fold

    private static func loadOrFetch(ident: String, coord: Coord, fieldElevFt: Int?,
                                    cacheDirectory: URL?,
                                    progress: (@Sendable (Int, Int) -> Void)?) async -> PowerClimateStats? {
        let years = targetYears()
        if let cached = readCache(ident: ident, years: years, dir: cacheDirectory) { return cached }
        var acc = ClimateAccumulator()
        var gridElevM: Double?
        for (i, year) in years.prefix(maxYears).enumerated() {     // bounded: ≤ 3 requests
            if Task.isCancelled { return nil }
            progress?(i + 1, years.count)
            guard let url = url(year: year, lat: coord.lat, lon: coord.lon),
                  let data = await fetch(url),
                  let chunk = decodeChunk(data) else { continue }  // fail-soft per year
            let elev = chunk.gridElevationM ?? gridElevM ?? 0
            gridElevM = elev
            let p = chunk.properties.parameter
            ClimateMath.fold(year: year,
                             ws: p["WS10M"] ?? [:], wd: p["WD10M"] ?? [:],
                             t2m: p["T2M"] ?? [:], ps: p["PS"] ?? [:],
                             gridElevM: elev, fieldElevFt: fieldElevFt, into: &acc)
        }
        guard acc.sampleCount > 0 else {
            // Nothing fetched (offline / POWER down): fall back to ANY older cached range.
            return readAnyCache(ident: ident, dir: cacheDirectory)
        }
        let stats = PowerClimateStats(version: PowerClimateStats.currentVersion, ident: ident,
                                      lat: coord.lat, lon: coord.lon,
                                      gridElevationM: gridElevM ?? 0, fieldElevationFt: fieldElevFt,
                                      years: acc.years.sorted(), sampleCount: acc.sampleCount,
                                      windCounts: acc.windCounts, daCounts: acc.daCounts,
                                      builtAt: Date())
        // Cache forever only when every target year landed; a partial pull is returned but not
        // persisted, so the next open retries the missing years.
        if acc.years.count == years.count { writeCache(stats, dir: cacheDirectory) }
        return stats
    }

    private static func fetch(_ url: URL) async -> Data? {
        var req = URLRequest(url: url)
        req.setValue("CommSight/1.0 (on-device ATC transcription)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.powerClimate.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              data.count <= maxResponseBytes else { return nil }
        return data
    }

    // MARK: Disk cache

    private static func cacheDir(_ override: URL?) -> URL? {
        override ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("PowerClimate", isDirectory: true)
    }

    static func cacheFile(ident: String, years: [Int], dir: URL?) -> URL? {
        guard let first = years.first, let last = years.last else { return nil }
        assert(first <= last, "year range ordered")
        return cacheDir(dir)?.appendingPathComponent("\(ident)_\(first)_\(last).json")
    }

    private static func readCache(ident: String, years: [Int], dir: URL?) -> PowerClimateStats? {
        guard let file = cacheFile(ident: ident, years: years, dir: dir) else { return nil }
        return decodeStats(at: file)
    }

    /// Any cached stats for this airport regardless of year range — the offline fallback when the
    /// current target range can't be fetched. Newest build wins.
    private static func readAnyCache(ident: String, dir: URL?) -> PowerClimateStats? {
        guard let cd = cacheDir(dir),
              let files = try? FileManager.default.contentsOfDirectory(at: cd, includingPropertiesForKeys: nil)
        else { return nil }
        var best: PowerClimateStats?
        for f in files.prefix(256) where f.lastPathComponent.hasPrefix("\(ident)_") {   // bounded
            guard let s = decodeStats(at: f) else { continue }
            if best == nil || s.builtAt > best!.builtAt { best = s }
        }
        return best
    }

    /// Internal (not private) so tests can exercise the version/layout guards directly.
    static func decodeStats(at file: URL) -> PowerClimateStats? {
        guard let data = try? Data(contentsOf: file), data.count <= maxResponseBytes,
              let stats = try? JSONDecoder().decode(PowerClimateStats.self, from: data),
              stats.version == PowerClimateStats.currentVersion,
              stats.windCounts.count == ClimateMath.windCellCount,
              stats.daCounts.count == ClimateMath.daCellCount else { return nil }
        return stats
    }

    private static func writeCache(_ stats: PowerClimateStats, dir: URL?) {
        guard let file = cacheFile(ident: stats.ident, years: stats.years, dir: dir),
              let data = try? JSONEncoder().encode(stats) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)               // fail-soft: cache is best-effort
    }
}

extension URLSession {
    /// POWER pulls are ~700 KB per year — a longer timeout than the pollers, still ephemeral and
    /// fail-fast when offline (falls back to the disk cache instead of spinning).
    static let powerClimate: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        c.timeoutIntervalForRequest = 60
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()
}
