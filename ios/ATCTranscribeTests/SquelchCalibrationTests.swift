import XCTest
@testable import ATCTranscribe

/// The pure math behind mic squelch calibration: turning a measured (ambient, voice) RMS pair into a
/// gate, and mapping that gate onto the manual-squelch slider. The mic capture itself (`MicCalibrator`)
/// is device-only and not exercised here.
final class SquelchCalibrationTests: XCTestCase {

    func testGateIsGeometricMeanBetweenLevels() {
        let a: Float = 0.02, s: Float = 0.20
        let g = SquelchCalibration.gate(ambientRMS: a, speechRMS: s)
        XCTAssertNotNil(g)
        XCTAssertEqual(g!, (a * s).squareRoot(), accuracy: 1e-6)   // ≈ 0.0632
        XCTAssertGreaterThan(g!, a, "gate must sit above the room floor")
        XCTAssertLessThan(g!, s, "gate must sit below the voice level")
    }

    func testGateNilWhenVoiceNotClearlyLouder() {
        // ratio 1.4 < minRatio → the two levels are too close to separate → nil (ask the user to retry).
        XCTAssertNil(SquelchCalibration.gate(ambientRMS: 0.05, speechRMS: 0.07))
    }

    func testGateAtMinRatioBoundary() {
        let a: Float = 0.05
        XCTAssertNotNil(SquelchCalibration.gate(ambientRMS: a, speechRMS: a * SquelchCalibration.minRatio))
        XCTAssertNil(SquelchCalibration.gate(ambientRMS: a, speechRMS: a * (SquelchCalibration.minRatio - 0.05)))
    }

    func testGateNilForNonPositiveInputs() {
        XCTAssertNil(SquelchCalibration.gate(ambientRMS: 0, speechRMS: 0.2))
        XCTAssertNil(SquelchCalibration.gate(ambientRMS: 0.02, speechRMS: 0))
    }

    func testGateKeepsMarginOnBothSides() {
        // Geometric mean guarantees ≥ √minRatio(≈1.34)× above ambient AND ≤ 1/√minRatio(≈0.75)× of
        // the voice, for any ratio ≥ minRatio — so the room never trips it and the voice always does.
        let a: Float = 0.03, s: Float = 0.03 * 4   // ratio 4 → gate = 2a
        let g = SquelchCalibration.gate(ambientRMS: a, speechRMS: s)!
        XCTAssertGreaterThanOrEqual(g, a * 1.34)
        XCTAssertLessThanOrEqual(g, s * 0.75)
    }

    // The calibrated gate maps onto the manual-squelch 0…1 range and back, so the slider reflects the
    // calibration and the VAD reconstructs the same absolute gate.
    func testManualLevelRoundTripsGate() {
        let gate: Float = 0.06
        let level = VADSegmenter.manualLevel(forGateRMS: gate)
        XCTAssertEqual(level, gate / VADSegmenter.manualGateMaxRMS, accuracy: 1e-6)
        XCTAssertEqual(level * VADSegmenter.manualGateMaxRMS, gate, accuracy: 1e-6)
    }

    func testManualLevelClamps() {
        XCTAssertEqual(VADSegmenter.manualLevel(forGateRMS: 10.0), 1.0, accuracy: 1e-6)
        XCTAssertEqual(VADSegmenter.manualLevel(forGateRMS: -1.0), 0.0, accuracy: 1e-6)
    }
}
