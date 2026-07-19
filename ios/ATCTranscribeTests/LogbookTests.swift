import XCTest
@testable import ATCTranscribe

/// The flight logbook + the LoggedFlight display/region helpers + the recorder's breadcrumb downsampling.
@MainActor final class LogbookTests: XCTestCase {

    private func flight(start: Date, distance: Double = 100, crumbs: Int = 3) -> LoggedFlight {
        let t0 = start
        let trail = (0..<crumbs).map { i in
            Breadcrumb(t: t0.addingTimeInterval(Double(i) * 60), lat: 42 + Double(i) * 0.1, lon: -71 - Double(i) * 0.1,
                       altFt: 3000, speedKt: 120, track: 90)
        }
        return LoggedFlight(id: UUID(), startedAt: t0, endedAt: t0.addingTimeInterval(3600), durationSec: 3600,
                            distanceNM: distance, maxSpeedKt: 140, avgSpeedKt: 110, maxAltFtMSL: 8500,
                            stops: [], aircraftCallsign: "N8925T", aircraftType: "Seneca", notes: "", breadcrumb: trail)
    }
    private func tempLogbook() -> Logbook {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("logtest-\(UUID().uuidString)")
        return Logbook(directory: dir)
    }

    func testAddInsertsNewestFirst() {
        let lb = tempLogbook()
        let old = flight(start: Date(timeIntervalSince1970: 1_000_000))
        let new = flight(start: Date(timeIntervalSince1970: 2_000_000))
        lb.add(old); lb.add(new)
        XCTAssertEqual(lb.flights.count, 2)
        XCTAssertEqual(lb.flights.first?.id, new.id)          // newest first
    }

    func testDeleteRemoves() {
        let lb = tempLogbook()
        let f = flight(start: Date())
        lb.add(f); XCTAssertEqual(lb.flights.count, 1)
        lb.delete(f.id); XCTAssertTrue(lb.flights.isEmpty)
    }

    func testUpdateReplacesInPlace() {
        let lb = tempLogbook()
        var f = flight(start: Date())
        lb.add(f)
        f.notes = "gusty crosswind at KBOS"
        lb.update(f)
        XCTAssertEqual(lb.flights.first?.notes, "gusty crosswind at KBOS")
        XCTAssertEqual(lb.flights.count, 1)                    // update, not append
    }

    func testPersistsAcrossReload() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("logtest-\(UUID().uuidString)")
        let lb = Logbook(directory: dir)
        lb.add(flight(start: Date()))
        let reopened = Logbook(directory: dir)                 // fresh instance reads the same file
        XCTAssertEqual(reopened.flights.count, 1)
        XCTAssertEqual(reopened.flights.first?.aircraftCallsign, "N8925T")
    }

    func testAddClampsBreadcrumbToCap() {
        let lb = tempLogbook()
        let t0 = Date()
        let big = (0..<(LoggedFlight.maxBreadcrumb + 300)).map { _ in
            Breadcrumb(t: t0, lat: 42, lon: -71, altFt: nil, speedKt: nil, track: nil)
        }
        var f = flight(start: t0)
        f = f.withBreadcrumb(big)
        lb.add(f)
        XCTAssertLessThanOrEqual(lb.flights.first!.breadcrumb.count, LoggedFlight.maxBreadcrumb)
    }

    func testHMSFormatting() {
        XCTAssertEqual(LoggedFlight.hms(0), "0:00")
        XCTAssertEqual(LoggedFlight.hms(65), "1:05")
        XCTAssertEqual(LoggedFlight.hms(3661), "1:01:01")
    }

    func testMapRegionCoversTheTrail() {
        let f = flight(start: Date(), crumbs: 3)
        let region = f.mapRegion
        XCTAssertNotNil(region)
        // center is inside the lat/lon bbox of the 3 points
        XCTAssertEqual(region!.center.lat, 42.1, accuracy: 0.05)
        XCTAssertGreaterThan(region!.spanLat, 0)
    }
    func testMapRegionNilForTooFewPoints() {
        let f = flight(start: Date(), crumbs: 1)
        XCTAssertNil(f.mapRegion)                              // <2 points → nothing to draw
    }

    func testRouteSummaryFromStops() {
        var f = flight(start: Date())
        let s1 = FlightStop(id: UUID(), lat: 42, lon: -71, arrivedAt: Date(), durationSec: 300, airport: "KBOS")
        let s2 = FlightStop(id: UUID(), lat: 41, lon: -73, arrivedAt: Date(), durationSec: 300, airport: "KJFK")
        f = LoggedFlight(id: f.id, startedAt: f.startedAt, endedAt: f.endedAt, durationSec: f.durationSec,
                         distanceNM: f.distanceNM, maxSpeedKt: f.maxSpeedKt, avgSpeedKt: f.avgSpeedKt,
                         maxAltFtMSL: f.maxAltFtMSL, stops: [s1, s2], aircraftCallsign: nil, aircraftType: nil,
                         notes: "", breadcrumb: f.breadcrumb)
        XCTAssertEqual(f.routeSummary, "KBOS → KJFK")
    }

    func testDownsampleKeepsFirstLastAndCaps() {
        let t0 = Date()
        let pts = (0..<1200).map { Breadcrumb(t: t0.addingTimeInterval(Double($0)), lat: Double($0), lon: 0,
                                              altFt: nil, speedKt: nil, track: nil) }
        let out = FlightRecorder.downsampled(pts, to: 500)
        XCTAssertLessThanOrEqual(out.count, 501)              // capped
        XCTAssertEqual(out.first?.lat, 0)                      // kept first
        XCTAssertEqual(out.last?.lat, 1199)                   // kept last
    }
    func testDownsampleNoOpUnderCap() {
        let t0 = Date()
        let pts = (0..<10).map { Breadcrumb(t: t0, lat: Double($0), lon: 0, altFt: nil, speedKt: nil, track: nil) }
        XCTAssertEqual(FlightRecorder.downsampled(pts, to: 500).count, 10)
    }
}
