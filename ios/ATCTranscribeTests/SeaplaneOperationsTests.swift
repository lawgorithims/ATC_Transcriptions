import XCTest
@testable import ATCTranscribe

/// Where an aircraft that floats may be told to put down — against the SHIPPED NASR data, following
/// `NearestAirportsDataTests`' doctrine that a safety feature's data path is asserted at the data
/// level, because shape-only tests have shipped real bugs here before.
///
/// The app has always assumed a landplane: `isNonAirplaneFacility` lumps seaplane bases ("C") in
/// with heliports and excludes them from the emergency list. 561 of them ship in `apt.sqlite`
/// today. These tests pin the three-way behaviour that replaces that assumption.
final class SeaplaneOperationsTests: XCTestCase {

    /// Lake Union, Seattle: five operational seaplane bases (Kenmore Air, Seattle Seaplanes) inside
    /// gliding distance of Boeing Field and Renton Muni. Real records, real geometry.
    private let seattle = Coord(lat: 47.64, lon: -122.33)

    private func assess(_ ops: AircraftProfile.WaterOps?) -> NRSTAssessment {
        let profile = AircraftProfile(callsign: "N1", type: "test", waterOps: ops)
        let situation = GlideSituation(coord: seattle, altitudeFtMSL: 7000,
                                       glideRatio: 9, isDefaultGlideRatio: false,
                                       verticalAccuracyM: 10,
                                       acceptsWater: profile.canLandOnWater,
                                       acceptsLand: profile.canLandOnLand)
        let terrain = TerrainElevation()
        XCTAssertTrue(terrain.isAvailable, "bundled CONUS grid must load")
        let radius = NearestAirports.searchRadiusNm(for: situation)
        let airports = AirportData.airportsNear(seattle, radiusNm: radius, limit: 256)
        return NearestAirports.assess(situation: situation, airports: airports,
                                      runwaysFor: { AirportData.runways(airport: $0) },
                                      weather: [:], terrain: terrain, now: Date())
    }

    // MARK: The three aircraft

    /// Unchanged behaviour for everyone flying today. A landplane must never be offered a lake, and
    /// a profile that predates water operations decodes with `waterOps == nil`.
    func testALandplaneIsNeverOfferedASeaplaneBase() {
        let water = assess(nil).candidates.filter(\.airport.isSeaplaneBase)
        XCTAssertTrue(water.isEmpty,
                      "a landplane was offered \(water.map(\.id)) — seaplane bases must stay excluded")
        XCTAssertFalse(assess(nil).candidates.isEmpty, "Boeing Field and Renton are right there")
    }

    func testAnAmphibianIsOfferedBothSurfaces() {
        let c = assess(.amphibian).candidates
        XCTAssertTrue(c.contains { $0.airport.isSeaplaneBase },
                      "no seaplane base near Lake Union for an amphibian — five are operational")
        XCTAssertTrue(c.contains { !$0.airport.isSeaplaneBase },
                      "an amphibian still uses runways; Boeing Field and Renton are in range")
    }

    /// ⚠️ THE ONE THAT MATTERS. A straight floatplane offered a paved runway during an engine-out is
    /// the most confident possible wrong answer, which is why `waterOps` is three states and not an
    /// `isSeaplane` boolean.
    func testAFloatplaneIsNeverOfferedAPavedRunway() {
        for c in assess(.floatOnly).candidates {
            let surfaces = AirportData.runways(airport: c.airport.ident)
                .filter { !$0.isHelipad && !$0.isFailed }
                .map { $0.surface.uppercased() }
            XCTAssertTrue(surfaces.isEmpty || surfaces.contains("WATER"),
                          "\(c.id) has no water runway (\(surfaces)) but was offered to a floatplane")
        }
        XCTAssertFalse(assess(.floatOnly).candidates.isEmpty,
                       "Lake Union is surrounded by water landing areas")
    }

    // MARK: The surface decides, not the site type

    /// 77 ordinary airports in the shipped cycle carry a water runway beside their asphalt. Gating on
    /// `site_type` instead of the surface would hide every one of them from a floatplane — this test
    /// exists because the first cut of the change did exactly that.
    func testLandAirportsWithWaterRunwaysStayAvailableToAFloatplane() throws {
        // Leesburg Intl (LEE) is site_type "A" with a 15,000 ft water lane.
        let lee = try XCTUnwrap(AirportData.airportsNear(Coord(lat: 28.82, lon: -81.81),
                                                         radiusNm: 5, limit: 32)
                                 .first { $0.ident == "LEE" },
                                "Leesburg Intl missing from the shipped NASR cycle")
        XCTAssertEqual(lee.siteType, "A", "LEE is an airport, not a seaplane base")
        let runways = AirportData.runways(airport: "LEE")
        XCTAssertTrue(runways.contains { $0.surface.uppercased() == "WATER" },
                      "LEE's water runway is the whole point of this test")

        let situation = GlideSituation(coord: Coord(lat: 28.82, lon: -81.81), altitudeFtMSL: 7000,
                                       glideRatio: 9, isDefaultGlideRatio: false,
                                       verticalAccuracyM: 10,
                                       acceptsWater: true, acceptsLand: false)
        let a = NearestAirports.assess(situation: situation,
                                       airports: AirportData.airportsNear(situation.coord,
                                                                          radiusNm: 20, limit: 128),
                                       runwaysFor: { AirportData.runways(airport: $0) },
                                       weather: [:], terrain: TerrainElevation(), now: Date())
        XCTAssertTrue(a.candidates.contains { $0.airport.ident == "LEE" },
                      "a floatplane over Leesburg was not offered its 15,000 ft water lane")
    }

    /// And the converse: a seaplane base whose only strip is turf must not reach a floatplane.
    func testASeaplaneBaseWithNoWaterRunwayIsNotOfferedToAFloatplane() {
        let situation = GlideSituation(coord: seattle, altitudeFtMSL: 7000, glideRatio: 9,
                                       isDefaultGlideRatio: false, verticalAccuracyM: 10,
                                       acceptsWater: true, acceptsLand: false)
        for c in assessAt(situation).candidates {
            let water = AirportData.runways(airport: c.airport.ident)
                .filter { !$0.isHelipad && !$0.isFailed }
                .contains { $0.surface.uppercased() == "WATER" }
            let none = AirportData.runways(airport: c.airport.ident).isEmpty
            XCTAssertTrue(water || none, "\(c.id) reached a floatplane with no water runway")
        }
    }

    private func assessAt(_ situation: GlideSituation) -> NRSTAssessment {
        NearestAirports.assess(situation: situation,
                               airports: AirportData.airportsNear(situation.coord,
                                                                  radiusNm: 30, limit: 256),
                               runwaysFor: { AirportData.runways(airport: $0) },
                               weather: [:], terrain: TerrainElevation(), now: Date())
    }

    // MARK: Heliports stay out regardless

    /// Floating does not make a rooftop helipad landable. Seattle's downtown is full of them.
    func testHeliportsAreStillExcludedForEveryAircraft() {
        for ops in [nil, AircraftProfile.WaterOps.amphibian, .floatOnly] {
            for c in assess(ops).candidates {
                XCTAssertNotEqual(c.airport.siteType.uppercased(), "H",
                                  "\(c.id) is a heliport, offered to \(String(describing: ops))")
            }
        }
    }

    // MARK: The profile default

    func testAProfileWithoutWaterOpsIsALandplane() {
        let p = AircraftProfile(callsign: "N2", type: "C172")
        XCTAssertNil(p.waterOps)
        XCTAssertFalse(p.canLandOnWater, "a profile written before water ops must not acquire lakes")
        XCTAssertTrue(p.canLandOnLand)
    }

    func testTheTwoWaterConfigurationsDifferOnLand() {
        XCTAssertTrue(AircraftProfile(callsign: "a", type: "t", waterOps: .amphibian).canLandOnLand)
        XCTAssertFalse(AircraftProfile(callsign: "b", type: "t", waterOps: .floatOnly).canLandOnLand)
        XCTAssertTrue(AircraftProfile(callsign: "c", type: "t", waterOps: .floatOnly).canLandOnWater)
    }
}
