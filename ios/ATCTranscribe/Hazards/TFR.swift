import Foundation
import CoreGraphics

/// One affected area of a TFR: a single closed lateral ring with its own altitude band. A NOTAM like
/// the DC SFRA (FDC 4/9383) defines several areas ("Area A" 30 NM ring, "Area B" the FRZ); drawing them
/// as one concatenated ring produced a bogus wedge between the areas — each ring must stand alone.
struct TFRArea: Sendable, Equatable, Codable {
    let ring: [Coord]         // closed lateral boundary (>= 3 points)
    let floorFt: Int?         // feet (0 = surface, 99999 = unlimited)
    let ceilingFt: Int?

    /// The northernmost vertex — where the per-area altitude block is drawn (chart convention).
    var labelCoord: Coord? { ring.max(by: { $0.lat < $1.lat }) }
}

/// A Temporary Flight Restriction — the live/dynamic counterpart to the bundled Special Use Airspace.
/// Sourced from the FAA's TFR service (`tfr.faa.gov`): a list of active NOTAMs, each with an AIXM detail
/// carrying one or more affected areas + altitude limits. Awareness context — always confirm against an
/// official briefing; the display shows how stale the snapshot is.
struct TFR: Identifiable, Sendable, Equatable, Codable {
    let id: String            // NOTAM id, e.g. "6/5198"
    let type: TFRType
    let title: String         // human description from the list
    let areas: [TFRArea]      // every affected area's ring (>= 1); render + hit-test ALL of them
    let floorFt: Int?         // envelope across areas: lowest floor (conservative for awareness)
    let ceilingFt: Int?       // envelope across areas: highest ceiling
    var reason: String?       // why the restriction exists, parsed from the NOTAM text (nil = unknown)
    var facility: String?     // controlling ARTCC, e.g. "ZOA" (from the list stub)
    var state: String?        // US state, e.g. "CA"
    var effective: Date?      // NOTAM effective start (UTC, from the AIXM detail)
    var expires: Date?        // NOTAM expiry (UTC); nil = indefinite/unknown

    /// The largest ring — for single-shape consumers (bbox seed, tests, legacy cache). Rendering and
    /// containment must iterate `areas`; using this for either would silently drop the other areas.
    var polygon: [Coord] { areas.max(by: { $0.ring.count < $1.ring.count })?.ring ?? [] }

    /// True when the point is inside ANY affected area (the tap probe's containment test).
    func contains(_ c: Coord) -> Bool {
        areas.contains { $0.ring.count >= 3 && Geo.pointInRing(c, $0.ring) }
    }
    /// At least one drawable ring — the render/keep guard (mirrors the old `polygon.count >= 3`).
    var hasGeometry: Bool { areas.contains { $0.ring.count >= 3 } }
    /// True when the areas carry different altitude bands (the card then flags "varies by area").
    var altitudesVaryByArea: Bool {
        Set(areas.map { "\($0.floorFt ?? -1):\($0.ceilingFt ?? -1)" }).count > 1
    }

    // Older cached snapshots carry a single `polygon` (and no areas/reason) — decode both shapes.
    enum CodingKeys: String, CodingKey { case id, type, title, polygon, areas, floorFt, ceilingFt, reason, facility, state, effective, expires }

    /// Primary init — one entry per affected area, envelope altitudes computed by the parser.
    init(id: String, type: TFRType, title: String, areas: [TFRArea], floorFt: Int?, ceilingFt: Int?,
         reason: String? = nil, facility: String? = nil, state: String? = nil,
         effective: Date? = nil, expires: Date? = nil) {
        self.id = id; self.type = type; self.title = title; self.areas = areas
        self.floorFt = floorFt; self.ceilingFt = ceilingFt; self.reason = reason
        self.facility = facility; self.state = state; self.effective = effective; self.expires = expires
    }
    /// Single-area convenience (tests, demo scenarios, legacy call sites).
    init(id: String, type: TFRType, title: String, polygon: [Coord], floorFt: Int?, ceilingFt: Int?,
         reason: String? = nil, facility: String? = nil, state: String? = nil,
         effective: Date? = nil, expires: Date? = nil) {
        self.init(id: id, type: type, title: title,
                  areas: [TFRArea(ring: polygon, floorFt: floorFt, ceilingFt: ceilingFt)],
                  floorFt: floorFt, ceilingFt: ceilingFt, reason: reason,
                  facility: facility, state: state, effective: effective, expires: expires)
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        type = try c.decode(TFRType.self, forKey: .type)
        title = try c.decode(String.self, forKey: .title)
        floorFt = try c.decodeIfPresent(Int.self, forKey: .floorFt)
        ceilingFt = try c.decodeIfPresent(Int.self, forKey: .ceilingFt)
        if let a = try c.decodeIfPresent([TFRArea].self, forKey: .areas), !a.isEmpty {
            areas = a
        } else {   // pre-areas snapshot: its single polygon becomes the one area, TFR-level altitudes
            let poly = try c.decodeIfPresent([Coord].self, forKey: .polygon) ?? []
            areas = [TFRArea(ring: poly, floorFt: floorFt, ceilingFt: ceilingFt)]
        }
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
        facility = try c.decodeIfPresent(String.self, forKey: .facility)
        state = try c.decodeIfPresent(String.self, forKey: .state)
        effective = try c.decodeIfPresent(Date.self, forKey: .effective)
        expires = try c.decodeIfPresent(Date.self, forKey: .expires)
    }
    func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(type, forKey: .type); try c.encode(title, forKey: .title)
        try c.encode(areas, forKey: .areas)
        try c.encode(polygon, forKey: .polygon)   // legacy mirror so a rolled-back build still reads the cache
        try c.encodeIfPresent(floorFt, forKey: .floorFt); try c.encodeIfPresent(ceilingFt, forKey: .ceilingFt)
        try c.encodeIfPresent(reason, forKey: .reason)
        try c.encodeIfPresent(facility, forKey: .facility); try c.encodeIfPresent(state, forKey: .state)
        try c.encodeIfPresent(effective, forKey: .effective); try c.encodeIfPresent(expires, forKey: .expires)
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
        let all = areas.flatMap(\.ring)
        let lat = all.map(\.lat), lon = all.map(\.lon)
        return BBox(minLat: lat.min() ?? 0, minLon: lon.min() ?? 0, maxLat: lat.max() ?? 0, maxLon: lon.max() ?? 0)
    }
    /// A representative "top edge" point (northernmost vertex across every area) — the card's anchor.
    var labelCoord: Coord? { areas.flatMap(\.ring).max(by: { $0.lat < $1.lat }) }
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
    ///
    /// A NOTAM's areas are its `<TFRAreaGroup>` blocks — one per FAA "Affected Area" (the DC SFRA has
    /// two: the 30 NM ring and the FRZ). Each is parsed to its OWN ring(s) with its OWN altitude band;
    /// concatenating them (the old whole-document scan) drew a bogus wedge bridging the areas. A detail
    /// with no group wrapper (hand-rolled fixtures, hypothetical feed variants) falls back to one area
    /// spanning the whole document — the old behaviour, correct for the single-area case.
    static func detail(_ xml: String, stub: Stub) -> TFR? {
        let groups = blocks("TFRAreaGroup", xml)
        let sources = groups.isEmpty ? [xml] : groups
        var areas: [TFRArea] = []
        for g in sources.prefix(64) {                                   // bounded (rule 2)
            let ceil = alt(tag("valDistVerUpper", g), tag("uomDistVerUpper", g))
            let floor = alt(tag("valDistVerLower", g), tag("uomDistVerLower", g))
            for ring in rings(boundary(g)) where ring.count >= 3 {
                areas.append(TFRArea(ring: ring, floorFt: floor, ceilingFt: ceil))
            }
        }
        assert(areas.count <= 64 * 9, "TFR area count bounded")   // 64 groups × (1 path ring + 8 circles)
        guard !areas.isEmpty else { return nil }
        let eff = tag("dateEffective", xml).flatMap { aixmDate.date(from: $0) }
        let exp = tag("dateExpire", xml).flatMap { aixmDate.date(from: $0) }
        // Envelope across areas — the card's summary band. Conservative for awareness: the lowest floor
        // and the highest ceiling that appear anywhere in the NOTAM (per-area bands stay on the areas).
        let floors = areas.compactMap(\.floorFt), ceils = areas.compactMap(\.ceilingFt)
        return TFR(id: stub.id, type: TFRType(raw: stub.type), title: stub.title,
                   areas: areas, floorFt: floors.min(), ceilingFt: ceils.max(),
                   reason: reason(xml),
                   facility: stub.facility, state: stub.state, effective: eff, expires: exp)
    }

    // MARK: reason extraction

    /// A concise "why this restriction exists", from the NOTAM text (`txtDescrTraditional`). Two tiers:
    /// the NOTAM's own purpose sentence when present ("TO PROVIDE A SAFE ENVIRONMENT FOR FIRE FIGHTING
    /// ACFT OPS"), else the statute it cites — every TFR class has a characteristic citation. Validated
    /// against all 126 NOTAMs live on 2026-07-27 (125 extracted; the one miss is FAA's own
    /// "TFR TYPE UNKNOWN" placeholder). nil = no reason parsed; the card hides the row.
    static func reason(_ xml: String) -> String? {
        guard let body = tag("txtDescrTraditional", xml)?.uppercased() else { return nil }
        // Tier 1: the hazard purpose phrase — always a genuine purpose when present. The GENERIC
        // phrases ("IN SUPPORT OF …", "FOR PROTECTION OF …") are NOT in this tier: security NOTAMs
        // carry them inside their EXEMPTION clauses ("FLIGHTS IN SUPPORT OF EVENT OPS ARE
        // AUTHORIZED…"), and harvesting one labelled 13 national-defense TFRs with their exemption
        // instead of their reason. Statutes outrank the generic phrases; validated over the live
        // corpus (125/126 extract, 0 defense NOTAMs mislabelled).
        for lead in ["TO PROVIDE A SAFE ENVIRONMENT FOR "] {
            guard let r = body.range(of: lead) else { continue }
            var phrase = String(body[r.upperBound...].prefix(120))
            // Purpose phrases are digit-free; the first digit starts the area definition / phone /
            // frequency boilerplate ("...ACFT OPS 5NM RADIUS OF 360300N..."), so cut there too.
            if let d = phrase.firstIndex(where: \.isNumber) { phrase = String(phrase[..<d]) }
            for stop in [".", ";", ",", "(", " WI ", " TEL ", " SFC", " EFFECTIVE"] {
                if let s = phrase.range(of: stop) { phrase = String(phrase[..<s.lowerBound]) }
            }
            let cleaned = expandAbbreviations(phrase)
            guard cleaned.count >= 3 else { continue }
            return "To provide a safe environment for " + cleaned
        }
        // Tier 2: the statute. Ordered specific → general.
        if body.contains("91.137(A)(1)") { return "Disaster/hazard area — only relief aircraft (14 CFR 91.137(a)(1))" }
        if body.contains("91.137(A)(2)") { return "Hazard area — safety of persons and property on the surface (14 CFR 91.137(a)(2))" }
        if body.contains("91.137(A)(3)") { return "Incident area — prevention of unsafe congestion (14 CFR 91.137(a)(3))" }
        if body.contains("91.141") { return "Security of VIP movement (14 CFR 91.141)" }
        if body.contains("91.145") { return "Aerial demonstration / major sporting event (14 CFR 91.145)" }
        if body.contains("91.143") { return "Space flight operations (14 CFR 91.143)" }
        if body.contains("44812") { return "UAS restriction — protection of a large public gathering" }
        if body.contains("NTL DEFENSE AIRSPACE") || body.contains("NATIONAL DEFENSE AIRSPACE") || body.contains("40103(B)(3)") {
            return "National defense airspace — security restriction (49 USC 40103(b)(3))"
        }
        // Tier 3: the generic phrases — only when NO statute matched, so an exemption clause can
        // never masquerade as the reason.
        for lead in ["FOR THE PROTECTION OF ", "FOR PROTECTION OF ", "IN SUPPORT OF "] {
            guard let r = body.range(of: lead) else { continue }
            var phrase = String(body[r.upperBound...].prefix(120))
            if let d = phrase.firstIndex(where: \.isNumber) { phrase = String(phrase[..<d]) }
            for stop in [".", ";", ",", "(", " WI ", " TEL ", " SFC", " EFFECTIVE"] {
                if let s2 = phrase.range(of: stop) { phrase = String(phrase[..<s2.lowerBound]) }
            }
            let cleaned = expandAbbreviations(phrase)
            guard cleaned.count >= 3 else { continue }
            let full = (lead.hasPrefix("IN SUPPORT") ? "In support of " : "Protection of ") + cleaned
            return full
        }
        return nil
    }

    /// Expand the NOTAM contractions that appear inside purpose phrases, then lowercase. Expansion runs
    /// on the UPPERCASE tokens (the keys) — lowercasing first would miss every one.
    private static func expandAbbreviations(_ s: String) -> String {
        let abbr = ["ACFT": "aircraft", "OPS": "operations", "OPNS": "operations", "FLT": "flight"]
        return s.split(separator: " ").map { abbr[String($0)] ?? String($0).lowercased() }
            .joined(separator: " ").trimmingCharacters(in: .whitespaces)
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

    /// Split one area's boundary elements into standalone rings. The path elements (vertices + arcs)
    /// form one ring; each CIR becomes its OWN ring — a full circle is closed by definition and can
    /// never be part of a path, and inlining its vertices bridged ring→circle with a bogus spike (the
    /// "pizza slice"). 62 of the 126 NOTAMs live on 2026-07-27 encode their circle TWICE — a tessellated
    /// vertex list AND the symbolic CIR of the same circle — so a CIR that coincides with the path ring
    /// is dropped as a duplicate (keeping it would stack two rings + two altitude labels).
    private static func rings(_ els: [Boundary]) -> [[Coord]] {
        var path: [Boundary] = []; var circles: [(Coord, Double)] = []
        for el in els {
            if case let .circle(c, r) = el { circles.append((c, r)) } else { path.append(el) }
        }
        var out: [[Coord]] = []
        let pathRing = tessellate(path)
        if pathRing.count >= 3 { out.append(pathRing) }
        for (c, r) in circles.prefix(8) {                              // bounded (rule 2)
            if coincides(ring: pathRing, center: c, radiusNm: r) { continue }   // duplicate encoding
            out.append(circle(centerLat: c.lat, centerLon: c.lon, radiusNm: r))
        }
        assert(out.count <= 9, "rings per area bounded")
        return out
    }

    /// True when EVERY path vertex sits on the circle (|distance − radius| within 15% of the radius or
    /// 0.5 NM, whichever is larger) — the duplicate-encoding test. An empty/degenerate ring never
    /// coincides, so a lone-CIR boundary still expands to its circle.
    private static func coincides(ring: [Coord], center: Coord, radiusNm: Double) -> Bool {
        guard ring.count >= 3, radiusNm > 0 else { return false }
        let cosLat = max(cos(center.lat * .pi / 180), 0.01)
        let tol = max(0.15 * radiusNm, 0.5)
        var i = 0
        while i < ring.count {                                         // bounded (rule 2)
            assert(i <= 4096, "coincides loop bound")
            let p = ring[i]
            let dNm = 60 * sqrt(pow(p.lat - center.lat, 2) + pow((p.lon - center.lon) * cosLat, 2))
            if abs(dNm - radiusNm) > tol { return false }
            i += 1
        }
        return true
    }

    /// Turn PATH boundary elements into a closed vertex ring: points pass through, and an arc is
    /// tessellated between the previous vertex and the next vertex about its centre. Circles never
    /// reach here — `rings()` splits them into standalone rings first.
    private static func tessellate(_ els: [Boundary]) -> [Coord] {
        var pts: [Coord] = []
        for (i, el) in els.enumerated() {
            assert(i <= 4096, "boundary loop bound")
            switch el {
            case .pt(let p):            pts.append(p)
            case .circle:               break   // split into its own ring before tessellation (rings())
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
