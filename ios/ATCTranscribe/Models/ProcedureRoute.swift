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
        appendEnroute(plan.route, to: &out)
        appendProcedure(plan.arrivalProcedure, to: &out)     // STAR
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
    static func appendEnroute(_ route: [String], to out: inout [ResolvedLeg]) {
        guard !route.isEmpty, out.count < maxLegs else { return }
        assert(route.count <= maxEnroute, "enroute route longer than the cap — tail is truncated")
        let legs = route.prefix(maxEnroute).map { RouteLeg(ident: $0.uppercased(), kind: RouteLeg.classify($0)) }
        let points = RouteResolver.resolve(Array(legs), seed: out.last?.coord).points
        for leg in points.prefix(maxLegs) where out.count < maxLegs { appendDeduped(leg, to: &out) }
    }

    /// Append a loaded procedure's coded legs (re-found from CIFP by its stable keys). Skips legs with no
    /// coordinate (a few vector / hold legs) and runway-threshold pseudo-fixes (RW*). Bounded.
    static func appendProcedure(_ proc: LoadedProcedure?, to out: inout [ResolvedLeg]) {
        guard let proc, !proc.ident.isEmpty, !proc.airport.isEmpty, out.count < maxLegs else { return }
        let legs = proc.kind == "IAP" ? approachLegs(proc)
                 : CIFP.legs(airport: proc.airport, ident: proc.ident, transition: proc.transition)
        assert(legs.count <= maxProcedureLegs, "procedure has more legs than the cap — tail is truncated")
        for leg in legs.prefix(maxProcedureLegs) where out.count < maxLegs {
            guard let coord = leg.coord, !leg.fix.isEmpty, !CIFP.isRunwayPseudoFix(leg.fix) else { continue }
            assert(coord.lat.isFinite && coord.lon.isFinite, "procedure leg coordinate is not finite")
            appendDeduped(ResolvedLeg(ident: leg.fix, kind: .waypoint, coord: coord), to: &out)
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

    /// Append `leg` unless it repeats the previous leg's ident (collapse the join-fix duplication) or the
    /// route is already at the cap. The entry assertion catches a caller that pushed past the cap.
    static func appendDeduped(_ leg: ResolvedLeg, to out: inout [ResolvedLeg]) {
        assert(out.count <= maxLegs, "route cap already breached on entry to appendDeduped")
        guard out.count < maxLegs, !leg.ident.isEmpty else { return }
        if out.last?.ident == leg.ident { return }
        out.append(leg)
    }
}
