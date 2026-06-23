import XCTest
@testable import ATCTranscribe

/// Verifies the Swift audio preprocessing matches the Python: the biquad filters are
/// parity-checked against SciPy `sosfiltfilt` (fixtures from Tools/gen_filter_fixtures.py),
/// the STFT reconstructs via round-trip, and the full pipeline is well-behaved.
final class AudioPreprocessorTests: XCTestCase {

    /// Deterministic test signal: 100 Hz (below HP) + 1000 Hz (passband) + 0.5·5000 Hz.
    /// Identical to the signal in gen_filter_fixtures.py so the fixtures line up.
    private static func signal(_ n: Int = 4000) -> [Double] {
        (0..<n).map { i in
            let t = Double(i)
            return sin(2 * .pi * 100 * t / 16000)
                 + sin(2 * .pi * 1000 * t / 16000)
                 + 0.5 * sin(2 * .pi * 5000 * t / 16000)
        }
    }

    // SciPy sosfiltfilt outputs at these interior indices (from gen_filter_fixtures.py).
    private static let parityIndices = [500, 1000, 2000, 3000, 3500]
    private static let expectedHP5: [Double] = [1.4999779118, 0.0000035730, -0.0000000000, -0.0000035730, -1.4999779120]
    private static let expectedBP4: [Double] = [1.0082517402, 0.0004506457, -0.0000000000, -0.0004506457, -1.0082517489]

    func testHighpassMatchesSciPy() {
        let y = SOSFilter(sections: Biquad.hp5_350).filtfilt(Self.signal())
        for (k, idx) in Self.parityIndices.enumerated() {
            XCTAssertEqual(y[idx], Self.expectedHP5[k], accuracy: 1e-3, "hp5 @\(idx)")
        }
    }

    func testBandpassMatchesSciPy() {
        let y = SOSFilter(sections: Biquad.bp4_250_3800).filtfilt(Self.signal())
        for (k, idx) in Self.parityIndices.enumerated() {
            XCTAssertEqual(y[idx], Self.expectedBP4[k], accuracy: 1e-3, "bp4 @\(idx)")
        }
    }

    func testSTFTRoundTripReconstructs() throws {
        let stft = try XCTUnwrap(STFT(nFFT: 2048, hop: 512))
        let x = Self.signal(8000)
        let y = stft.processGating(x) { $0 }          // identity gate → reconstruct input
        XCTAssertEqual(y.count, x.count)
        for idx in [1000, 2000, 4000, 6000, 7000] {
            XCTAssertEqual(y[idx], x[idx], accuracy: 1e-3, "round-trip @\(idx)")
        }
    }

    func testPipelineIsWellBehaved() {
        let out = AudioPreprocessor(aggressiveRadio: true).preprocess(Self.signal().map(Float.init))
        XCTAssertEqual(out.count, 4000)
        XCTAssertTrue(out.allSatisfy { $0.isFinite })
        let peak = out.map { Swift.abs($0) }.max() ?? 0
        XCTAssertLessThanOrEqual(peak, 0.9501)         // normalized to 0.95 peak
        XCTAssertGreaterThan(peak, 0.0)
    }
}
