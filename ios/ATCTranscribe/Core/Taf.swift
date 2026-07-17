import Foundation

/// One decoded TAF forecast period: the raw validity times + change kind, plus a plain-English summary.
/// The header is built on demand with the AIRPORT's coordinate so it can show local clock time next to
/// Zulu. The raw TAF is shown separately (some pilots read the codes), so this is the readable translation.
struct TafPeriod: Equatable, Sendable {
    let changeKind: String    // "", "FM", "BECMG", "TEMPO", "PROB"
    let probability: Int?
    let from: Int?            // epoch seconds (UTC)
    let to: Int?
    let summary: String       // e.g. "Wind from 320° at 6 kt, visibility 6+ SM, scattered clouds at 7,000 ft"

    /// Plain-English validity header with the location's local clock appended to Zulu — e.g.
    /// "From 01:00Z (9:00 PM EDT)" / "Becoming 03:00Z–06:00Z (11:00 PM–2:00 AM EDT)".
    func header(lat: Double, lon: Double) -> String {
        Taf.changeHeader(kind: changeKind, prob: probability, from: from, to: to, lat: lat, lon: lon)
    }
}

/// A Terminal Aerodrome Forecast for one airport, from aviationweather.gov's JSON API. Keeps the raw TAF
/// (what pilots read) plus lightly-decoded forecast periods. Lenient decode — one odd field never drops
/// the whole TAF. UI-only; nothing here touches the transcription pipeline.
struct Taf: Equatable, Sendable {
    let icaoId: String
    let rawText: String?
    let issued: Date?
    let periods: [TafPeriod]

    // LENIENT DECODE: every field is pulled with `try?` so one type-mismatched field never throws and
    // drops the whole TAF (the raw text especially must survive). A bad `fcsts` array degrades to no
    // periods; a bad field in one period degrades to nil for that field only.
    private struct DTO: Decodable {
        let icaoId: String?; let rawTAF: String?; let issueTime: String?; let fcsts: [Period]?
        enum K: String, CodingKey { case icaoId, rawTAF, issueTime, fcsts }
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: K.self)
            icaoId = try? c.decodeIfPresent(String.self, forKey: .icaoId)
            rawTAF = try? c.decodeIfPresent(String.self, forKey: .rawTAF)
            issueTime = try? c.decodeIfPresent(String.self, forKey: .issueTime)
            fcsts = try? c.decodeIfPresent([Period].self, forKey: .fcsts)
        }
        struct Cloud: Decodable { let cover: String?; let base: Int?
            enum K: String, CodingKey { case cover, base }
            init(from d: Decoder) throws {
                let c = try d.container(keyedBy: K.self)
                cover = try? c.decodeIfPresent(String.self, forKey: .cover)
                base = try? c.decodeIfPresent(Int.self, forKey: .base)
            }
        }
        struct Period: Decodable {
            let timeFrom: Int?; let timeTo: Int?; let fcstChange: String?; let probability: Int?
            let wdir: WindDir?; let wspd: Int?; let wgst: Int?; let visib: Vis?; let wxString: String?
            let clouds: [Cloud]?
            enum K: String, CodingKey { case timeFrom, timeTo, fcstChange, probability, wdir, wspd, wgst, visib, wxString, clouds }
            init(from d: Decoder) throws {
                let c = try d.container(keyedBy: K.self)
                timeFrom = try? c.decodeIfPresent(Int.self, forKey: .timeFrom)
                timeTo = try? c.decodeIfPresent(Int.self, forKey: .timeTo)
                fcstChange = try? c.decodeIfPresent(String.self, forKey: .fcstChange)
                probability = try? c.decodeIfPresent(Int.self, forKey: .probability)
                wdir = try? c.decodeIfPresent(WindDir.self, forKey: .wdir)
                wspd = try? c.decodeIfPresent(Int.self, forKey: .wspd)
                wgst = try? c.decodeIfPresent(Int.self, forKey: .wgst)
                visib = try? c.decodeIfPresent(Vis.self, forKey: .visib)
                wxString = try? c.decodeIfPresent(String.self, forKey: .wxString)
                clouds = try? c.decodeIfPresent([Cloud].self, forKey: .clouds)
            }
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
        let issued = d.issueTime.flatMap { parseISO($0) }
        var periods: [TafPeriod] = []
        for p in (d.fcsts ?? []).prefix(30) {                                  // bounded (rule 2)
            periods.append(decode(p))
        }
        return Taf(icaoId: d.icaoId ?? "", rawText: d.rawTAF, issued: issued, periods: periods)
    }

    /// Parse an ISO-8601 timestamp with OR without fractional seconds (the API usually sends ".000Z" but
    /// mustn't be assumed — a plain "…:00Z" would otherwise silently fail to parse).
    private static func parseISO(_ s: String) -> Date? {
        let withMs = ISO8601DateFormatter(); withMs.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withMs.date(from: s) { return d }
        let plain = ISO8601DateFormatter(); plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: s)
    }

    private static func decode(_ p: DTO.Period) -> TafPeriod {
        var bits: [String] = []
        if let w = windText(dir: p.wdir, spd: p.wspd, gust: p.wgst) { bits.append(w) }
        if let v = visText(p.visib) { bits.append(v) }
        if let wx = p.wxString, !wx.isEmpty { bits.append(wxText(wx)) }
        if let sky = skyText(p.clouds) { bits.append(sky) }
        var summary = bits.isEmpty ? "No significant change forecast" : bits.joined(separator: ", ")
        summary = summary.prefix(1).uppercased() + summary.dropFirst()      // sentence case
        return TafPeriod(changeKind: (p.fcstChange ?? "").uppercased(), probability: p.probability,
                         from: p.timeFrom, to: p.timeTo, summary: summary)
    }

    /// Plain-English change label + window in Zulu, with the location's local clock appended:
    /// "From 01:00Z (9:00 PM EDT)" / "Becoming 03:00Z–06:00Z (11:00 PM–2:00 AM EDT)".
    static func changeHeader(kind: String?, prob: Int?, from: Int?, to: Int?, lat: Double, lon: Double) -> String {
        let k = (kind ?? "").uppercased()
        let start = zulu(from)
        let span = to != nil ? "\(start)–\(zulu(to))" : "from \(start)"
        let probSuffix = prob.map { " (\($0)% probability)" } ?? ""
        let local = localSuffix(from: from, to: to, lat: lat, lon: lon)
        switch k {
        case "", "FM":    return "From \(start)\(local)"
        case "BECMG":     return "Becoming \(span)\(probSuffix)\(local)"
        case "TEMPO":     return "Temporary \(span)\(probSuffix)\(local)"
        case "PROB":      return "\(prob ?? 30)% probability \(span)\(local)"
        default:          return "\(k) \(span)\(probSuffix)\(local)"
        }
    }
    private static func zulu(_ e: Int?) -> String {
        guard let e else { return "—" }
        return "\(tafDF.string(from: Date(timeIntervalSince1970: TimeInterval(e))))Z"
    }
    /// " (9:00 PM EDT)" / " (11:00 PM–2:00 AM EDT)" for the airport's local zone, or "" if the from time or
    /// zone is unavailable.
    private static func localSuffix(from: Int?, to: Int?, lat: Double, lon: Double) -> String {
        guard let from else { return "" }
        let fromDate = Date(timeIntervalSince1970: TimeInterval(from))
        let toDate = to.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        return LocationTime.localRange(fromDate, toDate, lat: lat, lon: lon).map { " (\($0))" } ?? ""
    }

    private static func windText(dir: WindDir?, spd: Int?, gust: Int?) -> String? {
        guard spd != nil || dir != nil else { return nil }
        if let s = spd, s == 0 { return "wind calm" }
        let from: String
        switch dir {
        case .some(.vrb): from = "wind variable"
        case .some(.deg(let d)): from = String(format: "wind from %03d°", d)
        case .none: from = "wind"
        }
        let at = spd.map { " at \($0) kt" } ?? ""
        let g = gust.map { ", gusting \($0)" } ?? ""
        return from + at + g
    }

    private static func visText(_ v: Vis?) -> String? {
        guard let v else { return nil }
        switch v {
        case .num(let d): return d >= 6 ? "visibility 6+ SM" : "visibility \(d.clean) SM"
        case .str(let s):
            let t = s.uppercased()
            if t.isEmpty { return nil }
            if t.hasPrefix("P6") || t == "6+" { return "visibility 6+ SM" }
            let num = t.replacingOccurrences(of: "SM", with: "").trimmingCharacters(in: .whitespaces)
            return num.isEmpty ? "visibility \(t)" : "visibility \(num) SM"
        }
    }

    // MARK: weather-code + sky decode

    private static let wxIntensity: [Character: String] = ["-": "light ", "+": "heavy "]
    private static let wxDescriptor: [String: String] = [
        "MI": "shallow ", "PR": "partial ", "BC": "patches of ", "DR": "low drifting ", "BL": "blowing ",
        "SH": "showers of ", "TS": "thunderstorm", "FZ": "freezing "]
    private static let wxPhenom: [String: String] = [
        "DZ": "drizzle", "RA": "rain", "SN": "snow", "SG": "snow grains", "IC": "ice crystals",
        "PL": "ice pellets", "GR": "hail", "GS": "small hail", "UP": "unknown precipitation",
        "BR": "mist", "FG": "fog", "FU": "smoke", "VA": "volcanic ash", "DU": "dust", "SA": "sand",
        "HZ": "haze", "PY": "spray", "PO": "dust whirls", "SQ": "squalls", "FC": "funnel cloud",
        "SS": "sandstorm", "DS": "duststorm", "NSW": "no significant weather"]

    /// Decode a weather-code string ("-SHRA VCTS BR") to plain English, falling back to the raw token when
    /// a group can't be parsed (nothing is ever lost — the raw TAF is shown too).
    static func wxText(_ s: String) -> String {
        let groups = s.split(separator: " ").prefix(8)                        // bounded (rule 2)
        let phrases = groups.map { decodeWxGroup(String($0)) }
        return phrases.joined(separator: ", ")
    }
    private static func decodeWxGroup(_ raw: String) -> String {
        var t = raw.uppercased()
        var vicinity = false, out = ""
        if t.hasPrefix("VC") { vicinity = true; t.removeFirst(2) }
        if let first = t.first, let word = wxIntensity[first] { out += word; t.removeFirst() }
        var guard1 = 0
        while t.count >= 2, guard1 < 6 {                                     // bounded (rule 2)
            let tok = String(t.prefix(2)); t.removeFirst(2); guard1 += 1
            if tok == "TS", !t.isEmpty { out += "thunderstorm with " }        // TSRA → "thunderstorm with rain"
            else if let d = wxDescriptor[tok] { out += d }
            else if let ph = wxPhenom[tok] { out += ph }
            else { out += tok.lowercased() }                                 // unknown → keep the code
        }
        if out.trimmingCharacters(in: .whitespaces).isEmpty { out = raw.lowercased() }
        return (out + (vicinity ? " in the vicinity" : "")).trimmingCharacters(in: .whitespaces)
    }

    private static func skyText(_ clouds: [DTO.Cloud]?) -> String? {
        guard let clouds, !clouds.isEmpty else { return nil }
        let parts = clouds.prefix(6).compactMap { c -> String? in            // bounded (rule 2)
            guard let cover = c.cover?.uppercased() else { return nil }
            let name: String
            switch cover {
            case "SKC", "CLR", "NSC", "NCD": return "sky clear"
            case "FEW": name = "few clouds"
            case "SCT": name = "scattered clouds"
            case "BKN": name = "broken clouds"
            case "OVC": name = "overcast"
            case "VV":  name = "sky obscured, vertical visibility"
            default:    name = cover.lowercased()
            }
            guard let base = c.base else { return name }
            return "\(name) at \(base.grouped) ft"
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
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
