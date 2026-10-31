import Foundation

/// How much of a planned route is out of glide of every runway, at the planned altitude — and what
/// altitude would close the worst of it.
///
/// WHY THIS EXISTS. Measured over the Southwest coverage (2026-10): direct KLRU→KTUS at 8,500 ft is
/// out of glide of any runway for 81% of the way, with one gap of 57 minutes; at 10,500 ft that falls
/// to 58% and 20 minutes. Two thousand feet chosen on the ground changes the exposure more than any
/// field picker ever could in the air, and it is decided with time to think: no head-down cost, and
/// the data's local errors average out over a leg instead of deciding a landing.
///
/// ONE REACH MODEL. Each sample along the route is judged by the airport list's own engine
/// (`NearestAirports.assess`) — the same terrain sweep, 1,000 ft arrival reserve, headwind charged
/// and tailwind never credited, and the turn onto each airport charged from the leg's own course
/// (`GlideAllowance`). The plan and the in-flight list cannot disagree about whether a runway is in
/// reach, because they are the same computation.
///
/// LIMITS, said once: runways only — off-field ground is not credited, deliberately; forecast winds
/// at planning time; the route as filed, not as flown; terrain is the same max-aggregated grid the
/// airport list uses.
enum RouteGlideExposure {

    static let sampleSpacingNm = 1.0          // ~30 s of flight; finer measures noise, not exposure
    static let maxSamples = 800               // a hard bound on the walk (rule 2): 800 NM of route
    static let airportsPerSample = 8          // nearest-first fields judged per sample
    static let altitudeStepFt = 1000.0        // keeps a VFR +500 cruise on its hemispheric family
    static let maxSuggestedAltitudeFt = 17_500.0   // below Class A: a suggestion a VFR pilot can fly

    struct Gap: Equatable, Sendable {
        let fromNm: Double
        let toNm: Double
        var lengthNm: Double { toNm - fromNm }
    }

    struct Result: Equatable, Sendable {
        let routeNm: Double
        let altitudeFtMSL: Double
        let exposedFraction: Double
        let gaps: [Gap]
        let usedWind: Bool
        var longestGapNm: Double { gaps.map(\.lengthNm).max() ?? 0 }
        func longestGapMinutes(tasKt: Double?) -> Double? {
            guard let t = tasKt, t > 0 else { return nil }
            return longestGapNm / t * 60
        }
    }

    /// Everything the engine reads from the world — injected, so the engine stays pure and testable.
    struct World {
        let airportsNear: (Coord, Double) -> [AirportData.Airport]
        let runwaysFor: (String) -> [AirportData.Runway]
        let terrain: TerrainSampling
        /// Descent-mean wind for a glide from `fromFtMSL` at the point down to `groundFt`; nil = still air.
        let windAt: (Coord, Double, Double) -> (fromDeg: Double, kts: Double)?
    }

    /// One evaluation at one altitude. Nil for a route with fewer than two points or a dead grid.
    static func evaluate(route: [Coord], altitudeFtMSL: Double, glideRatio: Double,
                         bestGlideKts: Double, acceptsWater: Bool = false, acceptsLand: Bool = true,
                         world: World) -> Result? {
        guard route.count >= 2, world.terrain.isReady, glideRatio > 0 else { return nil }
        let samples = densify(route)
        guard samples.count >= 2 else { return nil }
        var covered = [Bool]()
        covered.reserveCapacity(samples.count)
        var sawWind = false
        for s in samples {                                            // bounded by maxSamples
            let ok = isCovered(s, altitudeFtMSL: altitudeFtMSL, glideRatio: glideRatio,
                               bestGlideKts: bestGlideKts, acceptsWater: acceptsWater,
                               acceptsLand: acceptsLand, world: world, sawWind: &sawWind)
            covered.append(ok)
        }
        let gaps = gapsFrom(samples.map(\.distanceNm), covered)
        let exposed = Double(covered.filter { !$0 }.count) / Double(covered.count)
        assert(exposed >= 0 && exposed <= 1, "evaluate: exposure out of range")
        return Result(routeNm: samples.last?.distanceNm ?? 0, altitudeFtMSL: altitudeFtMSL,
                      exposedFraction: exposed, gaps: gaps, usedWind: sawWind)
    }

    /// The lowest altitude, climbing from `startFtMSL` in `altitudeStepFt` steps up to
    /// `maxSuggestedAltitudeFt`, at which no gap is longer than `maxGapNm` — or nil if none is.
    static func lowestAltitude(closingGapsTo maxGapNm: Double, route: [Coord], startFtMSL: Double,
                               glideRatio: Double, bestGlideKts: Double, acceptsWater: Bool = false,
                               acceptsLand: Bool = true, world: World) -> Result? {
        assert(maxGapNm >= 0, "lowestAltitude: negative gap threshold")
        var alt = startFtMSL
        var steps = 0
        while alt <= maxSuggestedAltitudeFt && steps < 20 {           // bounded (rule 2)
            guard let r = evaluate(route: route, altitudeFtMSL: alt, glideRatio: glideRatio,
                                   bestGlideKts: bestGlideKts, acceptsWater: acceptsWater,
                                   acceptsLand: acceptsLand, world: world) else { return nil }
            if r.longestGapNm <= maxGapNm { return r }
            alt += altitudeStepFt
            steps += 1
        }
        return nil
    }

    // MARK: - internals

    struct Sample { let coord: Coord; let courseDeg: Double; let distanceNm: Double }

    /// The route walked every `sampleSpacingNm`, each sample carrying its leg's course.
    static func densify(_ route: [Coord]) -> [Sample] {
        var out = [Sample]()
        var along = 0.0
        for (a, b) in zip(route, route.dropFirst()) {                 // bounded by the route
            let leg = Geo.nmBetween(a, b)
            guard leg > 0 else { continue }
            let course = Geo.bearing(a, b)
            let n = max(1, Int((leg / sampleSpacingNm).rounded(.up)))
            for i in 0..<n where out.count < maxSamples {             // bounded (rule 2)
                let f = Double(i) / Double(n)
                out.append(Sample(coord: Geo.interpolate(a, b, fraction: f), courseDeg: course,
                                  distanceNm: along + leg * f))
            }
            along += leg
        }
        if let last = route.last, out.count < maxSamples, let prev = out.last {
            out.append(Sample(coord: last, courseDeg: prev.courseDeg, distanceNm: along))
        }
        return out
    }

    private static func isCovered(_ s: Sample, altitudeFtMSL: Double, glideRatio: Double,
                                  bestGlideKts: Double, acceptsWater: Bool, acceptsLand: Bool,
                                  world: World, sawWind: inout Bool) -> Bool {
        // The same surfaces the airport list would offer this aircraft: a seaplane base only counts
        // for something that can alight on water (see `GlideSituation.acceptsWater`).
        var g = GlideSituation(coord: s.coord, altitudeFtMSL: altitudeFtMSL, glideRatio: glideRatio,
                               isDefaultGlideRatio: false, verticalAccuracyM: nil,
                               acceptsWater: acceptsWater, acceptsLand: acceptsLand)
        g.trackDeg = s.courseDeg
        g.bestGlideKts = bestGlideKts
        let groundFt = world.terrain.sampleElevationFt(at: s.coord) ?? 0
        if let w = world.windAt(s.coord, altitudeFtMSL, groundFt) {
            g.windFromDeg = w.fromDeg
            g.windKts = w.kts
            sawWind = true
        }
        let radius = NearestAirports.searchRadiusNm(for: g)
        let near = world.airportsNear(s.coord, radius)
            .sorted { Geo.nmBetween(s.coord, $0.coord) < Geo.nmBetween(s.coord, $1.coord) }
            .prefix(airportsPerSample)
        guard !near.isEmpty else { return false }
        let a = NearestAirports.assess(situation: g, airports: Array(near), runwaysFor: world.runwaysFor,
                                       weather: [:], terrain: world.terrain, now: Date())
        return a.candidates.contains { $0.reachability.isReachable }
    }

    /// Maximal runs of uncovered samples, as distance intervals along the route.
    static func gapsFrom(_ along: [Double], _ covered: [Bool]) -> [Gap] {
        assert(along.count == covered.count, "gapsFrom: mismatched arrays")
        var gaps = [Gap]()
        var start: Double?
        for (d, ok) in zip(along, covered) {                          // bounded by the samples
            if !ok, start == nil { start = d }
            if ok, let s = start { gaps.append(Gap(fromNm: s, toNm: d)); start = nil }
        }
        if let s = start, let end = along.last { gaps.append(Gap(fromNm: s, toNm: end)) }
        return gaps
    }

    // MARK: - drawing

    /// A gap as a polyline along the route it was measured on: the stretch the map draws. The walk
    /// repeats `densify`'s arithmetic (the same `Geo.nmBetween` per leg, the same running sum), so a
    /// drawn gap starts and ends where the samples said it did, and bends at the route's own corners.
    /// Fewer than two points for a zero-length gap: there is nothing to draw.
    static func polyline(of gap: Gap, along route: [Coord]) -> [Coord] {
        assert(gap.toNm >= gap.fromNm, "polyline: inverted gap")
        var out = [Coord]()
        var along = 0.0
        for (a, b) in zip(route, route.dropFirst()) {                 // bounded by the route
            let leg = Geo.nmBetween(a, b)
            let legStart = along
            along += leg
            guard leg > 0, along > gap.fromNm, legStart < gap.toNm else { continue }
            let f0 = max(0, (gap.fromNm - legStart) / leg)
            let f1 = min(1, (gap.toNm - legStart) / leg)
            if out.isEmpty { out.append(Geo.interpolate(a, b, fraction: f0)) }
            out.append(Geo.interpolate(a, b, fraction: f1))
        }
        assert(out.count <= route.count + 1, "polyline: more points than the route has corners")
        return out
    }

    /// Every gap of `result` as a drawable polyline along `route`; zero-length gaps are dropped.
    static func gapLines(_ result: Result?, along route: [Coord]) -> [[Coord]] {
        guard let result else { return [] }
        return result.gaps.map { polyline(of: $0, along: route) }.filter { $0.count >= 2 }
    }
}
