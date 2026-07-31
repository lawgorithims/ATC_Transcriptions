import Foundation

/// A current surface observation (METAR) plus the derived FAA flight category, from aviationweather.gov's
/// free JSON API (US government, no key). Only the fields the airport caption needs are kept; the API's
/// polymorphic fields (`wdir` can be "VRB", `visib` can be "10+") are decoded leniently so one odd field
/// never drops the whole observation.
struct Metar: Decodable, Equatable, Sendable {
    enum Category: String, Sendable { case vfr = "VFR", mvfr = "MVFR", ifr = "IFR", lifr = "LIFR", unknown = "—" }

    let icaoId: String
    let windDir: Int?          // degrees true; nil = variable/calm
    let windKt: Int?
    let gustKt: Int?
    let visSm: Double?         // statute miles
    let ceilingFt: Int?        // lowest broken/overcast base AGL
    let skyCover: String?      // that layer's cover code (SKC/FEW/SCT/BKN/OVC…)
    let rawOb: String?
    let obsEpoch: Int?
    private let fltCatRaw: String?

    struct Cloud: Decodable, Equatable, Sendable { let cover: String?; let base: Int? }

    /// Surface temperature, °C. Needed for the Baro-VNAV temperature limit on an LNAV/VNAV line, which
    /// is a real restriction on the aircraft's vertical guidance rather than a comfort figure.
    let tempC: Double?

    private enum CodingKeys: String, CodingKey {
        case icaoId, wdir, wspd, wgst, visib, clouds, rawOb, obsTime, fltCat, temp
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        icaoId = (try? c.decode(String.self, forKey: .icaoId)) ?? ""
        windDir = try? c.decodeIfPresent(Int.self, forKey: .wdir)           // "VRB"/"CLM" → nil
        windKt = try? c.decodeIfPresent(Int.self, forKey: .wspd)
        gustKt = try? c.decodeIfPresent(Int.self, forKey: .wgst)
        visSm = Self.flexibleVis(c)
        let clouds = (try? c.decodeIfPresent([Cloud].self, forKey: .clouds)) ?? nil
        let ceil = clouds?.compactMap { cl -> Int? in
            guard let cover = cl.cover, ["BKN", "OVC", "OVX"].contains(cover), let b = cl.base else { return nil }
            return b
        }.min()
        ceilingFt = ceil
        skyCover = clouds?.first(where: { $0.base == ceil && ceil != nil })?.cover ?? clouds?.last?.cover
        rawOb = try? c.decodeIfPresent(String.self, forKey: .rawOb)
        obsEpoch = try? c.decodeIfPresent(Int.self, forKey: .obsTime)
        fltCatRaw = try? c.decodeIfPresent(String.self, forKey: .fltCat)
        // The feed usually carries `temp`; when it does not, the raw observation always does.
        if let t = try? c.decodeIfPresent(Double.self, forKey: .temp) { tempC = t }
        else { tempC = Self.temperatureFromRaw(rawOb) }
    }

    /// The `TT/DD` group of a raw METAR, where a leading `M` means minus: `M05/M12` is −5 °C.
    ///
    /// Anchored on the wind and altimeter groups around it so a runway designator or a visibility
    /// fraction elsewhere in the observation cannot be mistaken for a temperature.
    static func temperatureFromRaw(_ raw: String?) -> Double? {
        guard let raw, !raw.isEmpty else { return nil }
        let pattern = #"(?:^|\s)(M?\d{2})/(M?\d{2})(?=\s+[AQ]\d{4}|\s|$)"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = raw as NSString
        guard let m = re.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 1 else { return nil }
        var text = ns.substring(with: m.range(at: 1))
        var sign = 1.0
        if text.hasPrefix("M") { sign = -1; text.removeFirst() }
        guard let v = Double(text), v <= 70 else { return nil }
        return sign * v
    }

    /// `visib` is a Double ("6.0") or a String ("10+", "1 1/2") — take the leading numeric.
    private static func flexibleVis(_ c: KeyedDecodingContainer<CodingKeys>) -> Double? {
        if let d = try? c.decodeIfPresent(Double.self, forKey: .visib) { return d }
        if let s = try? c.decodeIfPresent(String.self, forKey: .visib) {
            let num = s.prefix { $0.isNumber || $0 == "." }
            return Double(num)
        }
        return nil
    }

    /// FAA flight category — the API's `fltCat` when valid, else the ceiling+visibility rules. `.unknown`
    /// only when there's neither a category nor any ceiling/visibility to derive from.
    var category: Category {
        if let raw = fltCatRaw, let cat = Category(rawValue: raw.uppercased()) { return cat }
        guard ceilingFt != nil || visSm != nil else { return .unknown }
        let ceil = ceilingFt ?? .max
        let vis = visSm ?? .greatestFiniteMagnitude
        if ceil < 500 || vis < 1 { return .lifr }
        if ceil < 1000 || vis < 3 { return .ifr }
        if ceil <= 3000 || vis <= 5 { return .mvfr }
        return .vfr
    }

    /// A ForeFlight-style one-line summary: "200° at 6 kts · 10 sm · OVC 10,000′".
    var summary: String {
        var parts: [String] = []
        if let k = windKt {
            if k == 0 { parts.append("Calm") }
            else {
                let dir = windDir.map { String(format: "%03d°", $0) } ?? "VRB"
                let gust = gustKt.map { "G\($0)" } ?? ""
                parts.append("\(dir) at \(k)\(gust) kt")
            }
        }
        if let v = visSm { parts.append(v >= 10 ? "10+ sm" : "\(v.clean) sm") }
        if let cover = skyCover {
            if let c = ceilingFt { parts.append("\(cover) \(c.grouped)′") } else { parts.append(cover) }
        }
        return parts.joined(separator: " · ")
    }
}

private extension Double {
    var clean: String { self == rounded() ? String(Int(self)) : String(format: "%.1f", self) }
}

/// Thousands-grouped ("4,862") for altitudes/ceilings/frequencies in captions.
extension Int {
    var grouped: String {
        let f = NumberFormatter(); f.numberStyle = .decimal
        return f.string(from: NSNumber(value: self)) ?? String(self)
    }
}

/// Fetches + caches METARs (10-minute TTL) for the airport captions. Batches every requested ident into
/// one aviationweather.gov call; a failed fetch keeps the last good observation. UI-only; nothing here
/// touches the transcription pipeline.
@MainActor final class MetarStore: ObservableObject {
    @Published private(set) var metars: [String: Metar] = [:]
    /// The last several observations per station, newest first — the input to the TREND. A pilot
    /// 45 minutes out needs to know where conditions are going, which one observation cannot say.
    @Published private(set) var history: [String: [Metar]] = [:]
    /// Idents for which a fetch COMPLETED (whether or not that field reports) — lets a caption show a
    /// terminal "no current METAR" instead of spinning forever for a non-reporting airport.
    @Published private(set) var checked: Set<String> = []
    /// Idents whose last fetch was a transport failure — a terminal "weather unavailable" (retryable via
    /// the 30 s backoff on the next `ensure`) rather than an eternal spinner.
    @Published private(set) var failed: Set<String> = []
    private var fetchedAt: [String: Date] = [:]
    private var inFlight: Set<String> = []
    private let ttl: TimeInterval = 600

    func metar(_ ident: String) -> Metar? { metars[Self.key(ident)] }

    /// The fitted trend for a station, or nil when nothing has been fetched for it yet.
    func trend(_ ident: String) -> MetarTrend.Result? {
        let id = Self.key(ident)
        guard let obs = history[id], !obs.isEmpty else { return nil }
        return MetarTrend.analyze(ident: id, observations: obs)
    }

    /// Every station currently trending toward worse conditions — what the chart marker draws.
    var deterioratingStations: [MetarTrend.Result] {
        history.keys.compactMap { trend($0) }.filter(\.isSignificant)
    }

    /// Terminal fetch state for one ident (nil = still loading / never requested).
    enum Fetch { case ok, noReport, failed }
    func state(_ ident: String) -> Fetch? {
        let id = Self.key(ident)
        if metars[id] != nil { return .ok }
        if failed.contains(id) { return .failed }
        if checked.contains(id) { return .noReport }
        return nil
    }

    /// Fetch any of `idents` that are missing or older than the TTL (deduped against in-flight requests).
    func ensure(_ idents: [String], now: Date = Date()) {
        let stale = Set(idents.map(Self.key)).filter { id in
            guard !id.isEmpty, !inFlight.contains(id) else { return false }
            return fetchedAt[id].map { now.timeIntervalSince($0) > ttl } ?? true
        }
        guard !stale.isEmpty else { return }
        stale.forEach { inFlight.insert($0) }
        Task { await load(Array(stale)) }
    }

    private func load(_ icaos: [String]) async {
        // ONE request serves both needs: the series' newest report is the current observation, and the
        // whole series is what the trend is fitted to.
        let series = await Self.downloadSeries(icaos)
        let result = series.map { d in d.compactMapValues { $0.first } }
        if let series { for (k, v) in series { history[k] = v } }
        let now = Date()
        for id in icaos { inFlight.remove(id) }
        guard let result else {
            // Transport/decode failure → short backoff (retry in ~30 s), NOT the full 10-min TTL, so a
            // transient blip doesn't leave every airport "unavailable" for ten minutes. Mark failed so the
            // caption shows a terminal state (only when we don't already hold a good obs to keep showing).
            for id in icaos {
                fetchedAt[id] = now.addingTimeInterval(30 - ttl)
                if metars[id] == nil { failed.insert(id) }
            }
            return
        }
        for id in icaos {
            fetchedAt[id] = now                        // success (incl. non-reporting fields) → full TTL
            failed.remove(id); checked.insert(id)      // fetch completed → terminal "reported"/"no report"
        }
        for (id, m) in result { metars[id] = m }
    }

    nonisolated private static func key(_ ident: String) -> String {
        ident.trimmingCharacters(in: .whitespaces).uppercased()
    }

    /// Returns nil on a TRANSPORT/decode failure (so the caller can retry soon) vs an empty-but-non-nil
    /// dictionary on a successful response that simply had no reporting stations (full TTL).
    /// (Superseded by `downloadSeries`, which serves the current observation AND the trend history from
    /// one request; kept for the single-observation path used by tests.)
    nonisolated static func download(_ icaos: [String]) async -> [String: Metar]? {
        guard var comps = URLComponents(string: "https://aviationweather.gov/api/data/metar") else { return nil }
        // `hours` makes the API return the RECENT SERIES per station, not just the latest observation
        // — that series is what the trend is fitted to. The newest report is still first, so the
        // current-observation behaviour below is unchanged.
        comps.queryItems = [URLQueryItem(name: "ids", value: icaos.joined(separator: ",")),
                            URLQueryItem(name: "format", value: "json"),
                            URLQueryItem(name: "hours", value: String(trendWindowHours))]
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url); req.timeoutInterval = 12
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let list = try? JSONDecoder().decode([Metar].self, from: data) else { return nil }
        return Dictionary(list.filter { !$0.icaoId.isEmpty }.map { ($0.icaoId.uppercased(), $0) },
                          uniquingKeysWith: { a, _ in a })
    }

    /// How far back the trend fit looks. Six hours covers 4-6 hourly observations at most stations.
    nonisolated static let trendWindowHours = 6

    /// The full recent series per station (newest first), from the same response the current
    /// observation comes from — one request serves both.
    nonisolated private static func downloadSeries(_ icaos: [String]) async -> [String: [Metar]]? {
        guard var comps = URLComponents(string: "https://aviationweather.gov/api/data/metar") else { return nil }
        comps.queryItems = [URLQueryItem(name: "ids", value: icaos.joined(separator: ",")),
                            URLQueryItem(name: "format", value: "json"),
                            URLQueryItem(name: "hours", value: String(trendWindowHours))]
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url); req.timeoutInterval = 15
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let list = try? JSONDecoder().decode([Metar].self, from: data) else { return nil }
        var out: [String: [Metar]] = [:]
        for m in list where !m.icaoId.isEmpty {
            out[m.icaoId.uppercased(), default: []].append(m)
        }
        for k in out.keys {                                        // bounded by the request's ident list
            out[k] = Array(out[k]!.sorted { ($0.obsEpoch ?? 0) > ($1.obsEpoch ?? 0) }.prefix(8))
        }
        return out
    }
}
