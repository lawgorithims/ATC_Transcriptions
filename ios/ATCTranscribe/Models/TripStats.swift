import Foundation

/// The flight-plan bar's ForeFlight-style trip overview: total distance from the resolved route,
/// and — when the selected aircraft has performance numbers — enroute time and fuel. Wind has no
/// on-device data source, so the bar renders "–" for it (exactly what ForeFlight shows without
/// wind data). Pure value math over already-resolved coordinates: no clock, no database, no I/O —
/// callers resolve the route off-main (`ProcedureRoute.resolve`) and format dates at display time.
struct TripStats: Equatable {
    let distanceNM: Double
    let eteMinutes: Int?     // needs cruiseKts
    let fuelGallons: Double? // needs burnGPH (and an ETE)

    /// Hard cap on summed legs (mirrors `ProcedureRoute.maxLegs` — rule 2).
    static let maxLegs = 600

    /// Compute stats for a resolved route. Returns nil when there's no distance to measure
    /// (fewer than two points). Speed/burn are optional planning numbers from the selected
    /// `AircraftProfile`; each stat degrades to nil (rendered "–") when its input is missing.
    static func compute(points: [Coord], cruiseKts: Int?, burnGPH: Double?) -> TripStats? {
        guard points.count >= 2 else { return nil }                       // param check (rule 7)
        var nm = 0.0
        for i in 1..<min(points.count, maxLegs) {                         // bounded (rule 2)
            nm += Geo.nmBetween(points[i - 1], points[i])
        }
        guard nm.isFinite, nm > 0 else { return nil }                     // degenerate route
        var ete: Int?
        if let kts = cruiseKts, kts > 0 { ete = Int((nm / Double(kts) * 60).rounded()) }
        var fuel: Double?
        if let gph = burnGPH, gph > 0, let minutes = ete { fuel = gph * Double(minutes) / 60 }
        return TripStats(distanceNM: nm, eteMinutes: ete, fuelGallons: fuel)
    }

    // MARK: display formatting (pure — dates are passed in, not read from a clock)

    /// "290 nm" (whole numbers below 1000, no decimals — matches ForeFlight's density).
    var distanceText: String { String(format: "%.0f nm", distanceNM) }

    /// "2h07m", or "–" without a cruise speed.
    var eteText: String {
        guard let minutes = eteMinutes, minutes >= 0 else { return "–" }
        return String(format: "%dh%02dm", minutes / 60, minutes % 60)
    }

    /// "60.3 g", or "–" without a burn rate.
    var fuelText: String {
        guard let gallons = fuelGallons, gallons.isFinite else { return "–" }
        return String(format: "%.1f g", gallons)
    }

    /// Shared short-time formatter — `etaText` re-renders every minute (TimelineView), and a
    /// DateFormatter is too expensive to allocate per tick.
    private static let etaFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()

    /// Arrival time if departing at `from`, e.g. "8:34 PM" — or "–" without an ETE.
    func etaText(from: Date) -> String {
        guard let minutes = eteMinutes else { return "–" }
        let eta = from.addingTimeInterval(Double(minutes) * 60)
        return Self.etaFormatter.string(from: eta)
    }
}
