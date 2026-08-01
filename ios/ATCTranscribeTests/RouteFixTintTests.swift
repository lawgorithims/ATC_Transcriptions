import XCTest
@testable import ATCTranscribe

/// Item 19 as specified: the waypoint MARK is coded by which restriction it carries — blue for an
/// altitude, magenta for a speed, a SPLIT star for both. The colours existed only on the sublabels
/// beneath the mark; the mark itself was always the same white star.
final class RouteFixTintTests: XCTestCase {

    private func leg(_ alt: String, _ desc: String = "+", speed: Int? = nil) -> ResolvedLeg {
        ResolvedLeg(ident: "TEST", kind: .waypoint, coord: Coord(lat: 42, lon: -71),
                    constraint: LegConstraint(altDesc: alt.isEmpty ? "" : desc, alt: alt, alt2: "",
                                              speedLimitKt: speed, verticalAngleDeg: nil, rnpNm: nil))
    }

    func testEachRestrictionCombinationGetsItsOwnMark() {
        typealias C = MapLibreChartView.Coordinator
        XCTAssertEqual(C.routeFixTint(leg("05000")), .altitude)
        XCTAssertEqual(C.routeFixTint(leg("", speed: 210)), .speed)
        XCTAssertEqual(C.routeFixTint(leg("05000", speed: 210)), .both)
        XCTAssertEqual(C.routeFixTint(leg("")), .plain)
    }

    func testAnUnrestrictedFixKeepsThePlainStar() {
        // The coding must read as "this one has a restriction" at a glance; tinting everything would
        // make the distinction disappear.
        XCTAssertEqual(MapLibreChartView.Coordinator.routeFixTint(
            ResolvedLeg(ident: "X", kind: .waypoint, coord: Coord(lat: 0, lon: 0))), .plain)
    }

    func testAnUnmodelledQualifierDoesNotClaimAnAltitudeMark() {
        // The mark reads the SAME accessor as the label, so a qualifier the app refuses to interpret
        // yields no label AND no tint — never a mark implying a limit that was not read.
        XCTAssertEqual(MapLibreChartView.Coordinator.routeFixTint(leg("05000", "X")), .plain)
    }

    func testEveryTintHasItsOwnDistinctGlyphNameAndImage() {
        var names = Set<String>()
        for t in NearbyMarkerView.RouteFixTint.allCases {
            names.insert(t.glyphName)
            let img = NearbyMarkerView.routeFixGlyph(t)
            XCTAssertGreaterThan(img.size.width, 0, "\(t) drew nothing")
        }
        XCTAssertEqual(names.count, NearbyMarkerView.RouteFixTint.allCases.count,
                       "two tints share a glyph name — one would overwrite the other")
    }

    func testTheFourMarksAreVisuallyDifferent() {
        // Registered as separate images, so a name collision or a copy-paste would silently give two
        // restrictions the same mark.
        let datas = NearbyMarkerView.RouteFixTint.allCases.compactMap {
            NearbyMarkerView.routeFixGlyph($0).pngData()
        }
        XCTAssertEqual(datas.count, 4)
        XCTAssertEqual(Set(datas).count, 4, "two of the four marks render identically")
    }

    func testTheGlyphNameIsWhatTheFeatureCarries() {
        let feats = MapLibreChartView.Coordinator.routeWptFeatures([leg("05000", speed: 210)])
        XCTAssertEqual(feats.first?.attributes["glyph"] as? String,
                       NearbyMarkerView.RouteFixTint.both.glyphName)
    }
}
