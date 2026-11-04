import Foundation

/// NWS Severe Thunderstorm Warnings (`api.weather.gov/alerts/active`) → `ConvectiveCell`.
///
/// # What this adds that the AWC feeds do not
///
/// Granularity. A Convective SIGMET covers an AREA of thunderstorms; a severe thunderstorm warning is
/// drawn around **one storm**, by the forecaster watching it on radar, and it carries that storm's own
/// motion vector measured minutes ago. On a day with a line of cells, the SIGMET says "this 200 NM box"
/// and the warnings say which four cells in it are the dangerous ones.
///
/// It also costs nothing: the whole active-warning set for the United States is a couple of kilobytes.
///
/// # What it does not carry, and why that is handled the way it is
///
/// **No tops.** Nothing in the CAP product states an echo top, so `topsFtMSL` is nil and the vertical
/// gate reads `.topsUnknown` — which alerts at every altitude. For a *severe* thunderstorm that is the
/// right default (tops are routinely in the 40s), and where MRMS is also running, `ConvectiveCellMerge`
/// fills in a measured top for the same storm.
///
/// # The field that would have inverted the alert
///
/// `parameters.eventMotionDescription`, e.g.
/// `"2026-11-03T23:37:00-00:00...storm...270DEG...16KT...31.25,-92.69"`.
///
/// ⚠️ **270DEG IS WHERE THE STORM IS COMING FROM.** It is the CAP encoding of the warning text's
/// `TIME...MOT...LOC` line, which uses the meteorological convention. This was not assumed: across 12
/// warnings from the live feed, the bearing was compared against each warning's OWN prose
/// (`description`), and the FROM reading matched 12 of 12 — `227DEG` with "moving northeast", `253DEG`
/// with "moving east", and so on. The TOWARD reading would have given southwest and west-southwest for
/// those, which is backwards. `ConvectiveCell.movingFromDeg` therefore takes the value unchanged.
///
/// The timestamp at the front of that same string is used as the cell's `observedAt`, because it is when
/// the motion was MEASURED — which is what the alert ages the vector from. Using the alert's issue time
/// instead would under-age a vector on a warning that has since been updated.
enum SevereWarningParser {

    /// GeoJSON, so coordinates arrive **[longitude, latitude]**. Reversing them puts Louisiana storms in
    /// the Indian Ocean, which is at least obvious; near the equator it would not be.
    private struct Collection: Decodable { let features: [Failable]? }

    private struct Failable: Decodable {
        let feature: Feature?
        init(from decoder: Decoder) throws { feature = try? Feature(from: decoder) }
    }

    private struct Feature: Decodable {
        let geometry: Geometry?
        let properties: Properties?
    }

    private struct Geometry: Decodable {
        let type: String?
        /// Polygon: `[ring][vertex][lon, lat]`.
        let coordinates: [[[Double]]]?
    }

    private struct Properties: Decodable {
        let id: String?
        let event: String?
        let sent: String?
        let effective: String?
        let onset: String?
        let expires: String?
        let ends: String?
        let severity: String?
        let areaDesc: String?
        let parameters: [String: [String]]?
    }

    static func cells(_ data: Data) -> [ConvectiveCell] {
        assert(ConvectiveAlert.maxCells > 0, "SevereWarningParser: cell cap must be positive")
        guard !data.isEmpty else { return [] }
        guard let doc = try? JSONDecoder().decode(Collection.self, from: data) else { return [] }
        var out: [ConvectiveCell] = []
        let rows = doc.features ?? []
        out.reserveCapacity(min(rows.count, ConvectiveAlert.maxCells))
        for row in rows.prefix(ConvectiveAlert.maxCells) {
            if let c = cell(from: row.feature) { out.append(c) }
        }
        assert(out.count <= ConvectiveAlert.maxCells, "SevereWarningParser: snapshot bounded")
        return out
    }

    private static func cell(from f: Feature?) -> ConvectiveCell? {
        guard let f, let p = f.properties else { return nil }
        // The query asks for the one event type; re-check, because a feed that starts returning Winter
        // Storm Warnings under the same parameter must not have them read as thunderstorms.
        let event = (p.event ?? "")
        guard event.localizedCaseInsensitiveContains("Thunderstorm") else { return nil }
        // A zone-based alert has no polygon. Storm-based warnings always do; resolving zone geometry
        // would mean a second round trip per alert, so a null geometry is simply skipped.
        guard let g = f.geometry, (g.type ?? "") == "Polygon",
              let ring = g.coordinates?.first, ring.count >= 4 else { return nil }

        var poly: [Coord] = []
        poly.reserveCapacity(min(ring.count, ConvectiveAlert.maxVertices))
        for pair in ring.prefix(ConvectiveAlert.maxVertices) {
            guard pair.count >= 2 else { continue }
            let lon = pair[0], lat = pair[1]        // ⚠️ GeoJSON order: longitude FIRST.
            guard lat >= -90, lat <= 90, lon >= -180, lon <= 180 else { return nil }
            poly.append(Coord(lat: lat, lon: lon))
        }
        let open = CWAParser.openRing(poly)
        guard open.count >= 3 else { return nil }

        let motion = Self.motion(p.parameters?["eventMotionDescription"]?.first)
        // Prefer the instant the motion was measured; fall back through the alert's own times.
        let observed = motion?.at
            ?? date(p.onset) ?? date(p.effective) ?? date(p.sent)
        guard let observed else { return nil }
        guard let until = date(p.ends) ?? date(p.expires), until > observed else { return nil }

        let urn = p.id ?? "?"
        let area = (p.areaDesc ?? "").split(separator: ";").first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""

        return ConvectiveCell(
            id: "SVR-\(urn)",
            label: area.isEmpty ? "Severe Tstm Warning" : "Severe Tstm Warning (\(area))",
            polygon: open,
            // No product field states a top. See the type comment: nil alerts at every altitude, and
            // the merge fills in a measured one when MRMS is also running.
            topsFtMSL: nil,
            baseFtMSL: nil,
            observedAt: observed,
            validUntil: until,
            severity: severityRank(p.severity),
            movingFromDeg: motion?.fromDeg,
            motionKt: motion?.kt,
            source: .warning)
    }

    /// `"2026-11-03T23:37:00-00:00...storm...270DEG...16KT...31.25,-92.69"`.
    ///
    /// Split on the literal `...` separators the CAP parameter uses, then take the field ending in `DEG`
    /// and the one ending in `KT`, rather than counting positions — the NWS emits this with a varying
    /// number of fields (some carry several location pairs for a line of storms).
    static func motion(_ raw: String?) -> (fromDeg: Double, kt: Double, at: Date?)? {
        guard let raw, !raw.isEmpty, raw.count < 1_024 else { return nil }
        let parts = raw.components(separatedBy: "...")
        guard parts.count >= 2, parts.count <= 32 else { return nil }
        var deg: Double?, kt: Double?
        for part in parts {                                  // bounded: ≤ 32 (rule 2)
            let t = part.trimmingCharacters(in: .whitespaces).uppercased()
            if t.hasSuffix("DEG"), deg == nil {
                deg = Double(t.dropLast(3))
            } else if t.hasSuffix("KT"), kt == nil {
                kt = Double(t.dropLast(2))
            }
        }
        guard let deg, let kt, deg >= 0, deg <= 360, kt > 0, kt < 200 else { return nil }
        return (deg == 360 ? 0 : deg, kt, date(parts.first))
    }

    /// NWS severity words → the same ordinal scale the AWC feed uses for `severity` (where a convective
    /// SIGMET reads 5). Ordinal only: it orders the banner and nothing else reads it as a measurement.
    static func severityRank(_ s: String?) -> Int? {
        switch (s ?? "").lowercased() {
        case "extreme":  return 6
        case "severe":   return 5
        case "moderate": return 3
        case "minor":    return 1
        default:         return nil
        }
    }

    /// ISO-8601 with an offset, which is how every time in this feed arrives — including the unusual
    /// `-00:00` the motion parameter uses.
    static func date(_ s: String?) -> Date? {
        guard let s, !s.isEmpty, s.count < 64 else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }
}
