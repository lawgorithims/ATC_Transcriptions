import Foundation

/// How the ground under a point in the glide footprint relates to the aircraft's energy.
enum LZEnergyClass: String, Sendable, CaseIterable {
    /// Terrain intercepts the glide profile before this range — unreachable, whatever is beyond it.
    case blocked
    /// Reachable, but arriving with little height in hand: no room to inspect, circle or change mind.
    case marginal
    /// Reachable with a workable arrival height.
    case comfortable
    /// Reachable, and arriving with MORE height than can be dissipated on arrival. Not a bonus —
    /// see the note on `excessArrivalFt`.
    case excess

    /// Draw order: worse states on top, so a marginal notch is never hidden by the comfortable
    /// ring it sits inside.
    var drawPriority: Int {
        switch self {
        case .comfortable: return 0
        case .excess:      return 1
        case .marginal:    return 2
        case .blocked:     return 3
        }
    }
}

/// One class's footprint, as annular sectors in map space.
struct LZEnergyBand: Sendable {
    let classification: LZEnergyClass
    /// Closed rings, each a quad spanning one azimuth step and one radial run.
    let rings: [[Coord]]
}

/// The computed field plus the honesty flags the UI has to surface.
struct LZEnergyField: Sendable {
    let bands: [LZEnergyBand]
    let maxRangeNm: Double
    /// False when no winds-aloft column was available — the footprint is then still-air and the
    /// badge must say so rather than implying the wind was accounted for.
    let usedWind: Bool
    /// True when any ray left terrain coverage. Fail-closed: unverified is not the same as clear.
    let sawHole: Bool
    let isDefaultGlideRatio: Bool
}

/// The live half of the LZ layer: where the aircraft can actually GET to, and with how much energy
/// in hand when it arrives.
///
/// WHY THIS IS SEPARATE FROM THE HEATMAP
/// The fact tiles are position-agnostic by construction — they describe ground, not a situation.
/// This engine supplies the other half of the murphy contract: the pilot's CURRENT vector state.
/// Same ground, different altitude, different answer.
///
/// IT REUSES THE NRST SAFETY INVARIANTS RATHER THAN RESTATING THEM
/// Two rules in `NearestAirports.reachability` were established the hard way and are imported here
/// verbatim, not reimplemented:
///
///  1. THE MEASUREMENT BUFFER IS NEVER DISCOUNTED. GPS vertical error and the terrain grid's
///     peak-under-read are both one-sided-optimistic and neither shrinks with distance, so the
///     clearance requirement cannot taper near the aircraft.
///  2. THE OWNSHIP'S OWN CELL IS NOT AN OBSTACLE. The terrain grid is MAX-aggregated, so the cell
///     the aircraft is sitting in routinely reads higher than the aircraft. Treating that as an
///     obstruction blanks the entire field.
///
/// WHY "EXCESS" IS A HAZARD STATE AND NOT A GOOD ONE
/// Arriving over a spot thousands of feet high is not surplus safety — it is a problem to solve
/// under time pressure. The case that motivates it: clearing a ridge with a little to spare, then
/// the ground falls away on the far side. The arrival height above THAT ground spikes, and the
/// aircraft is now committed past the ridge with more energy than it can shed before running out
/// of the terrain it can see. Height you cannot dissipate is height that turns into speed.
enum LZGlideField {

    // MARK: - Constants (bounded loops, rule 2)

    static let azimuthCount = 64                  // 5.625 degrees per ray
    static let stationSpacingNm = 0.5             // matches the NRST sweep's sampling
    static let maxStations = 256                  // hard cap; 128 NM at the spacing above
    static let minRangeNm = 0.5

    /// Arrival height below this is "marginal" — pattern height, with nothing to spare.
    static let marginalArrivalFt = 1000.0
    /// Arrival height above this is "excess". Anchored to what a light single can actually shed:
    /// a full slip or a spiral loses roughly 1500-2000 ft per circuit over the same ground, so
    /// arriving 3000 ft high means committing to at least two turns over terrain chosen from the
    /// air. Ruleset-tunable later; deliberately conservative now.
    static let excessArrivalFt = 3000.0

    /// Wind scaling bounds on the effective glide ratio. A tailwind genuinely extends range and a
    /// headwind genuinely shortens it, but the model is first-order and must not be allowed to
    /// invent an implausible footprint from one bad wind sample.
    static let windRatioMin = 0.55
    static let windRatioMax = 1.80
    static let defaultBestGlideKts = 65.0

    // MARK: - Input

    struct Input: Sendable {
        let coord: Coord
        let altitudeFtMSL: Double
        let glideRatio: Double
        let isDefaultGlideRatio: Bool
        let bestGlideKts: Double
        /// Meteorological direction the wind is FROM, and its speed. Nil = no column available.
        let windFromDeg: Double?
        let windKts: Double?
        let verticalAccuracyM: Double?
    }

    // MARK: - Compute

    /// Sweep the footprint and classify it. Pure: no clocks, no stores, no live state.
    static func compute(_ input: Input, terrain: TerrainSampling) -> LZEnergyField? {
        assert(azimuthCount > 0 && azimuthCount <= 360, "azimuth count out of range")
        assert(stationSpacingNm > 0, "station spacing must be positive")
        guard terrain.isReady else { return nil }
        guard input.glideRatio >= 3, input.glideRatio <= 60 else { return nil }
        guard input.altitudeFtMSL.isFinite else { return nil }

        let buffer = clearanceBufferFt(verticalAccuracyM: input.verticalAccuracyM)
        let ownFloor = terrain.sampleElevationFt(at: input.coord)
        var sawHole = (ownFloor == nil)
        var runsByClass = [LZEnergyClass: [[Coord]]]()
        var maxRange = 0.0

        for a in 0..<azimuthCount {                                   // bounded (rule 2)
            let az = 360.0 * Double(a) / Double(azimuthCount)
            let azNext = 360.0 * Double(a + 1) / Double(azimuthCount)
            let ratio = effectiveGlideRatio(input, azimuthDeg: az)
            let range = stillAirRangeNm(altitudeFtMSL: input.altitudeFtMSL,
                                        groundFt: ownFloor, glideRatio: ratio)
            guard range >= minRangeNm else { continue }
            maxRange = max(maxRange, range)

            let (runs, hole) = classifyRay(input, azimuthDeg: az, rangeNm: range, ratio: ratio,
                                           buffer: buffer, ownFloorFt: ownFloor, terrain: terrain)
            if hole { sawHole = true }
            for run in runs {
                let quad = sector(centre: input.coord, azFrom: az, azTo: azNext,
                                  rFrom: run.from, rTo: run.to)
                runsByClass[run.cls, default: []].append(quad)
            }
        }

        let bands = LZEnergyClass.allCases
            .sorted { $0.drawPriority < $1.drawPriority }
            .compactMap { cls -> LZEnergyBand? in
                guard let rings = runsByClass[cls], !rings.isEmpty else { return nil }
                return LZEnergyBand(classification: cls, rings: rings)
            }
        assert(bands.count <= LZEnergyClass.allCases.count, "one band per class at most")
        return LZEnergyField(bands: bands, maxRangeNm: maxRange,
                             usedWind: input.windKts != nil && input.windFromDeg != nil,
                             sawHole: sawHole,
                             isDefaultGlideRatio: input.isDefaultGlideRatio)
    }

    /// The NRST clearance buffer, verbatim. Never tapered — see the type comment, invariant 1.
    static func clearanceBufferFt(verticalAccuracyM: Double?) -> Double {
        NearestAirports.enrouteBufferFt
            + ((verticalAccuracyM ?? NearestAirports.defaultVerticalAccuracyM)
               + TerrainElevation.peakUnderReadM) * GPSReadout.mToFt
    }

    /// Still-air reach, with the arrival reserve measured AGL rather than MSL.
    ///
    /// `groundFt` is the terrain under the AIRCRAFT, used as the reference surface. Without it the
    /// reserve is silently treated as an MSL altitude, so over ground at 5,000 ft the footprint
    /// stretches to where the aeroplane would be AT ground level — and the whole outer edge then
    /// trips the terrain-interception test and paints as "blocked", as though a ridge ran right
    /// around the glide. The edge of a glide is not an obstruction; it is simply the edge.
    ///
    /// Nil `groundFt` (a data hole under the aircraft) falls back to MSL, which is the conservative
    /// direction: it under-states reach rather than over-stating it.
    ///
    /// A reading AT OR ABOVE the aircraft is also ignored, and that case is not hypothetical: the
    /// terrain grid is MAX-aggregated, so an aeroplane flying near a peak routinely sits "below"
    /// its own cell. Using that as the reference makes the usable height negative and blanks the
    /// entire footprint. The range is only a SWEEP BOUND — the per-station terrain test, with its
    /// buffer and its ownship-cell rule, is what actually decides reachability — so being generous
    /// here costs nothing and refusing to blank the map is worth a great deal.
    static func stillAirRangeNm(altitudeFtMSL: Double, groundFt: Double?,
                                glideRatio: Double) -> Double {
        let usableGround = groundFt.flatMap { $0 < altitudeFtMSL ? $0 : nil } ?? 0
        let usable = altitudeFtMSL - usableGround - NearestAirports.arrivalReserveFt
        guard usable > 0 else { return 0 }
        return usable * glideRatio / NearestAirports.ftPerNm
    }

    /// First-order wind distortion of the footprint: a tailwind buys ground distance per foot lost.
    /// Bounded so one bad sample cannot invent an implausible reach.
    static func effectiveGlideRatio(_ input: Input, azimuthDeg: Double) -> Double {
        guard let from = input.windFromDeg, let kts = input.windKts, kts > 0 else {
            return input.glideRatio
        }
        let vbg = max(20.0, input.bestGlideKts > 0 ? input.bestGlideKts : defaultBestGlideKts)
        // Wind FROM `from` blows TOWARDS from+180. A track along that heading is a tailwind.
        let tail = kts * cos((azimuthDeg - (from + 180.0)) * .pi / 180.0)
        let scale = min(windRatioMax, max(windRatioMin, (vbg + tail) / vbg))
        return input.glideRatio * scale
    }

    // MARK: - One ray

    private struct Run { let cls: LZEnergyClass; let from: Double; let to: Double }

    /// March one azimuth outward, classifying each station and coalescing equal neighbours.
    /// Stops permanently at the first terrain interception — you cannot glide through a ridge, so
    /// everything beyond it is blocked regardless of what the terrain does out there.
    private static func classifyRay(_ input: Input, azimuthDeg: Double, rangeNm: Double,
                                    ratio: Double, buffer: Double, ownFloorFt: Double?,
                                    terrain: TerrainSampling) -> ([Run], Bool) {
        let stations = min(maxStations, max(2, Int(rangeNm / stationSpacingNm) + 1))
        let ftPerNmDown = NearestAirports.ftPerNm / ratio
        var runs = [Run]()
        var current: LZEnergyClass?
        var runStart = 0.0
        var hole = false

        for i in 0...stations {                                        // bounded (rule 2)
            let f = Double(i) / Double(stations)
            let d = f * rangeNm
            let profileFt = input.altitudeFtMSL - d * ftPerNmDown
            let cls: LZEnergyClass
            if let groundFt = terrain.sampleElevationFt(
                at: Geo.destination(from: input.coord, bearingDeg: azimuthDeg, distanceNm: d)) {
                // Invariant 2: within one terrain cell of the aircraft, ground no higher than the
                // ownship's own MAX-aggregated reading is the aircraft's own cell, not an obstacle.
                let ownCell = d < NearestAirports.endpointCellNm
                    && (ownFloorFt.map { groundFt <= $0 } ?? false)
                if !ownCell && groundFt > profileFt - buffer {
                    cls = .blocked
                } else {
                    cls = arrivalClass(arrivalFt: profileFt - groundFt)
                }
            } else {
                hole = true
                cls = .marginal        // unverified is not clear; the badge says coverage was lost
            }

            if cls != current {
                if let c = current, d > runStart { runs.append(Run(cls: c, from: runStart, to: d)) }
                current = cls
                runStart = d
            }
            if cls == .blocked { break }                                // nothing beyond a ridge
        }
        // Close the trailing run. If the class only changed AT the final station, `runStart` equals
        // the range and a naive `rangeNm > runStart` test discards it — which silently deletes the
        // marginal band almost every time, because marginal ground lives at the rim by construction
        // (the footprint edge is exactly where arrival height falls to the reserve). Give the final
        // station the one-station width it actually describes.
        if let c = current {
            let step = rangeNm / Double(stations)
            let from = min(runStart, max(0, rangeNm - step))
            if rangeNm > from { runs.append(Run(cls: c, from: from, to: rangeNm)) }
        }
        return (runs, hole)
    }

    static func arrivalClass(arrivalFt: Double) -> LZEnergyClass {
        if arrivalFt < marginalArrivalFt { return .marginal }
        if arrivalFt > excessArrivalFt { return .excess }
        return .comfortable
    }

    // MARK: - Geometry

    /// One annular sector as a closed ring. Sectors are emitted per azimuth step rather than
    /// contoured: adjacent sectors share their edges exactly, so the bands render seamlessly
    /// without the interpolation artefacts a marching-squares pass would introduce on a polar grid.
    private static func sector(centre: Coord, azFrom: Double, azTo: Double,
                               rFrom: Double, rTo: Double) -> [Coord] {
        let inner = max(0.0, rFrom)
        var ring = [Coord]()
        ring.reserveCapacity(5)
        ring.append(Geo.destination(from: centre, bearingDeg: azFrom, distanceNm: inner))
        ring.append(Geo.destination(from: centre, bearingDeg: azTo, distanceNm: inner))
        ring.append(Geo.destination(from: centre, bearingDeg: azTo, distanceNm: rTo))
        ring.append(Geo.destination(from: centre, bearingDeg: azFrom, distanceNm: rTo))
        ring.append(ring[0])                                            // closed
        assert(ring.count == 5, "a sector is a closed quad")
        return ring
    }
}
