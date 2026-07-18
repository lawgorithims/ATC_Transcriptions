import XCTest
@testable import ATCTranscribe

/// Decoding the Stratux web API (`/traffic` WebSocket targets + `/getSituation` GPS) into CommSight's
/// `Aircraft` / `StratuxGPS`. The live link is verified on the device; this pins the JSON contract.
final class StratuxTests: XCTestCase {

    // MARK: /traffic → Aircraft

    func testTrafficDecodesToAircraft() throws {
        let json = """
        { "Icao_addr": 11259375, "Reg": "N172SP", "Tail": "N172SP", "Lat": 42.36, "Lng": -71.01,
          "Position_valid": true, "Alt": 3500, "OnGround": false, "Speed": 120, "Speed_valid": true,
          "Track": 270.0, "Distance": 9260.0, "Age": 2.0 }
        """.data(using: .utf8)!
        let at = Date()
        let ac = try JSONDecoder().decode(StratuxTraffic.self, from: json).aircraft(receivedAt: at)!
        XCTAssertEqual(ac.hex, "abcdef")               // 11259375 == 0xABCDEF
        XCTAssertEqual(ac.callsign, "N172SP")
        XCTAssertEqual(ac.registration, "N172SP")
        XCTAssertEqual(ac.lat ?? 0, 42.36, accuracy: 0.001)
        XCTAssertEqual(ac.lon ?? 0, -71.01, accuracy: 0.001)
        XCTAssertEqual(ac.altBaroFt, 3500)
        XCTAssertFalse(ac.onGround)
        XCTAssertEqual(ac.gsKt ?? 0, 120, accuracy: 0.001)
        XCTAssertEqual(ac.distanceNm ?? 0, 9260.0 / 1852.0, accuracy: 0.001)   // metres → 5.0 NM
        XCTAssertFalse(ac.isStale(window: 30, now: at))
    }

    func testTrafficWithoutPositionHasNoCoordinate() throws {
        let json = #"{ "Icao_addr": 100, "Tail": "DAL123", "Position_valid": false, "Age": 1.0 }"#.data(using: .utf8)!
        let ac = try JSONDecoder().decode(StratuxTraffic.self, from: json).aircraft(receivedAt: Date())!
        XCTAssertNil(ac.lat); XCTAssertNil(ac.lon); XCTAssertNil(ac.coordinate)
        XCTAssertEqual(ac.callsign, "DAL123")          // still useful for the corrector even without a fix
    }

    func testTrafficOnGroundHasNoAltitude() throws {
        let json = #"{ "Icao_addr": 200, "Tail": "N1  ", "Position_valid": true, "Lat": 1, "Lng": 2, "Alt": 0, "OnGround": true, "Age": 0 }"#.data(using: .utf8)!
        let ac = try JSONDecoder().decode(StratuxTraffic.self, from: json).aircraft(receivedAt: Date())!
        XCTAssertTrue(ac.onGround)
        XCTAssertNil(ac.altBaroFt)
        XCTAssertEqual(ac.callsign, "N1")              // space-padded Tail trimmed
    }

    func testZeroIcaoDropped() throws {
        let json = #"{ "Icao_addr": 0, "Tail": "X", "Age": 0 }"#.data(using: .utf8)!
        XCTAssertNil(try JSONDecoder().decode(StratuxTraffic.self, from: json).aircraft(receivedAt: Date()))
    }

    func testTrafficStaleByAge() {
        // `Age` is the offset back to the last fix; anchored to receivedAt it must age out like
        // airplanes.live's `seen`. 90 s old with a 60 s window → stale.
        let traf = StratuxTraffic(icaoAddr: 1, tail: nil, reg: nil, lat: 1, lng: 2, positionValid: true,
                                  alt: 1000, onGround: false, speed: nil, speedValid: nil, track: nil,
                                  distanceMeters: nil, ageSec: 90)
        let at = Date()
        XCTAssertTrue(traf.aircraft(receivedAt: at)!.isStale(window: 60, now: at))
    }

    // MARK: /getSituation → StratuxGPS

    func testSituationDecodesGPS() throws {
        let json = """
        { "GPSLatitude": 42.3656, "GPSLongitude": -71.0096, "GPSFixQuality": 2, "GPSSatellites": 11,
          "GPSAltitudeMSL": 230.0, "GPSGroundSpeed": 0.0, "GPSTrueCourse": 145.0 }
        """.data(using: .utf8)!
        let gps = try JSONDecoder().decode(StratuxSituation.self, from: json).gps
        XCTAssertTrue(gps.hasFix)
        XCTAssertEqual(gps.fixQuality, 2)
        XCTAssertEqual(gps.fixLabel, "WAAS")
        XCTAssertEqual(gps.satellites, 11)
        XCTAssertEqual(gps.trackDeg ?? -1, 145.0, accuracy: 0.01)   // GPSTrueCourse now flows into the readout
        XCTAssertEqual(gps.coordinate?.lat ?? 0, 42.3656, accuracy: 0.0001)
        XCTAssertEqual(gps.coordinate?.lon ?? 0, -71.0096, accuracy: 0.0001)
    }

    func testSituationNoFixWhenZeroZero() throws {
        let json = #"{ "GPSLatitude": 0, "GPSLongitude": 0, "GPSFixQuality": 0, "GPSSatellites": 0 }"#.data(using: .utf8)!
        let gps = try JSONDecoder().decode(StratuxSituation.self, from: json).gps
        XCTAssertFalse(gps.hasFix)
        XCTAssertNil(gps.coordinate)                   // (0,0) sentinel → no coordinate
        XCTAssertEqual(gps.fixLabel, "no fix")
    }

    // MARK: audio.raw PCM byte parsing (a boundary bug would corrupt the cockpit audio)

    func testPCM16DecodesAlignedBlock() {
        let data = Data([0x00, 0x01,   // 0x0100 LE = 256
                         0xFF, 0xFF,   // -1
                         0x00, 0x80])  // -32768
        let (s, carry) = StratuxAudioSource.decodePCM16(data, carry: nil)
        XCTAssertNil(carry)
        XCTAssertEqual(s.count, 3)
        XCTAssertEqual(s[0], 256.0 / 32768.0, accuracy: 1e-6)
        XCTAssertEqual(s[1], -1.0 / 32768.0, accuracy: 1e-6)
        XCTAssertEqual(s[2], -1.0, accuracy: 1e-6)
    }

    func testPCM16CarriesAcrossOddSplit() {
        // A sample whose two bytes land in different network blocks must reconstruct identically.
        let whole = StratuxAudioSource.decodePCM16(Data([0x12, 0x34]), carry: nil).samples
        let (a, c1) = StratuxAudioSource.decodePCM16(Data([0x12]), carry: nil)
        XCTAssertTrue(a.isEmpty); XCTAssertEqual(c1, 0x12)
        let (b, c2) = StratuxAudioSource.decodePCM16(Data([0x34]), carry: c1)
        XCTAssertNil(c2)
        XCTAssertEqual(b, whole)
    }

    func testPCM16EmptyBlockKeepsCarry() {
        let (s, c) = StratuxAudioSource.decodePCM16(Data(), carry: 0x42)
        XCTAssertTrue(s.isEmpty)
        XCTAssertEqual(c, 0x42)            // an empty block must NOT drop a pending half-sample
    }

    func testPCM16OddTrailingByteCarried() {
        let (s, c) = StratuxAudioSource.decodePCM16(Data([0x00, 0x01, 0x99]), carry: nil)
        XCTAssertEqual(s.count, 1)         // one full pair
        XCTAssertEqual(c, 0x99)            // trailing byte carried to the next block
    }
}
