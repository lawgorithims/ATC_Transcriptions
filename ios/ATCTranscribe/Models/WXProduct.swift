import Foundation

/// One axis of variants for a weather product (altitude, forecast hour, sector, hazard…). `token` is what
/// gets substituted into the URL template; `label` is what the pilot sees on the picker.
struct WXAxis: Equatable {
    let name: String
    let options: [(label: String, token: String)]
    static func == (a: WXAxis, b: WXAxis) -> Bool {
        a.name == b.name && a.options.map(\.token) == b.options.map(\.token)
    }
}

/// A NOAA weather-imagery product for the WX tab: a URL template with optional {A}/{B} axis placeholders
/// (e.g. flight level × forecast hour). Every base URL in the catalog was curl-verified (HTTP 200 image/*)
/// on 2026-07-19 — the AWC/SPC sites were redesigned and most legacy paths are dead, so DO NOT re-derive
/// URLs from old documentation; verify before changing.
struct WXProduct: Identifiable, Equatable {
    let id: String
    let name: String
    let category: WXCategory
    let urlTemplate: String        // may contain {A} and/or {B}
    var axisA: WXAxis? = nil
    var axisB: WXAxis? = nil
    var note: String = ""          // valid-time / coverage caveat shown under the image
    let attribution: String

    /// Resolve the concrete image URL for the selected axis options. Pure; >=2 assertions.
    func url(a: Int = 0, b: Int = 0) -> String {
        var s = urlTemplate
        if let axisA {
            assert(axisA.options.indices.contains(a), "axis A index out of range")
            s = s.replacingOccurrences(of: "{A}", with: axisA.options[max(0, min(a, axisA.options.count - 1))].token)
        }
        if let axisB {
            assert(axisB.options.indices.contains(b), "axis B index out of range")
            s = s.replacingOccurrences(of: "{B}", with: axisB.options[max(0, min(b, axisB.options.count - 1))].token)
        }
        assert(!s.contains("{A}") && !s.contains("{B}"), "unresolved axis placeholder in \(s)")
        return s
    }
}

enum WXCategory: String, CaseIterable, Identifiable {
    case satellite, gfa, progs, convective, precip, winds, icing, turbulence, airmets, pireps
    var id: String { rawValue }
    var title: String {
        switch self {
        case .satellite:  return "Satellite"
        case .gfa:        return "Clouds & weather (GFA)"
        case .progs:      return "Prog charts"
        case .convective: return "Convective"
        case .precip:     return "Precipitation"
        case .winds:      return "Winds aloft"
        case .icing:      return "Icing"
        case .turbulence: return "Turbulence"
        case .airmets:    return "AIRMETs / SIGMETs"
        case .pireps:     return "PIREPs"
        }
    }
    var symbol: String {
        switch self {
        case .satellite:  return "globe.americas.fill"
        case .gfa:        return "cloud.sun.fill"
        case .progs:      return "map"
        case .convective: return "cloud.bolt.fill"
        case .precip:     return "cloud.rain.fill"
        case .winds:      return "wind"
        case .icing:      return "snowflake"
        case .turbulence: return "water.waves"
        case .airmets:    return "exclamationmark.triangle"
        case .pireps:     return "person.wave.2"
        }
    }
}

/// The static product catalog. Grouped accessor for the tab's category list.
enum WXCatalog {
    static func products(in category: WXCategory) -> [WXProduct] { all.filter { $0.category == category } }
    static var categories: [WXCategory] { WXCategory.allCases.filter { !products(in: $0).isEmpty } }

    private static let nesdis = "NOAA/NESDIS STAR (GOES)"
    private static let wpc = "NOAA/NWS Weather Prediction Center"
    private static let spc = "NOAA/NWS Storm Prediction Center"
    private static let awc = "NOAA/NWS Aviation Weather Center"
    private static let ndfd = "NOAA/NWS National Digital Forecast Database"

    static let all: [WXProduct] = satellite + gfa + progs + convective + precip + winds + icing + turbulence + airmets

    private static let gfaRegions = WXAxis(name: "Region", options: [
        ("CONUS", "us"), ("Northeast", "ne"), ("East", "e"), ("Southeast", "se"), ("North Central", "nc"),
        ("Central", "c"), ("South Central", "sc"), ("Northwest", "nw"), ("West", "w"), ("Southwest", "sw")])
    private static let gairmetRegions = WXAxis(name: "Region", options: [
        ("CONUS", "us"), ("Northeast", "ne"), ("Southeast", "se"), ("North Central", "nc"),
        ("South Central", "sc"), ("Northwest", "nw"), ("Southwest", "sw")])
    private static let gairmetHours = WXAxis(name: "Valid", options: [
        ("Now", "00"), ("+3 h", "03"), ("+6 h", "06"), ("+9 h", "09"), ("+12 h", "12")])

    // MARK: GFA — Graphical Forecast for Aviation (official static renders; no 0-hr panel exists)
    private static let gfa: [WXProduct] = [
        WXProduct(id: "gfa-clouds", name: "Cloud forecast (GFA)", category: .gfa,
                  urlTemplate: "https://aviationweather.gov/data/products/gfa/F{B}_gfa_clouds_{A}.png",
                  axisA: gfaRegions,
                  axisB: WXAxis(name: "Forecast", options: [
                    ("+3 h", "03"), ("+6 h", "06"), ("+9 h", "09"), ("+12 h", "12"), ("+15 h", "15"), ("+18 h", "18")]),
                  note: "Cloud coverage, bases and tops. Valid time on the chart.", attribution: awc),
        WXProduct(id: "gfa-sfc", name: "Surface weather forecast (GFA)", category: .gfa,
                  urlTemplate: "https://aviationweather.gov/data/products/gfa/F{B}_gfa_sfc_{A}.png",
                  axisA: gfaRegions,
                  axisB: WXAxis(name: "Forecast", options: [
                    ("+3 h", "03"), ("+6 h", "06"), ("+9 h", "09"), ("+12 h", "12"), ("+15 h", "15"), ("+18 h", "18")]),
                  note: "Surface weather, visibility and obscurations.", attribution: awc),
    ]

    // MARK: Icing / Turbulence (the official rendered charts are the G-AIRMET sheets — the FL-by-FL
    // CIP/FIP/GTG grids only exist as transparent map overlays post-redesign and need basemap compositing)
    private static let icing: [WXProduct] = [
        WXProduct(id: "ice-gairmet", name: "Icing & freezing level (G-AIRMET)", category: .icing,
                  urlTemplate: "https://aviationweather.gov/data/products/gairmet/F{B}_gairmet_zulu-f_{A}.gif",
                  axisA: gairmetRegions, axisB: gairmetHours,
                  note: "G-AIRMET Zulu: forecast icing areas + freezing levels.", attribution: awc),
    ]
    private static let turbulence: [WXProduct] = [
        WXProduct(id: "turb-gairmet", name: "Turbulence & LLWS (G-AIRMET)", category: .turbulence,
                  urlTemplate: "https://aviationweather.gov/data/products/gairmet/F{B}_gairmet_tango_{A}.gif",
                  axisA: gairmetRegions, axisB: gairmetHours,
                  note: "G-AIRMET Tango: turbulence (high/low), low-level wind shear and strong surface winds.",
                  attribution: awc),
    ]

    // MARK: AIRMETs / SIGMETs
    private static let airmets: [WXProduct] = [
        WXProduct(id: "gairmet-sierra", name: "IFR & mountain obscuration (G-AIRMET)", category: .airmets,
                  urlTemplate: "https://aviationweather.gov/data/products/gairmet/F{B}_gairmet_sierra_{A}.gif",
                  axisA: gairmetRegions, axisB: gairmetHours,
                  note: "G-AIRMET Sierra: IFR conditions + mountain obscuration.", attribution: awc),
        WXProduct(id: "sigmet-all", name: "Active SIGMETs (US)", category: .airmets,
                  urlTemplate: "https://aviationweather.gov/data/products/sigmet/sigmet_all.gif",
                  note: "All active SIGMETs; refreshed every few minutes.", attribution: awc),
    ]

    // MARK: Satellite (stable "latest" URLs, ~5 min refresh; timestamp burned into the image banner)
    private static let satellite: [WXProduct] = [
        WXProduct(id: "sat-geocolor", name: "GOES-East — Color (CONUS)", category: .satellite,
                  urlTemplate: "https://cdn.star.nesdis.noaa.gov/GOES19/ABI/CONUS/GEOCOLOR/1250x750.jpg",
                  note: "True color by day, multispectral IR at night. Updates ~every 5 min.", attribution: nesdis),
        WXProduct(id: "sat-ir", name: "GOES-East — Infrared clouds (CONUS)", category: .satellite,
                  urlTemplate: "https://cdn.star.nesdis.noaa.gov/GOES19/ABI/CONUS/13/1250x750.jpg",
                  note: "Clean IR (Band 13): cloud tops day + night, colder = higher.", attribution: nesdis),
        WXProduct(id: "sat-wv", name: "GOES-East — Water vapor (CONUS)", category: .satellite,
                  urlTemplate: "https://cdn.star.nesdis.noaa.gov/GOES19/ABI/CONUS/{A}/1250x750.jpg",
                  axisA: WXAxis(name: "Layer", options: [("Upper", "08"), ("Mid", "09"), ("Low", "10")]),
                  note: "Moisture channels — the classic jet-stream view.", attribution: nesdis),
        WXProduct(id: "sat-sector", name: "GOES-East — Regional sector", category: .satellite,
                  urlTemplate: "https://cdn.star.nesdis.noaa.gov/GOES19/ABI/SECTOR/{A}/GEOCOLOR/1200x1200.jpg",
                  axisA: WXAxis(name: "Sector", options: [
                    ("Northeast", "ne"), ("Southeast", "se"), ("Great Lakes", "cgl"), ("Upper Miss.", "umv"),
                    ("So. Miss. Valley", "smv"), ("So. Plains", "sp"), ("No. Rockies", "nr"), ("So. Rockies", "sr"),
                    ("Pacific NW", "pnw"), ("Pacific SW", "psw")]),
                  note: "Regional close-up, color.", attribution: nesdis),
        WXProduct(id: "sat-fd", name: "GOES-East — Full disk", category: .satellite,
                  urlTemplate: "https://cdn.star.nesdis.noaa.gov/GOES19/ABI/FD/GEOCOLOR/1808x1808.jpg",
                  note: "Whole hemisphere, updates ~every 10 min.", attribution: nesdis),
        WXProduct(id: "sat-west", name: "GOES-West — Color (CONUS)", category: .satellite,
                  urlTemplate: "https://cdn.star.nesdis.noaa.gov/GOES18/ABI/CONUS/GEOCOLOR/1250x750.jpg",
                  note: "Better West-Coast / Pacific coverage.", attribution: nesdis),
    ]

    // MARK: Prog charts (WPC — issuance ~twice daily; valid time printed on each chart)
    private static let progs: [WXProduct] = [
        WXProduct(id: "prog-sfc", name: "Surface analysis (CONUS)", category: .progs,
                  urlTemplate: "https://www.wpc.ncep.noaa.gov/sfc/namussfcwbg.gif",
                  note: "Fronts + pressure systems, analyzed every 3 h.", attribution: wpc),
        WXProduct(id: "prog-fcst", name: "Surface prog — fronts & pressure", category: .progs,
                  urlTemplate: "https://www.wpc.ncep.noaa.gov/basicwx/{A}fndfd.gif",
                  axisA: WXAxis(name: "Forecast", options: [
                    ("+6 h", "91"), ("+12 h", "92"), ("+18 h", "93"), ("+24 h", "94"),
                    ("+30 h", "95"), ("+36 h", "96"), ("+48 h", "98"), ("+60 h", "99")]),
                  note: "Forecast fronts, pressure and weather. Valid time on the chart.", attribution: wpc),
    ]

    // MARK: Convective (SPC — PNG only since the redesign; the .gif paths are dead or stale)
    private static let convective: [WXProduct] = [
        WXProduct(id: "conv-tcf", name: "Convective forecast — 4/6/8 hr (TCF)", category: .convective,
                  urlTemplate: "https://aviationweather.gov/data/products/tcf/F{A}_tcf.gif",
                  axisA: WXAxis(name: "Forecast", options: [
                    ("+4 h", "04"), ("+6 h", "06"), ("+8 h", "08"), ("+10 h", "10"), ("+12 h", "12")]),
                  note: "Traffic-flow convective forecast: coverage, tops and movement. Issued ~every 2 h.",
                  attribution: awc),
        WXProduct(id: "conv-day1", name: "Convective outlook — Day 1", category: .convective,
                  urlTemplate: "https://www.spc.noaa.gov/products/outlook/day1otlk.png",
                  note: "Categorical severe risk covering the next ~4–24 h.", attribution: spc),
        WXProduct(id: "conv-day2", name: "Convective outlook — Day 2", category: .convective,
                  urlTemplate: "https://www.spc.noaa.gov/products/outlook/day2otlk.png",
                  note: "Categorical severe risk ~10–30 h out (tomorrow 12Z–12Z).", attribution: spc),
        WXProduct(id: "conv-day3", name: "Convective outlook — Day 3", category: .convective,
                  urlTemplate: "https://www.spc.noaa.gov/products/outlook/day3otlk.png",
                  note: "Categorical severe risk two days out.", attribution: spc),
        WXProduct(id: "conv-prob1", name: "Severe probability — Day 1", category: .convective,
                  urlTemplate: "https://www.spc.noaa.gov/products/outlook/day1probotlk_{A}.png",
                  axisA: WXAxis(name: "Hazard", options: [("Tornado", "torn"), ("Wind", "wind"), ("Hail", "hail")]),
                  note: "Probabilistic outlook per hazard.", attribution: spc),
        WXProduct(id: "conv-prob2", name: "Severe probability — Day 2", category: .convective,
                  urlTemplate: "https://www.spc.noaa.gov/products/outlook/day2probotlk_{A}.png",
                  axisA: WXAxis(name: "Hazard", options: [("Tornado", "torn"), ("Wind", "wind"), ("Hail", "hail")]),
                  note: "Probabilistic outlook per hazard.", attribution: spc),
    ]

    // MARK: Precipitation (NDFD 12-h PoP is the probability product; WPC QPF is amount)
    private static let precip: [WXProduct] = [
        WXProduct(id: "pop12", name: "Probability of precip — 12 hr", category: .precip,
                  urlTemplate: "https://graphical.weather.gov/images/conus/PoP12{A}_conus.png",
                  axisA: WXAxis(name: "Period", options: [
                    ("1st 12 hr", "1"), ("2nd 12 hr", "2"), ("3rd 12 hr", "3"), ("4th 12 hr", "4"),
                    ("5th 12 hr", "5"), ("6th 12 hr", "6")]),
                  note: "12-hour PoP periods; the valid window is printed in the image header.", attribution: ndfd),
        WXProduct(id: "qpf6", name: "Precip amount (QPF) — 6 hr windows", category: .precip,
                  urlTemplate: "https://www.wpc.ncep.noaa.gov/qpf/fill_{A}ewbg.gif",
                  axisA: WXAxis(name: "Window", options: [
                    ("0–6 h", "91"), ("6–12 h", "92"), ("12–18 h", "93"), ("18–24 h", "9e"), ("24–30 h", "9f")]),
                  note: "Forecast precipitation amount per 6-h window (NDFD has no 6-h probability graphic).",
                  attribution: wpc),
        WXProduct(id: "qpf-day", name: "Precip amount (QPF) — daily", category: .precip,
                  urlTemplate: "https://www.wpc.ncep.noaa.gov/qpf/fill_{A}wbg.gif",
                  axisA: WXAxis(name: "Day", options: [("Day 1", "94q"), ("Day 2", "98q"), ("Day 3", "99q")]),
                  note: "24-hour accumulations.", attribution: wpc),
    ]

    // MARK: Winds aloft (the WAFS fax charts are the all-altitudes graphical winds/temps product)
    private static let winds: [WXProduct] = [
        WXProduct(id: "winds-wafs", name: "Winds & temps aloft — forecast", category: .winds,
                  urlTemplate: "https://aviationweather.gov/data/products/fax/F{B}_wind_{A}_a.gif",
                  axisA: WXAxis(name: "Level", options: [
                    ("FL050", "050"), ("FL100", "100"), ("FL180", "180"), ("FL240", "240"), ("FL300", "300"),
                    ("FL340", "340"), ("FL390", "390"), ("FL450", "450"), ("FL630", "630")]),
                  axisB: WXAxis(name: "Forecast", options: [
                    ("+6 h", "06"), ("+12 h", "12"), ("+18 h", "18"), ("+24 h", "24"), ("+30 h", "30"), ("+36 h", "36")]),
                  note: "WAFS wind barbs + temps for the Americas; valid time on the chart. New cycle ~every 6 h.",
                  attribution: awc),
        WXProduct(id: "winds-now", name: "Winds aloft — current analysis", category: .winds,
                  urlTemplate: "https://www.spc.noaa.gov/exper/mesoanalysis/s19/{A}mb/{A}mb.gif",
                  axisA: WXAxis(name: "Level", options: [
                    ("925 mb · 2,500 ft", "925"), ("850 mb · 5,000 ft", "850"), ("700 mb · 10,000 ft", "700"),
                    ("500 mb · FL180", "500"), ("300 mb · FL300", "300")]),
                  note: "Hourly CONUS analysis: heights, temps and wind barbs (hatched ≥ 40 kt).", attribution: spc),
    ]
}
