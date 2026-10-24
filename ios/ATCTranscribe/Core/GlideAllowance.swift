import Foundation

/// What a straight-line, still-air glide leaves out — shared by the airport ranking and the glide
/// bands so both apply ONE standard.
///
/// WHY THIS EXISTS. Both reach models were straight lines from the present position. The airport list
/// assumed still air outright ("the app has no offline wind source" — it has had one since the winds
/// aloft layer); the field bands took wind from whatever level the map's wind slider sat on (the
/// surface, by default), never checked its age, and credited a TAILWIND with up to 1.8× the reach.
/// Neither charged anything for turning toward the place it named. The evidence is blunt about which
/// errors matter: in NTSB engine-failure data, stall/spin and uncontrolled impacts are about 11% of
/// accidents but 62% of the fatal ones, and the typical fatal error is stretching a glide. A reach
/// model that flatters is the one direction of error this feature must not have.
enum GlideAllowance {

    /// Height lost per 180° of heading change at best glide, before the glide toward a target starts.
    ///
    /// Derivation for a light single at 30° bank: ~37 s per 360° at 65 kt, with sink up ~25% in the
    /// bank over a ~730 fpm wings-level best-glide sink → ~280 ft per 180°, rounded UP to 300. Linear
    /// in the heading change. A per-aircraft figure can replace it; the default must not flatter.
    static let turnLossFtPer180 = 300.0

    /// Fraction of a forecast TAILWIND credited to reach. ZERO, deliberately: a headwind is charged in
    /// full and a tailwind buys nothing, so reach is never longer than still air. Nothing reachable in
    /// still air is lost, and upwind options shrink the way they really do. A forecast tailwind that
    /// has dropped, veered or was never there is exactly how a stretched glide starts.
    static let tailwindCredit = 0.0

    /// The most a headwind may cut the ratio — one bad wind sample must not erase the map either.
    static let minWindScale = 0.55

    /// A wind run whose valid time is further than this from now is not used at all. GFS runs every
    /// six hours, so beyond that the column describes some other afternoon.
    static let maxWindAgeS: TimeInterval = 6 * 3600

    /// Below this groundspeed the GPS track is not a heading worth charging turns against — taxiing,
    /// a hover, or a fix wandering at rest. Matches the simulator's own course-usable rule.
    static let minTrackSpeedKt = 30.0

    /// Height spent turning from the present track onto `bearingDeg`. Zero without a usable track.
    static func turnLossFt(fromTrackDeg track: Double?, toBearingDeg bearing: Double,
                           perHalfTurnFt: Double = turnLossFtPer180) -> Double {
        guard let t = track, t.isFinite, bearing.isFinite else { return 0 }
        assert(perHalfTurnFt >= 0, "turnLossFt: negative turn allowance")
        var d = abs((bearing - t).truncatingRemainder(dividingBy: 360))
        if d > 180 { d = 360 - d }
        assert(d >= 0 && d <= 180.000_1, "turnLossFt: heading change out of range")
        return perHalfTurnFt * d / 180
    }

    /// The scale on the still-air glide ratio along `bearingDeg`: a headwind shortens it in full, a
    /// tailwind is credited at `tailwindCredit`. With the shipped zero credit it never exceeds 1.
    static func windScale(bearingDeg: Double, windFromDeg: Double?, windKts: Double?,
                          bestGlideKts: Double) -> Double {
        guard let from = windFromDeg, let kts = windKts, kts > 0, from.isFinite, kts.isFinite else {
            return 1
        }
        let vbg = max(20, bestGlideKts)
        // Wind FROM `from` blows TOWARDS from+180; a track along that is a tailwind (positive).
        let tail = kts * cos((bearingDeg - (from + 180)) * .pi / 180)
        let credited = tail >= 0 ? tail * tailwindCredit : tail
        let scale = max(minWindScale, (vbg + credited) / vbg)
        assert(scale > 0, "windScale: non-positive scale")
        return min(1 + tailwindCredit, scale)
    }

    /// A GPS track worth charging turns against, or nil.
    static func usableTrack(trackDeg: Double?, groundSpeedKt: Double?) -> Double? {
        guard let t = trackDeg, t.isFinite, let gs = groundSpeedKt, gs >= minTrackSpeedKt else { return nil }
        return t
    }
}

/// The wind a glide actually meets: the vector mean over the column it descends through.
///
/// A glide spends time at every height between here and the ground — roughly evenly, at a constant
/// sink — so the wind at the aircraft's own level is the wrong input as soon as there is shear. The
/// GFS levels are interpolated by standard-atmosphere height and averaged as VECTORS: averaging
/// speeds and directions separately turns a wind that backs through the column into nonsense.
enum WindProfile {

    /// One level of the column. `fromDeg` is meteorological (the direction it blows FROM).
    struct Level: Equatable, Sendable {
        let altitudeFtMSL: Double
        let fromDeg: Double
        let kts: Double
    }

    static let layerSteps = 12               // samples through the descent (bounded, rule 2)

    /// The mean wind between `topFtMSL` and `bottomFtMSL`, or nil with no levels to draw on.
    static func layerMean(_ levels: [Level], topFtMSL: Double, bottomFtMSL: Double)
        -> (fromDeg: Double, kts: Double)? {
        let col = levels.filter { $0.altitudeFtMSL.isFinite && $0.kts.isFinite && $0.kts >= 0 }
                        .sorted { $0.altitudeFtMSL < $1.altitudeFtMSL }
        guard !col.isEmpty else { return nil }
        let lo = min(topFtMSL, bottomFtMSL), hi = max(topFtMSL, bottomFtMSL)
        var su = 0.0, sv = 0.0
        for i in 0...layerSteps {                                       // bounded (rule 2)
            let h = lo + (hi - lo) * Double(i) / Double(layerSteps)
            let (u, v) = vectorAt(col, h)
            su += u
            sv += v
        }
        let n = Double(layerSteps + 1)
        let u = su / n, v = sv / n
        let kts = (u * u + v * v).squareRoot()
        // (u, v) point where the wind blows TO; it comes FROM the reciprocal.
        let toward = atan2(u, v) * 180 / .pi
        var from = (toward + 180).truncatingRemainder(dividingBy: 360)
        if from < 0 { from += 360 }
        assert(kts >= 0 && from >= 0 && from < 360, "layerMean: wind out of range")
        return (from, kts)
    }

    /// The (east, north) components of the wind blowing TOWARD, interpolated at `h`, clamped to the
    /// end levels outside the column.
    private static func vectorAt(_ col: [Level], _ h: Double) -> (Double, Double) {
        func comps(_ l: Level) -> (Double, Double) {
            let to = (l.fromDeg + 180) * .pi / 180
            return (l.kts * sin(to), l.kts * cos(to))
        }
        guard let first = col.first, let last = col.last else { return (0, 0) }
        if h <= first.altitudeFtMSL { return comps(first) }
        if h >= last.altitudeFtMSL { return comps(last) }
        for (a, b) in zip(col, col.dropFirst()) where h <= b.altitudeFtMSL {   // bounded by col
            let span = b.altitudeFtMSL - a.altitudeFtMSL
            let t = span > 0 ? (h - a.altitudeFtMSL) / span : 0
            let (ua, va) = comps(a), (ub, vb) = comps(b)
            return (ua + (ub - ua) * t, va + (vb - va) * t)
        }
        return comps(last)
    }
}
