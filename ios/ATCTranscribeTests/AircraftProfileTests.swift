import XCTest
@testable import ATCTranscribe

/// `AircraftProfile` + `AircraftStore` — the flight-plan strip's saved-aircraft hangar.
final class AircraftProfileTests: XCTestCase {

    override func tearDown() {
        AircraftStore.clear()   // don't leak saved profiles into other tests / the running app
        super.tearDown()
    }

    private func seneca() -> AircraftProfile {
        AircraftProfile(callsign: "N8925T", type: "Piper Seneca", cruiseKts: 165, burnGPH: 16.5)
    }

    func testDisplayLine() {
        XCTAssertEqual(seneca().displayLine, "N8925T · Piper Seneca")
        XCTAssertEqual(AircraftProfile(callsign: "N8925T", type: "").displayLine, "N8925T")
        XCTAssertEqual(AircraftProfile().displayLine, "Aircraft", "empty profile falls back to the label")
    }

    func testStoreRoundTrip() {
        let hangar = [seneca(), AircraftProfile(callsign: "N345AB", type: "Cessna 172")]
        AircraftStore.save(hangar)
        let back = AircraftStore.load()
        XCTAssertEqual(back, hangar)
        XCTAssertEqual(back.first?.cruiseKts, 165)
        XCTAssertEqual(back.first?.burnGPH, 16.5)
    }

    func testStoreDropsEmptyAndClears() {
        AircraftStore.save([AircraftProfile()])                 // only an empty profile
        XCTAssertTrue(AircraftStore.load().isEmpty, "empty profiles are not worth persisting")
        AircraftStore.save([seneca()])
        AircraftStore.save([])                                  // empty list clears storage
        XCTAssertTrue(AircraftStore.load().isEmpty)
    }

    func testStoreBounded() {
        let many = (0..<50).map { AircraftProfile(callsign: "N\($0)X", type: "T") }
        AircraftStore.save(many)
        XCTAssertLessThanOrEqual(AircraftStore.load().count, AircraftStore.maxProfiles)
    }

    func testUndecodableStorageDegradesToEmpty() {
        UserDefaults.standard.set(Data("not json".utf8), forKey: AircraftStore.storageKey)
        XCTAssertTrue(AircraftStore.load().isEmpty)
    }
}
