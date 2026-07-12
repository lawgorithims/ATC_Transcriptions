import Foundation

/// The route/vicinity hazard check result: NASA EONET events within a corridor of the filed route,
/// and (separately) near ownship. Pure data — built off the main actor by `HazardCorridor.alert`.
struct HazardAlert: Equatable, Sendable {
    struct Hit: Equatable, Sendable, Identifiable {
        let eventID: String
        let title: String
        let category: EONETCategory
        let distanceNm: Double        // to the route (routeHits) or ownship (vicinityHits); 0 = inside
        let coord: Coord              // the event's representative point
        var id: String { eventID }
    }
    var routeHits: [Hit] = []         // within `corridorNm` of the route polyline, nearest first
    var vicinityHits: [Hit] = []      // within `vicinityNm` of ownship (route hits excluded), nearest first
    var isEmpty: Bool { routeHits.isEmpty && vicinityHits.isEmpty }
}

/// Pure corridor / vicinity math (no MapKit, no actor) so it is unit-testable and can run on a
/// detached task. Per-segment distances use a local equirectangular projection at the segment's
/// mid-latitude — closed-form (no iteration at all), and it errs <1% versus great-circle cross-track
/// for GA-length legs, far inside a 25 NM corridor's tolerance.
enum HazardCorridor {
    static let corridorNm = 25.0
    static let vicinityNm = 50.0
    static let maxRoutePoints = 256      // resolved routes are clamped here (rule 2)
    static let maxEvents = 400           // EONETService's hard event ceiling
    static let maxHits = 8               // banner cap — nearest first

    /// Point-to-segment distance in NM under a flat projection at the segment's mid-latitude. The
    /// projection parameter is clamped to [0, 1], so a zero-length segment degrades to endpoint
    /// distance and points beyond either end measure to that end.
    static func distanceNm(from p: Coord, toSegment a: Coord, _ b: Coord) -> Double {
        assert((-90...90).contains(p.lat) && (-90...90).contains(a.lat) && (-90...90).contains(b.lat),
               "latitudes in range")
        let kx = 60.0 * cos((a.lat + b.lat) / 2 * .pi / 180)   // NM per degree longitude here
        let ky = 60.0                                          // NM per degree latitude
        let bx = deltaLon(from: a.lon, to: b.lon) * kx, by = (b.lat - a.lat) * ky
        let px = deltaLon(from: a.lon, to: p.lon) * kx, py = (p.lat - a.lat) * ky
        let len2 = bx * bx + by * by
        let t = len2 > 0 ? max(0, min(1, (px * bx + py * by) / len2)) : 0
        assert(t >= 0 && t <= 1, "projection parameter clamped")
        let dx = px - t * bx, dy = py - t * by
        return (dx * dx + dy * dy).squareRoot()
    }

    /// Min distance from `p` to the polyline (NM) with a latitude-band pre-reject per segment:
    /// EXACT for anything within `within` NM; may return `.greatestFiniteMagnitude` for points
    /// farther than that (the only question the alert asks). Bounded loops (rule 2).
    static func distanceNm(from p: Coord, toPolyline pts: [Coord], within: Double) -> Double {
        assert(within > 0, "corridor radius must be positive")
        assert(pts.count <= maxRoutePoints, "route clamped upstream")
        guard pts.count >= 2 else {
            return pts.first.map { Geo.nmBetween(p, $0) } ?? .greatestFiniteMagnitude
        }
        let latMargin = (within + 1) / 60.0                    // the band, with 1 NM slack
        var best = Double.greatestFiniteMagnitude
        for i in 0..<min(pts.count - 1, maxRoutePoints - 1) {
            let a = pts[i], b = pts[i + 1]
            if p.lat < min(a.lat, b.lat) - latMargin || p.lat > max(a.lat, b.lat) + latMargin { continue }
            best = min(best, distanceNm(from: p, toSegment: a, b))
        }
        return best
    }

    /// Build the alert: events within `corridorNm` of the route, plus events within `vicinityNm`
    /// of ownship. A route hit never repeats as a vicinity hit, so one hazard can't fire twice.
    /// Nearest first, capped at `maxHits` per list.
    static func alert(events: [EONETEvent], route rawRoute: [Coord], ownship: Coord?) -> HazardAlert {
        assert(events.count <= maxEvents, "event snapshot bounded by EONETService")
        let route = Array(rawRoute.prefix(maxRoutePoints))
        assert(route.count <= maxRoutePoints, "route clamped")
        var routeHits: [HazardAlert.Hit] = []
        var vicinityHits: [HazardAlert.Hit] = []
        for ev in events.prefix(maxEvents) {
            if !route.isEmpty {
                let d = eventDistanceNm(ev, toPolyline: route, within: corridorNm)
                if d <= corridorNm {
                    routeHits.append(.init(eventID: ev.id, title: ev.title, category: ev.category,
                                           distanceNm: d, coord: ev.point))
                    continue
                }
            }
            if let own = ownship {
                let d = eventDistanceNm(ev, toPoint: own)
                if d <= vicinityNm {
                    vicinityHits.append(.init(eventID: ev.id, title: ev.title, category: ev.category,
                                              distanceNm: d, coord: ev.point))
                }
            }
        }
        routeHits.sort { $0.distanceNm < $1.distanceNm }
        vicinityHits.sort { $0.distanceNm < $1.distanceNm }
        return HazardAlert(routeHits: Array(routeHits.prefix(maxHits)),
                           vicinityHits: Array(vicinityHits.prefix(maxHits)))
    }

    /// An event's distance to the route: its marker point, any storm-track fix, or its perimeter —
    /// whichever is nearest; 0 when a route vertex lies inside the perimeter. Perimeter distance is
    /// vertex-based (rings are decode-capped and dense at regional scale), so a >50 NM-long polygon
    /// edge could under-count — no real EONET geometry looks like that.
    static func eventDistanceNm(_ ev: EONETEvent, toPolyline route: [Coord], within: Double) -> Double {
        assert(ev.track.count <= EONETEvent.maxTrackPoints, "track capped at decode")
        assert(ev.polygon.count <= EONETEvent.maxPolygonVertices, "ring capped at decode")
        var best = distanceNm(from: ev.point, toPolyline: route, within: within)
        for t in ev.track.prefix(EONETEvent.maxTrackPoints) {
            best = min(best, distanceNm(from: t, toPolyline: route, within: within))
        }
        if ev.polygon.count >= 3 {
            for v in route.prefix(maxRoutePoints) where Geo.pointInRing(v, ev.polygon) { return 0 }
            for v in ev.polygon.prefix(EONETEvent.maxPolygonVertices) {
                best = min(best, distanceNm(from: v, toPolyline: route, within: within))
            }
        }
        return best
    }

    /// An event's distance to a point (ownship): marker, track fixes, or 0 inside the perimeter.
    static func eventDistanceNm(_ ev: EONETEvent, toPoint own: Coord) -> Double {
        assert(ev.track.count <= EONETEvent.maxTrackPoints, "track capped at decode")
        assert(ev.polygon.count <= EONETEvent.maxPolygonVertices, "ring capped at decode")
        if ev.polygon.count >= 3, Geo.pointInRing(own, ev.polygon) { return 0 }
        var best = Geo.nmBetween(ev.point, own)
        for t in ev.track.prefix(EONETEvent.maxTrackPoints) {
            best = min(best, Geo.nmBetween(t, own))
        }
        return best
    }

    /// Shortest signed longitude difference a→b (handles the antimeridian).
    private static func deltaLon(from a: Double, to b: Double) -> Double {
        var d = b - a
        if d > 180 { d -= 360 }
        if d < -180 { d += 360 }
        return d
    }
}
