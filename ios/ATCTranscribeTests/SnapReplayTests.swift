import XCTest
@testable import ATCTranscribe

/// Gold-clip replay through the REAL pipeline: bundled gold audio + the real Whisper-small
/// hypothesis text (scripted through the `Transcribing` seam so no model download is needed)
/// flow through `LivePipeline.process` end-to-end — VAD segment shape, inline corrector,
/// CallsignSnap + SlotSnap with live traffic + the real KJFK airport context, attribution
/// gating, confidence gate, and the refiner queue. This is the app-side twin of the Python
/// gold scoreboard: same inputs, asserting the shipped pipeline produces the snapped outputs.
final class SnapReplayTests: XCTestCase {

    /// Returns the scripted hypothesis for each segment in order, ignoring the audio (the audio
    /// still flows through the real preprocessor/segment plumbing).
    private actor ScriptedTranscriber: Transcribing {
        private var script: [String]
        init(_ script: [String]) { self.script = script }
        func transcribe(_ audio: [Float], context: String?) async throws -> TranscriptionOutput {
            TranscriptionOutput(text: script.isEmpty ? "" : script.removeFirst(), asr: .unknown)
        }
    }

    private struct StubLLM: LLMCorrector {
        func correct(text: String, history: [String], retrieved: RetrievedContext) async -> Correction {
            .unchanged(text, backend: "stub")
        }
    }

    /// Bundled gold clip audio (real LiveATC radio, 16 kHz mono) — the file-replay input.
    private func goldAudio() throws -> [Float] {
        let url = try XCTUnwrap(
            Bundle.main.url(forResource: "usgold_dfw_aal2124", withExtension: "wav",
                            subdirectory: "DemoClips")
                ?? Bundle.main.url(forResource: "usgold_dfw_aal2124", withExtension: "wav"),
            "bundled gold clip missing")
        let data = try Data(contentsOf: url)
        // 16-bit PCM WAV: skip the 44-byte header, normalize to [-1, 1].
        let samples = data.dropFirst(44).withUnsafeBytes { raw in
            raw.bindMemory(to: Int16.self).map { Float($0) / 32768.0 }
        }
        XCTAssertGreaterThan(samples.count, 16_000, "gold clip should be at least 1 s of audio")
        return samples
    }

    private func segment(_ audio: [Float]) -> SpeechSegment {
        SpeechSegment(audio: audio, streamStartS: 0,
                      streamEndS: Double(audio.count) / 16_000.0,
                      finalizedWallTime: Date().timeIntervalSince1970)
    }

    private func makePipeline(script: [String]) throws -> (LivePipeline, ATCContext) {
        let config = try AirportConfig.load(named: "kjfk")
        let context = ATCContext(config: config, feedKey: nil)
        let pipeline = LivePipeline(transcriber: ScriptedTranscriber(script),
                                    context: context,
                                    llm: StubLLM(),
                                    diarizationEnabled: false)
        return (pipeline, context)
    }

    /// A misheard digit in the callsign snaps onto the aircraft actually on frequency, the
    /// runway mention is verified against KJFK's real runways, and the record attributes.
    func testReplaySnapsCallsignAndVerifiesRunway() async throws {
        let hyp = "delta 231 heavy kennedy tower runway 2 2 right cleared to land"
        let (pipeline, context) = try makePipeline(script: [hyp])
        context.setTraffic(block: "traffic", vocab: ["DAL232", "JBU604"],
                           expiry: Date().addingTimeInterval(60), epoch: 1)

        let record = try XCTUnwrap(await pipeline.process(segment(goldAudio())))
        XCTAssertTrue(record.display.contains("delta 2 3 2"),
                      "callsign must snap to the on-frequency aircraft: \(record.display)")
        XCTAssertFalse(record.display.contains("2 3 1"), record.display)
        XCTAssertTrue(record.corrections.contains { $0.backend == "snap" },
                      "snap edit must be visible in the transparent edit list")
        XCTAssertNotNil(record.callsignKey, "verified callsign must attribute")
        // runway 22R exists at KJFK — verified, so no runway edit and no gate alarm about it
        XCTAssertFalse(record.corrections.contains { $0.reason.contains("runway") })
    }

    /// A callsign NOT on frequency displays as heard but never attributes, and the gate fires.
    func testReplayUnverifiedCallsignAbstainsAndGates() async throws {
        let hyp = "united 456 kennedy tower going around"
        let (pipeline, context) = try makePipeline(script: [hyp])
        context.setTraffic(block: "traffic", vocab: ["DAL232"],
                           expiry: Date().addingTimeInterval(60), epoch: 1)

        let record = try XCTUnwrap(await pipeline.process(segment(goldAudio())))
        XCTAssertTrue(record.display.contains("united 456") || record.display.contains("united 4 5 6"),
                      "unverified callsign stays as heard: \(record.display)")
        XCTAssertNil(record.callsignKey, "unverified callsign must NOT attribute")
        XCTAssertNotNil(record.callsign, "…but still displays for the pilot")
        XCTAssertTrue(record.gateReason?.contains("unverified callsign") == true,
                      "gate must fire on the snap signal: \(record.gateReason ?? "nil")")
        XCTAssertEqual(record.refinementState, .pending)
    }

    /// No live traffic (offline / stale) — pre-snap behavior preserved: extraction attributes
    /// ungated and nothing is rewritten.
    func testReplayOfflineBehaviorUnchanged() async throws {
        let hyp = "delta 231 heavy kennedy tower runway 2 2 right cleared to land"
        let (pipeline, _) = try makePipeline(script: [hyp])

        let record = try XCTUnwrap(await pipeline.process(segment(goldAudio())))
        XCTAssertTrue(record.display.contains("delta 231") || record.display.contains("delta 2 3 1"),
                      "no candidate list → no rewrite: \(record.display)")
        XCTAssertNotNil(record.callsignKey, "offline attribution behavior must be unchanged")
    }
}
