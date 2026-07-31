import Foundation

/// Decodes the FAA NOTAM API's GeoJSON response.
///
/// PERMISSIVE PER RECORD. The FAA's field reference sits behind MyAccess and could not be checked, so
/// this is written to survive being partly wrong: every field is optional, both documented envelope
/// shapes are accepted, and a record that will not decode drops ITSELF rather than failing the page. A
/// decoder that throws on the first surprise would turn one unexpected field into "this airport has no
/// NOTAMs", which is the single most dangerous thing this feature could display.
enum NotamParser {

    /// Cap on records taken from one response (rule 2).
    static let maxRecords = 4_000

    static func parse(_ data: Data, icao: String) -> [Notam] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        // The envelope has been described as both `items` and `data`; accept either rather than
        // returning nothing because the key was named differently than expected.
        let records = (root["items"] as? [[String: Any]]) ?? (root["data"] as? [[String: Any]]) ?? []
        var out: [Notam] = []
        out.reserveCapacity(min(records.count, maxRecords))
        for record in records.prefix(maxRecords) {                   // bounded (rule 2)
            if let n = notam(from: record, fallbackICAO: icao) { out.append(n) }
        }
        return out
    }

    /// One GeoJSON Feature → a NOTAM, or nil when it carries no usable text.
    static func notam(from record: [String: Any], fallbackICAO: String) -> Notam? {
        let properties = (record["properties"] as? [String: Any]) ?? record
        let core = (properties["coreNOTAMData"] as? [String: Any]) ?? properties
        guard let body = core["notam"] as? [String: Any] else { return nil }

        let text = (body["text"] as? String) ?? ""
        let translations = (core["notamTranslation"] as? [[String: Any]]) ?? []
        let plain = translations.compactMap { $0["simpleText"] as? String ?? $0["formattedText"] as? String }
            .first { !$0.isEmpty }
        // A record with neither a body nor a translation says nothing and is not worth a row.
        guard !text.isEmpty || !(plain ?? "").isEmpty else { return nil }

        let number = (body["number"] as? String) ?? (body["id"] as? String) ?? UUID().uuidString
        let icao = (body["icaoLocation"] as? String) ?? (body["location"] as? String) ?? fallbackICAO

        let geometry = record["geometry"] as? [String: Any]
        let coords = geometry?["coordinates"] as? [Any]
        var lat: Double?, lon: Double?
        if (geometry?["type"] as? String) == "Point", let c = coords, c.count >= 2 {
            lon = numeric(c[0]); lat = numeric(c[1])
        }
        if lat == nil { lat = numeric(body["latitude"]) }
        if lon == nil { lon = numeric(body["longitude"]) }

        return Notam(id: number,
                     icao: icao.uppercased(),
                     text: text,
                     plainText: plain,
                     classification: body["classification"] as? String,
                     effectiveStart: date(body["effectiveStart"]),
                     effectiveEnd: date(body["effectiveEnd"]),
                     issued: date(body["issued"]),
                     lat: lat, lon: lon,
                     radiusNm: numeric(body["radius"]))
    }

    /// Numbers arrive as numbers or as strings depending on the field; accept both.
    static func numeric(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let s = any as? String { return Double(s) }
        return nil
    }

    /// ISO-8601 with or without fractional seconds, plus the bare `PERM` the FAA uses for a NOTAM with
    /// no end. `PERM` returns nil, which the model reads as open-ended — never as expired.
    static func date(_ any: Any?) -> Date? {
        guard let s = (any as? String)?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        let upper = s.uppercased()
        if upper == "PERM" || upper == "PERMANENT" || upper.hasPrefix("EST") { return nil }
        for formatter in isoFormatters {                             // bounded (rule 2)
            if let d = formatter.date(from: s) { return d }
        }
        return nil
    }

    private static let isoFormatters: [ISO8601DateFormatter] = {
        let a = ISO8601DateFormatter()
        a.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let b = ISO8601DateFormatter()
        b.formatOptions = [.withInternetDateTime]
        return [a, b]
    }()
}
