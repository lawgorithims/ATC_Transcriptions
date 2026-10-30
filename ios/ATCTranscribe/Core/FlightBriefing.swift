import Foundation

/// The pre-flight briefing: departure first (the engine failure after takeoff), then the route.
///
/// Plain data, built from what the app already holds, every field optional and a missing one left
/// out rather than guessed — `ApproachBrief`'s rules. The one number it must NEVER invent is the
/// turn-back altitude: that is the pilot's own, per aircraft, found with an instructor at a safe
/// height (AC 61-83J, A.11.4: "the expected loss of altitude in a turnback, plus a sufficient safety
/// factor, should be briefed"). This type converts it to what the altimeter will read and puts
/// today's density altitude beside the one it was set in. It never adjusts it.
struct FlightBriefing: Equatable, Sendable {

    struct RunwayWind: Equatable, Sendable {
        let end: String
        let headwindKt: Int        // negative = tailwind
        let crosswindKt: Int       // positive = from the right
    }

    struct Departure: Equatable, Sendable {
        let ident: String
        let fieldElevationFt: Int?
        let windText: String?       // "240° 12 kt G18", "calm", nil = no current weather
        let densityAltitudeFt: Int? // nil = no current weather; never a guess
        let weatherAgeMin: Int?
        let runways: [RunwayWind]   // into-wind first
    }

    enum Turnback: Equatable, Sendable {
        case noAircraft                                  // no saved profile matches the plan's callsign
        case rotorcraft
        case notSet(callsign: String)
        case set(TurnbackPlan)
    }

    struct TurnbackPlan: Equatable, Sendable {
        let aglFt: Int
        let altimeterFt: Int?        // agl + field elevation: what the altimeter reads at the decision
        let setAtDensityAltitudeFt: Int?
        let todayDensityAltitudeFt: Int?
        let practisedOn: Date?
        /// Today is higher than the conditions the number was set in, or the set conditions are
        /// unknown while today is high: the turn loses more height and the climb is slower.
        let densityAltitudeCaution: Bool
        let practiceStale: Bool      // never dated, or more than a year ago
    }

    struct Enroute: Equatable, Sendable {
        let exposedPercent: Int
        let longestGapNm: Int
        let cruiseFt: Int
        let betterAltitudeFt: Int?
    }

    let departure: Departure?
    let turnback: Turnback
    let enroute: Enroute?

    /// Density altitude above which a turn-back deserves a caution even when the pilot never recorded
    /// the conditions they practised in. Not a limit — the point at which the turn's height loss has
    /// grown enough (weight/density) that an unqualified number is misleading.
    static let highDensityAltitudeFt = 5_000
    static let maxWeatherAgeMin = 120

    static func build(departureIdent: String?, airport: AirportData.Airport?, ends: [AirportData.RunwayEnd],
                      metar: Metar?, aircraft: AircraftProfile?, callsign: String?,
                      exposure: RouteGlideExposure.Result?, suggestion: RouteGlideExposure.Result?,
                      now: Date = Date()) -> FlightBriefing {
        let dep = departureIdent.map { departure($0, airport: airport, ends: ends, metar: metar, now: now) }
        let tb = turnback(aircraft: aircraft, callsign: callsign, departure: dep, now: now)
        let en = exposure.map {
            Enroute(exposedPercent: Int(($0.exposedFraction * 100).rounded()),
                    longestGapNm: Int($0.longestGapNm.rounded()), cruiseFt: Int($0.altitudeFtMSL),
                    betterAltitudeFt: suggestion.map { Int($0.altitudeFtMSL) })
        }
        return FlightBriefing(departure: dep, turnback: tb, enroute: en)
    }

    static func departure(_ ident: String, airport: AirportData.Airport?, ends: [AirportData.RunwayEnd],
                          metar: Metar?, now: Date) -> Departure {
        let elev = airport?.elevationFt.map { Int($0.rounded()) }
        let age = metar?.obsEpoch.map { Int((now.timeIntervalSince1970 - Double($0)) / 60) }
        let fresh = metar != nil && (age ?? Int.max) <= maxWeatherAgeMin
        var da: Int?
        if fresh, let e = elev, let hpa = metar?.altimeterHPa, let t = metar?.tempC {
            da = Int(densityAltitudeFt(fieldElevationFt: Double(e), altimeterHPa: hpa, tempC: t).rounded())
        }
        var winds: [RunwayWind] = []
        var windText: String?
        if fresh, let m = metar {
            if let dir = m.windDir, let kt = m.windKt, kt > 0 {
                windText = "\(dir)° \(kt) kt" + (m.gustKt.map { " G\($0)" } ?? "")
                winds = ends.compactMap { e in
                    guard let a = e.trueAlignmentDeg else { return nil }
                    let rel = (Double(dir) - a) * .pi / 180
                    return RunwayWind(end: e.end, headwindKt: Int((Double(kt) * cos(rel)).rounded()),
                                      crosswindKt: Int((Double(kt) * sin(rel)).rounded()))
                }.sorted { $0.headwindKt > $1.headwindKt }
            } else if m.windKt == 0 {
                windText = "calm"
            } else if m.windKt != nil {
                windText = "variable \(m.windKt ?? 0) kt"
            }
        }
        return Departure(ident: ident, fieldElevationFt: elev, windText: windText, densityAltitudeFt: da,
                         weatherAgeMin: fresh ? age : nil, runways: Array(winds.prefix(8)))
    }

    static func turnback(aircraft: AircraftProfile?, callsign: String?, departure: Departure?, now: Date) -> Turnback {
        guard let a = aircraft else { return .noAircraft }
        if a.isRotorcraft == true { return .rotorcraft }
        guard let agl = a.turnbackMinimumFtAGL else { return .notSet(callsign: a.callsign.isEmpty ? (callsign ?? "") : a.callsign) }
        let today = departure?.densityAltitudeFt
        let caution: Bool
        if let t = today, let set = a.turnbackSetAtDensityAltitudeFt { caution = t > set + 500 }
        else if let t = today { caution = t >= highDensityAltitudeFt }
        else { caution = false }
        let stale = a.turnbackSetOn.map { now.timeIntervalSince($0) > 365 * 86_400 } ?? true
        return .set(TurnbackPlan(aglFt: agl, altimeterFt: departure?.fieldElevationFt.map { $0 + agl },
                                 setAtDensityAltitudeFt: a.turnbackSetAtDensityAltitudeFt,
                                 todayDensityAltitudeFt: today, practisedOn: a.turnbackSetOn,
                                 densityAltitudeCaution: caution, practiceStale: stale))
    }

    /// The pilot's rule: pressure altitude from the altimeter setting, then 118.8 ft per °C above the
    /// ISA temperature at that pressure altitude (the same constants as `ClimateMath.densityAltitudeFt`).
    static func densityAltitudeFt(fieldElevationFt: Double, altimeterHPa: Double, tempC: Double) -> Double {
        assert((870...1090).contains(altimeterHPa), "altimeter out of range")
        assert((-60...60).contains(tempC), "temperature out of range")
        let inHg = altimeterHPa / 33.8639
        let pa = fieldElevationFt + (29.92 - inHg) * 1000
        let isa = 15.0 - 0.0019812 * pa
        return pa + 118.8 * (tempC - isa)
    }
}
