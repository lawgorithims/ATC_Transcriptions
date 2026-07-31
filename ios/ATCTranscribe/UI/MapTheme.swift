import UIKit

/// UIColor-typed per-theme palette for BOTH map engines (MapLibre + the classic MKMapView
/// fallback). A plain value struct: resolved ONCE per theme change and applied by a one-shot
/// idempotent pass — never evaluated per frame (battery rule). Kept separate from
/// DesignSystem.swift (SwiftUI-only) and from the engines themselves (MapLibreChartView
/// diverges on the globe fork branch; a small central surface merges cleanly).
///
/// FAA raster charts are pre-rendered regulatory imagery: cockpit gets only a glare trim,
/// day is identity, and night dims + desaturates (dark adaptation) without recoloring the
/// symbology. Safety marks keep their meaning in every theme — TFR stays the most alarming
/// color on the map, and the ownship integrity ladder is theme-invariant.
struct MapTheme: Equatable {
    let id: AppTheme
    // Base
    let sea: UIColor            // flat-map background
    let globeSea: UIColor       // globe sphere ocean (must read as a planet against space)
    let space: UIColor          // globe void backdrop (StarfieldView)
    let starColor: UIColor      // starfield star tint (red-shifted at night)
    let starAlphaScale: Double  // dims the whole starfield at night
    let land: UIColor
    let coastline: UIColor
    // Vector context
    let airway: UIColor
    let airwayLabelText: UIColor
    let airwayLabelHalo: UIColor
    let navLabelText: UIColor
    let navLabelHalo: UIColor
    /// FAA airspace class tints keyed by the feature's "cls" attribute ("B" is the default).
    let airspace: [String: UIColor]
    let route: UIColor
    let track: UIColor
    let procedure: UIColor      // previewed coded procedure (classic engine's dashed preview line)
    /// Holding-pattern racetrack on the active approach. Part of the procedure, so it tracks the route's
    /// color family rather than the chart furniture.
    let hold: UIColor
    /// Route-waypoint ident text (the `.smartDark` route-fix labels). Night trims label EMISSION only —
    /// the base, terrain and route line are identical in every theme — so the mode keeps the app's
    /// "red-only emission where practical" dark-adaptation stance without changing its look by day.
    let routeWptText: UIColor
    /// Published crossing-restriction sublabels: altitude and speed, colored apart so a glance
    /// separates "how high" from "how fast" (chart convention, and what SmartCharts does).
    let routeWptAlt: UIColor
    let routeWptSpeed: UIColor
    /// Ident tint for the three approach roles worth calling out. Everything else — the intermediate
    /// fix, the final approach COURSE fix, and every enroute leg — keeps `routeWptText`, because they
    /// are read from position on the line and a fourth and fifth colour would only dilute the two that
    /// matter. Published roles exist on approaches only, so on any other route these never apply.
    ///
    /// Hue carries the meaning by day (green: you may begin here / amber: start down / red: decide).
    /// At NIGHT hue is not available — the whole theme is red-preserving for dark adaptation — and
    /// LUMINANCE cannot carry it either: Rec. 709 weights green at 0.72, so the only way to make a red
    /// label measurably brighter is to add green, which is the one thing a dark-adaptation theme must
    /// not do. So night orders the roles by SATURATION instead, the way `nightAirspace` already does
    /// (TFR is the purest red on the night map, not the lightest): green falls monotonically along
    /// unmarked → initial → final → missed, ending at an almost pure red for the decision point.
    let routeWptIAF: UIColor
    let routeWptFAF: UIColor
    let routeWptMAP: UIColor
    // FAA raster paint (identity = 1.0 / 0 / 0)
    let rasterBrightnessMax: Double
    let rasterSaturation: Double
    let rasterContrast: Double
    /// Red world-veil opacity over the chart (night only; 0 disables the layer).
    let nightVeilOpacity: Double

    /// The veil's red — chosen so the dimmed chart reads warm without crushing magenta symbology.
    static let nightVeilColor = rgb(0xFF2E14)

    /// The hold racetrack's long-standing magenta, spelled as component floats (not a hex triple) so
    /// moving it out of `setupDynamicLayers` and into the theme is bit-identical to what shipped.
    /// NOTE: alpha < 1 — apply via `NSExpression(forConstantValue:)`, never `hexString` (which asserts
    /// opacity, since style-JSON colors must be opaque).
    private static let legacyHold = UIColor(red: 0.95, green: 0.24, blue: 0.62, alpha: 0.95)

    /// Class color for a "cls" attribute value, defaulting to Class B chart blue.
    func airspaceColor(_ cls: String) -> UIColor {
        assert(!airspace.isEmpty, "MapTheme.airspace must not be empty")
        return airspace[cls] ?? airspace["B"] ?? .systemBlue
    }

    /// "#RRGGBB" for style-JSON interpolation.
    static func hexString(_ c: UIColor) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        assert(a > 0.99, "style-JSON colors must be opaque")
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }

    private static func rgb(_ hex: UInt, _ alpha: CGFloat = 1) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    /// The FAA chart-convention airspace classes shared by cockpit and day (the classic map's
    /// long-standing colors — pilots pattern-match these against the printed chart).
    private static let chartAirspace: [String: UIColor] = [
        "B": ChartMapView.Coordinator.airspaceColor("B"),
        "C": ChartMapView.Coordinator.airspaceColor("C"),
        "D": ChartMapView.Coordinator.airspaceColor("D"),
        "TFR": ChartMapView.Coordinator.airspaceColor("TFR"),
        "R": ChartMapView.Coordinator.airspaceColor("R"),
        "P": ChartMapView.Coordinator.airspaceColor("P"),
        "W": ChartMapView.Coordinator.airspaceColor("W"),
        "A": ChartMapView.Coordinator.airspaceColor("A"),
        "MOA": ChartMapView.Coordinator.airspaceColor("MOA"),
    ]

    /// Night ramp: warm dim tones for dark adaptation, with the SAFETY-CRITICAL distinctions kept —
    /// TFR is the brightest, most alarming mark on the night map; Prohibited reads as deep danger red.
    private static let nightAirspace: [String: UIColor] = [
        "B": rgb(0x8A4A26), "D": rgb(0x8A4A26), "C": rgb(0xB04058),
        "TFR": rgb(0xFF3B30), "R": rgb(0xD0392A), "P": rgb(0x8F1010),
        "W": rgb(0xC85A30), "A": rgb(0xA0701F), "MOA": rgb(0x7E4A62),
    ]

    /// `chartBrightness` is the pilot's Map-layers slider (0.3…1.0): it scales the theme's FAA-raster
    /// brightness so the night dim / cockpit glare trim are tunable, not hardcoded. Vector overlays
    /// and safety marks are NOT scaled — only the chart imagery.
    static func forTheme(_ t: AppTheme, chartBrightness: Double = 1.0) -> MapTheme {
        assert(chartBrightness > 0, "chart brightness must be positive")
        let scale = min(max(chartBrightness, 0.3), 1.0)
        let base = baseTheme(t)
        if scale >= 1.0 { return base }
        return base.dimmingRasters(by: scale)
    }

    /// THE palette entry point for both engines: the selected base layer can override the app theme.
    /// `.smartDark` is a purpose-built night base, so it ignores cockpit/day and takes only the night
    /// theme's label trim — every other layer resolves the app theme as before.
    static func forLayer(_ layer: ChartLayer, theme: AppTheme, chartBrightness: Double = 1.0) -> MapTheme {
        layer == .smartDark
            ? smartDark(appTheme: theme, chartBrightness: chartBrightness)
            : forTheme(theme, chartBrightness: chartBrightness)
    }

    /// The pilot's chart-brightness slider scales FAA/terrain raster imagery only — vector overlays and
    /// safety marks keep full strength. Field-by-field copy so adding a field can't silently skip it.
    private func dimmingRasters(by scale: Double) -> MapTheme {
        assert(scale > 0 && scale <= 1.0, "raster dim scale out of range")
        return MapTheme(
            id: id, sea: sea, globeSea: globeSea,
            space: space, starColor: starColor, starAlphaScale: starAlphaScale,
            land: land, coastline: coastline,
            airway: airway, airwayLabelText: airwayLabelText, airwayLabelHalo: airwayLabelHalo,
            navLabelText: navLabelText, navLabelHalo: navLabelHalo,
            airspace: airspace, route: route, track: track, procedure: procedure,
            hold: hold, routeWptText: routeWptText, routeWptAlt: routeWptAlt, routeWptSpeed: routeWptSpeed,
            routeWptIAF: routeWptIAF, routeWptFAF: routeWptFAF, routeWptMAP: routeWptMAP,
            rasterBrightnessMax: rasterBrightnessMax * scale,
            rasterSaturation: rasterSaturation, rasterContrast: rasterContrast,
            nightVeilOpacity: nightVeilOpacity)
    }

    /// The decluttered night base (`ChartLayer.smartDark`): near-black ground, dark terrain relief, land
    /// silhouettes, and an AMBER route so the flown path is the brightest thing on the map. Fixed across
    /// cockpit/day — only the night theme trims label emission (see `routeWptText`). Airspace keeps the
    /// chart tints because it is NOT suppressed in this mode (it is a constraint, not furniture) and
    /// because TFR colour is read from this table — a live NOTAM must stay the most alarming mark on
    /// any base.
    static func smartDark(appTheme: AppTheme, chartBrightness: Double = 1.0) -> MapTheme {
        assert(chartBrightness > 0, "chart brightness must be positive")
        let night = (appTheme == .night)
        let base = MapTheme(
            id: appTheme,
            sea: rgb(0x0A0C10), globeSea: rgb(0x0D1420),
            space: rgb(0x020407), starColor: night ? rgb(0xFF6B5A) : .white,
            starAlphaScale: night ? 0.5 : 1.0,
            land: rgb(0x12161C), coastline: rgb(0x2A3340, 0.55),
            // Enroute furniture is suppressed in this mode (see refreshOverlays), so these values only
            // matter if a future toggle brings a layer back — keep them dim rather than absent.
            airway: rgb(0x2A3A4A, 0.6),
            airwayLabelText: rgb(0x9FB0BE), airwayLabelHalo: UIColor.black.withAlphaComponent(0.85),
            navLabelText: night ? rgb(0xF2B0A0) : .white,
            navLabelHalo: UIColor.black.withAlphaComponent(0.85),
            airspace: chartAirspace,
            route: rgb(0xFF9F1C),                       // amber — the flown path owns the map
            track: rgb(0xFF9F1C, 0.45),                 // breadcrumb, deliberately quieter than the route
            procedure: rgb(0x29C7F0),                   // classic engine's dashed preview only
            hold: rgb(0xFF9F1C, 0.95),                  // part of the procedure → route's color family
            routeWptText: night ? rgb(0xF2B0A0) : .white,
            routeWptAlt: night ? rgb(0xC08A94) : rgb(0x4FC3F7),
            routeWptSpeed: night ? rgb(0xC77FB0) : rgb(0xE040FB),
            routeWptIAF: night ? rgb(0xD98A72) : rgb(0x7FE0A0),
            routeWptFAF: night ? rgb(0xFF7040) : rgb(0xFFC24B),
            routeWptMAP: night ? rgb(0xFF3B24) : rgb(0xFF6B6B),
            // The terrain pack ships pre-dimmed, so identity paint — the slider still scales it below.
            rasterBrightnessMax: 1.0, rasterSaturation: 0, rasterContrast: 0,
            nightVeilOpacity: 0)                        // the mode IS the dark adaptation
        let scale = min(max(chartBrightness, 0.3), 1.0)
        return scale >= 1.0 ? base : base.dimmingRasters(by: scale)
    }

    private static func baseTheme(_ t: AppTheme) -> MapTheme {
        switch t {
        case .cockpit:
            return MapTheme(
                id: .cockpit,
                sea: rgb(0x05080C), globeSea: rgb(0x0F3A63),
                space: rgb(0x020407), starColor: .white, starAlphaScale: 1.0,
                land: rgb(0x10161B), coastline: rgb(0x2A3A44, 0.7),
                airway: rgb(0x3D5F80, 0.75),
                airwayLabelText: rgb(0xE6F0F6), airwayLabelHalo: rgb(0x2A3F55, 0.9),
                navLabelText: .white, navLabelHalo: UIColor.black.withAlphaComponent(0.85),
                airspace: chartAirspace,
                route: rgb(0xF23D9E), track: rgb(0xFF9E33, 0.85), procedure: rgb(0x29C7F0),
                hold: legacyHold,
                routeWptText: .white, routeWptAlt: rgb(0x4FC3F7), routeWptSpeed: rgb(0xE040FB),
                routeWptIAF: rgb(0x7FE0A0), routeWptFAF: rgb(0xFFC24B), routeWptMAP: rgb(0xFF6B6B),
                rasterBrightnessMax: 0.95, rasterSaturation: 0, rasterContrast: 0,
                nightVeilOpacity: 0)
        case .day:
            return MapTheme(
                id: .day,
                sea: rgb(0xD7E2EA), globeSea: rgb(0x2E6EA8),
                space: rgb(0x0A1520), starColor: .white, starAlphaScale: 1.0,
                land: rgb(0xEAE6DC), coastline: rgb(0xA9BAC6, 0.9),
                airway: rgb(0x4C74C4, 0.8),
                // Halo scheme swaps in day: dark text needs a LIGHT halo to read over the map.
                airwayLabelText: rgb(0x17242E), airwayLabelHalo: UIColor.white.withAlphaComponent(0.9),
                navLabelText: rgb(0x17242E), navLabelHalo: UIColor.white.withAlphaComponent(0.9),
                airspace: chartAirspace,
                route: rgb(0xF23D9E), track: rgb(0xFF9E33, 0.85), procedure: rgb(0x29C7F0),
                hold: legacyHold,
                routeWptText: rgb(0x17242E), routeWptAlt: rgb(0x0B6C93), routeWptSpeed: rgb(0x8E1FA0),
                routeWptIAF: rgb(0x11703C), routeWptFAF: rgb(0x8A5200), routeWptMAP: rgb(0xB3261E),
                rasterBrightnessMax: 1.0, rasterSaturation: 0, rasterContrast: 0,
                nightVeilOpacity: 0)
        case .night:
            // Red-only emission where practical: dim brick airways, warm labels, dimmed +
            // desaturated chart under a faint red veil. Route stays a bright red-orange so it
            // reads over the dim context; TFR keeps pure alarm red.
            return MapTheme(
                id: .night,
                sea: rgb(0x000000), globeSea: rgb(0x231010),
                space: rgb(0x050202), starColor: rgb(0xFF6B5A), starAlphaScale: 0.5,
                land: rgb(0x0D0505), coastline: rgb(0x331512, 0.7),
                airway: rgb(0x7A2A1E, 0.8),
                airwayLabelText: rgb(0xF0A898), airwayLabelHalo: rgb(0x200A08, 0.9),
                navLabelText: rgb(0xF2B0A0), navLabelHalo: UIColor.black.withAlphaComponent(0.85),
                airspace: nightAirspace,
                route: rgb(0xFF5A3C), track: rgb(0xB0521E, 0.85), procedure: rgb(0xE07A5A),
                hold: legacyHold,
                routeWptText: rgb(0xF2B0A0), routeWptAlt: rgb(0xC08A94), routeWptSpeed: rgb(0xC77FB0),
                routeWptIAF: rgb(0xD98A72), routeWptFAF: rgb(0xFF7040), routeWptMAP: rgb(0xFF3B24),
                rasterBrightnessMax: 0.55, rasterSaturation: -0.65, rasterContrast: 0.10,
                nightVeilOpacity: 0.10)
        }
    }
}
