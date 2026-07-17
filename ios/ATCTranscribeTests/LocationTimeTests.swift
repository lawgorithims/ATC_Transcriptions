import XCTest
@testable import ATCTranscribe

/// Offline coordinate → local time zone (used to show weather/NOTAM Zulu times in local clock time).
final class LocationTimeTests: XCTestCase {

    func testUSZonesResolveToRealIdentifiers() {
        XCTAssertEqual(LocationTime.timeZone(lat: 42.36, lon: -71.01)?.identifier, "America/New_York")   // Boston
        XCTAssertEqual(LocationTime.timeZone(lat: 41.98, lon: -87.90)?.identifier, "America/Chicago")    // Chicago ORD
        XCTAssertEqual(LocationTime.timeZone(lat: 39.86, lon: -104.67)?.identifier, "America/Denver")    // Denver
        XCTAssertEqual(LocationTime.timeZone(lat: 33.94, lon: -118.41)?.identifier, "America/Los_Angeles") // LAX
        XCTAssertEqual(LocationTime.timeZone(lat: 33.43, lon: -112.01)?.identifier, "America/Phoenix")   // Phoenix (no DST)
        XCTAssertEqual(LocationTime.timeZone(lat: 61.17, lon: -149.99)?.identifier, "America/Anchorage") // Anchorage
        XCTAssertEqual(LocationTime.timeZone(lat: 21.32, lon: -157.92)?.identifier, "Pacific/Honolulu")  // Honolulu
    }

    func testNonUSFallsBackToLongitudeOffset() {
        // London → whole-hour offset from longitude ~0 → UTC.
        let tz = LocationTime.timeZone(lat: 51.47, lon: -0.45)
        XCTAssertEqual(tz?.secondsFromGMT(), 0)
        // Tokyo lon ~139.8 → round(139.8/15)=9 → +9h.
        XCTAssertEqual(LocationTime.timeZone(lat: 35.55, lon: 139.78)?.secondsFromGMT(), 9 * 3600)
    }

    func testLocalTimeFormatting() {
        // 2026-07-16 04:39Z is 2026-07-16 00:39 EDT at Boston (UTC-4 in July).
        let d = Date(timeIntervalSince1970: 1_784_176_740)   // 2026-07-16T04:39:00Z
        let s = LocationTime.localTime(d, lat: 42.36, lon: -71.01)
        XCTAssertNotNil(s)
        XCTAssertTrue(s!.contains("EDT"), "summer → daylight time: \(s!)")
        XCTAssertTrue(s!.contains("12:39") || s!.contains("00:39"), "converted to local clock: \(s!)")
    }

    func testOutOfRangeCoordIsNil() {
        XCTAssertNil(LocationTime.timeZone(lat: 200, lon: 0))
        XCTAssertNil(LocationTime.localTime(Date(), lat: 0, lon: 999))
    }
}
