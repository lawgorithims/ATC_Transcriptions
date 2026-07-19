import Foundation

/// Live ETAs down the filed route from PRESENT POSITION at the CURRENT ground speed (not planned cruise):
/// time/ETA to the next waypoint, to the destination, and the destination's LOCAL arrival clock. Pure value
/// math (no clock/DB/IO); the caller passes `now` and formats. Degrades to nil pieces when inputs are missing.
struct RouteETAs: Equatable {
    let nextIdent: String
    let destIdent: String
    let toNextMin: Int?          // minutes to the next waypoint at the current ground speed
    let toDestMin: Int?          // minutes to the destination
    let destCoord: Coord

    static let maxLegs = 600     // rule-2 bound (mirrors ProcedureRoute)
    static let minGroundSpeedKt = 10.0   // below this, ETAs are meaningless (parked/taxi)

    /// Compute progress + ETAs. Returns nil when there's no usable route, position, or ground speed.
    static func compute(route: [(ident: String, coord: Coord)], present: Coord?,
                        groundSpeedKt: Double?) -> RouteETAs? {
        guard route.count >= 2, let present, let gs = groundSpeedKt, gs >= minGroundSpeedKt,
              let dest = route.last else { return nil }
        let next = activeNextIndex(route.map { $0.coord }, present: present)
        let distToNext = Geo.nmBetween(present, route[next].coord)
        var distToDest = distToNext
        var i = next
        while i < min(route.count, maxLegs) - 1 {          // bounded (rule 2)
            distToDest += Geo.nmBetween(route[i].coord, route[i + 1].coord); i += 1
        }
        assert(distToNext >= 0 && distToDest >= distToNext - 0.001, "RouteETAs: distance invariant")
        let toNext = Int((distToNext / gs * 60).rounded())
        let toDest = Int((distToDest / gs * 60).rounded())
        return RouteETAs(nextIdent: route[next].ident, destIdent: dest.ident,
                         toNextMin: toNext, toDestMin: toDest, destCoord: dest.coord)
    }

    /// Index of the next waypoint: the end of the segment the aircraft is currently on (min cross-track among
    /// segments whose along-track fraction is in [0,1]); else the nearest waypoint ahead. Clamped to [1, n-1].
    static func activeNextIndex(_ pts: [Coord], present p: Coord) -> Int {
        assert(pts.count >= 2, "activeNextIndex: need >=2 points")
        var bestSeg = -1, bestCross = Double.greatestFiniteMagnitude
        for i in 0..<min(pts.count, maxLegs) - 1 {         // bounded (rule 2)
            let (frac, cross) = project(p, pts[i], pts[i + 1])
            if frac >= 0, frac <= 1, cross < bestCross { bestCross = cross; bestSeg = i }
        }
        if bestSeg >= 0 { return bestSeg + 1 }
        // Off any segment (before start / past end / doglegged): fall back to the nearest waypoint, clamped.
        var nearest = 1, nd = Double.greatestFiniteMagnitude
        for i in 1..<min(pts.count, maxLegs) {             // bounded (rule 2)
            let d = Geo.nmBetween(p, pts[i]); if d < nd { nd = d; nearest = i }
        }
        return min(max(nearest, 1), pts.count - 1)
    }

    /// Along-track fraction (0=at a, 1=at b) + cross-track distance (NM) of `p` onto segment a→b, via a local
    /// equirectangular projection (accurate for the short legs of a route).
    private static func project(_ p: Coord, _ a: Coord, _ b: Coord) -> (frac: Double, crossNM: Double) {
        let latRef = a.lat * .pi / 180
        func xy(_ c: Coord) -> (x: Double, y: Double) {
            ((c.lon - a.lon) * 60 * cos(latRef), (c.lat - a.lat) * 60)   // NM east, NM north
        }
        let (bx, by) = xy(b), (px, py) = xy(p)
        let len2 = bx * bx + by * by
        guard len2 > 0 else { return (0, Geo.nmBetween(p, a)) }
        let t = (px * bx + py * by) / len2
        return (t, hypot(px - t * bx, py - t * by))
    }

    // MARK: display (dates passed in — no clock read)

    private static let clock: DateFormatter = { let f = DateFormatter(); f.timeStyle = .short; return f }()

    /// Clock ETA at the next waypoint (current time zone), e.g. "8:34 PM", or "—".
    func nextETAText(now: Date) -> String { Self.eta(toNextMin, now: now) }
    /// Clock ETA at the destination (current time zone), or "—".
    func destETAText(now: Date) -> String { Self.eta(toDestMin, now: now) }
    /// Arrival clock at the destination in the DESTINATION's LOCAL time zone (crossing time zones), or "—".
    func destLocalText(now: Date) -> String {
        guard let m = toDestMin else { return "—" }
        let arrival = now.addingTimeInterval(Double(m) * 60)
        return LocationTime.localTime(arrival, lat: destCoord.lat, lon: destCoord.lon) ?? Self.clock.string(from: arrival)
    }
    private static func eta(_ minutes: Int?, now: Date) -> String {
        guard let m = minutes else { return "—" }
        return clock.string(from: now.addingTimeInterval(Double(m) * 60))
    }
}
