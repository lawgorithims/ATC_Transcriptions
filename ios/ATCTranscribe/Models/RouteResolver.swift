import Foundation

/// A filed route leg resolved to a map coordinate — its ident, `kind` (for colour), and location.
struct ResolvedLeg: Identifiable, Equatable {
    let ident: String
    let kind: RouteKind
    let coord: Coord
    var id: String { ident + "\(kind)" }
}

/// Turns a filed `[RouteLeg]` into plottable points for the route map. Airports resolve via the
/// curated `AirportCoordinates` first (then the fuller `NavDatabase`); VORs/fixes via `NavDatabase`,
/// each disambiguated to the candidate nearest the PREVIOUS resolved point so the magenta line walks
/// the intended chain. Airway designators (Q105, J42…) are path names, not points — they're skipped,
/// so the line connects the fixes on either side. Idents that resolve to nothing are reported so the
/// map can note "N waypoints not located".
enum RouteResolver {
    static func resolve(_ legs: [RouteLeg]) -> (points: [ResolvedLeg], unresolved: [String]) {
        var points: [ResolvedLeg] = []
        var unresolved: [String] = []
        var previous: Coord?
        for leg in legs {
            if let c = UserPoint.parse(leg.ident) {   // a dropped lat/lon user waypoint
                points.append(ResolvedLeg(ident: leg.ident, kind: .waypoint, coord: c))
                previous = c
                continue
            }
            if leg.kind == .airway { continue }   // an airway is a path between fixes, not a point
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
