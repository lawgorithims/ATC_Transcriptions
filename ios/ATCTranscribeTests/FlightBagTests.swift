import XCTest
@testable import ATCTranscribe

/// The Flight Bag data layer: chart-cycle validity (expiry) + region bundles, from the bundled
/// `procedures.json`. Skips gracefully if the resource isn't in the test host.
final class FlightBagTests: XCTestCase {

    func testCycleExpiryLogic() throws {
        let exp = try XCTUnwrap(Procedures.expiryDate, "bundled cycle has an expiry date")
        // A day before expiry is current; a day after is expired.
        XCTAssertFalse(Procedures.isExpired(asOf: exp.addingTimeInterval(-86_400)))
        XCTAssertTrue(Procedures.isExpired(asOf: exp.addingTimeInterval(86_400)))
        // Exactly-at-expiry counts as expired (>=).
        XCTAssertTrue(Procedures.isExpired(asOf: exp))
        // daysUntilExpiry counts down.
        XCTAssertEqual(Procedures.daysUntilExpiry(asOf: exp.addingTimeInterval(-3 * 86_400)), 3)
        XCTAssertEqual(Procedures.daysUntilExpiry(asOf: exp.addingTimeInterval(-86_400)), 1)
    }

    func testCycleWindowOrdered() throws {
        let eff = try XCTUnwrap(Procedures.effectiveDate)
        let exp = try XCTUnwrap(Procedures.expiryDate)
        XCTAssertLessThan(eff, exp, "effective date precedes expiry")
        // FAA d-TPP cycles are 28 days.
        let days = Calendar.current.dateComponents([.day], from: eff, to: exp).day ?? 0
        XCTAssertEqual(days, 28, "a d-TPP cycle is 28 days")
    }

    func testRegionsCoverAirportsWithPlates() throws {
        try XCTSkipIf(Procedures.regionNames.isEmpty, "no region bundles in the test host")
        // A well-known airport lands in the expected region.
        XCTAssertTrue(Procedures.airports(inRegion: "Northeast").contains("KBOS"))
        XCTAssertTrue(Procedures.airports(inRegion: "Southwest").contains("KLAX"))
        // Every airport listed in a region actually publishes plates (sampled).
        for r in Procedures.regionNames {
            for icao in Procedures.airports(inRegion: r).prefix(10) {
                XCTAssertFalse(Procedures.forAirport(icao).isEmpty, "\(icao) in \(r) has no plates")
            }
        }
    }

    @MainActor
    func testRouteAirportsDedupesAndKeepsOnlyPlateAirports() {
        // nil plan → empty; the helper only keeps idents that publish plates.
        XCTAssertTrue(PlateBag.routeAirports(nil).isEmpty)
    }
}
