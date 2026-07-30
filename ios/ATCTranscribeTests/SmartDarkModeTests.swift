import XCTest
@testable import ATCTranscribe

/// The decluttered night base (`ChartLayer.smartDark`) as a mode: its enum contract, its fixed palette,
/// and the feature-builder filtering that produces the declutter.
final class SmartDarkModeTests: XCTestCase {

    private func rgba(_ c: UIColor) -> [CGFloat] {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        XCTAssertTrue(c.getRed(&r, green: &g, blue: &b, alpha: &a), "color not in RGB space")
        return [r, g, b, a]
    }

    // MARK: the enum

    func testRawValueRoundTrips() {
        XCTAssertEqual(ChartLayer(rawValue: "smartDark"), .smartDark)
        XCTAssertEqual(ChartLayer.smartDark.rawValue, "smartDark")
        XCTAssertTrue(ChartLayer.allCases.contains(.smartDark))
    }

    /// Not an FAA chart: `isRaster` false is what keeps it out of the download pipeline, the chart-
    /// currency pills and the Downloads list. (`ChartStore.setLayer` clears its mounted packs BEFORE
    /// that early-return, so switching in can't leave a sectional drawing over the terrain.)
    func testIsNotARasterChartLayer() {
        XCTAssertFalse(ChartLayer.smartDark.isRaster)
        XCTAssertTrue(ChartLayer.smartDark.entries(nil).isEmpty)
    }

    /// Garmin's "SmartCharts" is their trademark; this mode must never carry it in pilot-visible text.
    func testUINamingCarriesNoTrademark() {
        for s in [ChartLayer.smartDark.title, ChartLayer.smartDark.short] {
            let l = s.lowercased()
            XCTAssertFalse(l.contains("smartchart"), "\(s) must not use Garmin's mark")
            XCTAssertFalse(l.contains("garmin"), "\(s) must not use Garmin's name")
        }
        XCTAssertEqual(ChartLayer.smartDark.short, "Dark")
    }

    // MARK: the palette

    /// The mode is a purpose-built night base, so cockpit and day must resolve IDENTICALLY — the point
    /// of `MapTheme.forLayer` overriding the app theme.
    func testPaletteIsFixedAcrossCockpitAndDay() {
        let cockpit = MapTheme.smartDark(appTheme: .cockpit)
        let day = MapTheme.smartDark(appTheme: .day)
        XCTAssertEqual(rgba(cockpit.sea), rgba(day.sea))
        XCTAssertEqual(rgba(cockpit.land), rgba(day.land))
        XCTAssertEqual(rgba(cockpit.route), rgba(day.route))
        XCTAssertEqual(rgba(cockpit.routeWptText), rgba(day.routeWptText))
    }

    /// Night trims LABEL EMISSION only — the base and the route line are the same in every theme, so the
    /// mode looks like itself by day while still honoring the app's dark-adaptation stance after dark.
    func testNightTrimsLabelsButNotTheBase() {
        let cockpit = MapTheme.smartDark(appTheme: .cockpit)
        let night = MapTheme.smartDark(appTheme: .night)
        XCTAssertEqual(rgba(cockpit.sea), rgba(night.sea), "night must not move the base")
        XCTAssertEqual(rgba(cockpit.route), rgba(night.route), "night must not move the route")
        XCTAssertNotEqual(rgba(cockpit.routeWptText), rgba(night.routeWptText),
                          "night must trim ident emission")
        // Warm-shifted, not merely dimmed: red channel leads.
        let n = rgba(night.routeWptText)
        XCTAssertGreaterThan(n[0], n[2], "night ident text should be red-shifted")
    }

    /// A live NOTAM must stay the most alarming mark on the map whatever the base — the dark mode reads
    /// its TFR color from the same table as every other theme.
    func testTFRStaysAlarmRed() {
        for theme in AppTheme.allCases {
            XCTAssertEqual(rgba(MapTheme.smartDark(appTheme: theme).airspaceColor("TFR")),
                           rgba(ChartMapView.Coordinator.airspaceColor("TFR")),
                           "TFR drifted in smartDark (\(theme.rawValue))")
        }
    }

    /// `forLayer` is THE dispatcher both engines use: smartDark overrides the theme, everything else
    /// resolves it as before.
    func testForLayerDispatch() {
        for theme in AppTheme.allCases {
            XCTAssertEqual(rgba(MapTheme.forLayer(.smartDark, theme: theme).sea),
                           rgba(MapTheme.smartDark(appTheme: theme).sea))
            for other in ChartLayer.allCases where other != .smartDark {
                XCTAssertEqual(rgba(MapTheme.forLayer(other, theme: theme).sea),
                               rgba(MapTheme.forTheme(theme).sea),
                               "\(other.rawValue) must not take the dark palette")
            }
        }
    }

    /// The brightness slider scales raster imagery only — the route and its labels are safety marks and
    /// must stay at full strength however far down the pilot dims the chart.
    func testBrightnessScalesRastersOnly() {
        let full = MapTheme.smartDark(appTheme: .cockpit, chartBrightness: 1.0)
        let dim = MapTheme.smartDark(appTheme: .cockpit, chartBrightness: 0.4)
        XCTAssertLessThan(dim.rasterBrightnessMax, full.rasterBrightnessMax)
        XCTAssertEqual(rgba(dim.route), rgba(full.route))
        XCTAssertEqual(rgba(dim.routeWptAlt), rgba(full.routeWptAlt))
    }

    /// The hold racetrack moved out of a hardcoded literal and into the theme; the three legacy themes
    /// must be BIT-identical to what shipped, or an unrelated palette edit becomes a visual regression.
    func testLegacyHoldColorUnchanged() {
        let shipped = UIColor(red: 0.95, green: 0.24, blue: 0.62, alpha: 0.95)
        for theme in AppTheme.allCases {
            XCTAssertEqual(rgba(MapTheme.forTheme(theme).hold), rgba(shipped),
                           "hold color drifted in \(theme.rawValue)")
        }
        // …and in the dark mode it joins the route's amber family instead.
        let dark = rgba(MapTheme.smartDark(appTheme: .cockpit).hold)
        XCTAssertGreaterThan(dark[0], dark[2], "dark-mode hold should be amber, not magenta")
    }

    /// The hold/track colors are translucent, so they must never reach the style JSON through
    /// `hexString` — which asserts opacity, because style-JSON colors have to be opaque.
    func testStyleJSONColorsAreOpaque() {
        for theme in AppTheme.allCases {
            for layer in ChartLayer.allCases {
                let t = MapTheme.forLayer(layer, theme: theme)
                for c in [t.sea, t.globeSea] {                  // the two colors writeStyle interpolates
                    XCTAssertEqual(rgba(c)[3], 1.0, accuracy: 0.001,
                                   "style-JSON color must be opaque (\(layer.rawValue)/\(theme.rawValue))")
                }
            }
        }
    }
}

#if canImport(MapLibre)
import MapLibre

/// The route-waypoint feature builder — the decluttered base's core new rendering. Pure and static, so
/// it is testable without a live map.
final class SmartDarkRouteWaypointTests: XCTestCase {

    private func leg(_ ident: String, _ lat: Double, _ lon: Double,
                     kind: RouteKind = .waypoint, constraint: LegConstraint? = nil) -> ResolvedLeg {
        ResolvedLeg(ident: ident, kind: kind, coord: Coord(lat: lat, lon: lon), constraint: constraint)
    }

    private func attrs(_ f: MLNPointFeature) -> [String: Any] { f.attributes }

    func testOnePointPerWaypointInOrder() {
        let legs = [leg("BOS", 42.36, -71.01, kind: .airport),
                    leg("GDM", 42.90, -71.38, kind: .vor),
                    leg("HOCUS", 41.50, -72.00)]
        let feats = MapLibreChartView.Coordinator.routeWptFeatures(legs)
        XCTAssertEqual(feats.count, 3)
        XCTAssertEqual(feats.map { $0.attributes["ident"] as? String }, ["BOS", "GDM", "HOCUS"])
    }

    /// Airports keep their real FAA symbol (the "minimal airport data" this mode wants); every other
    /// waypoint gets the white route-fix star, which is legible on a near-black base where the blue fix
    /// triangle is not.
    func testGlyphChoiceByKind() {
        let feats = MapLibreChartView.Coordinator.routeWptFeatures(
            [leg("KBOS", 42.36, -71.01, kind: .airport), leg("HOCUS", 41.5, -72.0)])
        XCTAssertTrue((feats[0].attributes["glyph"] as? String ?? "").hasPrefix("apt-"))
        XCTAssertEqual(feats[1].attributes["glyph"] as? String, "rw-fix")
    }

    /// A procedure turn or a hold revisits the same fix; two identical stacked labels is a rendering bug,
    /// so the same ident at the same place collapses to one symbol.
    func testRevisitedFixCollapses() {
        let feats = MapLibreChartView.Coordinator.routeWptFeatures(
            [leg("HOCUS", 41.5, -72.0), leg("SCUPP", 41.2, -72.4), leg("HOCUS", 41.5, -72.0)])
        XCTAssertEqual(feats.count, 2)
    }

    /// …but two different fixes that share an ident are two real points on the route.
    func testSameIdentAtDifferentPlacesBothSurvive() {
        let feats = MapLibreChartView.Coordinator.routeWptFeatures(
            [leg("DUPE", 41.5, -72.0), leg("DUPE", 38.0, -95.0)])
        XCTAssertEqual(feats.count, 2)
    }

    func testCapIsHonored() {
        let many = (0..<900).map { leg("FIX\($0)", 30.0 + Double($0) * 0.01, -90.0) }
        let feats = MapLibreChartView.Coordinator.routeWptFeatures(many)
        XCTAssertEqual(feats.count, MapLibreChartView.Coordinator.maxRouteWpts)
    }

    func testEmptyRouteYieldsNoFeatures() {
        XCTAssertTrue(MapLibreChartView.Coordinator.routeWptFeatures([]).isEmpty)
    }

    /// Constraint text rides on the feature, and the `stacked` flag is what moves the speed label down
    /// when an altitude occupies the slot above it.
    func testConstraintAttributesAndStacking() {
        let both = LegConstraint(altDesc: "+", alt: "06500", alt2: "",
                                 speedLimitKt: 210, verticalAngleDeg: nil, rnpNm: nil)
        let speedOnly = LegConstraint(altDesc: "", alt: "", alt2: "",
                                      speedLimitKt: 210, verticalAngleDeg: nil, rnpNm: nil)
        let feats = MapLibreChartView.Coordinator.routeWptFeatures(
            [leg("A", 41.0, -72.0, constraint: both),
             leg("B", 41.1, -72.1, constraint: speedOnly),
             leg("C", 41.2, -72.2)])

        XCTAssertEqual(feats[0].attributes["alt"] as? String, "6500A")
        XCTAssertEqual(feats[0].attributes["spd"] as? String, "210K")
        XCTAssertEqual(feats[0].attributes["stacked"] as? Bool, true)

        XCTAssertEqual(feats[1].attributes["alt"] as? String, "")
        XCTAssertEqual(feats[1].attributes["spd"] as? String, "210K")
        XCTAssertEqual(feats[1].attributes["stacked"] as? Bool, false,
                       "a speed-only leg must not leave an empty altitude slot above it")

        // An unconstrained leg carries empty strings, which render nothing — no per-feature filtering.
        XCTAssertEqual(feats[2].attributes["alt"] as? String, "")
        XCTAssertEqual(feats[2].attributes["spd"] as? String, "")
    }

    func testCoordinatesArePreserved() {
        let feats = MapLibreChartView.Coordinator.routeWptFeatures([leg("HOCUS", 41.5, -72.25)])
        XCTAssertEqual(feats[0].coordinate.latitude, 41.5, accuracy: 1e-9)
        XCTAssertEqual(feats[0].coordinate.longitude, -72.25, accuracy: 1e-9)
    }

    /// The three layer ids the visibility switch and `clearManagedStyle` both walk.
    func testRouteWptLayerSetIsStable() {
        XCTAssertEqual(MapLibreChartView.Coordinator.routeWptLayers,
                       ["route-wpt-sym", "route-wpt-alt", "route-wpt-spd"])
    }
}
#endif
