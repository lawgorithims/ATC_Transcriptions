import Foundation

/// A filed route leg resolved to a map coordinate — its ident, `kind` (for colour), and location.
struct ResolvedLeg: Identifiable, Equatable {
    let ident: String
    let kind: RouteKind
    let coord: Coord
    /// The published crossing restriction on this leg, when it came from a coded procedure. nil for
    /// enroute waypoints, which carry none. Identity deliberately ignores it — a leg is the same leg.
    var constraint: LegConstraint?
    /// The segment role the FAA publishes for this leg (`LegRole`, from the waypoint-description code).
    /// `.none` for every enroute leg and for the many procedure legs the source marks no role on — it is
    /// the common case, not a defect. Carried so the map can colour the FAF and the missed-approach point
    /// apart from the lead-in; the role was previously read from CIFP, used to split the missed approach,
    /// and then dropped at this exact boundary.
    ///
    /// ROLES EXIST ONLY ON APPROACHES. Cross-tabulated against the shipped cycle: all 66,103 role-marked
    /// legs sit on IAP rows and SID/STAR rows carry none, so a departure or arrival waypoint has no
    /// published role to colour and inferring one would be a guess.
    var role: LegRole = .none
    /// A point that SHAPES the drawn line but is not a waypoint — the interpolated interior of a DME
    /// arc. It has no ident, no restriction and nothing to label; it exists so the magenta line follows
    /// the published curve instead of cutting the chord. Excluded from the waypoint symbol layers.
    var isPathOnly: Bool = false
    var id: String { ident + "\(kind)" }
}

/// Turns a filed `[RouteLeg]` into plottable points for the route map. Airports resolve via the
/// curated `AirportCoordinates` first (then the fuller `NavDatabase`); VORs/fixes via `NavDatabase`,
/// each disambiguated to the candidate nearest the PREVIOUS resolved point so the magenta line walks
/// the intended chain. Airway designators (Q105, J42…) are path names, not points — they're skipped,
/// so the line connects the fixes on either side. Idents that resolve to nothing are reported so the
/// map can note "N waypoints not located".
enum RouteResolver {
    /// `seed` primes the "nearest to the previous point" disambiguation for the FIRST leg — pass the last
    /// already-resolved coordinate when resolving a route SLICE (e.g. the enroute middle after a departure
    /// or SID), so an ambiguous first ident resolves to the instance nearest the chain, not an arbitrary
    /// candidate. nil (the default) preserves the original whole-route behavior.
    static func resolve(_ legs: [RouteLeg], seed: Coord? = nil) -> (points: [ResolvedLeg], unresolved: [String]) {
        var points: [ResolvedLeg] = []
        var unresolved: [String] = []
        var previous: Coord? = seed
        for (i, leg) in legs.enumerated() {
            if let c = UserPoint.parse(leg.ident) {   // a dropped lat/lon user waypoint
                points.append(ResolvedLeg(ident: leg.ident, kind: .waypoint, coord: c))
                previous = c
                continue
            }
            // AN AIRWAY IS A PATH BETWEEN ITS TWO BRACKETING FIXES, and it was being dropped entirely —
            // so "GDM V1 ORW", the exact syntax the airway card tells the pilot to file, drew a straight
            // line with none of V1's fixes on it, and DIST/ETE/ETA/fuel were computed along that line.
            // Measured over 4,231 realistic filed sub-segments the published route is a median 0.1 NM
            // longer than the chord, a mean of 2.5, a 90th percentile of 6.9 and up to 100.6 NM.
            //
            // Expanded only when BOTH brackets are present and both are actually on the airway;
            // otherwise it stays skipped and the direct line stands, because a partial expansion would
            // be a path the data does not support.
            if leg.kind == .airway {
                let before = i > 0 ? legs[i - 1].ident : ""
                let after = i + 1 < legs.count ? legs[i + 1].ident : ""
                guard !before.isEmpty, !after.isEmpty else { continue }
                let seg = Airways.segment(of: leg.ident, from: before, to: after)
                guard seg.count > 2 else { continue }          // ends only → nothing to add
                // Drop both ENDS: they are the bracketing fixes, which the loop resolves on their own.
                for p in seg.dropFirst().dropLast().prefix(400) {         // bounded (rule 2)
                    points.append(ResolvedLeg(ident: p.fix, kind: .waypoint, coord: p.coord))
                    previous = p.coord
                }
                continue
            }
            let coord: Coord?
            if leg.kind == .airport {
                coord = AirportCoordinates.coordinate(icao: leg.ident) ?? NavDatabase.resolve(leg.ident, near: previous)
            } else {
                coord = NavDatabase.resolve(leg.ident, near: previous) ?? AirportCoordinates.coordinate(icao: leg.ident)
            }
            if let coord {
                points.append(ResolvedLeg(ident: leg.ident, kind: leg.kind, coord: coord))
                previous = coord
            } else {
                unresolved.append(leg.ident)
            }
        }
        return (points, unresolved)
    }
}
