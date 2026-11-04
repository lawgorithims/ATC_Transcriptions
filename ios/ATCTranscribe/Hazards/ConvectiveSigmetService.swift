import Foundation

/// Feed status surfaced to the UI (mirrors `TFRStatus`).
enum ConvectiveStatus: Sendable, Equatable {
    case idle
    case ok
    case error(String)
}

/// Network seam so the poller's lifecycle is unit-testable without hitting the AWC.
protocol ConvectiveFetching: Sendable {
    func fetchActive() async throws -> [ConvectiveCell]
}

/// # Why Convective SIGMETs, and not the radar the map already draws
///
/// The alert needs three things from its source: a shape, a height, and a velocity. Of everything
/// available to a tablet in a cockpit, this product is the only one that states all three in a payload
/// small enough to fetch over a cellular link at altitude.
///
///   * **RainViewer** (`RainViewerService`, already shipping) is a flat raster of surface reflectivity.
///     No tops, no bases, no motion vector — and nothing recoverable from a PNG tile. It is the picture,
///     and it stays the picture.
///   * **MRMS** has exactly the right fields and is now read — see `MRMSEchoTopService`. It is the only
///     source that finds a storm nobody reported, and it supplies a MEASURED top per cell. It is a
///     separate service rather than a fourth feed here because it is position-dependent (one frame is a
///     7000 × 3500 grid, so the decode is windowed around the aircraft) and because its motion has to be
///     derived from two frames rather than read off a bulletin.
///   * **Convective SIGMETs** (this file) carry the polygon, `altitudeHi` tops, `altitudeLow` bases, an
///     explicit motion vector and an issue time, in about 4 KB for the whole of CONUS. They are also what
///     ATC and dispatch are working from, so an alert built on them says the same thing the controller
///     offering a deviation is looking at.
///
/// ## What this therefore does NOT catch, which matters
///
/// A Convective SIGMET is issued for an area of thunderstorms with ~40% coverage or more, a line of them,
/// or any single cell that is severe or has ¾-inch hail or a tornado. **An isolated, non-severe cell may
/// legitimately have no Convective SIGMET at all.** That gap is a property of the product, not of this
/// code, and closing it is what the other three sources are for: this fetcher also reads CWAs (issued
/// BELOW SIGMET criteria) and per-storm NWS Severe Thunderstorm Warnings, and `MRMSEchoTopService`
/// measures echo tops directly. The banner still names what it read, because which source found a cell
/// determines what is known about it.
struct LiveConvectiveFetcher: ConvectiveFetching {

    /// `hazard=conv` filters server-side to convective SIGMETs; the parser re-checks anyway.
    private static let sigmets = URL(string: "https://aviationweather.gov/api/data/airsigmet"
                                     + "?format=json&hazard=conv")!
    /// Center Weather Advisories. No hazard filter exists on this endpoint, and filtering on the
    /// response's `hazard` field would drop the severe-thunderstorm ones — see `CWAParser`.
    private static let cwas = URL(string: "https://aviationweather.gov/api/data/cwa?format=json")!
    /// Per-storm NWS warnings. The whole active set for the United States is a couple of kilobytes.
    private static let warnings = URL(string: "https://api.weather.gov/alerts/active"
                                      + "?event=Severe%20Thunderstorm%20Warning")!

    func fetchActive() async throws -> [ConvectiveCell] {
        // ⚠️ THE SIGMET FEED IS REQUIRED; THE OTHER TWO ARE NOT, AND THE ASYMMETRY IS DELIBERATE.
        //
        // The service publishes an empty result on a clean fetch, because a quiet day really does mean
        // "clear the banner". That makes a silent partial failure the dangerous case: if the SIGMET feed
        // were allowed to fail quietly while the CWA feed returned its usual nothing, the alert would
        // go dark during an outage and look exactly like fair weather. So a SIGMET failure THROWS, which
        // keeps the previous snapshot and surfaces the error. A CWA or warning failure is tolerated —
        // both are additions to coverage, and losing an addition is not the same as losing the floor.
        async let sigmetTask = Self.cells(Self.sigmets, "Convective SIGMETs",
                                          ConvectiveSigmetParser.cells)
        async let cwaTask = Self.optional(Self.cwas, "Center Weather Advisories", CWAParser.cells)
        async let warningTask = Self.optional(Self.warnings, "Severe thunderstorm warnings",
                                              SevereWarningParser.cells)
        let sigmets = try await sigmetTask
        let cwas = await cwaTask
        let warnings = await warningTask
        let extra = cwas + warnings
        // Merge across sources so one storm described by three products is one banner carrying the best
        // field from each. With only SIGMETs present this is a no-op on disjoint areas.
        return ConvectiveCellMerge.merge(sigmets + extra)
    }

    private static func cells(_ url: URL, _ label: String,
                              _ parse: @Sendable (Data) -> [ConvectiveCell]) async throws
                              -> [ConvectiveCell] {
        var req = URLRequest(url: url, timeoutInterval: 25)
        req.setValue("Obelisk/1.0", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await NetworkActivity.data(for: req, label, .hazards)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        // 204 is how the AWC says "nothing active", and it is the usual answer on both bulletin
        // endpoints. It is a success with an empty body, not an error.
        guard code == 200 || code == 204 else { throw URLError(.badServerResponse) }
        return code == 204 ? [] : parse(data)
    }

    private static func optional(_ url: URL, _ label: String,
                                 _ parse: @Sendable (Data) -> [ConvectiveCell]) async
                                 -> [ConvectiveCell] {
        (try? await cells(url, label, parse)) ?? []
    }
}

/// Pure AWC-JSON → `ConvectiveCell` parsing, so every field mapping below is unit-testable against a
/// captured payload and none of it needs a network.
enum ConvectiveSigmetParser {

    /// One AWC record. Every field is optional because the feed omits rather than nulls, and a single
    /// malformed record must not take the snapshot with it.
    private struct Record: Decodable {
        let seriesId: String?
        let hazard: String?
        let airSigmetType: String?
        let validTimeFrom: Int?
        let validTimeTo: Int?
        let altitudeHi1: Int?
        let altitudeHi2: Int?
        let altitudeLow1: Int?
        let altitudeLow2: Int?
        let movementDir: Int?
        let movementSpd: Int?
        let severity: Int?
        let coords: [Point]?
        struct Point: Decodable { let lat: Double; let lon: Double }
    }

    /// A wrapper whose `init` swallows a decode error, so one bad record is dropped rather than
    /// collapsing the whole array (the same trick `PlateGeoref` uses on its table).
    private struct Failable: Decodable {
        let record: Record?
        init(from decoder: Decoder) throws { record = try? Record(from: decoder) }
    }

    static func cells(_ data: Data) -> [ConvectiveCell] {
        assert(!data.isEmpty || data.isEmpty, "total function over any payload")
        guard let rows = try? JSONDecoder().decode([Failable].self, from: data) else { return [] }
        var out: [ConvectiveCell] = []
        out.reserveCapacity(min(rows.count, ConvectiveAlert.maxCells))
        for row in rows.prefix(ConvectiveAlert.maxCells) {
            if let c = cell(from: row.record) { out.append(c) }
        }
        assert(out.count <= ConvectiveAlert.maxCells, "snapshot bounded for the alert's loops")
        return out
    }

    private static func cell(from r: Record?) -> ConvectiveCell? {
        guard let r else { return nil }
        // Convective only. The query asks for it, but a feed that starts returning icing under the same
        // parameter must not have its tops read as thunderstorm tops.
        guard (r.hazard ?? "").uppercased() == "CONVECTIVE" else { return nil }
        // No issue time means no way to age the motion vector, and an un-aged vector is the one thing
        // this alert must never extrapolate from. Drop it rather than guess at `Date()`.
        guard let from = r.validTimeFrom, let to = r.validTimeTo, to > from else { return nil }
        let ring = (r.coords ?? []).prefix(ConvectiveAlert.maxVertices)
            .map { Coord(lat: $0.lat, lon: $0.lon) }
        // A 2-point line is handled by the distance math but cannot be entered; fewer than 2 is nothing.
        guard ring.count >= 2 else { return nil }
        // Same rule as the CWA and warning parsers: an impossible vertex rejects the cell rather
        // than deforming its ring. See `ConvectiveAlert.isPlausible`.
        guard ring.allSatisfy(ConvectiveAlert.isPlausible) else { return nil }

        let series = r.seriesId ?? "?"
        // ⚠️ TOPS TAKE THE HIGHER OF THE PAIR, BASES THE LOWER. The feed carries two of each because a
        // SIGMET area can state different tops at different ends. Averaging them would invent a top that
        // is wrong at both ends and too low at one, and too low is the direction that stops the alert
        // firing — so the column is taken at its largest.
        let tops = [r.altitudeHi1, r.altitudeHi2].compactMap { $0 }.max().map(Double.init)
        let base = [r.altitudeLow1, r.altitudeLow2].compactMap { $0 }.min().map(Double.init)

        return ConvectiveCell(
            id: "WST-\(series)",
            label: "Convective SIGMET \(series)",
            polygon: Array(ring),
            topsFtMSL: tops,
            baseFtMSL: base,
            observedAt: Date(timeIntervalSince1970: Double(from)),
            validUntil: Date(timeIntervalSince1970: Double(to)),
            severity: r.severity,
            // The feed copies the bulletin's own "MOV FROM ddd" into this field — verified against
            // `rawAirSigmet` across the live feed. See the warning on `ConvectiveCell.movingFromDeg`.
            movingFromDeg: r.movementDir.map(Double.init),
            motionKt: r.movementSpd.map(Double.init))
    }
}

/// Polls the AWC convective feed while the alert is on and publishes a bounded snapshot plus the instant
/// it was fetched. Edge-triggered `sync(enabled:)` with exponential backoff, mirroring `TFRService`.
///
/// The refresh interval is 5 minutes rather than TFR's 30: Convective SIGMETs are reissued hourly but
/// SPECIAL issuances come at any time and are precisely the ones worth having early, and the payload is
/// small enough that asking often costs little.
actor ConvectiveSigmetService {
    struct Config: Sendable {
        var refreshInterval: TimeInterval = 5 * 60
        var backoffBase: TimeInterval = 60
        /// Older than this and the snapshot is not worth showing at all on a cold start — every bulletin
        /// in it would be long past `expiredGraceMinutes`.
        var snapshotMaxAge: TimeInterval = 3 * 3600
        var maxCells = ConvectiveAlert.maxCells
        var cacheDirectory: URL? = nil
    }

    static let attribution = "Convective SIGMETs: NOAA/NWS Aviation Weather Center. "
                           + "Not an official briefing."

    private let config: Config
    private let fetcher: ConvectiveFetching
    private let onUpdate: @Sendable ([ConvectiveCell], Date) -> Void
    private let onStatus: (@Sendable (ConvectiveStatus) -> Void)?

    private var pollTask: Task<Void, Never>?
    private var failureStreak = 0
    private var didLoadCache = false

    init(config: Config = Config(),
         fetcher: ConvectiveFetching = LiveConvectiveFetcher(),
         onUpdate: @escaping @Sendable ([ConvectiveCell], Date) -> Void,
         onStatus: (@Sendable (ConvectiveStatus) -> Void)? = nil) {
        self.config = config; self.fetcher = fetcher
        self.onUpdate = onUpdate; self.onStatus = onStatus
    }

    /// Single edge-triggered entry point — redundant calls are no-ops (no start/stop race).
    func sync(enabled: Bool) { enabled ? start() : stop() }

    private func start() {
        guard pollTask == nil else { return }
        loadCacheOnce()
        pollTask = Task { [weak self] in await self?.loop() }
    }

    private func stop() {
        pollTask?.cancel(); pollTask = nil
        failureStreak = 0
        onStatus?(.idle)
    }

    private func loop() async {
        while !Task.isCancelled {
            do {
                let cells = Array(try await fetcher.fetchActive().prefix(config.maxCells))
                guard !Task.isCancelled else { return }
                let now = Date()
                failureStreak = 0
                // ⚠️ AN EMPTY RESULT IS PUBLISHED, UNLIKE TFRs. A successful fetch that returns no
                // convective SIGMETs is the common case on a quiet day and is real information: the
                // banner must clear. TFRService keeps its last good set on failure for a different
                // reason (a partial outage there looks like an empty list); here a THROW keeps the last
                // set and only a clean 200 clears it.
                onUpdate(cells, now); onStatus?(.ok)
                saveCache(cells, at: now)
                try? await Task.sleep(nanoseconds: UInt64(config.refreshInterval * 1e9))
            } catch {
                guard !Task.isCancelled else { return }
                failureStreak += 1
                onStatus?(.error(error.localizedDescription))
                let backoff = min(config.backoffBase * pow(2, Double(failureStreak - 1)), 15 * 60)
                try? await Task.sleep(nanoseconds: UInt64(backoff * 1e9))
            }
        }
    }

    // MARK: disk cache

    private struct Snapshot: Codable {
        let cells: [StoredCell]; let at: Date

        /// A flat mirror of `ConvectiveCell` rather than making the alert's own type `Codable`: the cache
        /// format then cannot be changed by accident when a field is added to the alert.
        struct StoredCell: Codable {
            let id: String, label: String
            let polygon: [Coord]
            let topsFtMSL: Double?, baseFtMSL: Double?
            let observedAt: Date, validUntil: Date
            let severity: Int?
            let movingFromDeg: Double?, motionKt: Double?
            /// Defaulted on DECODE, not just on encode: a snapshot written by an earlier build has no
            /// such key, and a non-optional here would make every one of those caches undecodable —
            /// which on a cold start means no banner at all until the first live fetch lands.
            let source: ConvectiveSource?
            let dismissOverride: String?

            init(_ c: ConvectiveCell) {
                id = c.id; label = c.label; polygon = c.polygon
                topsFtMSL = c.topsFtMSL; baseFtMSL = c.baseFtMSL
                observedAt = c.observedAt; validUntil = c.validUntil
                severity = c.severity
                movingFromDeg = c.movingFromDeg; motionKt = c.motionKt
                source = c.source; dismissOverride = c.dismissOverride
            }
            var cell: ConvectiveCell {
                ConvectiveCell(id: id, label: label, polygon: polygon, topsFtMSL: topsFtMSL,
                               baseFtMSL: baseFtMSL, observedAt: observedAt, validUntil: validUntil,
                               severity: severity, movingFromDeg: movingFromDeg, motionKt: motionKt,
                               source: source ?? .sigmet, dismissOverride: dismissOverride)
            }
        }
    }

    private var cacheURL: URL? {
        let base = config.cacheDirectory
            ?? (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                             appropriateFor: nil, create: true))
        return base?.appendingPathComponent("convective_snapshot.json")
    }

    private func loadCacheOnce() {
        guard !didLoadCache else { return }
        didLoadCache = true
        guard let url = cacheURL, let d = try? Data(contentsOf: url),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: d),
              Date().timeIntervalSince(snap.at) < config.snapshotMaxAge, !snap.cells.isEmpty
        else { return }
        onUpdate(snap.cells.map(\.cell), snap.at)
    }

    private func saveCache(_ cells: [ConvectiveCell], at: Date) {
        let snap = Snapshot(cells: cells.map(Snapshot.StoredCell.init), at: at)
        guard let url = cacheURL, let d = try? JSONEncoder().encode(snap) else { return }
        try? d.write(to: url, options: .atomic)
    }
}
