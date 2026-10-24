import XCTest
import SwiftUI
@testable import ATCTranscribe

/// Guards the EntityTint (SwiftUI chrome) ↔ MapTheme (map engines) color contract: marks that
/// appear in BOTH worlds must match within 1/255 per channel in every theme, so a palette edit
/// in one file can't silently drift the other.
final class MapThemeSyncTests: XCTestCase {

    private func rgb(_ c: UIColor) -> [CGFloat] {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        XCTAssertTrue(c.getRed(&r, green: &g, blue: &b, alpha: &a), "color not in RGB space")
        return [r, g, b]
    }
    private func rgb(_ c: Color) -> [CGFloat] { rgb(UIColor(c)) }

    private func assertMatch(_ a: [CGFloat], _ b: [CGFloat], _ label: String) {
        XCTAssertEqual(a.count, 3); XCTAssertEqual(b.count, 3)
        for i in 0..<3 {
            XCTAssertEqual(a[i], b[i], accuracy: 1.0 / 255.0, "\(label) channel \(i) drifted")
        }
    }

    /// TFR is drawn by BOTH the SwiftUI chrome (EntityTint) and the map engines (MapTheme) — it must
    /// be the same alarming red in every theme.
    func testTFRMatchesAcrossThemes() {
        for theme in AppTheme.allCases {
            assertMatch(rgb(EntityTint.color(.tfr, theme)),
                        rgb(MapTheme.forTheme(theme).airspaceColor("TFR")),
                        "TFR (\(theme.rawValue))")
        }
    }

    /// Cockpit and day keep the classic engine's FAA airspace class colors — MapTheme delegates to
    /// ChartMapView.Coordinator.airspaceColor, and this pins that contract.
    func testChartAirspaceMatchesClassicEngine() {
        for cls in ["B", "C", "D", "R", "P", "W", "A", "MOA", "TFR"] {
            for theme in [AppTheme.cockpit, .day] {
                assertMatch(rgb(MapTheme.forTheme(theme).airspaceColor(cls)),
                            rgb(ChartMapView.Coordinator.airspaceColor(cls)),
                            "airspace \(cls) (\(theme.rawValue))")
            }
        }
    }

    /// The pilot brightness slider scales ONLY the raster brightness, clamped to the 0.3 floor —
    /// vector/safety colors must be untouched at any setting.
    func testChartBrightnessScalesRasterOnly() {
        for theme in AppTheme.allCases {
            let base = MapTheme.forTheme(theme)
            let dimmed = MapTheme.forTheme(theme, chartBrightness: 0.5)
            XCTAssertEqual(dimmed.rasterBrightnessMax, base.rasterBrightnessMax * 0.5, accuracy: 0.0001)
            XCTAssertEqual(dimmed.route, base.route, "route color must not scale with chart brightness")
            XCTAssertEqual(dimmed.airspaceColor("TFR"), base.airspaceColor("TFR"), "TFR must not scale")
            // Below-floor requests clamp to 0.3, and full brightness is identity.
            XCTAssertEqual(MapTheme.forTheme(theme, chartBrightness: 0.05).rasterBrightnessMax,
                           base.rasterBrightnessMax * 0.3, accuracy: 0.0001)
            XCTAssertEqual(MapTheme.forTheme(theme, chartBrightness: 1.0), base)
        }
    }

    /// The night airspace ramp must keep TFR the brightest mark on the map (safety hierarchy).
    /// The route's out-of-glide band sits UNDER the route line and beside the breadcrumb, on every base
    /// and in every theme. So it must be translucent (the route reads through it), its own colour — never
    /// the route's, the breadcrumb's, TFR red or alert-area amber — and untouched by the chart-brightness slider.
    func testGlideGapBandIsItsOwnTranslucentMark() {
        let themes = AppTheme.allCases.map { ("\($0.rawValue) chart", MapTheme.forTheme($0)) }
            + AppTheme.allCases.map { ("\($0.rawValue) dark base", MapTheme.smartDark(appTheme: $0)) }
        func distance(_ a: [CGFloat], _ b: [CGFloat]) -> CGFloat {
            sqrt(zip(a, b).map { ($0 - $1) * ($0 - $1) }.reduce(0, +))
        }
        for (label, t) in themes {
            let alpha = t.glideGap.cgColor.alpha
            XCTAssertLessThan(alpha, 0.7, "\(label): the band hides the route under it")
            XCTAssertGreaterThan(alpha, 0.2, "\(label): the band is invisible")
            for (name, other) in [("route", t.route), ("breadcrumb", t.track), ("TFR", t.airspaceColor("TFR")),
                                  ("alert area", t.airspaceColor("A"))] {
                XCTAssertGreaterThan(distance(rgb(t.glideGap), rgb(other)), 0.15,
                                     "\(label): the band reads as the \(name)")
            }
        }
        for theme in AppTheme.allCases {
            XCTAssertEqual(MapTheme.forTheme(theme, chartBrightness: 0.5).glideGap,
                           MapTheme.forTheme(theme).glideGap, "the band must not dim with the chart")
        }
    }

    func testNightTFRBrightest() {
        let t = MapTheme.forTheme(.night)
        let tfr = rgb(t.airspaceColor("TFR")).reduce(0, +)
        for cls in ["B", "C", "D", "R", "P", "W", "A", "MOA"] {
            let v = rgb(t.airspaceColor(cls)).reduce(0, +)
            XCTAssertLessThan(v, tfr, "night \(cls) must not outshine TFR")
        }
    }
}
