import Foundation

/// Expands a `FlightPlan` into the full georeferenced path the map draws and the pilot flies:
/// departure → SID → enroute → STAR → approach → destination. Enroute idents resolve through
/// `RouteResolver` (seeded with the previous resolved coordinate so an ambiguous fix disambiguates to the
/// instance nearest the chain, not an arbitrary candidate); each loaded procedure's legs come from CIFP,
/// re-found by its stable keys, with their coded coordinates. Pure + bounded (NASA/JPL "Power of 10"): a
/// hard cap on the assembled leg count, no recursion, every loop statically bounded, parameters validated
/// with explicit recovery.
enum ProcedureRoute {

    /// Hard caps so every loop is statically bounded (rule 2/3). A real IFR route + three procedures is
    /// well under these; exceeding one is asserted (surfacing the otherwise-silent tail truncation).
    static let maxLegs = 600
    static let maxProcedureLegs = 120
    static let maxEnroute = 256

    /// The ordered, plottable path for `plan`. Consecutive duplicate idents are collapsed (a procedure's
    /// first fix often repeats the enroute fix it joins). Never exceeds `maxLegs`.
    static func resolve(_ plan: FlightPlan) -> [ResolvedLeg] {
        var out: [ResolvedLeg] = []
        out.reserveCapacity(maxLegs)
        appendAirport(plan.departure, to: &out)
        appendProcedure(plan.departureProcedure, to: &out)   // SID / ODP
        // When the departure didn't resolve (empty or unknown), the first enroute fix has no predecessor
        // to disambiguate against, and NavDatabase.resolve(near: nil) returns an ARBITRARY worldwide
        // candidate for a non-unique ident — which the greedy nearest-walk then drags the whole route
        // (and its DIST/ETE) onto the wrong continent. Anchor the first leg on the DESTINATION airport
        // instead: a filed route's fixes lie between its endpoints, so the destination is a far better
        // guess than a random candidate, and it is an ICAO that resolves uniquely.
        let enrouteSeed = out.last?.coord
            ?? AirportCoordinates.coordinate(icao: plan.destination.uppercased())
            ?? NavDatabase.resolve(plan.destination.uppercased(), near: nil)
        appendEnroute(plan.route, to: &out, fallbackSeed: enrouteSeed)
        // The STAR is assembled from the enroute transition that joins the filed route (its last fix)
        // and the runway transition for the landing runway (from the loaded approach) — see starLegs.
        appendProcedure(plan.arrivalProcedure, to: &out,
                        connectingFix: plan.route.last, landingRunway: plan.approachProcedure?.runway)
        appendProcedure(plan.approachProcedure, to: &out)    // IAP
        appendAirport(plan.destination, to: &out)
        return out
    }

    /// Resolve + append a single airport endpoint, seeded with the last resolved coord so an ambiguous
    /// airport ident disambiguates nearest the chain. Deduped.
    static func appendAirport(_ ident: String, to out: inout [ResolvedLeg]) {
        guard !ident.isEmpty, out.count < maxLegs else { return }
        let points = RouteResolver.resolve([RouteLeg(ident: ident.uppercased(), kind: .airport)],
                                           seed: out.last?.coord).points
        for leg in points.prefix(2) { appendDeduped(leg, to: &out) }   // ≤1 airport; prefix bounds it
    }

    /// Resolve + append the enroute portion, SEEDED with the departure / SID-terminus coordinate so the
    /// first enroute ident disambiguates against the chain. Bounded by `maxEnroute` + `maxLegs`.
    static func appendEnroute(_ route: [String], to out: inout [ResolvedLeg], fallbackSeed: Coord? = nil) {
        guard !route.isEmpty, out.count < maxLegs else { return }
        assert(route.count <= maxEnroute, "enroute route longer than the cap — tail is truncated")
        let legs = route.prefix(maxEnroute).map { RouteLeg(ident: $0.uppercased(), kind: RouteLeg.classify($0)) }
        let points = RouteResolver.resolve(Array(legs), seed: out.last?.coord ?? fallbackSeed).points
        for leg in points.prefix(maxLegs) where out.count < maxLegs { appendDeduped(leg, to: &out) }
    }

    /// Append a loaded procedure's coded legs (re-found from CIFP by its stable keys). Skips legs with no
    /// coordinate (a few vector / hold legs) and runway-threshold pseudo-fixes (RW*). Bounded.
    static func appendProcedure(_ proc: LoadedProcedure?, to out: inout [ResolvedLeg],
                                connectingFix: String? = nil, landingRunway: String? = nil) {
        guard let proc, !proc.ident.isEmpty, !proc.airport.isEmpty, out.count < maxLegs else { return }
        let legs: [CIFPLeg]
        switch proc.kind {
        case "IAP":  legs = approachLegs(proc)
        case "STAR": legs = starLegs(proc, connectingFix: connectingFix, landingRunway: landingRunway)
        default:     legs = CIFP.legs(airport: proc.airport, ident: proc.ident, transition: proc.transition)
        }
        assert(legs.count <= maxProcedureLegs, "procedure has more legs than the cap — tail is truncated")
        for leg in legs.prefix(maxProcedureLegs) where out.count < maxLegs {
            guard let coord = leg.coord, !leg.fix.isEmpty, !CIFP.isRunwayPseudoFix(leg.fix) else { continue }
            assert(coord.lat.isFinite && coord.lon.isFinite, "procedure leg coordinate is not finite")
            appendDeduped(ResolvedLeg(ident: leg.fix, kind: .waypoint, coord: coord,
                                      constraint: leg.constraint), to: &out)
        }
    }

    /// The legs of an approach AS FLOWN: the chosen transition (how the aircraft gets in) followed by
    /// the approach proper, stopping at the missed-approach point.
    ///
    /// An approach is coded as two separate rows and the transition row is not the whole approach.
    /// Querying by `proc.transition` alone drew a path that ran to the join fix and then jumped
    /// straight to the airport reference point — the final approach segment, the part actually being
    /// flown, was simply absent from the magenta line. (Not from DIST/ETE: `ForeFlightExport
    /// .sendablePlan` drops the approach before the trip computation, so the readout never showed the
    /// gap. Triage this one by looking at the drawn route.) The opposite error sat on the other branch:
    /// joining with VECTORS queried the approach-proper row and drew its whole tail, so the
    /// missed-approach hold appeared as a normal enroute leg of an approach nobody had gone missed on.
    static func approachLegs(_ proc: LoadedProcedure) -> [CIFPLeg] {
        assert(proc.kind == "IAP", "approachLegs given a non-approach")
        guard let proper = CIFP.approachProper(airport: proc.airport, ident: proc.ident) else {
            return CIFP.legs(airport: proc.airport, ident: proc.ident, transition: proc.transition)
        }
        let properLegs = CIFP.legs(procedureID: proper.id).prefix(maxProcedureLegs)
        let split = ApproachActivation.splitMissed(
            properLegs.map { (seq: $0.seq, fix: $0.fix, legType: $0.legType) }, roles: properLegs.map(\.role))
        let missed = Set(split.missed)
        let flown = properLegs.filter { !missed.contains($0.seq) }
        guard !proc.transition.isEmpty else { return Array(flown) }
        // A LoadedProcedure persists to UserDefaults keyed by airport+ident+transition so it survives an
        // AIRAC rebuild — which means the transition can be WITHDRAWN under it. CIFP.legs falls back to
        // the first row matching the ident, and that is the approach-proper row, so a stale key spliced
        // the untrimmed approach (missed hold and all) in front of the trimmed one: the hold drawn as a
        // normal leg, then the whole approach again. Verify the transition still exists; if it does not,
        // this is a vectors join.
        let published = CIFP.transitions(airport: proc.airport, ident: proc.ident)
        guard published.contains(where: { $0.caseInsensitiveCompare(proc.transition) == .orderedSame })
        else { return Array(flown) }
        let entry = CIFP.legs(airport: proc.airport, ident: proc.ident, transition: proc.transition)
        return Array(entry.prefix(maxProcedureLegs)) + flown
    }

    /// The full legs of a STAR AS FLOWN, assembled from its several ARINC rows.
    ///
    /// A STAR is coded as separate rows: enroute transitions (each named by its entry fix, running to a
    /// common junction), an optional common row, and runway transitions (junction → landing runway). A
    /// single (ident, transition) query returns only ONE of these — a 2-leg enroute stub for a
    /// procedure that spans tens of miles, so a voice-loaded arrival drew a fragment diverging wildly
    /// from the chart. Assemble the branch actually being flown: the enroute transition that joins the
    /// filed route, then the common, then the runway transition for the landing runway.
    ///
    /// STRICT by design: assemble only when the enroute end is positively identified by the connecting
    /// fix. When it cannot be, fall back to the single loaded row — a visible stub is safer than a
    /// GUESSED connected path, which is the worse failure. The runway transition is appended only on an
    /// exact runway-number match; absent an approach the path still connects through the junction.
    static func starLegs(_ proc: LoadedProcedure, connectingFix: String?, landingRunway: String?) -> [CIFPLeg] {
        let single = CIFP.legs(airport: proc.airport, ident: proc.ident, transition: proc.transition)
        guard let connectingFix, !connectingFix.isEmpty else { return single }
        let want = connectingFix.uppercased()
        // ALL rows of this STAR, including the common ("") and runway ("RW…") transitions —
        // CIFP.transitions is IAP-only and excludes both, so it cannot drive a STAR assembly.
        let transitions = CIFP.procedures(airport: proc.airport)
            .filter { $0.kind == "STAR" && $0.ident == proc.ident }.map { $0.transition }
        guard transitions.count > 1 else { return single }
        func legs(_ t: String) -> [CIFPLeg] { CIFP.legs(airport: proc.airport, ident: proc.ident, transition: t) }
        // A STAR runway transition is "RW" + two digits + an optional side letter (incl. "B" = both) —
        // NOT the L/C/R-only shape CIFP.isRunwayPseudoFix tests, so use a local check.
        func isRunwayTransition(_ t: String) -> Bool {
            let u = t.uppercased()
            return u.hasPrefix("RW") && u.count >= 4 && u.dropFirst(2).prefix(2).allSatisfy(\.isNumber)
        }
        // Enroute transition whose FIRST leg is the connecting fix — the point the route joins the STAR.
        guard let enrName = transitions.first(where: {
            !$0.isEmpty && !isRunwayTransition($0) && legs($0).first?.fix.uppercased() == want
        }) else { return single }

        var assembled = legs(enrName)
        if transitions.contains(where: { $0.isEmpty }) { assembled += legs("") }   // common junction
        if let rw = landingRunway, rw.count >= 2 {
            let u = rw.uppercased()
            let num = u.prefix(2)
            let side = u.count > 2 ? String(u[u.index(u.startIndex, offsetBy: 2)]) : ""   // "L"/"C"/"R" or ""
            // Pick the runway transition for the SIDE actually being landed, never the wrong parallel.
            // "RW04B" serves both 04L and 04R; a bare "RW04" is side-agnostic. Prefer exact side, then
            // the both/bare form; if the STAR codes ONLY the other specific side, append nothing (ending
            // at the junction is safe — drawing the opposite parallel's transition is not).
            let rwys = transitions.filter { isRunwayTransition($0) && $0.dropFirst(2).prefix(2) == num }
            func sideOf(_ t: String) -> String { t.count > 4 ? String(t[t.index(t.startIndex, offsetBy: 4)]) : "" }
            let pick = rwys.first { sideOf($0) == side && !side.isEmpty }      // exact side (RW04R for 04R)
                ?? rwys.first { sideOf($0) == "B" || sideOf($0).isEmpty }      // both / side-agnostic
            if let rwName = pick { assembled += legs(rwName) }
        }
        assert(assembled.count <= maxProcedureLegs * 3, "assembled STAR unexpectedly large")
        return assembled
    }

    /// Append `leg` unless it repeats the previous leg's ident (collapse the join-fix duplication) or the
    /// route is already at the cap. The entry assertion catches a caller that pushed past the cap.
    static func appendDeduped(_ leg: ResolvedLeg, to out: inout [ResolvedLeg]) {
        assert(out.count <= maxLegs, "route cap already breached on entry to appendDeduped")
        guard out.count < maxLegs, !leg.ident.isEmpty else { return }
        if out.last?.ident == leg.ident { return }
        out.append(leg)
    }
}
