import Foundation

/// Serializes the filed `FlightPlan` for hand-off to ForeFlight — two offline app-to-app paths:
///
///  1. A route STRING for ForeFlight's URL scheme (`foreflightmobile://maps/search?q=…`), used by
///     the one-tap "Accept ➔ ForeFlight" action on an EFB suggestion. Loaded procedures are expanded
///     to their captured fix idents (`LoadedProcedure.fixes`) because `FlightPlan.fullRoute` holds
///     only departure→enroute→destination — the SID/STAR/IAP slots never appear in `route[]`, so a
///     plain `fullRoute` string would silently drop the very amendment being sent.
///  2. A Garmin FPL v1 XML document (`.fpl`) for the share sheet ("Copy to ForeFlight"), built from
///     `ProcedureRoute.resolve(plan)` legs so every waypoint carries a coordinate.
///
/// Everything here is a pure function over value types (no UIKit, no I/O, no clock) so it is fully
/// unit-testable without the app bundle. NASA Power-of-10: every loop is bounded, every function
/// validates its inputs, no recursion, no closures stored in data.
enum ForeFlightExport {
    /// Upper bound on emitted route tokens / FPL points (mirrors `ProcedureRoute.maxLegs`).
    static let maxTokens = 600

    /// The URL-scheme prefix ForeFlight registers for route loading (public, documented scheme).
    static let scheme = "foreflightmobile"

    // MARK: Route string (URL scheme)

    /// The plan as actually sent: a copy with procedure slots that must NOT be serialized dropped.
    /// - The APPROACH slot is ALWAYS dropped: the CIFP approach record includes the missed-approach
    ///   segment (the RW* MAP pseudo-fix is stripped at capture, but the named hold fix survives),
    ///   so splicing approach fixes into an enroute string draws a route that doubles back through
    ///   the missed-approach hold — misrepresenting a coded approach as a filed route. Approaches
    ///   are loaded in ForeFlight through its own procedure advisor instead.
    /// - SID/STAR slots are dropped when their airport no longer matches the plan's endpoint (a
    ///   "proceed direct BOSOX" makes the destination a fix; the old arrival's fixes must not be
    ///   sent as though still cleared). Conservative: an unmatchable slot is dropped, not guessed.
    static func sendablePlan(_ plan: FlightPlan) -> FlightPlan {
        var out = plan
        out.approachProcedure = nil                                           // never a route segment
        if out.departureProcedure?.airport.uppercased() != out.departure.uppercased() {
            out.departureProcedure = nil                                      // SID orphaned by an edit
        }
        if out.arrivalProcedure?.airport.uppercased() != out.destination.uppercased() {
            out.arrivalProcedure = nil                                        // STAR orphaned (e.g. direct-to)
        }
        assert(out.approachProcedure == nil, "approach fixes must never serialize")
        return out
    }

    /// The plan as ordered ForeFlight route tokens: departure → SID fixes → enroute → STAR fixes →
    /// destination (approach fixes are never sent — see `sendablePlan`). `DCT`/`DIRECT` filler is
    /// dropped, user `lat,lon` waypoints are re-encoded as ForeFlight's `lat/lon` form, and
    /// consecutive duplicates are collapsed (a STAR's entry fix often repeats the last enroute
    /// fix). Bounded and total; an empty plan yields [].
    static func routeTokens(for plan: FlightPlan) -> [String] {
        guard !plan.isEmpty else { return [] }                                // param check (rule 7)
        let sendable = sendablePlan(plan)
        var raw: [String] = []
        if !sendable.departure.isEmpty { raw.append(sendable.departure) }
        for fix in (sendable.departureProcedure?.fixes ?? []).prefix(128) { raw.append(fix) }
        for tok in sendable.route.prefix(256) { raw.append(tok) }
        for fix in (sendable.arrivalProcedure?.fixes ?? []).prefix(128) { raw.append(fix) }
        if !sendable.destination.isEmpty { raw.append(sendable.destination) }

        var tokens: [String] = []
        for entry in raw.prefix(maxTokens) {                                  // bounded (rule 2)
            guard let tok = routeToken(entry) else { continue }               // filler / blank → skip
            if tok == tokens.last { continue }                                // collapse consecutive dupes
            tokens.append(tok)
        }
        assert(tokens.count <= maxTokens, "token emission must respect the bound")
        return tokens
    }

    /// Normalize one filed entry into a ForeFlight route token, or nil when it contributes nothing
    /// (blank, DCT/DIRECT filler). A user `lat,lon` waypoint becomes ForeFlight's `lat/lon` form.
    static func routeToken(_ entry: String) -> String? {
        let trimmed = entry.trimmingCharacters(in: .whitespaces).uppercased()
        guard !trimmed.isEmpty else { return nil }                            // param check (rule 7)
        guard trimmed != "DCT", trimmed != "DIRECT" else { return nil }       // filler, not a fix
        if let c = UserPoint.parse(trimmed) {                                 // dropped map waypoint
            return String(format: "%.3f/%.3f", c.lat, c.lon)
        }
        return trimmed
    }

    /// The one-tap hand-off URL (`foreflightmobile://maps/search?q=FIX+FIX+…`), or nil when the plan
    /// serializes to fewer than two tokens — a single point is not a route worth switching apps for.
    static func url(for plan: FlightPlan) -> URL? {
        let tokens = routeTokens(for: plan)
        guard tokens.count >= 2 else { return nil }                           // nothing worth sending
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "./-")                                   // lat/lon token chars
        var encoded: [String] = []
        for tok in tokens.prefix(maxTokens) {                                 // bounded (rule 2)
            guard let e = tok.addingPercentEncoding(withAllowedCharacters: allowed) else { continue }
            encoded.append(e)
        }
        assert(encoded.count >= 2, "≥2 tokens in must yield ≥2 tokens out")
        return URL(string: scheme + "://maps/search?q=" + encoded.joined(separator: "+"))
    }

    /// True only when accepting a clearance actually CHANGED the plan and left something sendable.
    /// Accepting a SID/STAR/approach clearance is a silent no-op when no CIFP procedure matches at
    /// the active airport — the chip clears and haptics fire regardless — and yanking the pilot into
    /// ForeFlight with an unamended route would misrepresent the clearance as loaded.
    static func shouldHandoff(before: FlightPlan?, after: FlightPlan?) -> Bool {
        guard let after, !after.isEmpty else { return false }                 // nothing to send
        return after != before                                                // no-op accept → stay put
    }

    // MARK: Garmin FPL (.fpl share-sheet export)

    /// The resolved plan as a Garmin FPL v1 XML document, or "" when there are no legs. Waypoints
    /// are deduped into the `<waypoint-table>`; every leg becomes a `<route-point>`. `country-code`
    /// is deliberately omitted (optional in the schema; our nav data has none). User `lat,lon`
    /// waypoints get synthesized identifiers (WP01…) since FPL requires an identifier per waypoint.
    static func fplXML(for legs: [ResolvedLeg], routeName: String) -> String {
        guard !legs.isEmpty else { return "" }                                // param check (rule 7)
        let points = fplPoints(legs)
        guard !points.isEmpty else { return "" }                              // nothing survived
        // Dedupe the waypoint table by identifier (first occurrence wins). Route-points below
        // re-emit the TABLE's type for their identifier so every <route-point> references a
        // (identifier, type) pair that exists in the table — the same ident can arrive with two
        // classifications (a VOR filed enroute also appears on a procedure as a plain waypoint),
        // and a route-point typed differently from the table is a self-inconsistent FPL.
        var seen = Set<String>()
        var table: [FPLPoint] = []
        var typeFor: [String: String] = [:]
        for p in points.prefix(maxTokens) where seen.insert(p.identifier).inserted {  // bounded dedupe
            table.append(p)
            typeFor[p.identifier] = p.type
        }
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <flight-plan xmlns="http://www8.garmin.com/xmlschemas/FlightPlan/v1">
          <waypoint-table>

        """
        for p in table {
            xml += "    <waypoint>\n"
            xml += "      <identifier>\(xmlEscape(p.identifier))</identifier>\n"
            xml += "      <type>\(p.type)</type>\n"
            xml += String(format: "      <lat>%.6f</lat>\n", p.coord.lat)
            xml += String(format: "      <lon>%.6f</lon>\n", p.coord.lon)
            xml += "    </waypoint>\n"
        }
        xml += "  </waypoint-table>\n  <route>\n"
        xml += "    <route-name>\(xmlEscape(String(routeName.prefix(25))))</route-name>\n"
        for p in points {
            xml += "    <route-point>\n"
            xml += "      <waypoint-identifier>\(xmlEscape(p.identifier))</waypoint-identifier>\n"
            xml += "      <waypoint-type>\(typeFor[p.identifier] ?? p.type)</waypoint-type>\n"
            xml += "    </route-point>\n"
        }
        xml += "  </route>\n</flight-plan>\n"
        return xml
    }

    /// One FPL waypoint: identifier, Garmin type string, and location.
    struct FPLPoint: Equatable {
        let identifier: String
        let type: String
        let coord: Coord
    }

    /// Map resolved legs to FPL points. User `lat,lon` legs get WPnn identifiers in first-occurrence
    /// order (the same token always maps to the same identifier so table and route stay consistent).
    static func fplPoints(_ legs: [ResolvedLeg]) -> [FPLPoint] {
        guard !legs.isEmpty else { return [] }                                // param check (rule 7)
        var points: [FPLPoint] = []
        var userNames: [String: String] = [:]                                 // token → WPnn
        for leg in legs.prefix(maxTokens) {                                   // bounded (rule 2)
            let ident = leg.ident.trimmingCharacters(in: .whitespaces).uppercased()
            guard !ident.isEmpty else { continue }
            if UserPoint.isUserPoint(ident) {
                let name = userNames[ident] ?? String(format: "WP%02d", userNames.count + 1)
                userNames[ident] = name
                points.append(FPLPoint(identifier: name, type: "USER WAYPOINT", coord: leg.coord))
            } else {
                points.append(FPLPoint(identifier: ident, type: fplType(leg.kind), coord: leg.coord))
            }
        }
        assert(points.count <= maxTokens, "point emission must respect the bound")
        return points
    }

    /// Garmin FPL `<type>` for a route-leg kind. Airways never reach here (the resolver skips them —
    /// they are paths, not points); anything unclassified is an intersection.
    static func fplType(_ kind: RouteKind) -> String {
        switch kind {
        case .airport:  return "AIRPORT"
        case .vor:      return "VOR"
        case .waypoint: return "INT"
        case .airway:   return "INT"      // unreachable via RouteResolver; total switch (safety)
        case .other:    return "INT"
        }
    }

    /// Minimal XML text escaping for element content (idents are [A-Z0-9.] in practice, but inputs
    /// are validated, not trusted — rule 7).
    static func xmlEscape(_ s: String) -> String {
        guard !s.isEmpty else { return s }
        var out = ""
        for ch in s.prefix(256) {                                             // bounded (rule 2)
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default:  out.append(ch)
            }
        }
        return out
    }
}
