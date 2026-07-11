import XCTest
@testable import ATCTranscribe

/// Validates the on-device ECAPA embedder (Stage 5b) end-to-end in the simulator: it loads the
/// bundled Core ML model, embeds the bundled real ATC clips, and checks the embeddings are
/// well-formed AND discriminative (same-speaker closer than different-speaker). Skips cleanly when
/// the 80 MB model isn't bundled (e.g. a lean CI checkout), so it never blocks the suite.
final class CoreMLSpeakerEmbedderTests: XCTestCase {

    private func audio(_ file: String) throws -> [Float] {
        let url = try XCTUnwrap(
            Bundle.main.url(forResource: file, withExtension: "wav", subdirectory: "DemoClips")
                ?? Bundle.main.url(forResource: file, withExtension: "wav"),
            "bundled clip \(file) missing")
        let data = try Data(contentsOf: url)
        return data.dropFirst(44).withUnsafeBytes { raw in
            raw.bindMemory(to: Int16.self).map { Float($0) / 32768.0 }
        }
    }

    private func embedderOrSkip() throws -> CoreMLSpeakerEmbedder {
        let e = CoreMLSpeakerEmbedder()
        try XCTSkipUnless(e.isAvailable, "ECAPA.mlmodelc not bundled — skipping on-device embedder test")
        return e
    }

    func testEmbeddingsAreWellFormed() throws {
        let e = try embedderOrSkip()
        for clip in ["usgold_dfw_aal2124", "usgold_bna_ual1616", "usgold_sfo_ils28r"] {
            let v = try XCTUnwrap(e.embed(try audio(clip)), "embed returned nil for \(clip)")
            XCTAssertEqual(v.count, CoreMLSpeakerEmbedder.dims)
            var sumSq: Float = 0
            for x in v { XCTAssertTrue(x.isFinite); sumSq += x * x }
            XCTAssertEqual(sumSq.squareRoot(), 1.0, accuracy: 1e-3, "embedding must be L2-normalized")
        }
    }

    func testSameSpeakerCloserThanDifferentSpeaker() throws {
        let e = try embedderOrSkip()
        let model = SpeakerModel()   // provides the cosine distance
        // Two halves of ONE clip = same speaker; a different clip = different speaker.
        let a = try audio("usgold_dfw_aal2124")
        let mid = a.count / 2
        let h1 = try XCTUnwrap(e.embed(Array(a[0..<mid])))
        let h2 = try XCTUnwrap(e.embed(Array(a[mid...])))
        let other = try XCTUnwrap(e.embed(try audio("usgold_sfo_ils28r")))
        let within = model.dist(h1, h2)
        let cross = model.dist(h1, other)
        XCTAssertLessThan(within, cross,
                          "same-speaker halves (\(within)) must be closer than a different speaker (\(cross))")
    }

    func testTooShortAudioReturnsNil() throws {
        let e = try embedderOrSkip()
        XCTAssertNil(e.embed([Float](repeating: 0.01, count: 100)), "sub-25ms audio must return nil")
    }

    func testMissingModelIsUnavailable() {
        let e = CoreMLSpeakerEmbedder(modelURL: URL(fileURLWithPath: "/no/such/ECAPA.mlmodelc"))
        XCTAssertFalse(e.isAvailable)
        XCTAssertNil(e.embed([Float](repeating: 0.1, count: 48_000)))
    }

    // MARK: - SpeakerModel optional backend

    func testSpeakerModelDefaultsToMFCC() {
        let model = SpeakerModel()   // no embedder → MFCC backend + MFCC-scale thresholds
        XCTAssertEqual(model.newSpeakerDist, 0.05, accuracy: 1e-6)
        XCTAssertEqual(model.mergeDist, 0.03, accuracy: 1e-6)
        XCTAssertEqual(model.fingerprint([Float](repeating: 0.1, count: 16_000)).count, 13)
    }

    func testSpeakerModelUsesECAPABackendWhenGiven() throws {
        let e = try embedderOrSkip()
        let model = SpeakerModel(embedder: e)
        // Fingerprint is now the 192-dim ECAPA embedding, and ECAPA-scale thresholds are in effect.
        let a = try audio("usgold_dfw_aal2124")
        XCTAssertEqual(model.fingerprint(a).count, CoreMLSpeakerEmbedder.dims)
        XCTAssertGreaterThan(model.newSpeakerDist, 0.3)
        XCTAssertGreaterThan(model.mergeDist, 0.3)
        // Same-speaker halves closer than a different speaker, through SpeakerModel's own dist.
        let mid = a.count / 2
        let within = model.dist(model.fingerprint(Array(a[0..<mid])), model.fingerprint(Array(a[mid...])))
        let cross = model.dist(model.fingerprint(Array(a[0..<mid])), model.fingerprint(try audio("usgold_sfo_ils28r")))
        XCTAssertLessThan(within, cross)
    }
}
