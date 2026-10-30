import XCTest
@testable import ATCTranscribe

/// The flight briefing's one hard rule: the turn-back altitude is the pilot's own number. The app
/// converts it to what the altimeter reads and puts today's density altitude beside it — and never
/// produces, adjusts or defaults it.
final class FlightBriefingTests: XCTestCase {

    private func plane(_ tb: Int? = nil, setDA: Int? = nil, on: Date? = nil, rotor: Bool = false) -> AircraftProfile {
        var a = AircraftProfile()
        a.callsign = "N123AB"
        a.type = "Cessna 172S"
        a.turnbackMinimumFtAGL = tb
        a.turnbackSetAtDensityAltitudeFt = setDA
        a.turnbackSetOn = on
        a.isRotorcraft = rotor ? true : nil
        return a
    }

    private func departure(elev: Int? = 4457, da: Int? = nil) -> FlightBriefing.Departure {
        FlightBriefing.Departure(ident: "KLRU", fieldElevationFt: elev, windText: nil, densityAltitudeFt: da,
                                 weatherAgeMin: nil, runways: [])
    }

    func testNoNumberMeansLandAheadAndNoNumberIsInvented() {
        XCTAssertEqual(FlightBriefing.turnback(aircraft: plane(), callsign: "N123AB", departure: departure(), now: Date()),
                       .notSet(callsign: "N123AB"))
        XCTAssertEqual(FlightBriefing.turnback(aircraft: nil, callsign: nil, departure: departure(), now: Date()),
                       .noAircraft)
        XCTAssertEqual(FlightBriefing.turnback(aircraft: plane(1000, rotor: true), callsign: nil,
                                               departure: departure(), now: Date()), .rotorcraft)
    }

    func testThePilotsNumberIsOnlyConvertedToAnAltimeterReading() throws {
        guard case .set(let p) = FlightBriefing.turnback(aircraft: plane(1000, setDA: 3000, on: Date()),
                                                         callsign: nil, departure: departure(da: 3200), now: Date())
        else { return XCTFail("expected a set plan") }
        XCTAssertEqual(p.aglFt, 1000, "the pilot's number must come back unchanged")
        XCTAssertEqual(p.altimeterFt, 5457, "field elevation + the pilot's number, nothing else")
        XCTAssertFalse(p.densityAltitudeCaution, "200 ft above the set conditions is not a caution")
        XCTAssertFalse(p.practiceStale)
    }

    func testAHigherDensityAltitudeThanTheNumberWasSetInIsCalledOut() {
        guard case .set(let p) = FlightBriefing.turnback(aircraft: plane(1000, setDA: 3000, on: Date()),
                                                         callsign: nil, departure: departure(da: 7800), now: Date())
        else { return XCTFail("expected a set plan") }
        XCTAssertTrue(p.densityAltitudeCaution)
        XCTAssertEqual(p.aglFt, 1000, "a caution, never an adjusted number")
    }

    func testUnrecordedConditionsAreCautionedOnlyWhenTodayIsHigh() {
        guard case .set(let high) = FlightBriefing.turnback(aircraft: plane(800), callsign: nil,
                                                            departure: departure(da: 6000), now: Date()),
              case .set(let low) = FlightBriefing.turnback(aircraft: plane(800), callsign: nil,
                                                           departure: departure(da: 1200), now: Date()),
              case .set(let unknown) = FlightBriefing.turnback(aircraft: plane(800), callsign: nil,
                                                               departure: departure(da: nil), now: Date())
        else { return XCTFail("expected set plans") }
        XCTAssertTrue(high.densityAltitudeCaution)
        XCTAssertFalse(low.densityAltitudeCaution)
        XCTAssertFalse(unknown.densityAltitudeCaution, "no weather is reported as unknown, not as a caution")
        XCTAssertTrue(high.practiceStale, "a number with no practice date asks to be practised")
    }

    func testPracticeOverAYearAgoIsStale() {
        let old = Date().addingTimeInterval(-400 * 86_400)
        guard case .set(let p) = FlightBriefing.turnback(aircraft: plane(1000, on: old), callsign: nil,
                                                         departure: departure(), now: Date())
        else { return XCTFail("expected a set plan") }
        XCTAssertTrue(p.practiceStale)
    }

    func testDensityAltitudeFollowsThePilotsRule() {
        // Standard day at sea level is ~0 ft; KLRU 4,457 ft, 30.12 inHg, 30 °C → PA 4,257, DA ≈ 7,041.
        XCTAssertEqual(FlightBriefing.densityAltitudeFt(fieldElevationFt: 0, altimeterHPa: 1013.25, tempC: 15), 0,
                       accuracy: 15)
        XCTAssertEqual(FlightBriefing.densityAltitudeFt(fieldElevationFt: 4457, altimeterHPa: 30.12 * 33.8639,
                                                        tempC: 30), 7041, accuracy: 15)
    }

    func testTheAltimeterIsReadFromTheFeedOrTheRawReport() {
        XCTAssertEqual(Metar.plausibleHPa(1013.2) ?? 0, 1013.2, accuracy: 0.01)
        XCTAssertEqual(Metar.plausibleHPa(29.92) ?? 0, 1013.2, accuracy: 0.1, "inHg must be converted, not read as hPa")
        XCTAssertNil(Metar.plausibleHPa(9999))
        XCTAssertEqual(Metar.altimeterFromRaw("KLRU 251753Z 24012KT 10SM CLR 30/M02 A3012 RMK AO2") ?? 0,
                       1019.9, accuracy: 0.2)
        XCTAssertEqual(Metar.altimeterFromRaw("EGLL 251750Z 24012KT 9999 FEW030 12/06 Q1009") ?? 0, 1009, accuracy: 0.01)
        XCTAssertNil(Metar.altimeterFromRaw("KLRU 251753Z 24012KT 10SM CLR"))
    }

    func testRunwayWindComponentsUseTrueHeadingsIntoWindFirst() {
        let ends = [AirportData.RunwayEnd(runway: "04/22", end: "22", trueAlignmentDeg: 220, coord: nil, elevationFt: nil,
                                          touchdownZoneElevationFt: nil, displacedThresholdFt: nil, landingDistanceFt: nil,
                                          vgsi: "", approachLights: ""),
                    AirportData.RunwayEnd(runway: "04/22", end: "04", trueAlignmentDeg: 40, coord: nil, elevationFt: nil,
                                          touchdownZoneElevationFt: nil, displacedThresholdFt: nil, landingDistanceFt: nil,
                                          vgsi: "", approachLights: "")]
        let json = #"{"icaoId":"KLRU","wdir":240,"wspd":10,"temp":20,"altim":1013.2,"obsTime":\#(Int(Date().timeIntervalSince1970))}"#
        let metar = try? JSONDecoder().decode(Metar.self, from: Data(json.utf8))
        let d = FlightBriefing.departure("KLRU", airport: nil, ends: ends, metar: metar, now: Date())
        XCTAssertEqual(d.runways.first?.end, "22", "the into-wind runway first")
        XCTAssertEqual(d.runways.first?.headwindKt, 9)
        XCTAssertEqual(d.runways.first?.crosswindKt, 3, "20° right of the nose is a crosswind from the right")
        XCTAssertEqual(d.runways.last?.headwindKt, -9, "the other end is a tailwind, and says so")
        XCTAssertNil(d.densityAltitudeFt, "no field elevation, no density altitude — never a guess")
    }
}
