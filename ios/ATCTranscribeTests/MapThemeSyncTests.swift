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

    /// The night airspace ramp must keep TFR the brightest mark on the map (safety hierarchy).
    func testNightTFRBrightest() {
        let t = MapTheme.forTheme(.night)
        let tfr = rgb(t.airspaceColor("TFR")).reduce(0, +)
        for cls in ["B", "C", "D", "R", "P", "W", "A", "MOA"] {
            let v = rgb(t.airspaceColor(cls)).reduce(0, +)
            XCTAssertLessThan(v, tfr, "night \(cls) must not outshine TFR")
        }
    }
}
