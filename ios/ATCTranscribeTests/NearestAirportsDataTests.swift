import XCTest
@testable import ATCTranscribe

/// NRST against the SHIPPED data — apt.sqlite (with its new site_type/far139 columns) and the
/// bundled CONUS terrain grid — following the SafetyAuditRegressionTests doctrine: shape-only tests
/// have shipped real bugs, so a safety feature's data path gets asserted at the data level.
final class NearestAirportsDataTests: XCTestCase {

    private let dfw = Coord(lat: 32.897, lon: -97.038)

    func testAirportsNearReturnsRankedNasrFacilities() {
        let near = AirportData.airportsNear(dfw, radiusNm: 30, limit: 64)
        XCTAssertGreaterThan(near.count, 20, "DFW metro has dozens of NASR facilities within 30 NM")
        // Nearest-first, all inside the radius, all with real coordinates.
        for (a, b) in zip(near, near.dropFirst()) {
            XCTAssertLessThanOrEqual(Geo.nmBetween(dfw, a.coord), Geo.nmBetween(dfw, b.coord) + 1e-9)
        }
        XCTAssertTrue(near.allSatisfy { Geo.nmBetween(dfw, $0.coord) <= 30 })
        // DFW itself: towered, public, Part-139 with the highest ARFF index, ICAO filled in.
        guard let dfwRow = near.first(where: { $0.ident == "DFW" }) else {
            return XCTFail("KDFW missing from its own metro query")
        }
        XCTAssertEqual(dfwRow.icao, "KDFW")
        XCTAssertTrue(dfwRow.isTowered)
        XCTAssertTrue(dfwRow.isPublicUse)
        XCTAssertEqual(dfwRow.far139, "I E", "the 2026-07-09 NASR cycle certificates DFW at Class I index E")
        XCTAssertEqual(dfwRow.siteType, "A")
        XCTAssertEqual(dfwRow.elevationFt ?? 0, 607, accuracy: 5)
        // The metro holds real heliports — the site-type column must actually be populated.
        XCTAssertTrue(near.contains { $0.siteType == "H" }, "site_type looks unpopulated")
    }

    func testRunwayLightsColumnIsExposed() {
        let runways = AirportData.runways(airport: "KDFW")
        XCTAssertGreaterThanOrEqual(runways.count, 7)
        XCTAssertTrue(runways.contains { !$0.lights.isEmpty }, "DFW's runways are lit — lights column lost")
        XCTAssertGreaterThan(runways.compactMap(\.lengthFt).max() ?? 0, 8000)
    }

    func testWxIdentAgainstRealRecords() {
        let near = AirportData.airportsNear(dfw, radiusNm: 25, limit: 128)
        guard let dfwRow = near.first(where: { $0.ident == "DFW" }),
              let addison = near.first(where: { $0.ident == "ADS" }) else {
            return XCTFail("expected DFW and ADS in the metro query")
        }
        XCTAssertEqual(NearestAirports.wxIdent(for: dfwRow), "KDFW")
        XCTAssertEqual(NearestAirports.wxIdent(for: addison), "KADS")
        // Alphanumeric private-field idents (T67, 52F) have no ICAO form and must map to nil —
        // requesting a METAR under a fabricated ident is how a ranking quietly rots.
        if let hicks = near.first(where: { $0.ident == "T67" }) {
            XCTAssertNil(NearestAirports.wxIdent(for: hicks))
        }
    }

    func testEndToEndAssessmentOverTheMetroplex() {
        // 6,500 ft over the flat DFW metroplex at 9:1 — real airports, real runways, real terrain.
        let situation = GlideSituation(coord: Coord(lat: 32.75, lon: -97.20), altitudeFtMSL: 6500,
                                       glideRatio: 9, isDefaultGlideRatio: false, verticalAccuracyM: 10)
        let terrain = TerrainElevation()          // fresh bundled-grid instance (main thread here)
        XCTAssertTrue(terrain.isAvailable, "bundled CONUS grid must load")
        let radius = NearestAirports.searchRadiusNm(for: situation)
        let airports = AirportData.airportsNear(situation.coord, radiusNm: radius, limit: 128)
        let a = NearestAirports.assess(situation: situation, airports: airports,
                                       runwaysFor: { AirportData.runways(airport: $0) },
                                       weather: [:], terrain: terrain, now: Date())
        XCTAssertFalse(a.candidates.isEmpty)
        XCTAssertTrue(a.terrainAvailable)
        // Flat country from 6,500 ft: something must be reachable, and it must sort first.
        XCTAssertTrue(a.candidates.contains { $0.reachability.isReachable },
                      "no reachable field over the DFW metroplex from 6,500 ft is data nonsense")
        XCTAssertTrue(a.candidates.first?.reachability.isReachable ?? false)
        // Reachable candidates over flat Texas must be CLEAR or thin-margin — a terrain hole here
        // would mean the grid sweep is broken, and a heliport in the list means the filter is.
        for c in a.candidates where c.reachability.isReachable {
            XCTAssertNotEqual(c.reachability, .caution(.terrainUnknown),
                              "\(c.id): terrain sweep hit a hole over CONUS flatland")
            XCTAssertFalse(c.airport.isNonAirplaneFacility, "\(c.id) is not an airplane field")
        }
        // Every ranked row carries what the panel shows.
        for c in a.candidates.prefix(5) {
            XCTAssertGreaterThan(c.distanceNm, 0)
            XCTAssertTrue((0...360).contains(c.bearingTrueDeg))
        }
    }

    /// THE mountain test: a real ridge, the real bundled grid, a real airport in a box canyon.
    ///
    /// Telluride (KTEX, field elevation 9,070 ft) sits in a dead-end San Juan valley. From 8.00 NM
    /// northeast the field is comfortably inside still-air glide range at 9:1 from 15,671 ft — the
    /// arithmetic says "reachable, 8.3 NM of range for an 8.0 NM hop" — but the ridge in between tops
    /// out 1,939 ft ABOVE the required descent profile (verified independently against
    /// `terrain_conus.bin`, worst point 5 NM along the path). A ranker that only did arithmetic would
    /// send the pilot into a mountain, so this must come back BLOCKED, with the obstruction reported at
    /// roughly where it actually is.
    func testRealTerrainBlocksAGlideIntoTellurideOverTheRidge() throws {
        let terrain = TerrainElevation()
        try XCTSkipUnless(terrain.isAvailable)
        let ownship = Coord(lat: 38.0394, lon: -107.7789)
        let ktex = try XCTUnwrap(AirportData.airportsNear(Coord(lat: 37.9538, lon: -107.9085),
                                                          radiusNm: 3, limit: 32)
                                    .first { $0.ident == "TEX" })
        XCTAssertEqual(ktex.elevationFt ?? 0, 9070, accuracy: 60, "KTEX field elevation moved — re-derive the case")
        let distance = Geo.nmBetween(ownship, ktex.coord)
        XCTAssertEqual(distance, 8.0, accuracy: 0.3, "the geometry this case was derived from")

        let blocked = NearestAirports.assess(
            situation: GlideSituation(coord: ownship, altitudeFtMSL: 15_671, glideRatio: 9,
                                      isDefaultGlideRatio: false, verticalAccuracyM: 25),
            airports: [ktex], runwaysFor: { AirportData.runways(airport: $0) },
            weather: [:], terrain: terrain, now: Date())
        let verdict = try XCTUnwrap(blocked.candidates.first?.reachability)
        // Distance alone says yes — so this proves the terrain sweep, not the range check, did the work.
        XCTAssertGreaterThanOrEqual(NearestAirports.stillAirRangeNm(blocked.situation, fieldElevFt: 9070),
                                    distance, "precondition: the field IS in glide by distance")
        guard case .blocked(let atNm) = verdict else {
            return XCTFail("real terrain 1,939 ft above the glide path must block — got \(verdict)")
        }
        XCTAssertGreaterThan(atNm, 0.9, "the obstruction is enroute, not in the ownship's own cell")
        XCTAssertLessThan(atNm, distance, "…and short of the field")

        // CONTROL: the same course and field, 20,000 ft — +2,390 ft of clearance over the same ridge.
        // If this also blocked, the sweep would just be rejecting mountains wholesale.
        let high = NearestAirports.assess(
            situation: GlideSituation(coord: ownship, altitudeFtMSL: 20_000, glideRatio: 9,
                                      isDefaultGlideRatio: false, verticalAccuracyM: 25),
            airports: [ktex], runwaysFor: { AirportData.runways(airport: $0) },
            weather: [:], terrain: terrain, now: Date())
        let highVerdict = try XCTUnwrap(high.candidates.first?.reachability)
        XCTAssertTrue(highVerdict.isReachable,
                      "2,390 ft of clearance over the ridge must be reachable — got \(highVerdict)")
        // And the AGL readout works over real mountains: 20,000 MSL over ~11,000 ft terrain.
        let agl = try XCTUnwrap(high.ownshipAglFt)
        XCTAssertGreaterThan(agl, 6_000)
        XCTAssertLessThan(agl, 13_000)
        XCTAssertEqual(try XCTUnwrap(high.ownshipTerrainFt), 20_000 - agl, accuracy: 1)
    }

    func testMountainFieldRanksTerrainHostility() throws {
        // Aspen (ASE) sits in a box canyon; its vicinity rise must dwarf a plains field's.
        let terrain = TerrainElevation()
        try XCTSkipUnless(terrain.isAvailable)
        let aspen = Coord(lat: 39.221, lon: -106.868)
        let plains = Coord(lat: 32.75, lon: -97.20)
        let aspenRise = NearestAirports.vicinityRiseFt(around: aspen, fieldElevFt: 7838, terrain: terrain) ?? 0
        let plainsRise = NearestAirports.vicinityRiseFt(around: plains, fieldElevFt: 600, terrain: terrain) ?? 0
        XCTAssertGreaterThan(aspenRise, 2500, "the ridges over Aspen are >11,000 ft MSL")
        XCTAssertLessThan(plainsRise, 1500)
        XCTAssertGreaterThan(aspenRise, plainsRise + 2000)
    }

    func testAircraftProfileDecodesLegacyBlobWithoutGlideFields() throws {
        let legacy = """
        [{"id":"6E4D2C1A-0000-4000-8000-000000000001","callsign":"N8925T","type":"Piper Seneca","cruiseKts":165,"burnGPH":16.5}]
        """
        let profiles = try JSONDecoder().decode([AircraftProfile].self, from: Data(legacy.utf8))
        XCTAssertEqual(profiles.first?.callsign, "N8925T")
        XCTAssertNil(profiles.first?.glideRatio, "pre-glide blobs must decode with nil glide fields")
        XCTAssertNil(profiles.first?.bestGlideKts)
        // And a round-trip with the new fields survives.
        var p = profiles[0]
        p.glideRatio = 9.5
        p.bestGlideKts = 105
        let redecoded = try JSONDecoder().decode([AircraftProfile].self,
                                                 from: JSONEncoder().encode([p]))
        XCTAssertEqual(redecoded.first?.glideRatio, 9.5)
        XCTAssertEqual(redecoded.first?.bestGlideKts, 105)
        // ⚠️ EVERY FIELD ADDED SINCE must be nil on that legacy blob, not defaulted. This assertion
        // is named explicitly rather than left implicit, because the test predates the airframe
        // fields and would have kept passing whether or not they were back-compatible — the pilot's
        // saved hangar decoding is not something to establish by accident.
        XCTAssertNil(profiles.first?.vRefKts)
        XCTAssertNil(profiles.first?.landingOver50Ft)
        XCTAssertNil(profiles.first?.mtowLb)
        XCTAssertNil(profiles.first?.spanFt)
        XCTAssertNil(profiles.first?.isRotorcraft,
                     "a legacy profile must not decode as an aeroplane OR a helicopter — unknown")
    }

    /// The catalogue must not contain a value that would poison the layers it feeds.
    ///
    /// These figures reach the glide footprint and the landability shading directly, so a typo — a
    /// 90:1 glide, a landing distance entered in metres — would not look like a bug, it would look
    /// like a confident wrong answer on the map.
    func testEveryCatalogueEntryIsWithinThePlausibleBand() {
        XCTAssertFalse(AircraftCatalog.all.isEmpty)
        for e in AircraftCatalog.all {
            XCTAssertTrue((3.0...30.0).contains(e.glideRatio), "\(e.id) glide \(e.glideRatio)")
            XCTAssertTrue((40...250).contains(e.bestGlideKts), "\(e.id) best glide")
            XCTAssertTrue((30...200).contains(e.vRefKts), "\(e.id) Vref")
            XCTAssertTrue((200...1_500_000).contains(e.mtowLb), "\(e.id) MTOW")
            XCTAssertTrue((5.0...300.0).contains(e.spanFt), "\(e.id) span")
            XCTAssertGreaterThan(e.bestGlideKts, e.vRefKts,
                                 "\(e.id): best glide is flown ABOVE approach speed")
            if let ld = e.landingOver50Ft {
                XCTAssertTrue((300.0...12_000.0).contains(ld), "\(e.id) landing distance")
            }
        }
    }

    /// ⚠️ ROTORCRAFT CARRY NO FIXED-WING LANDING DISTANCE. If one ever did, the landability layer
    /// would demand a runway's worth of open ground from a helicopter that can land in a clearing.
    func testRotorcraftCarryNoLandingDistanceAndAShallowerGlide() {
        let rotor = AircraftCatalog.all.filter(\.isRotorcraft)
        XCTAssertGreaterThanOrEqual(rotor.count, 5, "the catalogue should offer rotorcraft")
        for r in rotor {
            XCTAssertNil(r.landingOver50Ft, "\(r.id) carries a fixed-wing landing distance")
            XCTAssertLessThanOrEqual(r.glideRatio, 6.0,
                                     "\(r.id): autorotation is a steep descent, not a glide")
        }
        // And the converse — no aeroplane is silently missing its landing distance, which would
        // make `isRotorcraft` true for it and quietly exempt it from the run-length check.
        for a in AircraftCatalog.all where !a.isRotorcraft {
            XCTAssertNotNil(a.landingOver50Ft, "\(a.id) would be treated as a rotorcraft")
        }
    }

    // MARK: engagement — the undo that stands in for the missing confirm alert

    func testEngagementRoundTripsThroughUserDefaults() throws {
        // The no-confirm engage is justified by one-tap reversibility, and engaging immediately
        // overwrites the filed plan on disk — so the snapshot has to survive a process death too.
        var plan = FlightPlan()
        plan.departure = "KDFW"
        plan.destination = "KAUS"
        plan.route = ["GEP"]
        let engagement = NRSTEngagement(ident: "T67", displayIdent: "T67", name: "HICKS AIRFIELD",
                                        coord: Coord(lat: 32.93, lon: -97.53),
                                        routeTarget: "32.930,-97.530",
                                        engagedAt: Date(timeIntervalSince1970: 1_800_000_000),
                                        priorPlan: plan, frequencyLine: "CTAF 122.8")
        NRSTEngagement.clear()
        XCTAssertNil(NRSTEngagement.load())
        engagement.save()
        let restored = try XCTUnwrap(NRSTEngagement.load())
        XCTAssertEqual(restored, engagement)
        XCTAssertEqual(restored.priorPlan?.destination, "KAUS", "the filed plan must come back intact")
        XCTAssertEqual(restored.priorPlan?.route, ["GEP"])
        NRSTEngagement.clear()
        XCTAssertNil(NRSTEngagement.load())
    }

    func testRouteTargetResolvesToTheRankedFieldOrFallsBackToItsCoordinate() throws {
        let near = AirportData.airportsNear(dfw, radiusNm: 25, limit: 128)
        let dfwRow = try XCTUnwrap(near.first(where: { $0.ident == "DFW" }))
        // A charted field the real nav database knows: the ICAO is used, and it resolves AT the field.
        let target = NearestAirports.routeTarget(for: dfwRow) { NavDatabase.resolve($0, near: dfwRow.coord) }
        XCTAssertEqual(target, "KDFW")
        let resolved = try XCTUnwrap(NavDatabase.resolve(target, near: dfwRow.coord))
        XCTAssertLessThan(Geo.nmBetween(resolved, dfwRow.coord), NearestAirports.targetToleranceNm)
        // An ident the database places SOMEWHERE ELSE must not be filed: the ranked airport and its
        // magenta line have to be the same place, so it falls back to the exact coordinate. (An
        // existence-only check accepted the far-away entry, which is the bug this pins.)
        let farAway = Coord(lat: dfwRow.coord.lat + 4, lon: dfwRow.coord.lon + 4)
        let fallback = NearestAirports.routeTarget(for: dfwRow) { _ in farAway }
        XCTAssertEqual(UserPoint.parse(fallback)?.lat ?? 0, dfwRow.coord.lat, accuracy: 0.001)
        XCTAssertEqual(UserPoint.parse(fallback)?.lon ?? 0, dfwRow.coord.lon, accuracy: 0.001)
        // And an ident nothing can resolve also falls back rather than filing an unplottable token.
        XCTAssertNotNil(UserPoint.parse(NearestAirports.routeTarget(for: dfwRow) { _ in nil }))
    }

    func testEngagementFrequencyLinePrefersCtafThenRealTowerFrequencies() throws {
        // DEN publishes local control (NASR "LCL/P") and no CTAF row. Matching the string "TWR" —
        // which is not a FREQ_USE value at all — made the tower tier dead code and printed
        // "UNICOM 122.95" for 247 towered fields, at exactly the Part-139 fields the ranker promotes.
        let denver = AirportData.frequencies(airport: "KDEN")
        try XCTSkipIf(denver.isEmpty, "KDEN absent from this cycle")
        XCTAssertFalse(denver.contains { $0.use.uppercased().hasPrefix("TWR") },
                       "NASR does not use 'TWR' as a frequency use — the old match could never fire")
        let line = try XCTUnwrap(NearestAirports.frequencyLine(from: denver))
        XCTAssertTrue(line.hasPrefix("TWR "), "expected a tower frequency for KDEN, got \(line)")
        XCTAssertFalse(line.contains("122.95"), "122.95 is the aircraft-to-aircraft unicom, not the tower")
        // Tier order is CTAF first where a field publishes one.
        let ctaf = [AirportData.Frequency(value: "122.8", use: "CTAF", sectorization: "", facility: ""),
                    AirportData.Frequency(value: "118.3", use: "LCL/P", sectorization: "", facility: "")]
        XCTAssertEqual(NearestAirports.frequencyLine(from: ctaf), "CTAF 122.8")
        XCTAssertNil(NearestAirports.frequencyLine(from: []))
    }

    func testAirportDatabaseReportsItselfQueryable() {
        // The panel presents "no landable airports" as a fact, so it must be able to tell that claim
        // apart from a data fault. With the shipped cycle bundled this is true; if it ever goes false
        // in CI the NRST panel is showing a data failure as an authoritative negative.
        XCTAssertTrue(AirportData.isQueryable)
    }

    func testClosedFacilitiesExistAndAreExcludedByTheEngine() {
        // NASR carries hundreds of CI/CP records; make sure the engine's operational gate is real
        // by finding one and pushing it through candidate construction.
        let anywhere = AirportData.airportsNear(Coord(lat: 39.0, lon: -95.0), radiusNm: 200, limit: 512)
        let closed = anywhere.filter { !$0.isOperational }
        // Not guaranteed in every 200 NM circle — but the sort/limit caps at 512 nearest, so only
        // assert the flag machinery itself when one shows up.
        for c in closed { XCTAssertNotEqual(c.status.uppercased(), "O") }
        let situation = GlideSituation(coord: Coord(lat: 39.0, lon: -95.0), altitudeFtMSL: 50_000,
                                       glideRatio: 9, isDefaultGlideRatio: false, verticalAccuracyM: 10)
        let a = NearestAirports.assess(situation: situation, airports: anywhere,
                                       runwaysFor: { AirportData.runways(airport: $0) },
                                       weather: [:], terrain: TerrainElevation(), now: Date())
        for c in a.candidates {
            XCTAssertTrue(c.airport.isOperational, "\(c.id) is closed and must never be a glide target")
        }
    }
}
