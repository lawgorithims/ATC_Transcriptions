import Foundation

/// One decoded TAF forecast period ("FM170100 …"): the validity header + a one-line decoded summary.
struct TafPeriod: Equatable, Sendable {
    let header: String        // e.g. "17 01:00Z – 15:00Z" or "TEMPO 17 03:00Z – 06:00Z"
    let summary: String       // e.g. "320° 6 kt · P6SM · SCT070"
}

/// A Terminal Aerodrome Forecast for one airport, from aviationweather.gov's JSON API. Keeps the raw TAF
/// (what pilots read) plus lightly-decoded forecast periods. Lenient decode — one odd field never drops
/// the whole TAF. UI-only; nothing here touches the transcription pipeline.
struct Taf: Equatable, Sendable {
    let icaoId: String
    let rawText: String?
    let issued: Date?
    let periods: [TafPeriod]

    private struct DTO: Decodable {
        let icaoId: String?
        let rawTAF: String?
        let issueTime: String?
        let fcsts: [Period]?
        struct Cloud: Decodable { let cover: String?; let base: Int? }
        struct Period: Decodable {
            let timeFrom: Int?; let timeTo: Int?; let fcstChange: String?; let probability: Int?
            let wdir: WindDir?; let wspd: Int?; let wgst: Int?; let visib: Vis?; let wxString: String?
            let clouds: [Cloud]?
        }
    }

    /// wdir is an Int or the string "VRB".
    private enum WindDir: Decodable { case deg(Int), vrb
        init(from d: Decoder) throws {
            let c = try d.singleValueContainer()
            if let i = try? c.decode(Int.self) { self = .deg(i) } else { self = .vrb }
        }
        var text: String? { switch self { case .deg(let i): return String(format: "%03d°", i); case .vrb: return "VRB" } }
    }
    /// visib is a Double ("6.0") or a String ("6+", "P6SM").
    private enum Vis: Decodable { case num(Double), str(String)
        init(from d: Decoder) throws {
            let c = try d.singleValueContainer()
            if let v = try? c.decode(Double.self) { self = .num(v) } else { self = .str((try? c.decode(String.self)) ?? "") }
        }
        var text: String? {
            switch self {
            case .num(let v): return v >= 6 ? "P6SM" : "\(v.clean)SM"
            case .str(let s): return s.isEmpty ? nil : s
            }
        }
    }

    /// Parse the aviationweather.gov TAF JSON (first element) into a Taf, or nil when the payload is empty.
    static func parse(_ data: Data) -> Taf? {
        guard let list = try? JSONDecoder().decode([DTO].self, from: data), let d = list.first else { return nil }
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let issued = d.issueTime.flatMap { iso.date(from: $0) }
        var periods: [TafPeriod] = []
        for p in (d.fcsts ?? []).prefix(30) {                                  // bounded (rule 2)
            periods.append(decode(p))
        }
        return Taf(icaoId: d.icaoId ?? "", rawText: d.rawTAF, issued: issued, periods: periods)
    }

    private static func decode(_ p: DTO.Period) -> TafPeriod {
        let kind = p.fcstChange.map { $0.uppercased() } ?? ""
        let prefix = kind.isEmpty ? "" : (p.probability.map { "PROB\($0) " } ?? "") + kind + " "
        let header = prefix + timeRange(p.timeFrom, p.timeTo)
        var bits: [String] = []
        if let w = p.wdir?.text {
            let spd = p.wspd.map { "\($0)" } ?? "—"
            let gust = p.wgst.map { "G\($0)" } ?? ""
            bits.append("\(w) \(spd)\(gust) kt")
        }
        if let v = p.visib?.text { bits.append(v) }
        if let wx = p.wxString, !wx.isEmpty { bits.append(wx) }
        if let clouds = p.clouds, !clouds.isEmpty {
            let sky = clouds.compactMap { c -> String? in
                guard let cover = c.cover else { return nil }
                return c.base.map { "\(cover)\($0 / 100)" } ?? cover
            }.joined(separator: " ")
            if !sky.isEmpty { bits.append(sky) }
        }
        return TafPeriod(header: header, summary: bits.isEmpty ? "—" : bits.joined(separator: " · "))
    }

    /// "17 01:00Z – 15:00Z" from two epoch seconds (UTC).
    private static func timeRange(_ from: Int?, _ to: Int?) -> String {
        func z(_ e: Int?) -> String {
            guard let e else { return "—" }
            return "\(tafDF.string(from: Date(timeIntervalSince1970: TimeInterval(e))))Z"
        }
        return "\(z(from)) – \(z(to))"
    }
    private static let tafDF: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "d HH:mm"
        f.timeZone = TimeZone(identifier: "UTC"); f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()
}

private extension Double {
    var clean: String { self == rounded() ? String(Int(self)) : String(format: "%.1f", self) }
}

/// Fetches + caches TAFs (30-minute TTL) for the airport card's TAF sub-tab. Mirrors `MetarStore`:
/// batched fetch, terminal checked/failed states so the UI never spins forever, short failure backoff.
@MainActor final class TafStore: ObservableObject {
    @Published private(set) var tafs: [String: Taf] = [:]
    @Published private(set) var checked: Set<String> = []      // fetch completed (may be non-issuing field)
    @Published private(set) var failed: Set<String> = []       // last fetch was a transport failure
    private var fetchedAt: [String: Date] = [:]
    private var inFlight: Set<String> = []
    private let ttl: TimeInterval = 1800

    func taf(_ ident: String) -> Taf? { tafs[Self.key(ident)] }

    enum Fetch { case ok, noReport, failed }
    func state(_ ident: String) -> Fetch? {
        let id = Self.key(ident)
        if tafs[id] != nil { return .ok }
        if failed.contains(id) { return .failed }
        if checked.contains(id) { return .noReport }
        return nil
    }

    func ensure(_ idents: [String], now: Date = Date()) {
        assert(idents.count < 500, "ensure: unbounded ident list")
        let stale = Set(idents.map(Self.key)).filter { id in
            guard !id.isEmpty, !inFlight.contains(id) else { return false }
            return fetchedAt[id].map { now.timeIntervalSince($0) > ttl } ?? true
        }
        guard !stale.isEmpty else { return }
        stale.forEach { inFlight.insert($0) }
        Task { await load(Array(stale)) }
    }

    private func load(_ icaos: [String]) async {
        assert(!icaos.isEmpty, "load: no idents")
        let result = await Self.download(icaos)
        let now = Date()
        for id in icaos { inFlight.remove(id) }
        guard let result else {
            for id in icaos { fetchedAt[id] = now.addingTimeInterval(30 - ttl); if tafs[id] == nil { failed.insert(id) } }
            return
        }
        for id in icaos { fetchedAt[id] = now; failed.remove(id); checked.insert(id) }
        for (id, t) in result { tafs[id] = t }
    }

    nonisolated private static func key(_ ident: String) -> String {
        ident.trimmingCharacters(in: .whitespaces).uppercased()
    }

    /// nil = transport/decode failure (retry soon); a dictionary (possibly empty) on success.
    nonisolated private static func download(_ icaos: [String]) async -> [String: Taf]? {
        guard var comps = URLComponents(string: "https://aviationweather.gov/api/data/taf") else { return nil }
        comps.queryItems = [URLQueryItem(name: "ids", value: icaos.joined(separator: ",")),
                            URLQueryItem(name: "format", value: "json")]
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url); req.timeoutInterval = 12
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        // The API returns a JSON array; decode each element as a TAF (one call can request several idents).
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        var out: [String: Taf] = [:]
        for obj in raw.prefix(500) {                                          // bounded (rule 2)
            guard let one = try? JSONSerialization.data(withJSONObject: [obj]), let t = Taf.parse(one),
                  !t.icaoId.isEmpty else { continue }
            out[t.icaoId.uppercased()] = t
        }
        return out
    }
}
