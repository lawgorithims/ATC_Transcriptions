import Foundation

/// Parses a Garmin FPL v1 XML document (`.fpl` — what ForeFlight shares/exports) back into an ordered
/// route string, so a plan built in ForeFlight can be imported with one tap ("Open in CommSight" from
/// ForeFlight's share sheet, or the flight-plan strip's Import button). The inverse of
/// `ForeFlightExport.fplXML`. Pure Foundation (XMLParser) — fully unit-testable. NASA Power-of-10:
/// bounded collections, validated inputs, no recursion.
enum ForeFlightImport {
    /// Upper bound on accepted route points (mirrors `ForeFlightExport.maxTokens`).
    static let maxTokens = 600

    /// The ordered route tokens from an FPL document ("KBOS BOSOX KORD"-style idents; a USER WAYPOINT
    /// becomes its "lat,lon" form). nil when the XML isn't a parseable FPL or has fewer than 2 points.
    static func routeTokens(fromFPL data: Data) -> [String]? {
        assert(maxTokens > 0, "token bound must be positive")
        guard !data.isEmpty, data.count < 4_000_000 else { return nil }   // param check: no 4 MB "plans"
        let extractor = FPLRouteExtractor()
        let parser = XMLParser(data: data)
        parser.delegate = extractor
        guard parser.parse() || !extractor.routeIdents.isEmpty else { return nil }
        let tokens = extractor.orderedTokens()
        return tokens.count >= 2 ? tokens : nil
    }

    /// The route as one committable string ("KBOS BOSOX KORD"), for `AppModel.commitRouteString`.
    static func routeString(fromFPL data: Data) -> String? {
        routeTokens(fromFPL: data).map { $0.joined(separator: " ") }
    }
}

/// SAX extractor for the two FPL sections: the `<waypoint-table>` (identifier → type + coordinate) and
/// the ordered `<route-point>` identifiers. Tolerant of unknown elements; bounded everywhere.
private final class FPLRouteExtractor: NSObject, XMLParserDelegate {
    private(set) var routeIdents: [String] = []
    private var table: [String: (type: String, lat: Double?, lon: Double?)] = [:]

    private var text = ""
    private var inWaypoint = false
    private var wpIdent = "", wpType = ""
    private var wpLat: Double?, wpLon: Double?

    func orderedTokens() -> [String] {
        var out: [String] = []
        for ident in routeIdents.prefix(ForeFlightImport.maxTokens) {         // bounded (rule 2)
            guard !ident.isEmpty else { continue }
            if let entry = table[ident], entry.type.uppercased() == "USER WAYPOINT",
               let lat = entry.lat, let lon = entry.lon,
               (-90...90).contains(lat), (-180...180).contains(lon) {
                out.append(String(format: "%.4f,%.4f", lat, lon))            // UserPoint token form
            } else {
                out.append(ident)
            }
        }
        assert(out.count <= ForeFlightImport.maxTokens, "token bound respected")
        return out
    }

    // MARK: XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
        if name == "waypoint" { inWaypoint = true; wpIdent = ""; wpType = ""; wpLat = nil; wpLon = nil }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if text.count < 512 { text += string }                                // bounded accumulation
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "identifier" where inWaypoint:          wpIdent = value.uppercased()
        case "type" where inWaypoint:                wpType = value
        case "lat" where inWaypoint:                 wpLat = Double(value)
        case "lon" where inWaypoint:                 wpLon = Double(value)
        case "waypoint":
            if !wpIdent.isEmpty, table.count < ForeFlightImport.maxTokens {
                table[wpIdent] = (wpType, wpLat, wpLon)
            }
            inWaypoint = false
        case "waypoint-identifier":
            if routeIdents.count < ForeFlightImport.maxTokens {
                routeIdents.append(value.uppercased())
            }
        default: break
        }
        text = ""
    }
}
