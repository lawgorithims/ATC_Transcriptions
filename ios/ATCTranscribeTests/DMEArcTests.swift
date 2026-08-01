import XCTest
@testable import ATCTranscribe

/// DME arcs. An `AF` leg is flown at a constant distance from a navaid, so its two endpoints describe a
/// CHORD that cuts inside the real track. `leg.recd_navaid` — the arc's centre, and the one column of
/// the leg table the app never asked for — was unread, so all 1,210 published arcs drew as straight
/// lines, by a median of 1.54 NM and up to 13.1 NM at KPDT.
final class DMEArcTests: XCTestCase {

    private let pdt = Coord(lat: 45.6947, lon: -118.8428)      // PDT VOR

    private func onArc(_ centre: Coord, radiusNm: Double, bearing: Double) -> Coord {
        Geo.point(from: centre, bearingDeg: bearing, distanceNm: radiusNm)
    }

    func testGeoPointIsTheInverseOfBearingAndDistance() {
        let p = Geo.point(from: pdt, bearingDeg: 137.0, distanceNm: 20.0)
        XCTAssertEqual(Geo.nmBetween(pdt, p), 20.0, accuracy: 0.02)
        XCTAssertEqual(Geo.bearing(pdt, p), 137.0, accuracy: 0.2)
    }

    func testArcPointsStayOnTheArc() {
        let a = onArc(pdt, radiusNm: 20, bearing: 100)
        let b = onArc(pdt, radiusNm: 20, bearing: 240)          // a 140-degree sweep, as at KPDT
        let pts = ProcedureRoute.arcPoints(from: a, to: b, centre: pdt)
        XCTAssertFalse(pts.isEmpty, "a 140-degree arc must produce interior points")
        for p in pts {
            XCTAssertEqual(Geo.nmBetween(pdt, p), 20.0, accuracy: 0.05,
                           "an interpolated point left the published arc")
        }
    }

    func testTheArcIsMateriallyDifferentFromTheChord() {
        // The whole point: at KPDT the chord runs 13 NM inside the arc, directly over the VOR.
        let a = onArc(pdt, radiusNm: 20, bearing: 100)
        let b = onArc(pdt, radiusNm: 20, bearing: 240)
        let midChord = Coord(lat: (a.lat + b.lat) / 2, lon: (a.lon + b.lon) / 2)
        let sagitta = 20.0 - Geo.nmBetween(pdt, midChord)
        XCTAssertGreaterThan(sagitta, 5.0, "this fixture should show a large chord error")
        let pts = ProcedureRoute.arcPoints(from: a, to: b, centre: pdt)
        let worst = pts.map { abs(Geo.nmBetween(pdt, $0) - 20.0) }.max() ?? 0
        XCTAssertLessThan(worst, 0.05, "the drawn arc must track the published one")
    }

    func testShortArcsAndStraightLegsProduceNothing() {
        // Below a few degrees of sweep the chord IS the arc; interpolating would add noise.
        let a = onArc(pdt, radiusNm: 20, bearing: 100)
        let b = onArc(pdt, radiusNm: 20, bearing: 102)
        XCTAssertTrue(ProcedureRoute.arcPoints(from: a, to: b, centre: pdt).isEmpty)
    }

    func testAMismatchedCentreIsRefusedRatherThanFabricated() {
        // THE safety property. If the two radii disagree, the resolved navaid is not the centre of this
        // curve — a wrong ident, or a leg that is not really an arc. A fabricated arc would be worse
        // than the honest chord, so it must return nothing and let the straight line stand.
        let a = onArc(pdt, radiusNm: 20, bearing: 100)
        let b = onArc(pdt, radiusNm: 35, bearing: 240)          // not the same radius
        XCTAssertTrue(ProcedureRoute.arcPoints(from: a, to: b, centre: pdt).isEmpty)
    }

    func testADegenerateCentreIsRefused() {
        let a = onArc(pdt, radiusNm: 0.2, bearing: 10)
        let b = onArc(pdt, radiusNm: 0.2, bearing: 200)
        XCTAssertTrue(ProcedureRoute.arcPoints(from: a, to: b, centre: pdt).isEmpty,
                      "a sub-nautical-mile radius is not a DME arc")
    }

    func testTheStepCountIsBounded() {
        // A full 360-degree sweep must stay inside the cap rather than emitting hundreds of points.
        let a = onArc(pdt, radiusNm: 20, bearing: 0)
        let b = onArc(pdt, radiusNm: 20, bearing: 179.9)
        XCTAssertLessThan(ProcedureRoute.arcPoints(from: a, to: b, centre: pdt).count, 60)
    }

    func testArcPointsCarryNoIdentAndDrawNoSymbol() {
        // They shape the line only; a phantom waypoint star on every arc segment would be clutter and a
        // claim that there is a fix there.
        let leg = ResolvedLeg(ident: "", kind: .waypoint, coord: pdt, isPathOnly: true)
        let feats = MapLibreChartView.Coordinator.routeWptFeatures([leg])
        XCTAssertTrue(feats.isEmpty, "a path-only point must not become a waypoint symbol")
    }

    func testTheRecommendedNavaidIsNowReadFromTheDatabase() throws {
        try XCTSkipUnless(CIFP.available, "cifp.sqlite not present")
        // 1,210 AF legs in the cycle; every one carries a recd_navaid. If the column is unread this is
        // empty on all of them, which is exactly the state that produced the chords.
        var seen = 0
        for apt in ["KPDT", "PABR", "KFMN", "PAOM"] {
            for p in CIFP.procedures(airport: apt) where p.kind == "IAP" {
                for leg in CIFP.legs(procedureID: p.id).prefix(64) where leg.legType == "AF" {
                    seen += 1
                    XCTAssertFalse(leg.recommendedNavaid.isEmpty,
                                   "\(apt) \(p.ident) AF leg at \(leg.fix) has no arc centre")
                }
            }
        }
        XCTAssertGreaterThan(seen, 0, "no AF legs found — the fixture airports should publish arcs")
    }

    func testRFArcCentresAreNowInTheDatabase() throws {
        try XCTSkipUnless(CIFP.available, "cifp.sqlite not present")
        // ARINC publishes the RF centre fix at columns 106-111; the builder never extracted it, so all
        // 1,439 radius-to-fix legs drew as chords. RNP AR approaches exist precisely because the arc
        // keeps the aircraft in a narrow terrain-contained corridor.
        var rf = 0, withCentre = 0
        for apt in ["KYKM", "KGUC", "KGPI", "KSDL", "PANC"] {
            for p in CIFP.procedures(airport: apt) where p.kind == "IAP" {
                for leg in CIFP.legs(procedureID: p.id).prefix(80) where leg.legType == "RF" {
                    rf += 1
                    if leg.arcCentre != nil { withCentre += 1 }
                }
            }
        }
        try XCTSkipIf(rf == 0, "no RF legs at the fixture airports in this cycle")
        XCTAssertEqual(withCentre, rf, "every RF leg must carry its arc centre")
    }

    func testAnRFCentreIsAPlausibleDistanceFromItsOwnLeg() throws {
        try XCTSkipUnless(CIFP.available, "cifp.sqlite not present")
        // A centre resolved to the wrong record would sit absurdly far away — the same failure mode as
        // the SJ collision. RF radii are small by design (these are terminal turns).
        for apt in ["KYKM", "KGUC", "KGPI", "KSDL"] {
            for p in CIFP.procedures(airport: apt) where p.kind == "IAP" {
                for leg in CIFP.legs(procedureID: p.id).prefix(80) {
                    guard leg.legType == "RF", let c = leg.arcCentre, let at = leg.coord else { continue }
                    let r = Geo.nmBetween(c, at)
                    XCTAssertLessThan(r, 30.0, "\(apt) \(p.ident) RF radius \(r) NM is not a terminal turn")
                    XCTAssertGreaterThan(r, 0.05, "\(apt) \(p.ident) RF centre sits on its own fix")
                }
            }
        }
    }

    func testOnlyRFLegsClaimACentre() throws {
        try XCTSkipUnless(CIFP.available, "cifp.sqlite not present")
        for p in CIFP.procedures(airport: "KBOS") where p.kind == "IAP" {
            for leg in CIFP.legs(procedureID: p.id).prefix(80) where leg.legType != "RF" {
                XCTAssertNil(leg.arcCentre, "a \(leg.legType) leg must not claim an arc centre")
            }
        }
    }
}
