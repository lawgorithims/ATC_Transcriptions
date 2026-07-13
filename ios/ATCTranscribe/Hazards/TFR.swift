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
    struct Stub: Sendable { let id: String; let type: String; let title: String }

    /// Parse the `exportTfrList` JSON into per-TFR stubs (id + type + description).
    static func list(_ data: Data) -> [Stub] {
        guard let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return arr.prefix(400).compactMap { o in
            guard let id = o["notam_id"] as? String, !id.isEmpty else { return nil }
            let type = (o["type"] as? String) ?? ""
            let desc = (o["description"] as? String) ?? (o["facility"] as? String) ?? id
            return Stub(id: id, type: type, title: desc)
        }
    }

    /// The URL path segment for a NOTAM's detail XML (`6/5198` → `6_5198`).
    static func detailFile(_ notamID: String) -> String { notamID.replacingOccurrences(of: "/", with: "_") }

    /// Parse one AIXM detail XML + its stub into a TFR, or nil if it carries no usable geometry (some
    /// reference-defined security NOTAMs have no inline boundary).
    static func detail(_ xml: String, stub: Stub) -> TFR? {
        let ceil = alt(tag("valDistVerUpper", xml), tag("uomDistVerUpper", xml))
        let floor = alt(tag("valDistVerLower", xml), tag("uomDistVerLower", xml))
        var pts: [Coord] = []
        for block in blocks("Avx", xml) {
            guard let latS = tag("geoLat", block), let lonS = tag("geoLong", block),
                  let la = coord(latS), let lo = coord(lonS) else { continue }
            if tag("codeType", block) == "CIR", let rS = tag("valRadiusArc", block), let r = Double(rS) {
                // circle: centre = the arc centre if present, else this vertex; radius in NM
                let cy = coord(tag("geoLatArc", block) ?? latS) ?? la
                let cx = coord(tag("geoLongArc", block) ?? lonS) ?? lo
                pts.append(contentsOf: circle(centerLat: cy, centerLon: cx, radiusNm: r))
                continue
            }
            pts.append(Coord(lat: la, lon: lo))   // GRC + arc endpoints (arc curvature approximated by its ends)
        }
        guard pts.count >= 3 else { return nil }
        return TFR(id: stub.id, type: TFRType(raw: stub.type), title: stub.title,
                   polygon: pts, floorFt: floor, ceilingFt: ceil)
    }

    // MARK: helpers

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
