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
        // The SID's connecting fix is the FIRST enroute fix — where the departure hands off to the route
        // — which is the mirror of the STAR's, and the departure runway is not modelled on FlightPlan,
        // so the runway transition is simply not selected rather than guessed.
        appendProcedure(plan.departureProcedure, to: &out, connectingFix: plan.route.first)   // SID / ODP
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
        case "SID":  legs = sidLegs(proc, connectingFix: connectingFix, departureRunway: landingRunway)
        default:     legs = CIFP.legs(airport: proc.airport, ident: proc.ident, transition: proc.transition)
        }
        assert(legs.count <= maxProcedureLegs, "procedure has more legs than the cap — tail is truncated")
        // Resolved ONCE, outside the loop: the geometry guard below needs the field's own position.
        let field = proc.kind == "IAP" ? AirportCoordinates.coordinate(icao: proc.airport) : nil
        for leg in legs.prefix(maxProcedureLegs) where out.count < maxLegs {
            guard let coord = leg.coord, !leg.fix.isEmpty, !CIFP.isRunwayPseudoFix(leg.fix) else { continue }
            assert(coord.lat.isFinite && coord.lon.isFinite, "procedure leg coordinate is not finite")
            guard isPlausibleApproachLeg(coord, field: field) else {
                NSLog("CommSight: REFUSED implausible approach leg %@ %@ fix=%@ (%.4f, %.4f)",
                      proc.airport, proc.ident, leg.fix, coord.lat, coord.lon)
                continue
            }
            appendDeduped(ResolvedLeg(ident: leg.fix, kind: .waypoint, coord: coord,
                                      constraint: leg.constraint, role: leg.role), to: &out)
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
        let rows = CIFP.procedures(airport: proc.airport)
            .filter { $0.kind == "STAR" && $0.ident == proc.ident }
        let transitions = rows.map { $0.transition }
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
        // THE COMMON JUNCTION, selected by ARINC route type rather than by an empty transition name.
        // 1,469 STAR common rows are named "ALL" instead of left blank, so the old `transition.isEmpty`
        // test silently dropped the entire common segment of 1,423 arrivals — 5,819 legs, 1,686 of them
        // carrying a published crossing altitude. The drawn line stopped at the STAR's junction fix and
        // jumped straight to the destination, and those restrictions never reached LegConstraintCheck.
        if let common = rows.first(where: { $0.isCommonSegment }) { assembled += legs(common.transition) }
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

    /// The full legs of a SID AS FLOWN, assembled from its several ARINC rows.
    ///
    /// The exact mirror of `starLegs`, and it should have been written at the same time: a departure is
    /// coded as runway transitions (runway → common junction), an optional common row, and enroute
    /// transitions (junction → the enroute structure). Loading one row drew a median of 20% of a
    /// departure — 82.5% of every coded SID leg in the cycle never reached the map, and in 563 cases the
    /// row that happened to sort first was an ENROUTE transition, so the drawn departure began tens of
    /// miles from the field with nothing touching the runway. KDEN's EMMYS8 drew 2 legs of 67.
    ///
    /// ⚠️ THE NAMING CONVENTION IS REVERSED FROM A STAR, so this cannot be `starLegs` with the order
    /// flipped. A STAR's enroute transition is named by its FIRST leg fix (6,521 of 6,521) because that
    /// is where the route joins it; a SID's is named by its LAST (5,144 of 5,146) because that is where
    /// the departure leaves. Matching on the wrong end finds nothing at all.
    ///
    /// STRICT, like `starLegs`: assemble only what is positively identified, and fall back to the single
    /// loaded row otherwise — a visible stub is safer than a guessed connected path. The runway
    /// transition is appended only when the departure runway is KNOWN and matches exactly; a plan that
    /// does not state one gets the common route and the enroute exit, which is the part that is certain.
    static func sidLegs(_ proc: LoadedProcedure, connectingFix: String?, departureRunway: String?) -> [CIFPLeg] {
        let single = CIFP.legs(airport: proc.airport, ident: proc.ident, transition: proc.transition)
        let rows = CIFP.procedures(airport: proc.airport)
            .filter { $0.kind == "SID" && $0.ident == proc.ident }
        guard rows.count > 1 else { return single }
        func legs(_ t: String) -> [CIFPLeg] { CIFP.legs(airport: proc.airport, ident: proc.ident, transition: t) }

        var assembled: [CIFPLeg] = []
        // Runway transition first — it is the part that touches the departure end.
        if let rw = departureRunway?.uppercased(), rw.count >= 2 {
            let num = rw.prefix(2)
            let side = rw.count > 2 ? String(rw[rw.index(rw.startIndex, offsetBy: 2)]) : ""
            let cands = rows.filter { $0.isRunwayTransition && $0.transition.dropFirst(2).prefix(2) == num }
            func sideOf(_ t: String) -> String { t.count > 4 ? String(t[t.index(t.startIndex, offsetBy: 4)]) : "" }
            let pick = cands.first { sideOf($0.transition) == side && !side.isEmpty }
                ?? cands.first { sideOf($0.transition) == "B" || sideOf($0.transition).isEmpty }
            if let pick { assembled += legs(pick.transition) }
        }
        if let common = rows.first(where: { $0.isCommonSegment }) { assembled += legs(common.transition) }
        // Enroute exit, matched on the LAST leg fix — see the warning above.
        if let want = connectingFix?.uppercased(), !want.isEmpty,
           let exit = rows.first(where: { $0.isEnrouteTransition && legs($0.transition).last?.fix.uppercased() == want }) {
            assembled += legs(exit.transition)
        }
        // Nothing positively identified → the single row, unchanged. Never a guessed path.
        guard !assembled.isEmpty else { return single }
        assert(assembled.count <= maxProcedureLegs * 3, "assembled SID unexpectedly large")
        return assembled
    }

    /// Append `leg` unless it repeats the previous leg's ident (collapse the join-fix duplication) or the
    /// route is already at the cap. The entry assertion catches a caller that pushed past the cap.
    ///
    /// When the duplicate IS collapsed, the surviving leg keeps the more specific of the two ROLES. The
    /// join fix is coded from both sides and the two sides disagree by design — at KBOS H33LX, CRLTN is
    /// `B` on each transition's last leg and `I` on the approach proper's first leg: the same fix, seen
    /// from either side. First-wins would keep whatever the transition happened to say, and measured on
    /// the shipped cycle that silently discards the FAF mark on 1,129 approaches (1,026 where the
    /// transition's last leg carries no role at all, 102 where it is coded IAF, 1 coded IF). The FAF is
    /// the fix this whole colouring exists to point at, so it must not lose a tie to an unmarked leg.
    static func appendDeduped(_ leg: ResolvedLeg, to out: inout [ResolvedLeg]) {
        assert(out.count <= maxLegs, "route cap already breached on entry to appendDeduped")
        guard out.count < maxLegs, !leg.ident.isEmpty else { return }
        if out.last?.ident == leg.ident {
            guard let last = out.last else { return }
            if roleRank(leg.role) > roleRank(last.role) { out[out.count - 1].role = leg.role }
            // The RESTRICTION must survive the collapse too, not just the role. Keeping only the first
            // leg's altitude discarded a differing published rule on 1,452 adjacent pairs, and on 464 of
            // them the retained floor sat more than the warning tolerance above the discarded one — so
            // the app told a pilot flying the published hold altitude that they were thousands of feet
            // low. See LegConstraint.unioned(with:) for why this widens rather than tightens.
            switch (last.constraint, leg.constraint) {
            case (let a?, let b?): out[out.count - 1].constraint = a.unioned(with: b)
            case (nil, let b?):    out[out.count - 1].constraint = b
            default:               break                     // incoming carries nothing to merge
            }
            return
        }
        out.append(leg)
    }

    /// The furthest a leg of an APPROACH may plausibly sit from its own airport.
    ///
    /// Measured over every coded approach leg in the shipped cycle: the 99.9th percentile is 70.8 NM
    /// and the distribution then stops — the next value is 2,028.9 NM. The count caught is identical at
    /// 150, 200 and 300 NM (66 legs), so this is a genuine cliff and not a threshold that trades good
    /// data for bad. 150 NM sits at roughly twice the legitimate extreme.
    ///
    /// ⚠️ APPROACHES ONLY. SIDs and STARs legitimately reach 480 NM from their field (KMIA's FROGZ5
    /// touches ACORI at 463 NM), so no comparable bound exists for them and none is applied.
    static let maxApproachLegNm = 150.0

    /// Refuse to plot an approach leg that cannot belong to its own airport.
    ///
    /// `Tools/build_cifp.py` resolves each leg's fix through ONE global ident table, first-record-wins,
    /// with no airport scoping — so a terminal NDB whose two-letter ident collides with a distant navaid
    /// takes the wrong coordinate. 66 legs across 19 published approaches at 10 airports land 369-2,028
    /// NM away: KSJT's NDB RWY 03 resolves its fix "SJ" to San Juan, Puerto Rico, and every one of its
    /// 15 legs — the IF, the procedure turn, the FAF, the missed-approach hold — goes with it.
    ///
    /// The real fix is in the builder (scope terminal fixes by their owning airport, which the ARINC
    /// record states). This is the guard that should have been here anyway: nothing downstream sanity-
    /// checked a coordinate before drawing it, and the consequences were not cosmetic — a magenta
    /// approach line from Texas to Puerto Rico, DIST/ETE/fuel computed along it, and a published
    /// missed-approach hold drawn as a confident racetrack 942 NM from the runway.
    ///
    /// Refusing is the safe direction: a missing leg is visibly missing, while a leg 2,000 NM away is
    /// drawn with exactly the same authority as a correct one. `field == nil` cannot judge, so it
    /// permits — this must never reject a leg merely because the airport is unknown.
    static func isPlausibleApproachLeg(_ coord: Coord, field: Coord?) -> Bool {
        guard let field else { return true }                 // nothing to compare against
        assert(coord.lat.isFinite && coord.lon.isFinite, "isPlausibleApproachLeg: non-finite leg")
        assert(field.lat.isFinite && field.lon.isFinite, "isPlausibleApproachLeg: non-finite field")
        return Geo.nmBetween(field, coord) <= maxApproachLegNm
    }

    /// How specific a published role is, for resolving the join fix's two codings. Higher wins.
    /// `.none` is last because it means "the source marks nothing here", never "no role applies".
    static func roleRank(_ r: LegRole) -> Int {
        switch r {
        case .missedApproachPoint:     return 5   // the hardest limit on the chart
        case .finalApproachFix:        return 4
        case .initialApproachFix:      return 3
        case .finalApproachCourseFix:  return 2
        case .intermediateFix:         return 1
        case .none:                    return 0
        }
    }
}
