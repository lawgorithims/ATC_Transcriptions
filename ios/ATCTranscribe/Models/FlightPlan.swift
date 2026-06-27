import Foundation

/// A filed flight plan — the Electronic Flight Bag's saved data. ForeFlight-style free-form
/// fields the pilot types or pastes; persisted to `UserDefaults` as JSON and packed into the
/// on-device correction LLM's context (see `ATCContext.retrieveKnowledge`) so the fixer can lock
/// onto the filed callsign, airports, and route waypoints. A plan older than a week is flagged
/// stale so the briefcase nudges the pilot to refile before the next flight.
struct FlightPlan: Codable, Equatable {
    var aircraftType = ""
    var callsign = ""
    var departure = ""
    var destination = ""
    var alternate = ""
    var route: [String] = []        // waypoints / airways between departure and destination
    var savedAt = Date()

    /// True when nothing meaningful has been entered (drives the "no plan" prompt + warning badge).
    var isEmpty: Bool {
        aircraftType.isEmpty && callsign.isEmpty && departure.isEmpty
            && destination.isEmpty && alternate.isEmpty && route.isEmpty
    }

    /// A filed plan older than this should be refreshed before the next flight.
    static let staleAfter: TimeInterval = 7 * 24 * 3600
    var isStale: Bool { Date().timeIntervalSince(savedAt) > Self.staleAfter }
    var ageDays: Int { max(0, Int(Date().timeIntervalSince(savedAt) / 86_400)) }

    /// The route as one editable/display string (space-joined).
    var routeText: String { route.joined(separator: " ") }

    /// The whole filed path as ordered, classified legs — departure airport, each route element,
    /// then the destination airport — so the notification bar can show and colour-code the full
    /// route (airports vs VOR navaids vs RNAV/GPS fixes vs airways).
    var fullRoute: [RouteLeg] {
        var legs: [RouteLeg] = []
        if !departure.isEmpty { legs.append(RouteLeg(ident: departure.uppercased(), kind: .airport)) }
        for tok in route where !tok.isEmpty { legs.append(RouteLeg(ident: tok.uppercased(), kind: RouteLeg.classify(tok))) }
        if !destination.isEmpty { legs.append(RouteLeg(ident: destination.uppercased(), kind: .airport)) }
        return legs
    }

    /// One-line summary for the notification carousel's flight-plan page.
    var summaryLine: String {
        let leg = [departure, destination].filter { !$0.isEmpty }.joined(separator: " → ")
        let parts = [callsign, leg].filter { !$0.isEmpty }
        return parts.isEmpty ? "Flight plan saved" : parts.joined(separator: "  ·  ")
    }

    /// Compact labelled block injected into the LLM correction context (the `KNOWN CONTEXT:`
    /// block). Empty fields are omitted so a partial plan still produces a clean line. Reaches
    /// both LLM backends through `RetrievedContext.block`.
    var contextBlock: String {
        guard !isEmpty else { return "" }
        var bits: [String] = []
        if !callsign.isEmpty { bits.append("callsign \(callsign)") }
        if !aircraftType.isEmpty { bits.append(aircraftType) }
        let leg = [departure, destination].filter { !$0.isEmpty }.joined(separator: " to ")
        if !leg.isEmpty { bits.append(leg) }
        if !alternate.isEmpty { bits.append("alternate \(alternate)") }
        var line = "Own flight: " + bits.joined(separator: ", ") + "."
        if !route.isEmpty { line += " Route: " + route.joined(separator: " ") + "." }
        return line
    }

    /// Filed terms the corrector's validator should be allowed to snap onto (callsign + route
    /// fixes/airways), so the LLM can fix a near-miss back onto what the pilot actually filed.
    var vocabTerms: [String] {
        var t = route
        if !callsign.isEmpty { t.append(callsign) }
        if !departure.isEmpty { t.append(departure) }
        if !destination.isEmpty { t.append(destination) }
        return t.filter { !$0.isEmpty }
    }

    // MARK: ForeFlight paste parsing

    /// Tolerant parser for a pasted ForeFlight-style route. Handles a plain string
    /// ("KDFW DCT BLECO Q105 LFK KAUS") and a dotted one ("KDFW./.BLECO.Q105.LFK..KAUS"): the
    /// first and last 4-letter ICAO-shaped tokens are the departure/destination, the tokens
    /// between them are the route. `DCT`/`DIRECT` filler is dropped. Anything ambiguous is left
    /// for the pilot to fix in the editor.
    static func parseRoute(_ pasted: String) -> (departure: String?, destination: String?, route: [String]) {
        let separators = CharacterSet(charactersIn: " \t\r\n./\\,;")
        let tokens = pasted.uppercased()
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "DCT" && $0 != "DIRECT" }
        guard !tokens.isEmpty else { return (nil, nil, []) }

        func isICAO(_ s: String) -> Bool { s.count == 4 && s.allSatisfy(\.isLetter) }

        var body = tokens
        var departure: String?
        var destination: String?
        if let first = body.first, isICAO(first) { departure = first; body.removeFirst() }
        if let last = body.last, isICAO(last) { destination = last; body.removeLast() }
        return (departure, destination, body)
    }

    // MARK: Persistence (UserDefaults JSON, mirrors the app's `atc.*` convention)

    static let storageKey = "atc.flightPlan"

    /// The saved plan, or nil when nothing meaningful is stored.
    static func load() -> FlightPlan? {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let plan = try? JSONDecoder().decode(FlightPlan.self, from: data),
              !plan.isEmpty else { return nil }
        return plan
    }

    /// Persist this plan (or clear storage when it's empty).
    func save() {
        guard !isEmpty else { Self.clear(); return }
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    static func clear() { UserDefaults.standard.removeObject(forKey: storageKey) }
}

/// One element of a filed route, with a heuristic classification so the UI can colour-code it.
struct RouteLeg: Identifiable, Equatable {
    let ident: String
    let kind: RouteKind
    var id: String { ident + "\(kind)" }

    /// Classify a single route token. Heuristic (no nav database on-device): airways are a
    /// letter(s)+digits identifier (Q105, J42, V16, UL607); a 4-letter token is an ICAO airport;
    /// a 5-letter token is an RNAV/GPS waypoint (named fix); a 3-letter token is a VOR/navaid.
    /// `DCT`/`DIRECT` and anything else (SID/STAR procedure names, etc.) fall through to `.other`.
    static func classify(_ token: String) -> RouteKind {
        let t = token.uppercased()
        if t == "DCT" || t == "DIRECT" { return .other }
        if t.range(of: "^[A-Z]{1,2}[0-9]{1,4}[A-Z]?$", options: .regularExpression) != nil { return .airway }
        if t.range(of: "^[A-Z]{4}$", options: .regularExpression) != nil { return .airport }
        if t.range(of: "^[A-Z]{5}$", options: .regularExpression) != nil { return .waypoint }
        if t.range(of: "^[A-Z]{3}$", options: .regularExpression) != nil { return .vor }
        return .other
    }
}

/// Kind of route leg, used to colour the route on the notification bar.
enum RouteKind {
    case airport    // departure / destination (ICAO) — purple-pink
    case vor        // 3-letter VOR / navaid — green
    case waypoint   // 5-letter RNAV / GPS named fix — blue
    case airway     // airway designator (Q105, J42, V16…) — amber
    case other      // DCT, SID/STAR procedure, unknown
}
