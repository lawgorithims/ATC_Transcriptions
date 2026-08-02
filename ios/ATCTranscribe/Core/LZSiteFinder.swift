import Foundation

/// Finds the best REACHABLE ground to put an aeroplane down on, and measures how much of it there is
/// in a straight line.
///
/// =============================================================================================
/// WHAT THIS MAY CLAIM, AND WHAT IT MAY NOT
/// =============================================================================================
/// This is the most dangerous thing in the whole layer, and the danger is not in the arithmetic —
/// it is that naming a place makes it look surveyed.
///
/// What the data actually supports: "along this bearing, from about here, roughly 600 m of ground
/// reads as non-vetoed cropland at 10 m resolution, and you can reach it from your present height."
/// Every word of that is an INFERENCE from land cover, a reduced 1 m DEM and a modelled hazard
/// field.
///
/// What the data does NOT support, at any resolution it has: that the ground is firm today, that
/// there is no fence across it, no irrigation ditch narrower than a cell, no crop standing four
/// feet high, no wire below the charted-obstacle threshold, no livestock. None of that is modelled
/// and none of it is knowable from here.
///
/// So this type deliberately produces a **candidate area with a measured run**, never a "site" and
/// never a "strip":
///
///   * `Candidate.centre` is a POINT INSIDE an area, not a threshold. There is no start, no end and
///     no centreline, because a centreline is the visual grammar of a runway and would be read as
///     one from six hundred feet in a bad moment.
///   * `runMetres` is reported as "longest run found", with the heading it was found on. It is a
///     measurement of the data, phrased as a measurement.
///   * `unknowns` travels WITH every candidate, so no caller can present the number without the
///     caveat. Anything rendering these must show it.
///
/// If a presentation cannot carry that, the honest fallback is to show the BEARING BAND only — a
/// direction is a much weaker claim than a place, and the weaker claim is the correct one.
///
/// =============================================================================================
/// ON DEMAND, NOT ON A TIMER
/// =============================================================================================
/// A sweep costs a few hundred scored samples plus a directional walk per candidate. The answer
/// changes slowly (it is ground), so this runs when a pilot asks, not every five seconds.
enum LZSiteFinder {

    /// 1 NM in metres. `NearestAirports` publishes feet per NM; this is the metric twin, kept here
    /// rather than duplicated at each call site.
    static let metresPerNm = 1852.0

    /// Bounded work (rule 2). A sweep must never grow with the footprint without limit.
    static let azimuthCount = 36              // 10 deg steps for the coarse scan
    static let maxStations = 240
    static let maxCoarseSamples = 9_000       // hard ceiling on the scan, whatever the geometry
    static let runHeadingCount = 12           // 30 deg steps for the directional run measurement
    static let runStepM = 30.0                // ~3 fact cells; finer than this measures noise
    static let maxRunSteps = 200              // 6 km — beyond any light-aircraft need
    static let maxCandidates = 5
    /// How many times the expensive directional walk may run in one search.
    ///
    /// ⚠️ This is NOT a window over the sorted samples, and it must never become one again. It was,
    /// and the effect was that the list under-delivered in exactly the terrain it should do best in:
    /// the highest-scoring ground is CONTIGUOUS, so the top-scoring samples all sit inside one or
    /// two fields, the separation filter rejects them as duplicates, and the search ran out of
    /// window with most of the footprint never examined. Over southern New Mexico — desert and
    /// cropland, some of the most landable ground in the country — it offered two.
    ///
    /// The separation test is a handful of distance comparisons, so it is cheap enough to apply to
    /// every scored sample; only the walk is metered. That way the cluster is thinned first and the
    /// budget is spent on genuinely distinct ground.
    static let maxRunWalks = 40

    /// Ground this scores below is not worth naming, whatever else is true of it. A candidate the
    /// pilot would reject on sight costs trust in the ones that are good.
    static let minScore = 55

    /// What one candidate is, and what a caller must show alongside it.
    struct Candidate: Equatable {
        /// A point INSIDE the area — deliberately not a threshold or an end.
        let centre: Coord
        /// Bearing and distance from the aircraft, which is how a pilot would fly to it.
        let bearingDeg: Double
        let distanceNm: Double
        /// Longest contiguous run of usable ground found through `centre`, and the heading it lies
        /// on. A measurement, phrased as one — not a runway.
        let runMetres: Double
        let runHeadingDeg: Double
        /// Score of the ground at the centre, 0...100, from the same ruleset the heatmap paints.
        let score: Int
        /// How the arrival would be: reaching it comfortably matters as much as the ground.
        let arrival: LZEnergyClass
        /// Rules that fired on this ground, by name — the same explainability the tap card shows.
        let rules: [LZFiredRule]
        /// Whether any of this candidate sits on 10 m elevation, where the ditch-scale checks did
        /// not run. Surfaced per candidate because it changes what the run measurement is worth.
        let coarseTerrain: Bool

        /// Never optional, never abbreviated, never assembled by the caller. A candidate that is
        /// displayed without this is a candidate presented as a survey.
        var unknowns: String {
            "Inferred from 10 m land cover and terrain — not surveyed. Surface condition, fences, "
            + "ditches, standing crop, wires and livestock are not modelled."
        }
    }

    /// What this aeroplane needs on unprepared ground, in metres — the same figure the shading's
    /// extent cap uses, so the list and the map cannot disagree about what "too short" means.
    static func requiredRunMetres(for aircraft: AircraftProfile?) -> Double {
        let bookFt = max(300.0, min(12_000.0, aircraft?.landingOver50Ft ?? 1600.0))
        return bookFt * 0.3048 * unpreparedFactor
    }

    /// Mirrors `extent_model.unprepared_factor` in the ruleset. Duplicated as a constant rather than
    /// re-read here because this type must stay usable without a compiled ruleset; the two are
    /// pinned equal by a test.
    static let unpreparedFactor = 1.5

    struct Input {
        let coord: Coord
        let altitudeFtMSL: Double
        let headingDeg: Double?
        let windFromDeg: Double?
        let windKts: Double?
        let requiredRunMetres: Double
    }

    /// Scores ground. `LZTileCompositor.sample` in production; a closure so the geometry can be
    /// tested against known surfaces without a pack.
    typealias Sampler = (Coord) -> LZSampleInfo?

    /// Search the reachable footprint for candidate ground.
    ///
    /// Returns at most `maxCandidates`, best first, or an empty array — which is a real answer and
    /// must be shown as one. "Nothing here scores well enough to name" is far more useful than the
    /// least-bad patch of forest dressed up as a find.
    static func find(_ input: Input, field: LZEnergyField, sample: Sampler) -> [Candidate] {
        assert(input.requiredRunMetres > 0, "find: required run must be positive")
        assert(field.maxRangeNm >= 0, "find: negative footprint")
        guard field.maxRangeNm > 0 else { return [] }

        // 1. COARSE SCAN over a polar grid, reusing the footprint's own geometry so a candidate can
        //    never be somewhere the energy engine says is unreachable.
        var scored: [(coord: Coord, info: LZSampleInfo, arrival: LZEnergyClass,
                      bearing: Double, distance: Double)] = []
        // ⚠️ THE SCAN STEP BOUNDS THE SMALLEST FIELD THAT CAN BE FOUND. A fixed 0.25 NM step is
        // 463 m, so a 600 m field — perfectly adequate for a short-landing aeroplane — falls
        // BETWEEN stations and is never sampled at all. The failure is silent and it is worst for
        // exactly the aircraft with the most options.
        //
        // So the step follows the aeroplane: never more than half the run it needs, so no
        // qualifying field can be stepped over. Floored so a very short-landing aeroplane cannot
        // turn this into a raster scan, and the whole sweep is capped besides.
        let stepNm = max(0.05, min(0.25, input.requiredRunMetres / 2.0 / metresPerNm))
        let byRange = Int(field.maxRangeNm / stepNm) + 1
        let byBudget = max(1, maxCoarseSamples / azimuthCount)
        let stations = min(maxStations, min(byRange, byBudget))
        for a in 0..<azimuthCount {                                  // bounded (rule 2)
            let bearing = Double(a) * 360.0 / Double(azimuthCount)
            for s in 1...max(1, stations) {                          // bounded (rule 2)
                let d = Double(s) * stepNm
                guard d <= field.maxRangeNm else { break }
                let here = Geo.point(from: input.coord, bearingDeg: bearing, distanceNm: d)
                guard let arrival = arrivalClass(at: here, field: field), arrival != .blocked else {
                    continue
                }
                guard let info = sample(here), !info.vetoed, info.score >= minScore else { continue }
                scored.append((here, info, arrival, bearing, d))
            }
        }
        guard !scored.isEmpty else { return [] }

        // 2. Take the strongest samples and measure a RUN through each. Sorting first keeps the
        //    expensive directional walk off ground that was never going to be offered.
        scored.sort { rank($0.info.score, $0.arrival) > rank($1.info.score, $1.arrival) }

        var out: [Candidate] = []
        // Every point already measured, accepted or not. Testing separation against ACCEPTED
        // candidates alone is not enough: ground that fails the run test never enters `out`, so a
        // large contiguous patch that is merely too short would be re-measured by every one of its
        // samples and could spend the entire walk budget on one rejected field.
        var probed: [Coord] = []
        var walks = 0
        // Keep candidates apart, but scale the separation to the footprint: a fixed 1 NM radius
        // inside a 2 NM footprint collapses every distinct field into one offer.
        let apartNm = min(1.0, max(0.2, field.maxRangeNm / 5.0))
        // Walks the WHOLE sorted list — its length is already capped by the scan budget, so this is
        // bounded (rule 2) without a second window over it. The two `break`s below are the real
        // limits: enough candidates, or the walk budget spent.
        for cand in scored {                                         // bounded (rule 2)
            guard out.count < maxCandidates, walks < maxRunWalks else { break }
            // Cheap first: five names for one field is not five options, and rejecting a duplicate
            // here costs a few distance comparisons instead of a 12-heading walk.
            if probed.contains(where: { Geo.nmBetween($0, cand.coord) < apartNm }) { continue }

            probed.append(cand.coord)
            walks += 1
            let (runM, runHdg) = longestRun(through: cand.coord,
                                            preferInto: input.windFromDeg,
                                            sample: sample)
            guard runM >= input.requiredRunMetres else { continue }

            out.append(Candidate(centre: cand.coord,
                                 bearingDeg: cand.bearing,
                                 distanceNm: cand.distance,
                                 runMetres: runM,
                                 runHeadingDeg: runHdg,
                                 score: cand.info.score,
                                 arrival: cand.arrival,
                                 rules: cand.info.rules,
                                 coarseTerrain: cand.info.coarseTerrain))
        }
        assert(out.count <= maxCandidates, "find: candidate cap exceeded")
        return out
    }

    /// Longest contiguous run of usable ground through a point, and the heading it lies on.
    ///
    /// Walks BOTH ways from the point so the measurement is of the ground, not of where the walk
    /// happened to start. Headings are tried into wind first, because that is the direction an
    /// aeroplane would actually use and a long run across a 25 kt wind is not the better option.
    static func longestRun(through centre: Coord, preferInto windFromDeg: Double?,
                           sample: Sampler) -> (metres: Double, headingDeg: Double) {
        var best = (metres: 0.0, headingDeg: 0.0)
        for h in 0..<runHeadingCount {                               // bounded (rule 2)
            let heading = Double(h) * 180.0 / Double(runHeadingCount)   // a run is bidirectional
            let forward = walk(from: centre, headingDeg: heading, sample: sample)
            let back = walk(from: centre, headingDeg: heading + 180, sample: sample)
            let total = forward + back
            guard total > 0 else { continue }
            // Wind alignment breaks ties, it does not manufacture length: a run only wins on
            // alignment when it is already at least as long.
            let score = total * (1.0 + 0.15 * alignment(heading, windFromDeg))
            let bestScore = best.metres * (1.0 + 0.15 * alignment(best.headingDeg, windFromDeg))
            if score > bestScore {
                best = (total, intoWindOrientation(heading, windFromDeg))
            }
        }
        return best
    }

    /// How far usable ground continues from a point along a heading, in metres.
    private static func walk(from: Coord, headingDeg: Double, sample: Sampler) -> Double {
        var travelled = 0.0
        for step in 1...maxRunSteps {                                // bounded (rule 2)
            let d = Double(step) * runStepM
            let p = Geo.point(from: from, bearingDeg: headingDeg, distanceNm: d / metresPerNm)
            guard let info = sample(p), !info.vetoed, info.score >= minScore else { break }
            travelled = d
        }
        return travelled
    }

    /// 1 when the heading points into wind, 0 across, -1 downwind.
    static func alignment(_ headingDeg: Double, _ windFromDeg: Double?) -> Double {
        guard let w = windFromDeg else { return 0 }
        return cos((headingDeg - w) * .pi / 180)
    }

    /// A run is a line; landing on it has two directions. Pick the into-wind one.
    static func intoWindOrientation(_ headingDeg: Double, _ windFromDeg: Double?) -> Double {
        guard windFromDeg != nil else { return normalised(headingDeg) }
        let a = normalised(headingDeg), b = normalised(headingDeg + 180)
        return alignment(a, windFromDeg) >= alignment(b, windFromDeg) ? a : b
    }

    static func normalised(_ deg: Double) -> Double {
        var d = deg.truncatingRemainder(dividingBy: 360)
        if d < 0 { d += 360 }
        return d
    }

    /// Ground score and arrival comfort together. Reaching good ground with nothing in hand is not
    /// the same offer as reaching it comfortably, and a ranking that ignores that would send a pilot
    /// to the edge of the footprint.
    private static func rank(_ score: Int, _ arrival: LZEnergyClass) -> Double {
        let arrivalWeight: Double
        switch arrival {
        case .comfortable: arrivalWeight = 1.0
        case .excess:      arrivalWeight = 0.85     // reachable, but you arrive with energy to lose
        case .marginal:    arrivalWeight = 0.6
        case .blocked:     arrivalWeight = 0.0
        }
        return Double(score) * arrivalWeight
    }

    /// Which arrival band a point falls in, from the already-computed footprint.
    private static func arrivalClass(at p: Coord, field: LZEnergyField) -> LZEnergyClass? {
        for band in field.bands {                                    // bounded: 4 classes
            for ring in band.rings where Geo.pointInRing(p, ring) {
                return band.classification
            }
        }
        return nil
    }
}
