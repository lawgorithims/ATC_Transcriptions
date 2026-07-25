import Foundation

/// Where a station's weather is GOING, not just where it is.
///
/// A raw METAR tells a pilot the conditions at the field right now. A pilot 45 minutes out needs to
/// know whether the ceiling is coming down and whether the field will still be legal when they get
/// there. This fits a trend across the last several observations and projects it forward.
///
/// Pure value math — observations in, a trend out — so the thresholds are unit-testable and nothing
/// here touches the network. `MetarStore` supplies the history.
enum MetarTrend {

    /// Ceiling above this is effectively unlimited; used so a clear-sky report (no BKN/OVC layer, and
    /// therefore no ceiling at all) still contributes a point to the fit instead of being dropped.
    /// Without it a deck forming over a clear field would show no trend until the deck already existed.
    static let unlimitedCeilingFt = 12_000.0
    /// The API reports "10+" for visibility; treat 10 SM as the top of the scale.
    static let maxVisSm = 10.0

    /// "Significant" deterioration, per the rates a pilot actually reacts to.
    static let significantCeilingFallFtPerHr = 200.0
    static let significantVisFallSmPerHr = 1.0

    /// A minimum span, so two observations minutes apart can't imply a wild hourly rate.
    static let minSpanMinutes = 25.0

    enum Direction: String, Equatable { case improving, steady, deteriorating }

    struct Result: Equatable {
        let ident: String
        let current: Metar.Category
        /// Signed rates. NEGATIVE means getting worse (ceiling coming down / visibility dropping).
        let ceilingRateFtPerHr: Double?
        let visRateSmPerHr: Double?
        let direction: Direction
        /// Category projected forward, nil when there isn't enough history to project.
        let projected1h: Metar.Category?
        let projected2h: Metar.Category?
        /// Deteriorating at or beyond the significant rates — what the chart marker keys on.
        let isSignificant: Bool
        /// How many observations the fit used.
        let sampleCount: Int

        /// True when the projection crosses INTO a worse category within the next two hours.
        var projectsCategoryDrop: Bool {
            guard let p2 = projected2h else { return false }
            let worst = [projected1h, p2].compactMap { $0 }.map(rank).max() ?? rank(current)
            return worst > rank(current)
        }

        /// A short pilot-facing summary, e.g. "Ceiling ↓ 300 ft/hr — IFR within 1 hr".
        var summary: String {
            var parts: [String] = []
            if let c = ceilingRateFtPerHr, abs(c) >= 50 {
                parts.append("Ceiling \(c < 0 ? "↓" : "↑") \(Int(abs(c).rounded())) ft/hr")
            }
            if let v = visRateSmPerHr, abs(v) >= 0.5 {
                parts.append("Vis \(v < 0 ? "↓" : "↑") \(String(format: "%.1f", abs(v))) SM/hr")
            }
            if parts.isEmpty { parts.append(direction == .steady ? "Steady" : direction.rawValue.capitalized) }
            if projectsCategoryDrop, let p = projected1h ?? projected2h, p != current {
                parts.append("\(p.rawValue) within \(projected1h == p ? "1" : "2") hr")
            }
            return parts.joined(separator: " · ")
        }
    }

    private static func rank(_ c: Metar.Category) -> Int {
        switch c { case .vfr: return 0; case .mvfr: return 1; case .ifr: return 2
                   case .lifr: return 3; case .unknown: return -1 }
    }

    /// Fit a trend across a station's recent observations (newest or oldest first — either is fine).
    ///
    /// Uses least squares over time rather than first-vs-last, so one anomalous report doesn't invent
    /// a trend; and the projection is clamped to physically sensible bounds.
    static func analyze(ident: String, observations: [Metar], now: Date = Date()) -> Result? {
        // Keep only observations with a usable timestamp, newest last, bounded.
        let obs = observations
            .filter { ($0.obsEpoch ?? 0) > 0 }
            .sorted { ($0.obsEpoch ?? 0) < ($1.obsEpoch ?? 0) }
            .suffix(6)
        guard let latest = obs.last else { return nil }
        let current = latest.category

        guard obs.count >= 2 else {
            return Result(ident: ident, current: current, ceilingRateFtPerHr: nil, visRateSmPerHr: nil,
                          direction: .steady, projected1h: nil, projected2h: nil,
                          isSignificant: false, sampleCount: obs.count)
        }
        let t0 = Double(obs.first?.obsEpoch ?? 0)
        let spanMin = (Double(latest.obsEpoch ?? 0) - t0) / 60.0
        guard spanMin >= minSpanMinutes else {
            return Result(ident: ident, current: current, ceilingRateFtPerHr: nil, visRateSmPerHr: nil,
                          direction: .steady, projected1h: nil, projected2h: nil,
                          isSignificant: false, sampleCount: obs.count)
        }

        let hours = obs.map { (Double($0.obsEpoch ?? 0) - t0) / 3600.0 }
        let ceils = obs.map { Double($0.ceilingFt ?? Int(unlimitedCeilingFt)) }
        let viss  = obs.map { min($0.visSm ?? maxVisSm, maxVisSm) }

        let ceilRate = slope(x: hours, y: ceils)
        let visRate  = slope(x: hours, y: viss)

        // Project from the LATEST observation, not the fitted line, so the starting point is real.
        let ceilNow = Double(latest.ceilingFt ?? Int(unlimitedCeilingFt))
        let visNow  = min(latest.visSm ?? maxVisSm, maxVisSm)
        func project(_ h: Double) -> Metar.Category {
            let c = max(0, min(unlimitedCeilingFt, ceilNow + (ceilRate ?? 0) * h))
            let v = max(0, min(maxVisSm, visNow + (visRate ?? 0) * h))
            return category(ceilingFt: c, visSm: v)
        }

        let falling = (ceilRate ?? 0) <= -significantCeilingFallFtPerHr
            || (visRate ?? 0) <= -significantVisFallSmPerHr
        let rising = (ceilRate ?? 0) >= significantCeilingFallFtPerHr
            || (visRate ?? 0) >= significantVisFallSmPerHr
        let direction: Direction = falling ? .deteriorating : (rising ? .improving : .steady)

        return Result(ident: ident, current: current,
                      ceilingRateFtPerHr: ceilRate, visRateSmPerHr: visRate,
                      direction: direction,
                      projected1h: project(1), projected2h: project(2),
                      isSignificant: falling, sampleCount: obs.count)
    }

    /// Least-squares slope of y over x. nil when x has no spread (all reports at one instant).
    static func slope(x: [Double], y: [Double]) -> Double? {
        assert(x.count == y.count, "slope: mismatched series")
        let n = Double(x.count)
        guard n >= 2 else { return nil }
        let mx = x.reduce(0, +) / n, my = y.reduce(0, +) / n
        var num = 0.0, den = 0.0
        for i in 0..<x.count {                                   // bounded by the caller's suffix(6)
            let dx = x[i] - mx
            num += dx * (y[i] - my)
            den += dx * dx
        }
        guard den > 1e-9 else { return nil }
        let s = num / den
        return s.isFinite ? s : nil
    }

    /// FAA flight category from a ceiling and visibility. Ceiling in feet AGL, visibility in statute
    /// miles. (LIFR < 500 ft or < 1 SM; IFR < 1,000 ft or < 3 SM; MVFR ≤ 3,000 ft or ≤ 5 SM.)
    static func category(ceilingFt: Double, visSm: Double) -> Metar.Category {
        if ceilingFt < 500 || visSm < 1 { return .lifr }
        if ceilingFt < 1_000 || visSm < 3 { return .ifr }
        if ceilingFt <= 3_000 || visSm <= 5 { return .mvfr }
        return .vfr
    }
}
