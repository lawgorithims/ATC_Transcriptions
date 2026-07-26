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
    // FAA raster paint (identity = 1.0 / 0 / 0)
    let rasterBrightnessMax: Double
    let rasterSaturation: Double
    let rasterContrast: Double
    /// Red world-veil opacity over the chart (night only; 0 disables the layer).
    let nightVeilOpacity: Double

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

    static func forTheme(_ t: AppTheme) -> MapTheme {
        switch t {
        case .cockpit, .night:
            // Night refinements (dim red ramp, raster dim + veil) land with the night-map pass;
            // until then night deliberately aliases the cockpit map, which is already dark.
            return MapTheme(
                id: t,
                sea: rgb(0x05080C), globeSea: rgb(0x0F3A63),
                land: rgb(0x10161B), coastline: rgb(0x2A3A44, 0.7),
                airway: rgb(0x3D5F80, 0.75),
                airwayLabelText: rgb(0xE6F0F6), airwayLabelHalo: rgb(0x2A3F55, 0.9),
                navLabelText: .white, navLabelHalo: UIColor.black.withAlphaComponent(0.85),
                airspace: chartAirspace,
                route: rgb(0xF23D9E), track: rgb(0xFF9E33, 0.85),
                rasterBrightnessMax: 0.95, rasterSaturation: 0, rasterContrast: 0,
                nightVeilOpacity: 0)
        case .day:
            return MapTheme(
                id: t,
                sea: rgb(0xD7E2EA), globeSea: rgb(0x2E6EA8),
                land: rgb(0xEAE6DC), coastline: rgb(0xA9BAC6, 0.9),
                airway: rgb(0x4C74C4, 0.8),
                // Halo scheme swaps in day: dark text needs a LIGHT halo to read over the map.
                airwayLabelText: rgb(0x17242E), airwayLabelHalo: UIColor.white.withAlphaComponent(0.9),
                navLabelText: rgb(0x17242E), navLabelHalo: UIColor.white.withAlphaComponent(0.9),
                airspace: chartAirspace,
                route: rgb(0xF23D9E), track: rgb(0xFF9E33, 0.85),
                rasterBrightnessMax: 1.0, rasterSaturation: 0, rasterContrast: 0,
                nightVeilOpacity: 0)
        }
    }
}
