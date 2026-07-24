import XCTest
@testable import ATCTranscribe

/// ATC-assigned values on FlightPlan: excluded from `isEmpty`, Codable round-trip, ephemeral on reload,
/// and kept out of the corrector context / ForeFlight export.
final class FlightPlanAssignmentTests: XCTestCase {

    func testAssignmentAloneIsEmpty() {
        var p = FlightPlan()
        p.assignedAltitudeFt = 5000
        XCTAssertTrue(p.isEmpty, "an assignment alone is not a filed plan")
        XCTAssertTrue(p.hasAssignments)
    }

    func testAssignmentWithCallsignNotEmpty() {
        var p = FlightPlan()
        p.callsign = "N8925T"
        p.assignedSquawk = "4231"
        XCTAssertFalse(p.isEmpty)
        XCTAssertTrue(p.hasAssignments)
    }

    func testClearAssignments() {
        var p = FlightPlan()
        p.assignedAltitudeFt = 5000; p.assignedHeadingDeg = 270; p.activeFrequency = "Tower 124.5"
        p.clearAssignments()
        XCTAssertFalse(p.hasAssignments)
    }

    func testCodableRoundTrip() throws {
        var p = FlightPlan()
        p.callsign = "N1"; p.assignedAltitudeFt = 8000; p.activeFrequency = "Tower 124.5"; p.assignedSquawk = "4231"
        let back = try JSONDecoder().decode(FlightPlan.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(back.assignedAltitudeFt, 8000)
        XCTAssertEqual(back.activeFrequency, "Tower 124.5")
        XCTAssertEqual(back.assignedSquawk, "4231")
    }

    func testOldPlanDecodesWithNilAssignments() throws {
        let json = #"{"aircraftType":"","callsign":"N1","departure":"","destination":"","alternate":"","route":[],"savedAt":0}"#
        let back = try JSONDecoder().decode(FlightPlan.self, from: Data(json.utf8))
        XCTAssertNil(back.assignedAltitudeFt)
        XCTAssertNil(back.assignedSquawk)
    }

    func testAssignmentsNotInContextOrExport() {
        var p = FlightPlan()
        p.callsign = "N1"; p.departure = "KBOS"; p.destination = "KJFK"
        p.assignedAltitudeFt = 8000; p.assignedSquawk = "4231"; p.activeFrequency = "Tower 124.5"
        XCTAssertFalse(p.contextBlock.contains("8000"), "assigned altitude must not bias the corrector")
        XCTAssertFalse(p.contextBlock.contains("4231"))
        XCTAssertFalse(p.vocabTerms.contains("4231"))
        // The ForeFlight route export must be identical with or without the assignments.
        var bare = p; bare.clearAssignments()
        XCTAssertEqual(ForeFlightExport.url(for: p), ForeFlightExport.url(for: bare))
    }
}
