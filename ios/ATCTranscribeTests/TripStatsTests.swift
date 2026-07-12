import XCTest
@testable import ATCTranscribe

/// `TripStats` — the flight-plan strip's DIST/ETE/ETA/FUEL math and formatting. Pure value tests;
/// coordinates are fixed, dates are injected (no clock).
final class TripStatsTests: XCTestCase {

    // KMSP → KORD is ~289 nm great-circle; a simple two-point route pins the math.
    private let kmsp = Coord(lat: 44.881944, lon: -93.221667)
    private let kord = Coord(lat: 41.978611, lon: -87.904722)

    func testDistanceSumsLegs() {
        let mid = Coord(lat: 43.5, lon: -90.5)
        let direct = TripStats.compute(points: [kmsp, kord], cruiseKts: nil, burnGPH: nil)
        let dogleg = TripStats.compute(points: [kmsp, mid, kord], cruiseKts: nil, burnGPH: nil)
        XCTAssertNotNil(direct); XCTAssertNotNil(dogleg)
        XCTAssertEqual(direct?.distanceNM ?? 0, 289, accuracy: 5, "KMSP→KORD is ~289 nm")
        XCTAssertGreaterThan(dogleg?.distanceNM ?? 0, direct?.distanceNM ?? 0,
                             "a dogleg must be longer than the direct")
    }

    func testETEAndFuelFromPerformance() {
        let stats = TripStats.compute(points: [kmsp, kord], cruiseKts: 140, burnGPH: 16.0)
        XCTAssertNotNil(stats)
        // ~289 nm at 140 kts ≈ 124 min; fuel = 16 gph × ~2.06 h ≈ 33 g.
        XCTAssertEqual(stats?.eteMinutes ?? 0, 124, accuracy: 3)
        XCTAssertEqual(stats?.fuelGallons ?? 0, 33, accuracy: 1.5)
    }

    func testMissingPerformanceDegradesToNil() {
        let noSpeed = TripStats.compute(points: [kmsp, kord], cruiseKts: nil, burnGPH: 16)
        XCTAssertNil(noSpeed?.eteMinutes, "no cruise speed → no ETE")
        XCTAssertNil(noSpeed?.fuelGallons, "fuel needs an ETE")
        let zeroSpeed = TripStats.compute(points: [kmsp, kord], cruiseKts: 0, burnGPH: 16)
        XCTAssertNil(zeroSpeed?.eteMinutes, "zero speed must not divide")
    }

    func testDegenerateRoutes() {
        XCTAssertNil(TripStats.compute(points: [], cruiseKts: 140, burnGPH: 16))
        XCTAssertNil(TripStats.compute(points: [kmsp], cruiseKts: 140, burnGPH: 16), "one point is not a route")
        XCTAssertNil(TripStats.compute(points: [kmsp, kmsp], cruiseKts: 140, burnGPH: 16), "zero distance")
    }

    // MARK: formatting

    func testFormatting() {
        let stats = TripStats(distanceNM: 290.4, eteMinutes: 127, fuelGallons: 60.34)
        XCTAssertEqual(stats.distanceText, "290 nm")
        XCTAssertEqual(stats.eteText, "2h07m")
        XCTAssertEqual(stats.fuelText, "60.3 g")
    }

    func testFormattingFallbacks() {
        let bare = TripStats(distanceNM: 100, eteMinutes: nil, fuelGallons: nil)
        XCTAssertEqual(bare.eteText, "–")
        XCTAssertEqual(bare.fuelText, "–")
        XCTAssertEqual(bare.etaText(from: Date(timeIntervalSince1970: 0)), "–")
    }

    func testETAFromInjectedDate() {
        let stats = TripStats(distanceNM: 290, eteMinutes: 120, fuelGallons: nil)
        let noon = DateComponents(calendar: .current, year: 2026, month: 7, day: 11, hour: 12).date!
        let text = stats.etaText(from: noon)
        XCTAssertTrue(text.contains("2"), "noon + 2h lands at 2 o'clock local: \(text)")
        XCTAssertNotEqual(text, "–")
    }
}
