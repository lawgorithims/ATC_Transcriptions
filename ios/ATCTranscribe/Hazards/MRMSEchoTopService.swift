import Foundation

/// Polls NOAA's MRMS echo-top mosaic and publishes measured convective cells — the source that finds a
/// thunderstorm **nobody has issued a bulletin about**.
///
/// # Why this is a different shape from every other poller in the app
///
/// Two reasons, both forced by the product.
///
/// 1. **It is position-dependent.** Every other feed (`TFRService`, `ConvectiveSigmetService`, EONET) can
///    fetch all of CONUS in a few kilobytes and let the UI filter. One MRMS frame is a 7000 × 3500 grid,
///    so the decode is windowed around the aircraft and the service has to be TOLD where that is
///    (`setCenter`). With no position there is no window, so it does not poll at all.
/// 2. **Motion has to be measured, not read.** A radar grid states position, never velocity. So the
///    service keeps a REFERENCE frame and cross-correlates against it
///    (`RadarCellFinder.fieldMotion`) — and deliberately does not correlate consecutive refreshes,
///    because at 0.01° a 20 kt storm moves 1.3 grid cells in two minutes and the answer would be noise.
///    See `RadarCellFinder.Config.minFrameGapSeconds`.
///
/// # Finding the newest frame without downloading a directory
///
/// NCEP's own listing at `mrms.ncep.noaa.gov/data/2D/EchoTop_30/` holds ~764 entries (25 hours at a
/// 2-minute cadence) and the filenames carry irregular seconds (`…-031643`, `…-031839`, `…-032040`), so
/// the name cannot be computed from the clock. The NOAA Open Data mirror on S3 solves it: keys sort
/// lexicographically, which for these names is chronologically, so `start-after` set to a timestamp a
/// few minutes back returns only the newest handful. Measured: **1.4 KB** of XML for the last three
/// frames, with their sizes. That is the discovery cost per poll; the grid itself is ~364 KB.
///
/// # Bandwidth, stated plainly because the pilot is paying for it
///
/// ~364 KB per frame, one frame per refresh, 5-minute refresh ⇒ about **4.4 MB/hour**. Comparable to the
/// precipitation-radar tiles the app already streams, and the reason this has its own toggle rather than
/// riding on the bulletin alert's.
actor MRMSEchoTopService {

    struct Config: Sendable {
        /// One frame per refresh. Five minutes also makes consecutive refreshes a usable correlation
        /// baseline on the second hop (see `RadarCellFinder.Config.minFrameGapSeconds`).
        var refreshInterval: TimeInterval = 5 * 60
        var backoffBase: TimeInterval = 60
        /// Half-width of the decoded window, degrees. 2.5° is ~150 NM of latitude — comfortably past the
        /// 20 NM avoidance radius plus a 20-minute look-ahead at jet speeds, with room for the storm to
        /// come the other way.
        var halfSpanDeg = 2.5
        /// Re-poll early when the aircraft has left the window it was fetched for. At 450 kt the window
        /// edge is about 20 minutes away, so this rarely fires in cruise and matters on a long leg.
        var recentreNm = 60.0
        /// Frames whose timestamp is older than this are not worth fetching on a cold start.
        var maxFrameAge: TimeInterval = 20 * 60
        var cellConfig = RadarCellFinder.Config()
        var product = "EchoTop_30_00.50"
        var fetcher: MRMSFetching = LiveMRMSFetcher()

        public init() {}
    }

    /// What the UI shows about this feed. Separate from `ConvectiveStatus` because this one can be
    /// legitimately idle for a reason the pilot should be able to see: no position yet.
    enum Status: Sendable, Equatable {
        case idle
        case needsPosition
        case ok(cells: Int, frameAt: Date)
        case error(String)
    }

    static let attribution = "Radar cells derived from NOAA/NWS MRMS echo tops. "
                           + "Derived product, not an official briefing."

    private let config: Config
    private let onUpdate: @Sendable ([ConvectiveCell], Date) -> Void
    private let onStatus: (@Sendable (Status) -> Void)?

    private var pollTask: Task<Void, Never>?
    private var failureStreak = 0
    private var centre: Coord?
    /// Where the last successful window was centred — the `recentreNm` anchor.
    private var fetchedFor: Coord?
    /// The frame motion is measured against. Replaced only once it is old enough that the NEXT frame
    /// will be a usable baseline, so the gap never collapses to the refresh interval.
    private var reference: (window: Grib2Decoder.Window, at: Date)?
    private var lastMotion: RadarCellFinder.FieldMotion?

    init(config: Config = Config(),
         onUpdate: @escaping @Sendable ([ConvectiveCell], Date) -> Void,
         onStatus: (@Sendable (Status) -> Void)? = nil) {
        self.config = config
        self.onUpdate = onUpdate
        self.onStatus = onStatus
    }

    /// Single edge-triggered entry point, like every other poller here — redundant calls are no-ops.
    func sync(enabled: Bool) { enabled ? start() : stop() }

    /// Tell the service where the aircraft is. Cheap and idempotent: it only wakes the poller when the
    /// aircraft has moved out of the window the current snapshot was decoded for.
    func setCenter(_ coord: Coord?) {
        centre = coord
        guard pollTask != nil else { return }
        guard let coord else { return }
        guard let was = fetchedFor else { return }          // nothing fetched yet; the loop will
        if Geo.nmBetween(was, coord) >= config.recentreNm {
            // Drop the reference: a window centred somewhere else is not the same grid, and
            // `fieldMotion` would (correctly) refuse to correlate it anyway.
            reference = nil
            lastMotion = nil
            fetchedFor = nil
        }
    }

    private func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in await self?.loop() }
    }

    private func stop() {
        pollTask?.cancel(); pollTask = nil
        failureStreak = 0
        reference = nil
        lastMotion = nil
        fetchedFor = nil
        onStatus?(.idle)
    }

    private func loop() async {
        while !Task.isCancelled {
            guard let here = centre else {
                // No position, no window. Say so rather than appearing broken, and check back often —
                // this is the state on the ramp before the first GPS fix.
                onStatus?(.needsPosition)
                try? await Task.sleep(nanoseconds: UInt64(30 * 1e9))
                continue
            }
            do {
                try await refresh(around: here)
                guard !Task.isCancelled else { return }
                failureStreak = 0
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

    private func refresh(around here: Coord) async throws {
        let frames = try await config.fetcher.latestFrames(product: config.product)
        guard let newest = frames.max(by: { $0.at < $1.at }) else { throw URLError(.zeroByteResource) }
        guard Date().timeIntervalSince(newest.at) <= config.maxFrameAge else {
            throw URLError(.resourceUnavailable)
        }
        // Nothing new since last time: don't spend 364 KB to re-decode the same frame.
        if let ref = reference, newest.at <= ref.at, fetchedFor != nil { return }

        let data = try await config.fetcher.frame(newest)
        guard let grib = Gunzip.isGzip(data) ? Gunzip.inflate(data) : data else {
            throw URLError(.cannotDecodeContentData)
        }
        let half = config.halfSpanDeg
        let latRange = max(-90, here.lat - half)...min(90, here.lat + half)
        let lonRange = max(-180, here.lon - half)...min(180, here.lon + half)
        let cellCfg = config.cellConfig
        // Decode and label OFF the actor's executor: this is ~100 ms of inflate plus a flood fill, and
        // it has no business holding up `setCenter`.
        let decoded: (window: Grib2Decoder.Window, cells: [ConvectiveCell])? =
            await Task.detached(priority: .utility) {
                guard let w = Grib2Decoder.windows(from: grib, latRange: latRange,
                                                   lonRange: lonRange).first else { return nil }
                return (w, RadarCellFinder.cells(from: w, observedAt: newest.at, config: cellCfg))
            }.value
        guard let decoded else { throw URLError(.cannotParseResponse) }

        // Motion against the reference frame, if there is a usable baseline.
        var motion: RadarCellFinder.FieldMotion?
        if let ref = reference {
            motion = RadarCellFinder.fieldMotion(current: decoded.window, currentAt: newest.at,
                                                 previous: ref.window, previousAt: ref.at,
                                                 config: cellCfg)
            // A refusal is not a failure — it means this baseline cannot support a vector. Keep the last
            // good one only while it is still describing roughly this weather.
            if motion == nil, let last = lastMotion,
               newest.at.timeIntervalSince(ref.at) <= cellCfg.maxFrameGapSeconds {
                motion = last
            }
        }
        if motion != nil { lastMotion = motion }

        // Replace the reference only once it is old enough that the NEXT frame will still clear
        // `minFrameGapSeconds` against this one. Otherwise the baseline would shrink to the refresh
        // interval and every correlation would be refused.
        let refAge = reference.map { newest.at.timeIntervalSince($0.at) } ?? .greatestFiniteMagnitude
        if reference == nil || refAge >= cellCfg.minFrameGapSeconds {
            reference = (decoded.window, newest.at)
        }

        let cells = RadarCellFinder.withMotion(decoded.cells, motion)
        fetchedFor = here
        // ⚠️ AN EMPTY RESULT IS PUBLISHED, for the same reason `ConvectiveSigmetService` publishes one:
        // a clean decode that found no convection is real information and the banner must clear. Only a
        // THROW keeps the previous set.
        onUpdate(cells, newest.at)
        onStatus?(.ok(cells: cells.count, frameAt: newest.at))
    }
}

/// One published MRMS frame: where to get it and when it was observed.
struct MRMSFrame: Sendable, Equatable {
    let url: URL
    let at: Date
    let bytes: Int
}

/// Network seam, so the poller's lifecycle, the reference-frame logic and the motion plumbing are all
/// testable without reaching NOAA.
protocol MRMSFetching: Sendable {
    /// The newest few frames of a product, newest last. Cheap: a kilobyte or two.
    func latestFrames(product: String) async throws -> [MRMSFrame]
    func frame(_ frame: MRMSFrame) async throws -> Data
}

/// The live NOAA Open Data (S3) implementation.
struct LiveMRMSFetcher: MRMSFetching {

    /// NOAA's public mirror. No key, no credentials, no request signing — it is an open bucket.
    static let bucket = "https://noaa-mrms-pds.s3.amazonaws.com"
    /// How far back `start-after` reaches. Wide enough to survive a stalled publisher, narrow enough
    /// that the listing stays a kilobyte.
    static let lookBack: TimeInterval = 12 * 60
    static let maxFrames = 8

    func latestFrames(product: String) async throws -> [MRMSFrame] {
        let now = Date()
        var frames: [MRMSFrame] = []
        // ⚠️ THE UTC DAY ROLLOVER. Keys are partitioned by day, and `start-after` inside today's
        // partition returns nothing for the first `lookBack` minutes after 00:00Z — at which point the
        // radar silently stops updating for twelve minutes a day. So when the look-back window crosses
        // midnight, yesterday's partition is listed too.
        let from = now.addingTimeInterval(-Self.lookBack)
        for day in Set([Self.day(from), Self.day(now)]).sorted() {
            let prefix = "CONUS/\(product)/\(day)/"
            // Only the first day listed needs a start-after; a day that has just begun is short anyway.
            let after = day == Self.day(from)
                ? "\(prefix)MRMS_\(product)_\(day)-\(Self.hms(from)).grib2.gz"
                : nil
            frames += try await list(prefix: prefix, startAfter: after, product: product, day: day)
        }
        return Array(frames.sorted { $0.at < $1.at }.suffix(Self.maxFrames))
    }

    private func list(prefix: String, startAfter: String?,
                      product: String, day: String) async throws -> [MRMSFrame] {
        var c = URLComponents(string: Self.bucket)!
        var q = [URLQueryItem(name: "list-type", value: "2"),
                 URLQueryItem(name: "prefix", value: prefix)]
        if let startAfter { q.append(URLQueryItem(name: "start-after", value: startAfter)) }
        c.queryItems = q
        guard let url = c.url else { throw URLError(.badURL) }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("Obelisk/1.0", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await NetworkActivity.data(for: req, "MRMS frame list", .radar)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return MRMSKeyListing.frames(data, bucket: Self.bucket, product: product)
    }

    func frame(_ frame: MRMSFrame) async throws -> Data {
        var req = URLRequest(url: frame.url, timeoutInterval: 60)
        req.setValue("Obelisk/1.0", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await NetworkActivity.data(for: req, "MRMS echo tops", .radar)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    private static let utc: TimeZone = TimeZone(identifier: "UTC") ?? .gmt

    static func day(_ d: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = utc
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd"
        return f.string(from: d)
    }

    static func hms(_ d: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = utc
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HHmmss"
        return f.string(from: d)
    }
}

/// Pure S3-listing → `[MRMSFrame]` parsing, so the key-name and timestamp handling is testable against a
/// captured listing with no network.
///
/// Deliberately a scan for `<Key>` and `<Size>` rather than an `XMLParser` delegate: the document is a
/// flat list of `<Contents>` elements and the two fields appear in a fixed order inside each, so a
/// 40-line scan carries no schema assumptions an XML parser would not also carry, and it cannot throw.
enum MRMSKeyListing {

    static let maxKeys = 64

    static func frames(_ data: Data, bucket: String, product: String) -> [MRMSFrame] {
        assert(maxKeys > 0, "MRMSKeyListing: key cap must be positive")
        guard let xml = String(data: data, encoding: .utf8) else { return [] }
        var out: [MRMSFrame] = []
        var cursor = xml.startIndex
        var seen = 0
        // Bounded: each pass consumes at least one `<Key>` and the cursor only moves forward (rule 2).
        while seen < maxKeys, let keyRange = xml.range(of: "<Key>", range: cursor..<xml.endIndex) {
            seen += 1
            guard let keyEnd = xml.range(of: "</Key>", range: keyRange.upperBound..<xml.endIndex) else {
                break
            }
            let key = String(xml[keyRange.upperBound..<keyEnd.lowerBound])
            cursor = keyEnd.upperBound
            // The size follows the key inside the same <Contents>; absent, the frame is still usable.
            var bytes = 0
            if let sizeRange = xml.range(of: "<Size>", range: cursor..<xml.endIndex),
               let sizeEnd = xml.range(of: "</Size>", range: sizeRange.upperBound..<xml.endIndex),
               // Only if it is still inside this element — guard against reading the NEXT entry's size.
               xml.range(of: "<Key>", range: cursor..<sizeRange.lowerBound) == nil {
                bytes = Int(xml[sizeRange.upperBound..<sizeEnd.lowerBound]) ?? 0
            }
            guard let at = timestamp(ofKey: key, product: product) else { continue }
            guard let url = URL(string: "\(bucket)/\(key)") else { continue }
            out.append(MRMSFrame(url: url, at: at, bytes: bytes))
        }
        return out
    }

    /// Pull the observation time out of `…/MRMS_<product>_<yyyyMMdd>-<HHmmss>.grib2.gz`.
    ///
    /// ⚠️ THE TIMESTAMP COMES FROM THE NAME AND IS THEN RE-CHECKED AGAINST THE GRIB'S OWN REFERENCE
    /// TIME by the decode path, which is what actually dates the cells. This is only used to choose
    /// which frame to download, so a name this cannot read means "skip that key", never "use now".
    static func timestamp(ofKey key: String, product: String) -> Date? {
        assert(!product.isEmpty, "MRMSKeyListing: empty product name")
        guard let name = key.split(separator: "/").last else { return nil }
        let marker = "MRMS_\(product)_"
        guard name.hasPrefix(marker) else { return nil }
        let rest = name.dropFirst(marker.count)
        guard let dot = rest.firstIndex(of: ".") else { return nil }
        let stamp = rest[rest.startIndex..<dot]              // yyyyMMdd-HHmmss
        guard stamp.count == 15 else { return nil }
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.date(from: String(stamp))
    }
}
