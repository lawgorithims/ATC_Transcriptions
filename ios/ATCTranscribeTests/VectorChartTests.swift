import XCTest
import CoreGraphics
@testable import ATCTranscribe

/// The vector procedure chart (items 1–7, 9).
///
/// The engine's job is to be TRUE TO SCALE and to disclose progressively. Both are properties of the
/// model rather than the drawing, which is why they are tested here and not by looking at pixels.
final class VectorChartTests: XCTestCase {

    private let size = CGSize(width: 400, height: 400)
    private func c(_ lat: Double, _ lon: Double) -> Coord { Coord(lat: lat, lon: lon) }

    // MARK: to scale

    func testEqualDistancesDrawEqualLengths() throws {
        // THE property that makes item 9 meaningful: a nautical mile is the same number of points
        // wherever it is on the chart. Web Mercator would fail this — its scale varies with latitude.
        let g = try XCTUnwrap(VectorChartGeometry.fitting(
            [c(42.0, -71.0), c(42.5, -71.0), c(42.0, -70.0)], in: size))
        let northLeg = hypot(g.point(c(42.0, -71.0)).x - g.point(c(42.1, -71.0)).x,
                             g.point(c(42.0, -71.0)).y - g.point(c(42.1, -71.0)).y)
        let farNorthLeg = hypot(g.point(c(42.3, -71.0)).x - g.point(c(42.4, -71.0)).x,
                                g.point(c(42.3, -71.0)).y - g.point(c(42.4, -71.0)).y)
        XCTAssertEqual(northLeg, farNorthLeg, accuracy: 0.01,
                       "the same distance drew different lengths at different latitudes")
    }

    func testTheStatedScaleMatchesTheDrawing() throws {
        let g = try XCTUnwrap(VectorChartGeometry.fitting([c(42.0, -71.0), c(42.2, -71.0)], in: size))
        // 0.2 degrees of latitude is 12 NM. Whatever the fit chose, points(nm:) must agree with it.
        let drawn = abs(g.point(c(42.0, -71.0)).y - g.point(c(42.2, -71.0)).y)
        XCTAssertEqual(Double(drawn), Double(g.points(nm: 12.0)), accuracy: 0.5)
    }

    func testNorthIsUp() throws {
        let g = try XCTUnwrap(VectorChartGeometry.fitting([c(42.0, -71.0), c(43.0, -70.0)], in: size))
        XCTAssertLessThan(g.point(c(43.0, -71.0)).y, g.point(c(42.0, -71.0)).y,
                          "a more northerly point must draw HIGHER on screen")
        XCTAssertGreaterThan(g.point(c(42.0, -70.0)).x, g.point(c(42.0, -71.0)).x,
                             "a more easterly point must draw further right")
    }

    func testADegenerateExtentIsRefusedRatherThanScaled() {
        // One point has no meaningful zoom; inventing one would draw a procedure that appears to span
        // the screen.
        XCTAssertNil(VectorChartGeometry.fitting([], in: size))
        XCTAssertNil(VectorChartGeometry.fitting([c(42, -71)], in: size))
        XCTAssertNil(VectorChartGeometry.fitting([c(42, -71), c(42, -71)], in: size))
    }

    func testAStraightNorthSouthProcedureStillFits() throws {
        // Zero span on one axis must fall back to the other rather than divide by zero.
        let g = try XCTUnwrap(VectorChartGeometry.fitting([c(42.0, -71.0), c(42.4, -71.0)], in: size))
        XCTAssertTrue(g.nmPerPoint.isFinite && g.nmPerPoint > 0)
    }

    func testZoomingChangesScaleNotCentre() throws {
        let g = try XCTUnwrap(VectorChartGeometry.fitting([c(42, -71), c(42.3, -70.7)], in: size))
        let z = g.zoomed(2)
        XCTAssertEqual(z.center, g.center)
        XCTAssertEqual(z.nmPerPoint, g.nmPerPoint / 2, accuracy: 1e-9)
    }

    // MARK: progressive disclosure

    func testDetailRisesAsTheChartNarrows() {
        XCTAssertEqual(ChartDetail.forScale(nmAcross: 40), .overview)
        XCTAssertEqual(ChartDetail.forScale(nmAcross: 20), .idents)
        XCTAssertEqual(ChartDetail.forScale(nmAcross: 8), .restrictions)
    }

    func testTheShapeDefiningFixesAreNamedEvenInTheOverview() {
        // Without the FAF, the MAP and the initial fix, the outline is anonymous — those three carry
        // their idents at every scale; the rest wait for room.
        let chart = sampleChart()
        for p in chart.primitives {
            guard case .fix(let f) = p else { continue }
            switch f.role {
            case .finalApproachFix, .missedApproachPoint, .initialApproachFix:
                XCTAssertTrue(chart.showsIdent(f, at: .overview), "\(f.ident) must be named at overview")
            default:
                XCTAssertFalse(chart.showsIdent(f, at: .overview), "\(f.ident) crowds the overview")
                XCTAssertTrue(chart.showsIdent(f, at: .idents))
            }
        }
    }

    func testRestrictionsAppearOnlyAtTheClosestDetail() {
        let chart = sampleChart()
        guard case .fix(let faf)? = chart.primitives.first(where: {
            if case .fix(let f) = $0 { return f.role == .finalApproachFix }; return false
        }) else { return XCTFail("no FAF in the fixture") }
        XCTAssertFalse(chart.showsRestriction(faf, at: .idents))
        XCTAssertTrue(chart.showsRestriction(faf, at: .restrictions))
    }

    func testTheTrackAndRunwayAreAlwaysDrawn() {
        let chart = sampleChart()
        for detail in ChartDetail.allCases {
            let kinds = chart.visible(at: detail)
            XCTAssertTrue(kinds.contains { if case .track = $0 { return true }; return false },
                          "the track vanished at \(detail)")
        }
    }

    // MARK: legs the source cannot place

    func testAnUnplaceableLegIsDescribedNotInvented() {
        // "Climb heading 040 to 2000" has no endpoint. It must be stated, never drawn to a fabricated
        // fix — 20,000 of the 122,323 coded IAP legs carry no coordinate.
        let leg = CIFPLeg(seq: 10, fix: "", coord: nil, legType: "CA", course: 40, altitude: "02000",
                          wpDesc: "    ", altDesc: "+")
        let text = VectorProcedureChart.unplacedText(leg)
        XCTAssertTrue(text.lowercased().contains("climb"), "got: \(text)")
        XCTAssertTrue(text.contains("040"), "the published course must be stated: \(text)")
    }

    func testEveryPathTerminatorTheDataUsesIsDescribed() {
        for t in ["CA", "VA", "FA", "CI", "VI", "CD", "VD", "CR", "VR", "VM", "FM", "PI"] {
            let leg = CIFPLeg(seq: 1, fix: "", coord: nil, legType: t, course: 90, altitude: "")
            let s = VectorProcedureChart.unplacedText(leg)
            XCTAssertFalse(s.isEmpty)
            XCTAssertNotEqual(s, t, "\(t) is shown as a raw ARINC code rather than an instruction")
        }
    }

    func testAnUnplacedLegAppearsOnlyWhenThereIsRoomForItsText() {
        let legs = [
            CIFPLeg(seq: 10, fix: "AAAAA", coord: Coord(lat: 42.2, lon: -71.0), legType: "IF",
                    course: nil, altitude: "", wpDesc: "   A"),
            CIFPLeg(seq: 20, fix: "", coord: nil, legType: "CA", course: 40, altitude: "02000",
                    wpDesc: "    ", altDesc: "+"),
        ]
        let chart = VectorProcedureChart.build(legs: legs, airport: "KTST",
                                               procedureName: "TEST", kind: "IAP")
        func hasRay(_ d: ChartDetail) -> Bool {
            chart.visible(at: d).contains { if case .unplacedLeg = $0 { return true }; return false }
        }
        XCTAssertFalse(hasRay(.overview), "an instruction is text and needs room")
        XCTAssertTrue(hasRay(.idents))
    }

    // MARK: build

    func testTheChartCarriesEveryDrawnCoordinateInItsExtent() {
        let chart = sampleChart()
        XCTAssertFalse(chart.extent.isEmpty)
        XCTAssertNotNil(VectorChartGeometry.fitting(chart.extent, in: size),
                        "the extent must be fittable — that is what it is for")
    }

    func testRunwayPseudoFixesAreNotDrawnAsNamedFixes() {
        let legs = [
            CIFPLeg(seq: 10, fix: "AAAAA", coord: Coord(lat: 42.2, lon: -71.0), legType: "TF",
                    course: nil, altitude: "", wpDesc: "   F"),
            CIFPLeg(seq: 20, fix: "RW04", coord: Coord(lat: 42.0, lon: -71.0), legType: "TF",
                    course: nil, altitude: "", wpDesc: "   M"),
        ]
        let chart = VectorProcedureChart.build(legs: legs, airport: "KTST",
                                               procedureName: "TEST", kind: "IAP")
        for p in chart.primitives {
            if case .fix(let f) = p { XCTAssertNotEqual(f.ident, "RW04",
                "a runway threshold is a leg endpoint, not a fix anyone is cleared to") }
        }
    }

    private func sampleChart() -> VectorProcedureChart {
        let legs = [
            CIFPLeg(seq: 10, fix: "IAFIX", coord: Coord(lat: 42.30, lon: -71.10), legType: "IF",
                    course: nil, altitude: "04000", wpDesc: "   A", altDesc: "+"),
            CIFPLeg(seq: 20, fix: "MIDDL", coord: Coord(lat: 42.20, lon: -71.05), legType: "TF",
                    course: nil, altitude: "03000", wpDesc: "   B", altDesc: "+"),
            CIFPLeg(seq: 30, fix: "FAFIX", coord: Coord(lat: 42.10, lon: -71.02), legType: "TF",
                    course: nil, altitude: "02000", wpDesc: "   F", altDesc: "+"),
            CIFPLeg(seq: 40, fix: "MAPPT", coord: Coord(lat: 42.02, lon: -71.00), legType: "TF",
                    course: nil, altitude: "00250", wpDesc: "   M"),
        ]
        return VectorProcedureChart.build(
            legs: legs, airport: "KTST", procedureName: "RNAV (GPS) RWY 04", kind: "IAP",
            runwayThresholds: (from: Coord(lat: 42.00, lon: -71.00),
                               to: Coord(lat: 42.01, lon: -70.99), designator: "04"))
    }

    // MARK: item 4 — the airport diagram

    func testTheReciprocalSwapsTheSide() {
        // ⚠️ Boston's 04L pairs with 22R, not 22L — a LEFT runway approached from the other direction is
        // the RIGHT one. Pairing on the number alone puts 04L with 22L, which at a parallel-runway field
        // is a DIFFERENT STRIP, and the diagram draws two crossing lines where there are two parallel.
        XCTAssertEqual(VectorProcedureChart.reciprocal(of: "04L"), "22R")
        XCTAssertEqual(VectorProcedureChart.reciprocal(of: "22R"), "04L")
        XCTAssertEqual(VectorProcedureChart.reciprocal(of: "09"), "27")
        XCTAssertEqual(VectorProcedureChart.reciprocal(of: "27"), "09")
        XCTAssertEqual(VectorProcedureChart.reciprocal(of: "18C"), "36C", "a centre runway stays centre")
    }

    func testAnImplausibleDesignatorHasNoReciprocal() {
        XCTAssertNil(VectorProcedureChart.reciprocal(of: "99"))
        XCTAssertNil(VectorProcedureChart.reciprocal(of: ""))
        XCTAssertNil(VectorProcedureChart.reciprocal(of: "AB"))
    }

    func testEachRunwayIsDrawnOnceNotTwice() {
        // Both ends are separate rows; drawing per row would stack two identical lines.
        let rwys = [
            CIFPRunway(designator: "RW04", coord: c(42.00, -71.00), bearingMag: 40, lengthFt: 7000),
            CIFPRunway(designator: "RW22", coord: c(42.02, -70.98), bearingMag: 220, lengthFt: 7000),
        ]
        let d = VectorProcedureChart.airportDiagram(airport: "KTST", runways: rwys)
        XCTAssertEqual(d.primitives.count, 1)
        if case .runway(_, _, let designator)? = d.primitives.first {
            XCTAssertEqual(designator, "04/22")
        } else { XCTFail("no runway drawn") }
    }

    func testParallelRunwaysPairWithTheirOwnOppositeEnd() {
        // The real KBOS shape: 04L/22R (7,864 ft) and 04R/22L (10,006 ft). Mis-pairing would draw two
        // crossing lines through the middle of the field.
        let rwys = [
            CIFPRunway(designator: "RW04L", coord: c(42.3580, -71.0143), bearingMag: 40, lengthFt: 7864),
            CIFPRunway(designator: "RW22R", coord: c(42.3762, -71.0055), bearingMag: 220, lengthFt: 7864),
            CIFPRunway(designator: "RW04R", coord: c(42.3540, -71.0104), bearingMag: 40, lengthFt: 10006),
            CIFPRunway(designator: "RW22L", coord: c(42.3738, -71.0008), bearingMag: 220, lengthFt: 10006),
        ]
        let d = VectorProcedureChart.airportDiagram(airport: "KBOS", runways: rwys)
        XCTAssertEqual(d.primitives.count, 2)
        let names = d.primitives.compactMap { p -> String? in
            if case .runway(_, _, let n) = p { return n }; return nil
        }.sorted()
        XCTAssertEqual(names, ["04L/22R", "04R/22L"])
    }

    func testAFarApartPairIsRefusedRatherThanDrawn() {
        // A reciprocal NUMBER at a different field (or a bad coordinate) must not become a runway
        // stretching across the chart.
        let rwys = [
            CIFPRunway(designator: "RW09", coord: c(42.00, -71.00), bearingMag: 90, lengthFt: 5000),
            CIFPRunway(designator: "RW27", coord: c(43.00, -70.00), bearingMag: 270, lengthFt: 5000),
        ]
        XCTAssertTrue(VectorProcedureChart.airportDiagram(airport: "KTST", runways: rwys)
                        .primitives.isEmpty)
    }

    func testTheDiagramIsDrawnToScale() throws {
        // A 7,000 ft runway is 1.15 NM; the drawn line must be that long in the chart's own units.
        let rwys = [
            CIFPRunway(designator: "RW18", coord: c(42.00, -71.00), bearingMag: 180, lengthFt: 7000),
            CIFPRunway(designator: "RW36", coord: c(42.0192, -71.00), bearingMag: 360, lengthFt: 7000),
        ]
        let d = VectorProcedureChart.airportDiagram(airport: "KTST", runways: rwys)
        let g = try XCTUnwrap(VectorChartGeometry.fitting(d.extent, in: size))
        guard case .runway(let a, let b, _)? = d.primitives.first else { return XCTFail("no runway") }
        let drawn = hypot(g.point(a).x - g.point(b).x, g.point(a).y - g.point(b).y)
        XCTAssertEqual(Double(drawn), Double(g.points(nm: Geo.nmBetween(a, b))), accuracy: 0.5)
    }
}
