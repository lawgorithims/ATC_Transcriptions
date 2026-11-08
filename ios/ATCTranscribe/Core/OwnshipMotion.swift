import Foundation

/// Dead-reckons the ownship symbol between GPS fixes so it flies instead of hopping.
///
/// # Why the symbol hops without this
///
/// `DeviceLocation` runs a 15 m `distanceFilter` for battery, so CoreLocation delivers a fix every
/// 15 m of travel and not more often. The MapLibre engine then wrote that straight into its shape
/// source — `src.shape = f` — which is a teleport, with no animation of any kind. (The MapKit engine
/// gets away with it because `MKAnnotation.coordinate` is `@objc dynamic` and MapKit glides the view
/// between values; the GPU engine has no equivalent.) On a chart 0.5 NM across, 15 m is a dozen
/// points of screen, so the aeroplane advanced in visible steps several times a second. Reported from
/// the air as "the movement during flight of the plane is jerky".
///
/// # What it does
///
/// Two things, and they are separate. It **extrapolates** the last fix forward along the reported
/// track at the reported ground speed, which is where the aeroplane actually is between deliveries;
/// and it **eases** the drawn position toward that estimate instead of snapping, so a correction when
/// the next fix disagrees is a glide rather than a jump. Smoothing only the second would still step
/// once per fix; doing only the first would trade small regular steps for occasional large ones.
///
/// # ⚠️ THIS DRAWS THE AEROPLANE WHERE THE RECEIVER HAS NOT SAID IT IS
///
/// That is the whole point, and it is also the risk, so the extrapolation is bounded on every side:
///
/// * `maxExtrapolationS` — beyond two seconds of silence it stops projecting and holds the last fix.
///   A vector is only evidence about the near future; a lost signal must not fly the symbol onward
///   across the chart on a stale heading, which is exactly how a pilot ends up following a ghost.
/// * `minSpeedKt` — below taxi speed GPS course is noise (the integrity monitor says the same thing in
///   `courseValidSpeedMps`), and projecting along noise makes a parked aeroplane wander.
/// * Track and speed must both be present. Either missing means there is nothing to project along.
/// * `snapDistanceNm` — a correction larger than a quarter mile is not a correction, it is a different
///   place: a resumed app, a recovered signal, a jump. Easing across it would crawl the symbol over
///   the map for seconds while the pilot watched; it snaps instead.
///
/// Pure and deterministic: `now` is injected, nothing reads the clock, so every branch is testable.
struct OwnshipMotion: Equatable {

    /// How far ahead of the last fix the symbol may be projected.
    static let maxExtrapolationS: TimeInterval = 2.0
    /// Below this the reported track is noise rather than a direction of travel.
    static let minSpeedKt = 15.0
    /// Easing time constant — the drawn position closes this fraction of the remaining gap per second.
    /// 0.6 s reads as "flying" without lagging perceptibly behind a turn.
    static let catchUpS: TimeInterval = 0.6
    /// A correction bigger than this is a reposition, not a refinement, and is taken instantly.
    static let snapDistanceNm = 0.25

    private var fix: Coord?
    private var fixAt: Date = .distantPast
    private var trackDeg: Double?
    private var speedKt: Double?
    private var shown: Coord?
    private var shownAt: Date = .distantPast

    /// The position last handed to the renderer, or nil before the first fix.
    var displayed: Coord? { shown }

    /// Take a new fix. `trackDeg` and `speedKt` should be the values the integrity monitor has already
    /// called usable — passing it unusable ones is how a parked aeroplane starts drifting.
    mutating func ingest(_ coord: Coord, trackDeg: Double?, speedKt: Double?, at now: Date) {
        assert(coord.lat.isFinite && coord.lon.isFinite, "a non-finite fix must not reach the smoother")
        guard coord.lat.isFinite, coord.lon.isFinite else { return }
        fix = coord
        fixAt = now
        self.trackDeg = trackDeg
        self.speedKt = speedKt
    }

    /// Forget everything — a source change, a resumed session, a lost fix. The next ingest starts clean
    /// rather than easing across whatever gap opened while nobody was looking.
    mutating func reset() {
        fix = nil; fixAt = .distantPast; trackDeg = nil; speedKt = nil
        shown = nil; shownAt = .distantPast
    }

    /// Where the aeroplane should be drawn at `now`. Call it at display rate; it is cheap and it
    /// advances its own state, so two calls at the same instant give the same answer.
    mutating func position(at now: Date) -> Coord? {
        guard let fix else { return nil }
        let target = estimate(at: now, from: fix)

        guard let current = shown else {                 // first fix — nothing to ease from
            shown = target; shownAt = now
            return target
        }
        let gap = Geo.nmBetween(current, target)
        if gap >= Self.snapDistanceNm {                  // a different place, not a nudge
            shown = target; shownAt = now
            return target
        }
        let dt = max(now.timeIntervalSince(shownAt), 0)
        shownAt = now
        guard dt > 0, gap > 0 else { return current }
        // Exponential approach: frame-rate independent, so the motion looks the same at 30 and 60 Hz.
        let closed = 1 - exp(-dt / Self.catchUpS)
        assert(closed >= 0 && closed <= 1, "easing fraction out of range")
        let next = Geo.point(from: current, bearingDeg: Geo.bearing(current, target),
                             distanceNm: gap * closed)
        shown = next
        return next
    }

    /// Where the receiver's last fix implies the aeroplane is now. The fix itself whenever there is no
    /// usable vector to project along, or the projection window has run out.
    private func estimate(at now: Date, from fix: Coord) -> Coord {
        guard let trackDeg, let speedKt, speedKt >= Self.minSpeedKt,
              trackDeg.isFinite, speedKt.isFinite else { return fix }
        let age = now.timeIntervalSince(fixAt)
        guard age > 0 else { return fix }
        let seconds = min(age, Self.maxExtrapolationS)
        assert(seconds <= Self.maxExtrapolationS, "projection window exceeded")
        return Geo.point(from: fix, bearingDeg: trackDeg, distanceNm: speedKt * (seconds / 3600))
    }
}
