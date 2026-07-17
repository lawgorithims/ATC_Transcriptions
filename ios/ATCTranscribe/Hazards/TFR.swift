import Foundation
import CoreGraphics

/// A Temporary Flight Restriction — the live/dynamic counterpart to the bundled Special Use Airspace.
/// Sourced from the FAA's TFR service (`tfr.faa.gov`): a list of active NOTAMs, each with an AIXM detail
/// carrying the boundary + altitude limits. Awareness context — always confirm against an official
/// briefing; the display shows how stale the snapshot is.
struct TFR: Identifiable, Sendable, Equatable, Codable {
    let id: String            // NOTAM id, e.g. "6/5198"
    let type: TFRType
    let title: String         // human description from the list
    let polygon: [Coord]      // closed lateral boundary (>= 3 points)
    let floorFt: Int?         // feet (0 = surface, 99999 = unlimited)
    let ceilingFt: Int?
    var facility: String?     // controlling ARTCC, e.g. "ZOA" (from the list stub)
    var state: String?        // US state, e.g. "CA"
    var effective: Date?      // NOTAM effective start (UTC, from the AIXM detail)
    var expires: Date?        // NOTAM expiry (UTC); nil = indefinite/unknown

    // Older cached snapshots (pre-enrichment) decode with these fields absent — hence the defaults.
    enum CodingKeys: String, CodingKey { case id, type, title, polygon, floorFt, ceilingFt, facility, state, effective, expires }
    init(id: String, type: TFRType, title: String, polygon: [Coord], floorFt: Int?, ceilingFt: Int?,
         facility: String? = nil, state: String? = nil, effective: Date? = nil, expires: Date? = nil) {
        self.id = id; self.type = type; self.title = title; self.polygon = polygon
        self.floorFt = floorFt; self.ceilingFt = ceilingFt
        self.facility = facility; self.state = state; self.effective = effective; self.expires = expires
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        type = try c.decode(TFRType.self, forKey: .type)
        title = try c.decode(String.self, forKey: .title)
        polygon = try c.decode([Coord].self, forKey: .polygon)
        floorFt = try c.decodeIfPresent(Int.self, forKey: .floorFt)
        ceilingFt = try c.decodeIfPresent(Int.self, forKey: .ceilingFt)
        facility = try c.decodeIfPresent(String.self, forKey: .facility)
        state = try c.decodeIfPresent(String.self, forKey: .state)
        effective = try c.decodeIfPresent(Date.self, forKey: .effective)
        expires = try c.decodeIfPresent(Date.self, forKey: .expires)
    }

    /// Where `now` falls in the NOTAM's effective window. A missing bound is open-ended on that side.
    enum Window { case upcoming, active, expired }
    func window(at now: Date) -> Window {
        if let e = effective, now < e { return .upcoming }
        if let x = expires, now > x { return .expired }
        return .active
    }
    /// True when the NOTAM's window is currently in effect (awareness hint only — always confirm against
    /// an official briefing).
    func isActive(at now: Date) -> Bool { window(at: now) == .active }

    var bbox: BBox {
        let lat = polygon.map(\.lat), lon = polygon.map(\.lon)
        return BBox(minLat: lat.min() ?? 0, minLon: lon.min() ?? 0, maxLat: lat.max() ?? 0, maxLon: lon.max() ?? 0)
    }
    /// A representative "top edge" point for the altitude label (northernmost vertex).
    var labelCoord: Coord? { polygon.max(by: { $0.lat < $1.lat }) }
}

/// TFR categories → the map glyph/label. Colour is fixed red (a restriction) regardless of type.
enum TFRType: String, Sendable, Codable {
    case security, hazards, vip, airshow, space, uas, special, other
    init(raw: String) {
        switch raw.uppercased() {
        case "SECURITY":                self = .security
        case "HAZARDS":                 self = .hazards
        case "VIP":                     self = .vip
        case "AIR SHOWS/SPORTS":        self = .airshow
        case "SPACE OPERATIONS":        self = .space
        case "UAS PUBLIC GATHERING":    self = .uas
        case "SPECIAL":                 self = .special
        default:                        self = .other
        }
    }
    var label: String {
        switch self {
        case .security: return "Security"
        case .hazards:  return "Hazard"
        case .vip:      return "VIP Movement"
        case .airshow:  return "Air Show / Sporting Event"
        case .space:    return "Space Operations"
        case .uas:      return "UAS / Public Gathering"
        case .special:  return "Special"
        case .other:    return "TFR"
        }
    }
}

/// Pure parser for the FAA TFR feed — no network, so it's unit-tested with fixture strings. The list is
/// JSON (`exportTfrList`); each detail is AIXM XML (`download/detail_<id>.xml`) whose boundary is a
/// sequence of `<Avx>` vertices (GRC point / CIR circle / CCA·CWA arc) and whose altitudes are
/// `valDistVer{Upper,Lower}` (FL → ×100). Machine-generated, so a lightweight tag scan is robust.
enum TFRParser {
    struct Stub: Sendable { let id: String; let type: String; let title: String; var facility: String? = nil; var state: String? = nil }

    /// Parse the `exportTfrList` JSON into per-TFR stubs (id + type + description + facility/state).
    static func list(_ data: Data) -> [Stub] {
        guard let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return arr.prefix(400).compactMap { o in
            guard let id = o["notam_id"] as? String, !id.isEmpty else { return nil }
            let type = (o["type"] as? String) ?? ""
            let desc = (o["description"] as? String) ?? (o["facility"] as? String) ?? id
            let fac = (o["facility"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let st = (o["state"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return Stub(id: id, type: type, title: desc, facility: fac, state: st)
        }
    }

    /// Shared UTC parser for the AIXM `yyyy-MM-dd'T'HH:mm:ss` timestamps — configured once, read-only.
    private static let aixmDate: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// The URL path segment for a NOTAM's detail XML (`6/5198` → `6_5198`).
    static func detailFile(_ notamID: String) -> String { notamID.replacingOccurrences(of: "/", with: "_") }

    /// Parse one AIXM detail XML + its stub into a TFR, or nil if it carries no usable geometry (some
    /// reference-defined security NOTAMs have no inline boundary).
    static func detail(_ xml: String, stub: Stub) -> TFR? {
        let ceil = alt(tag("valDistVerUpper", xml), tag("uomDistVerUpper", xml))
        let floor = alt(tag("valDistVerLower", xml), tag("uomDistVerLower", xml))
        let pts = tessellate(boundary(xml))
        guard pts.count >= 3 else { return nil }
        let eff = tag("dateEffective", xml).flatMap { aixmDate.date(from: $0) }
        let exp = tag("dateExpire", xml).flatMap { aixmDate.date(from: $0) }
        return TFR(id: stub.id, type: TFRType(raw: stub.type), title: stub.title,
                   polygon: pts, floorFt: floor, ceilingFt: ceil,
                   facility: stub.facility, state: stub.state, effective: eff, expires: exp)
    }

    // MARK: boundary parsing

    /// One `<Avx>` boundary element: a straight-edge vertex (GRC), a full circle (CIR), or a curved arc
    /// segment (CWA clockwise / CCA counter-clockwise) that spans between its two neighbouring vertices.
    private enum Boundary { case pt(Coord); case circle(Coord, Double); case arc(center: Coord, radiusNm: Double, cw: Bool) }

    /// Parse the ordered `<Avx>` boundary. A CWA/CCA block carries NO top-level geoLat — only geoLatArc
    /// (the arc centre) + valRadiusArc — so it is read via the explicit centre, never the first-match
    /// geoLat (which would grab the nested Frd reference fix and plant a vertex ~radius NM interior).
    private static func boundary(_ xml: String) -> [Boundary] {
        var out: [Boundary] = []
        for block in blocks("Avx", xml) {
            assert(out.count <= 4096, "Avx element bound")
            let type = tag("codeType", block) ?? "GRC"
            if type == "CIR" {
                if let r = radius(block), let c = arcCenter(block) ?? point(block) { out.append(.circle(c, r)) }
            } else if type == "CWA" || type == "CCA" {
                if let r = radius(block), let c = arcCenter(block) { out.append(.arc(center: c, radiusNm: r, cw: type == "CWA")) }
            } else if let p = point(block) {
                out.append(.pt(p))                                  // GRC + any straight-edge default
            }
        }
        return out
    }

    /// Turn boundary elements into a closed vertex ring: points pass through, a lone circle expands to a
    /// ring, and an arc is tessellated between the previous vertex and the next vertex about its centre.
    private static func tessellate(_ els: [Boundary]) -> [Coord] {
        if els.count == 1, case let .circle(c, r) = els[0] { return circle(centerLat: c.lat, centerLon: c.lon, radiusNm: r) }
        var pts: [Coord] = []
        for (i, el) in els.enumerated() {
            assert(i <= 4096, "boundary loop bound")
            switch el {
            case .pt(let p):            pts.append(p)
            case .circle(let c, let r): pts.append(contentsOf: circle(centerLat: c.lat, centerLon: c.lon, radiusNm: r))
            case .arc(let c, let r, let cw):
                guard let start = pts.last, let end = nextPoint(els, after: i) else { continue }
                pts.append(contentsOf: arcBetween(center: c, radiusNm: r, from: start, to: end, cw: cw))
            }
        }
        return pts
    }

    /// The next straight-edge vertex after `i` (wrapping) — an arc's far endpoint.
    private static func nextPoint(_ els: [Boundary], after i: Int) -> Coord? {
        var k = 1
        while k <= els.count {
            assert(k <= 4097, "next-point scan bound")
            if case let .pt(p) = els[(i + k) % els.count] { return p }
            k += 1
        }
        return nil
    }

    /// Intermediate points of an arc from `s` to `e` about `center` (the endpoints are already in the
    /// ring), ~10° apart, sweeping clockwise (CWA) or counter-clockwise (CCA). Angle 0 = N, +90 = E.
    private static func arcBetween(center: Coord, radiusNm: Double, from s: Coord, to e: Coord, cw: Bool) -> [Coord] {
        let cosLat = max(cos(center.lat * .pi / 180), 0.01)
        func angle(_ p: Coord) -> Double { atan2((p.lon - center.lon) * cosLat, p.lat - center.lat) }
        let a0 = angle(s); var a1 = angle(e)
        if cw { while a1 <= a0 { a1 += 2 * .pi } } else { while a1 >= a0 { a1 -= 2 * .pi } }
        let dLat = radiusNm / 60.0, sweep = a1 - a0
        let steps = min(1000, max(1, Int(abs(sweep) / (10 * .pi / 180))))
        var out: [Coord] = []; var k = 1
        while k < steps {
            assert(k <= 1000, "arc step bound")
            let a = a0 + sweep * Double(k) / Double(steps)
            out.append(Coord(lat: center.lat + dLat * cos(a), lon: center.lon + (dLat / cosLat) * sin(a)))
            k += 1
        }
        return out
    }

    // MARK: helpers

    private static func point(_ block: String) -> Coord? {
        guard let la = coord(tag("geoLat", block) ?? ""), let lo = coord(tag("geoLong", block) ?? "") else { return nil }
        return Coord(lat: la, lon: lo)
    }
    private static func arcCenter(_ block: String) -> Coord? {
        guard let cy = coord(tag("geoLatArc", block) ?? ""), let cx = coord(tag("geoLongArc", block) ?? "") else { return nil }
        return Coord(lat: cy, lon: cx)
    }
    private static func radius(_ block: String) -> Double? {
        guard let s = tag("valRadiusArc", block), let r = Double(s), r > 0, r < 1000 else { return nil }
        return r
    }

    private static func alt(_ v: String?, _ uom: String?) -> Int? {
        guard let v, let d = Double(v) else { return nil }
        if d < 0 { return 99_999 }
        return (uom == "FL") ? Int(d * 100) : Int(d)
    }
    /// "39.96806849N" / "075.14888889W" → signed decimal degrees.
    private static func coord(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard let h = t.last, let v = Double(t.dropLast()) else { return nil }
        return (h == "S" || h == "W") ? -v : v
    }
    private static func circle(centerLat: Double, centerLon: Double, radiusNm: Double) -> [Coord] {
        let dLat = radiusNm / 60.0
        let cosLat = max(cos(centerLat * .pi / 180), 0.01)
        return stride(from: 0, to: 360, by: 10).map { deg in
            let a = Double(deg) * .pi / 180
            return Coord(lat: centerLat + dLat * cos(a), lon: centerLon + (dLat / cosLat) * sin(a))
        }
    }
    private static func tag(_ name: String, _ s: String) -> String? {
        guard let r = s.range(of: "<\(name)>"), let e = s.range(of: "</\(name)>", range: r.upperBound..<s.endIndex)
        else { return nil }
        return String(s[r.upperBound..<e.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static func blocks(_ name: String, _ s: String) -> [String] {
        var out: [String] = []; var idx = s.startIndex
        let open = "<\(name)>", close = "</\(name)>"
        while let o = s.range(of: open, range: idx..<s.endIndex),
              let c = s.range(of: close, range: o.upperBound..<s.endIndex) {
            out.append(String(s[o.upperBound..<c.lowerBound]))
            idx = c.upperBound
            if out.count >= 4096 { break }
        }
        return out
    }
}
