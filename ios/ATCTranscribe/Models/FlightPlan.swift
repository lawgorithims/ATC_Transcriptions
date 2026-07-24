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

    // Loaded coded terminal procedures (CIFP). The flight plan is really departure → SID → enroute →
    // STAR → approach → destination; these three slots hold the departure procedure (SID/ODP), the
    // arrival procedure (STAR), and the instrument approach (IAP). Optional Codable → old persisted plans
    // (which lack these keys) still decode (missing key → nil).
    var departureProcedure: LoadedProcedure?
    var arrivalProcedure: LoadedProcedure?
    var approachProcedure: LoadedProcedure?

    /// Planned cruise altitude in feet (the flight-plan bar's altitude box). Optional Codable —
    /// old persisted plans (which lack the key) still decode. Also sent to ForeFlight as `NNNNft`.
    var cruiseAltitudeFt: Int?

    // ATC-ASSIGNED (not filed) values, set by accepting an EFB clearance. Optional Codable so old plans
    // decode (missing key → nil). These are EPHEMERAL per-flight state: `load()` drops them on an app
    // restart (a week-old "squawk 4231" is wrong), they are EXCLUDED from `isEmpty` (an assignment alone
    // is not a "filed plan"), and — deliberately — NOT added to `contextBlock`/`vocabTerms` (they must not
    // bias correction) nor to the ForeFlight export. `activeFrequency` is display-only situational
    // awareness; the app tunes no radio.
    var assignedAltitudeFt: Int?     // "maintain / climb / descend and maintain N"
    var assignedHeadingDeg: Int?     // "fly / turn left|right heading DDD"
    var assignedSpeedKt: Int?        // "maintain / reduce / increase N knots"
    var assignedSquawk: String?      // "squawk NNNN" (4 octal digits)
    var activeFrequency: String?     // "contact <facility> NNN.NN" — display only

    /// The loaded procedures in flight order (departure, arrival, approach), skipping empty slots.
    var loadedProcedures: [LoadedProcedure] {
        [departureProcedure, arrivalProcedure, approachProcedure].compactMap { $0 }
    }

    /// True when nothing meaningful has been entered (drives the "no plan" prompt + warning badge).
    /// ATC-assigned values are DELIBERATELY excluded — an assignment alone is not a filed plan (and in
    /// practice never occurs alone: a suggestion only fires when a callsign is already filed).
    var isEmpty: Bool {
        aircraftType.isEmpty && callsign.isEmpty && departure.isEmpty
            && destination.isEmpty && alternate.isEmpty && route.isEmpty
            && departureProcedure == nil && arrivalProcedure == nil && approachProcedure == nil
            && cruiseAltitudeFt == nil
    }

    /// True when any ATC-assigned value is set (drives the assignments chip row).
    var hasAssignments: Bool {
        assignedAltitudeFt != nil || assignedHeadingDeg != nil || assignedSpeedKt != nil
            || assignedSquawk != nil || activeFrequency != nil
    }

    /// Clear all ATC-assigned values (ephemeral per-flight state; dropped on app restart).
    mutating func clearAssignments() {
        assignedAltitudeFt = nil; assignedHeadingDeg = nil; assignedSpeedKt = nil
        assignedSquawk = nil; activeFrequency = nil
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
        if let alt = cruiseAltitudeFt, alt > 0 { bits.append("cruising \(alt) feet") }
        // Assemble as parts so a procedure-only plan (no callsign/airports/route) doesn't emit a dangling
        // "Own flight: ." fragment.
        var parts: [String] = []
        if !bits.isEmpty { parts.append("Own flight: " + bits.joined(separator: ", ") + ".") }
        if !route.isEmpty { parts.append("Route: " + route.joined(separator: " ") + ".") }
        for proc in loadedProcedures { parts.append(proc.contextPhrase) }   // SID / STAR / approach
        return parts.joined(separator: " ")
    }

    /// Filed terms the corrector's validator (deterministic near-miss snap) may snap onto — callsign +
    /// route fixes/airways only. Loaded-procedure fixes are DELIBERATELY excluded: they go to the LLM
    /// context block (`contextBlock`) for grounding, but adding a large procedure fix set to the snap-vocab
    /// would let the validator rewrite a correct word onto a look-alike fix (the Phase-3 false-positive
    /// class). Deterministic snapping of an airport's procedure fixes is already handled by the SlotSnap
    /// fix slot via `AirportContextData.fixes`.
    var vocabTerms: [String] {
        var t = route
        if !callsign.isEmpty { t.append(callsign) }
        if !departure.isEmpty { t.append(departure) }
        if !destination.isEmpty { t.append(destination) }
        return t.filter { !$0.isEmpty }
    }

    // MARK: Loaded procedures (SID / STAR / approach)

    /// Load a coded procedure into its slot by kind (SID → departure, STAR → arrival, IAP → approach).
    /// Validates the kind (rule 7); an unknown kind is a no-op rather than a mis-file.
    mutating func loadProcedure(_ proc: LoadedProcedure) {
        assert(!proc.ident.isEmpty, "a loaded procedure must have an ident")
        switch proc.kind {
        case "SID":  departureProcedure = proc
        case "STAR": arrivalProcedure = proc
        case "IAP":  approachProcedure = proc
        default:     break                                     // unknown kind → ignore (safety)
        }
    }

    /// Drop loaded procedures whose airport no longer matches the plan's endpoints — a TYPED route
    /// edit re-anchors the plan, so a SID at an airport that is no longer the departure (or a
    /// STAR/approach no longer at the destination) is a stale clearance, not part of what the
    /// pilot just filed. (An EFB direct-to deliberately KEEPS procedures; only route-field edits
    /// call this.)
    mutating func reconcileProceduresWithEndpoints() {
        if let sid = departureProcedure, sid.airport.uppercased() != departure.uppercased() { departureProcedure = nil }
        if let star = arrivalProcedure, star.airport.uppercased() != destination.uppercased() { arrivalProcedure = nil }
        if let iap = approachProcedure, iap.airport.uppercased() != destination.uppercased() { approachProcedure = nil }
    }

    /// Clear the procedure slot for `kind` (or all slots when `kind` is empty).
    mutating func clearProcedure(kind: String) {
        switch kind {
        case "SID":  departureProcedure = nil
        case "STAR": arrivalProcedure = nil
        case "IAP":  approachProcedure = nil
        case "":     departureProcedure = nil; arrivalProcedure = nil; approachProcedure = nil
        default:     break
        }
    }

    // MARK: Editing (map "add to route" / "Direct-To" actions)

    // The enroute portion is `route` (middle only); `departure`/`destination` are separate and
    // `fullRoute` synthesizes departure→route→destination. Edits therefore map back by IDENT and
    // special-case the two endpoints. Callers reassign the whole struct to `AppModel.flightPlan` so its
    // didSet persists + re-prefetches (a value type has no other save trigger).

    private static func norm(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces).uppercased() }

    /// Append a waypoint to the end of the enroute portion (just before the destination).
    mutating func addWaypoint(_ ident: String) {
        let id = Self.norm(ident)
        guard !id.isEmpty else { return }
        route.append(id)
    }

    /// Insert a waypoint where it best fits geographically — into the adjacent leg-gap whose detour
    /// through it is smallest — so the magenta line routes through it sensibly. `resolved` is the current
    /// `RouteResolver.resolve(fullRoute).points`.
    mutating func insertWaypointInOrder(_ ident: String, at coord: Coord, resolved: [ResolvedLeg]) {
        let id = Self.norm(ident)
        guard !id.isEmpty else { return }
        guard resolved.count >= 2 else { addWaypoint(id); return }
        var bestGap = 0, bestCost = Double.greatestFiniteMagnitude
        for i in 0..<(resolved.count - 1) {
            let a = resolved[i].coord, b = resolved[i + 1].coord
            let cost = Geo.nmBetween(a, coord) + Geo.nmBetween(coord, b) - Geo.nmBetween(a, b)
            if cost < bestCost { bestCost = cost; bestGap = i }
        }
        let at = routeIndex(afterResolved: bestGap, resolved: resolved)
        route.insert(id, at: min(max(at, 0), route.count))
    }

    /// The `route`-array index at which to insert so a new leg follows `resolved[i]`.
    private func routeIndex(afterResolved i: Int, resolved: [ResolvedLeg]) -> Int {
        let leg = resolved[i]
        if !departure.isEmpty, i == 0, leg.ident == Self.norm(departure) { return 0 }               // after departure → front
        if !destination.isEmpty, i == resolved.count - 1, leg.ident == Self.norm(destination) { return route.count }  // after destination → end
        if let k = route.firstIndex(where: { Self.norm($0) == leg.ident }) { return k + 1 }          // after a middle leg
        return route.count
    }

    /// Proceed direct to `ident` FROM the aircraft's present position: make `ident` the destination, drop the
    /// intermediate enroute waypoints, and re-anchor the origin to `origin` (the live GPS fix) so the drawn
    /// course runs from where the aircraft actually IS — not the filed departure (ForeFlight parity). `origin`
    /// is stored as a `lat,lon` user-point that RouteResolver + the ForeFlight hand-off already understand.
    /// `origin == nil` (no fix) keeps the filed departure — the only sensible anchor then.
    mutating func directTo(_ ident: String, from origin: Coord? = nil) {
        let id = Self.norm(ident)
        guard !id.isEmpty else { return }
        assert(origin.map { (-90...90).contains($0.lat) && (-180...180).contains($0.lon) } ?? true,
               "direct-to origin must be a valid coordinate")
        if let origin { departure = UserPoint.token(origin) }   // re-anchor the origin to present position
        route = []
        destination = id
        assert(destination == id && route.isEmpty, "direct-to must clear the route onto the target")
    }

    mutating func setDeparture(_ ident: String) { departure = Self.norm(ident) }
    mutating func setDestination(_ ident: String) { destination = Self.norm(ident) }

    /// Remove a filed waypoint: clear the departure/destination endpoint if it matches, else drop its
    /// first enroute occurrence.
    mutating func removeWaypoint(_ ident: String) {
        let id = Self.norm(ident)
        if Self.norm(departure) == id { departure = ""; return }
        if Self.norm(destination) == id { destination = ""; return }
        if let k = route.firstIndex(where: { Self.norm($0) == id }) { route.remove(at: k) }
    }

    /// True when `ident` is already part of the filed plan (endpoint or enroute) — drives "Remove".
    func contains(_ ident: String) -> Bool {
        let id = Self.norm(ident)
        return Self.norm(departure) == id || Self.norm(destination) == id
            || route.contains { Self.norm($0) == id }
    }

    // MARK: ForeFlight paste parsing

    /// Tolerant parser for a pasted ForeFlight-style route. Handles a plain string
    /// ("KDFW DCT BLECO Q105 LFK KAUS") and a dotted one ("KDFW./.BLECO.Q105.LFK..KAUS"): the
    /// first and last 4-letter ICAO-shaped tokens are the departure/destination, the tokens
    /// between them are the route. `DCT`/`DIRECT` filler is dropped. A map-dropped user waypoint
    /// ("42.100,-71.300" — see `UserPoint`) is kept VERBATIM: the dotted-route separators would
    /// otherwise shred it, destroying the waypoint on any flight-plan-strip edit. Anything
    /// ambiguous is left for the pilot to fix in the editor.
    static func parseRoute(_ pasted: String) -> (departure: String?, destination: String?, route: [String]) {
        let separators = CharacterSet(charactersIn: " \t\r\n./\\,;")
        var tokens: [String] = []
        for word in pasted.uppercased().split(whereSeparator: \.isWhitespace).prefix(600) {   // bounded
            if UserPoint.isUserPoint(String(word)) { tokens.append(String(word)); continue }  // lat,lon kept whole
            for piece in word.components(separatedBy: separators) {
                let tok = piece.trimmingCharacters(in: .whitespaces)
                if !tok.isEmpty, tok != "DCT", tok != "DIRECT" { tokens.append(tok) }
            }
        }
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

    /// The saved plan, or nil when nothing meaningful is stored. ATC-assigned values are ephemeral
    /// per-flight state and are dropped on load — they must not resurface a week later at next launch.
    static func load() -> FlightPlan? {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              var plan = try? JSONDecoder().decode(FlightPlan.self, from: data),
              !plan.isEmpty else { return nil }
        plan.clearAssignments()
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

/// A coded terminal procedure loaded into a flight plan (SID / STAR / IAP). Keyed by
/// `airport`+`ident`+`transition` so it survives a CIFP database rebuild (rowids change each AIRAC
/// cycle) — the legs are re-resolved from CIFP at draw time by those keys. `fixes` are captured at load
/// for grounding + a compact display. Pure value type.
struct LoadedProcedure: Codable, Equatable {
    var airport: String
    var kind: String        // "SID" | "STAR" | "IAP"
    var ident: String       // ARINC ident, e.g. "H33LX"
    var name: String        // readable, e.g. "RNAV (GPS) RWY 33L"
    var runway: String
    var transition: String
    var fixes: [String]     // fix idents on the procedure, captured at load

    /// The flight-phase label ("Departure" / "Arrival" / "Approach").
    var phaseLabel: String {
        switch kind {
        case "SID":  return "Departure"
        case "STAR": return "Arrival"
        case "IAP":  return "Approach"
        default:     return "Procedure"
        }
    }

    /// A compact phrase for the LLM grounding block, e.g. "Approach RNAV (GPS) RWY 33L via BBOGG."
    var contextPhrase: String {
        var s = phaseLabel + " " + name
        if !transition.isEmpty { s += " via " + transition }
        return s + "."
    }

    /// One-line UI label, e.g. "Approach · RNAV (GPS) RWY 33L (BBOGG)".
    var displayLine: String {
        phaseLabel + " · " + name + (transition.isEmpty ? "" : " (" + transition + ")")
    }
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
