import XCTest
@testable import ATCTranscribe

/// The merged GPS readout: Stratux preferred, on-device CoreLocation as the contingency, unit conversions,
/// and the invalid-sentinel handling that keeps a stationary device from showing bogus speed/track.
final class GPSReadoutTests: XCTestCase {

    private func device(acc: Double, alt: Double? = nil, spd: Double? = nil, crs: Double? = nil) -> DeviceFix {
        DeviceFix(coord: Coord(lat: 42, lon: -71), altitudeMSLm: alt, groundSpeedMps: spd,
                  courseDeg: crs, horizontalAccuracyM: acc)
    }
    private func stratux(q: Int, sats: Int = 9, altFt: Double? = 3500, kt: Double? = 120, trk: Double? = 270) -> StratuxGPS {
        StratuxGPS(coordinate: Coord(lat: 42, lon: -71), fixQuality: q, satellites: sats,
                   altMSLft: altFt, groundSpeedKt: kt, trackDeg: trk)
    }

    func testStratuxPreferredWhenItHasAFix() {
        let r = GPSReadout.merge(stratux: stratux(q: 2), device: device(acc: 5))
        XCTAssertEqual(r.source, .stratux)
        XCTAssertEqual(r.fixQuality, .excellent)          // WAAS
        XCTAssertEqual(r.satellites, 9)
        XCTAssertEqual(r.altitudeFtMSL, 3500)
        XCTAssertEqual(r.groundSpeedKt, 120)
        XCTAssertEqual(r.trackDeg, 270)
        XCTAssertNil(r.horizontalAccuracyM)               // Stratux reports sats, not an accuracy
    }

    func testFallsBackToDeviceWhenStratuxHasNoFix() {
        let noFix = StratuxGPS(coordinate: nil, fixQuality: 0, satellites: 0, altMSLft: nil, groundSpeedKt: nil, trackDeg: nil)
        let r = GPSReadout.merge(stratux: noFix, device: device(acc: 6, alt: 100, spd: 50, crs: 90))
        XCTAssertEqual(r.source, .device)
        XCTAssertEqual(r.satellites, nil)
        XCTAssertEqual(r.horizontalAccuracyM, 6)
        XCTAssertEqual(r.altitudeFtMSL ?? 0, 100 * 3.280839895, accuracy: 0.01)   // m → ft
        XCTAssertEqual(r.groundSpeedKt ?? 0, 50 * 1.9438444924, accuracy: 0.01)   // m/s → kt
        XCTAssertEqual(r.trackDeg, 90)
    }

    func testNoneWhenBothUnavailable() {
        XCTAssertEqual(GPSReadout.merge(stratux: nil, device: nil), .none)
        XCTAssertEqual(GPSReadout.merge(stratux: nil, device: nil).source, .none)
    }

    func testDeviceInvalidSpeedAndCourseSurfaceAsNil() {
        // DeviceLocation resolves CLLocation's -1 sentinels to nil BEFORE building DeviceFix; a parked device
        // therefore shows "—" for speed/track, never a bogus value.
        let r = GPSReadout.merge(stratux: nil, device: device(acc: 12, alt: 80, spd: nil, crs: nil))
        XCTAssertEqual(r.source, .device)
        XCTAssertNil(r.groundSpeedKt)
        XCTAssertNil(r.trackDeg)
        XCTAssertNotNil(r.altitudeFtMSL)
    }

    func testDeviceQualityFromHorizontalAccuracy() {
        XCTAssertEqual(FixQuality(horizontalAccuracyM: 5), .excellent)
        XCTAssertEqual(FixQuality(horizontalAccuracyM: 15), .good)
        XCTAssertEqual(FixQuality(horizontalAccuracyM: 30), .fair)
        XCTAssertEqual(FixQuality(horizontalAccuracyM: 100), .poor)
        XCTAssertEqual(FixQuality(horizontalAccuracyM: 500), .none)
        XCTAssertEqual(FixQuality(horizontalAccuracyM: -1), .none)   // invalid accuracy
    }

    func testStratuxQualityFromFixType() {
        XCTAssertEqual(FixQuality(stratux: 0), .none)
        XCTAssertEqual(FixQuality(stratux: 1), .good)        // 3D
        XCTAssertEqual(FixQuality(stratux: 2), .excellent)   // WAAS
        XCTAssertEqual(FixQuality(stratux: 2).bars, 4)
    }
}
