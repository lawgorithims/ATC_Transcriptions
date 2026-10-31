import XCTest
@testable import ATCTranscribe

/// The preflight half of the reach model: how much of a filed route has no runway in glide.
final class RouteGlideExposureTests: XCTestCase {

    private struct Flat: TerrainSampling {
        var isReady: Bool { true }
        func sampleElevationFt(at coord: Coord) -> Double? { 0 }
    }
    private let start = Coord(lat: 35.0, lon: -98.0)

    private func field(_ id: String, nmNorth: Double) -> AirportData.Airport {
        AirportData.Airport(ident: id, icao: "", name: "\(id) test field",
                            coord: Coord(lat: start.lat + nmNorth / 60.0, lon: start.lon),
                            elevationFt: 0, ownership: "PU", use: "PU", status: "O",
                            tower: "NON-ATCT", fuel: "", siteType: "A", far139: "")
    }
    private let runway = [AirportData.Runway(designator: "09/27", lengthFt: 4000, widthFt: 75,
                                             surface: "ASPH", condition: "GOOD", lights: "MED")]

    /// Fields at 0 and 60 NM along a northbound 60 NM route, nothing between.
    private func world(_ fields: [AirportData.Airport]) -> RouteGlideExposure.World {
        RouteGlideExposure.World(
            airportsNear: { c, r in fields.filter { Geo.nmBetween(c, $0.coord) <= r } },
            runwaysFor: { _ in self.runway }, terrain: Flat(), windAt: { _, _, _ in nil })
    }
    private var route: [Coord] { [start, Coord(lat: start.lat + 1, lon: start.lon)] }   // 60 NM north

    /// 6,000 ft at 9:1 reaches 7.41 NM from a sea-level field in still air — so with fields only at
    /// either end, roughly the first and last 7 NM are covered and the middle ~46 NM is not. (The turn
    /// back to the field behind costs 300 ft, so the trailing coverage is a little shorter.)
    func testTheMiddleOfAnEmptyLegIsOutOfGlide() throws {
        let r = try XCTUnwrap(RouteGlideExposure.evaluate(
            route: route, altitudeFtMSL: 6_000, glideRatio: 9, bestGlideKts: 65,
            world: world([field("SRT", nmNorth: 0), field("END", nmNorth: 60)])))
        XCTAssertEqual(r.routeNm, 60, accuracy: 0.5)
        XCTAssertEqual(r.gaps.count, 1, "one gap between the two fields: \(r.gaps)")
        XCTAssertEqual(r.longestGapNm, 60 - 6.96 - 7.41, accuracy: 2.0)
        XCTAssertEqual(r.exposedFraction, r.longestGapNm / 60, accuracy: 0.05)
    }

    /// Height buys coverage: the same route higher is never MORE exposed.
    func testClimbingNeverAddsExposure() throws {
        let w = world([field("SRT", nmNorth: 0), field("MID", nmNorth: 30), field("END", nmNorth: 60)])
        var last = 1.0
        for alt in stride(from: 4_000.0, through: 10_000, by: 2_000) {
            let r = try XCTUnwrap(RouteGlideExposure.evaluate(route: route, altitudeFtMSL: alt,
                                                              glideRatio: 9, bestGlideKts: 65, world: w))
            XCTAssertLessThanOrEqual(r.exposedFraction, last + 1e-9, "climbing to \(alt) ft added exposure")
            last = r.exposedFraction
        }
    }

    /// Fields every 30 NM need ~15 NM of reach to close every gap: (15 NM × 6076 / 9) + 1,000 ft
    /// reserve ≈ 11,100 ft, plus the turn. The search climbs in 1,000 ft steps and must land there.
    func testTheSuggestionFindsTheAltitudeThatClosesTheGaps() throws {
        let w = world([field("SRT", nmNorth: 0), field("MID", nmNorth: 30), field("END", nmNorth: 60)])
        let s = try XCTUnwrap(RouteGlideExposure.lowestAltitude(
            closingGapsTo: 0.5, route: route, startFtMSL: 6_000, glideRatio: 9, bestGlideKts: 65, world: w))
        XCTAssertEqual(s.altitudeFtMSL, 12_000, accuracy: 1_000)
        XCTAssertLessThanOrEqual(s.longestGapNm, 0.5)
    }

    func testAFieldlessRouteIsEntirelyExposed() throws {
        let r = try XCTUnwrap(RouteGlideExposure.evaluate(route: route, altitudeFtMSL: 9_000,
                                                          glideRatio: 9, bestGlideKts: 65, world: world([])))
        XCTAssertEqual(r.exposedFraction, 1, accuracy: 1e-9)
    }

    func testGapsAreMaximalRuns() {
        let g = RouteGlideExposure.gapsFrom([0, 1, 2, 3, 4, 5], [true, false, false, true, false, false])
        XCTAssertEqual(g, [.init(fromNm: 1, toNm: 3), .init(fromNm: 4, toNm: 5)])
    }

    func testDensifyIsBoundedAndKeepsEachLegsCourse() {
        let s = RouteGlideExposure.densify(route)
        // One degree of latitude is a hair over 60 NM on the app's sphere, so derive, don't assume.
        let leg = Geo.nmBetween(route[0], route[1])
        XCTAssertEqual(s.count, Int((leg / RouteGlideExposure.sampleSpacingNm).rounded(.up)) + 1,
                       "a sample per NM plus the endpoint")
        XCTAssertEqual(s.first?.courseDeg ?? -1, 0, accuracy: 0.5)
        let huge = RouteGlideExposure.densify([start, Coord(lat: start.lat + 20, lon: start.lon)])
        XCTAssertLessThanOrEqual(huge.count, RouteGlideExposure.maxSamples, "the walk is unbounded")
    }

    // MARK: - drawing

    /// A gap inside one leg is two points, at the gap's own distances along the route.
    func testAGapInsideOneLegIsDrawnBetweenItsDistances() {
        let line = RouteGlideExposure.polyline(of: .init(fromNm: 10, toNm: 20), along: route)
        XCTAssertEqual(line.count, 2)
        XCTAssertEqual(Geo.nmBetween(start, line[0]), 10, accuracy: 0.01)
        XCTAssertEqual(Geo.nmBetween(start, line[1]), 20, accuracy: 0.01)
    }

    /// A gap that spans a turn bends with the route: it keeps the corner, never cutting across it.
    func testAGapAcrossACornerKeepsTheCorner() {
        let corner = Coord(lat: start.lat + 0.5, lon: start.lon)                      // ~30 NM north
        let dogleg = [start, corner, Geo.destination(from: corner, bearingDeg: 90, distanceNm: 30)]
        let first = Geo.nmBetween(dogleg[0], dogleg[1])
        let line = RouteGlideExposure.polyline(of: .init(fromNm: first - 10, toNm: first + 10), along: dogleg)
        XCTAssertEqual(line.count, 3, "start, the corner, end: \(line)")
        XCTAssertEqual(line[1].lat, corner.lat, accuracy: 1e-9)
        XCTAssertEqual(line[1].lon, corner.lon, accuracy: 1e-9)
        XCTAssertEqual(Geo.nmBetween(corner, line[2]), 10, accuracy: 0.01)
    }

    /// What the map draws comes from the same distances the samples measured: the drawn gap of the
    /// empty-middle route starts and ends where `evaluate` says it does. A gap of no length draws nothing.
    func testTheDrawnGapsAreTheMeasuredOnes() throws {
        let r = try XCTUnwrap(RouteGlideExposure.evaluate(
            route: route, altitudeFtMSL: 6_000, glideRatio: 9, bestGlideKts: 65,
            world: world([field("SRT", nmNorth: 0), field("END", nmNorth: 60)])))
        let lines = RouteGlideExposure.gapLines(r, along: route)
        XCTAssertEqual(lines.count, r.gaps.count)
        let gap = try XCTUnwrap(r.gaps.first), line = try XCTUnwrap(lines.first)
        XCTAssertEqual(Geo.nmBetween(start, try XCTUnwrap(line.first)), gap.fromNm, accuracy: 0.01)
        XCTAssertEqual(Geo.nmBetween(start, try XCTUnwrap(line.last)), gap.toNm, accuracy: 0.01)
        let end = Geo.nmBetween(route[0], route[1])
        XCTAssertTrue(RouteGlideExposure.polyline(of: .init(fromNm: end, toNm: end), along: route).count < 2)
        XCTAssertTrue(RouteGlideExposure.gapLines(nil, along: route).isEmpty)
    }

    // MARK: - real data

    /// KLRU → KTUS direct, against the bundled airport database and terrain grid — the route the deep
    /// dive measured (81% at 8,500 vs 58% at 10,500, still air, runways ≥ 1,500 ft, no terrain between).
    /// This engine sweeps terrain and charges turns, so its numbers differ; what must hold is the SHAPE
    /// the planner exists to show: most of the route out of glide at 8,500, and a climb shrinking it.
    func testKLRUToKTUSIsMostlyOutOfGlideAndAClimbHelps() throws {
        try XCTSkipUnless(AirportData.isQueryable, "airport database unavailable")
        let terrain = TerrainElevation()
        try XCTSkipUnless(terrain.isReady, "terrain grid unavailable")
        let w = RouteGlideExposure.World(
            airportsNear: { AirportData.airportsNear($0, radiusNm: $1, limit: 256) },
            runwaysFor: { AirportData.runways(airport: $0) }, terrain: terrain, windAt: { _, _, _ in nil })
        let klru = Coord(lat: 32.2894, lon: -106.9219), ktus = Coord(lat: 32.1161, lon: -110.9410)
        let low = try XCTUnwrap(RouteGlideExposure.evaluate(route: [klru, ktus], altitudeFtMSL: 8_500,
                                                            glideRatio: 9, bestGlideKts: 68, world: w))
        let high = try XCTUnwrap(RouteGlideExposure.evaluate(route: [klru, ktus], altitudeFtMSL: 10_500,
                                                             glideRatio: 9, bestGlideKts: 68, world: w))
        print("KLRU-KTUS 8,500: \(low.exposedFraction) longest \(low.longestGapNm) NM | "
              + "10,500: \(high.exposedFraction) longest \(high.longestGapNm) NM")
        XCTAssertEqual(low.routeNm, 204, accuracy: 3)
        // Measured 2026-10-24 on cycle-2610 data: 77% / 98 NM at 8,500, 59% / 44 NM at 10,500.
        XCTAssertEqual(low.exposedFraction, 0.77, accuracy: 0.08)
        XCTAssertEqual(high.exposedFraction, 0.59, accuracy: 0.08)
        XCTAssertGreaterThan(low.exposedFraction, 0.5, "most of KLRU-KTUS at 8,500 should be out of glide")
        XCTAssertLessThan(high.exposedFraction, low.exposedFraction - 0.1, "2,000 ft did not shrink the exposure")
        XCTAssertLessThan(high.longestGapNm, low.longestGapNm, "2,000 ft did not shorten the longest gap")
    }
}
