import XCTest
@testable import ATCTranscribe

/// M2/M3 (remediation): record delivery order + the natural-end drain, and decode-error surfacing.
/// The pipeline awaits each `onRecord` (FIFO by construction), `run()` cannot return until every
/// record has been consumed, and a thrown decode surfaces a trouble notice instead of vanishing.
final class EngineReliabilityTests: XCTestCase {

    /// Scripted hypothesis per segment, ignoring the audio (the real VAD/segment plumbing runs).
    private actor ScriptedTranscriber: Transcribing {
        private var script: [String]
        init(_ script: [String]) { self.script = script }
        func transcribe(_ audio: [Float], context: String?) async throws -> TranscriptionOutput {
            TranscriptionOutput(text: script.isEmpty ? "" : script.removeFirst(), asr: .unknown)
        }
    }

    /// Always throws — the decode-failure path.
    private actor ThrowingTranscriber: Transcribing {
        let error: Error
        init(_ error: Error) { self.error = error }
        func transcribe(_ audio: [Float], context: String?) async throws -> TranscriptionOutput {
            throw error
        }
    }

    /// Order-preserving async collector for the awaited `onRecord`.
    private actor Collector {
        private(set) var records: [TranscriptRecord] = []
        func append(_ r: TranscriptRecord) { records.append(r) }
    }

    /// Thread-safe trouble-message box for the sync `onTrouble` callback.
    private final class TroubleBox: @unchecked Sendable {
        private let lock = NSLock()
        private var buf: [String] = []
        func append(_ m: String) { lock.lock(); buf.append(m); lock.unlock() }
        var messages: [String] { lock.lock(); defer { lock.unlock() }; return buf }
    }

    /// `n` frames of constant amplitude (RMS == amp): 0.5 reads as speech, 0.0 as silence.
    private func frames(_ n: Int, _ amp: Float) -> [Float] {
        [Float](repeating: amp, count: n * VADSegmenter.frameSamples)
    }

    // MARK: - M2: ordering + drain

    func testRecordsArriveInOrderAndAllArriveBeforeRunReturns() async {
        // Three bursts, each long enough to be speech (≥17 frames), separated by ≥14 silence
        // frames; trailing silence closes the last one through the normal path.
        let audio = frames(34, 0.5) + frames(20, 0)
                  + frames(34, 0.5) + frames(20, 0)
                  + frames(34, 0.5) + frames(20, 0)
        let pipeline = LivePipeline(transcriber: ScriptedTranscriber(["one", "two", "three"]),
                                    context: ATCContext(), diarizationEnabled: false)
        let collector = Collector()
        await pipeline.run(source: ArrayAudioSource(audio)) { record in
            await collector.append(record)
        }
        // run() has returned → every record must already be collected, in script order.
        let records = await collector.records
        XCTAssertEqual(records.map(\.text), ["one", "two", "three"],
                       "records must arrive in emission order, all before run() returns")
        let starts = records.map(\.streamStartS)
        XCTAssertEqual(starts, starts.sorted(), "stream offsets must be non-decreasing")
    }

    func testFlushRecordArrivesBeforeRunReturns() async {
        // The feed ends MID-SPEECH (no trailing silence): the only segment comes from the
        // flush() drain — the exact record the old fire-and-forget hop could drop at stream end.
        let audio = frames(34, 0.5)
        let pipeline = LivePipeline(transcriber: ScriptedTranscriber(["last words"]),
                                    context: ATCContext(), diarizationEnabled: false)
        let collector = Collector()
        await pipeline.run(source: ArrayAudioSource(audio)) { record in
            await collector.append(record)
        }
        let records = await collector.records
        XCTAssertEqual(records.map(\.text), ["last words"],
                       "the flush-drained final record must be delivered before run() returns")
    }

    // MARK: - M2: session-level natural end vs explicit stop

    @MainActor
    func testNaturalEndKeepsFinalRecord() async throws {
        let pipeline = LivePipeline(transcriber: ScriptedTranscriber(["final line"]),
                                    context: ATCContext(), diarizationEnabled: false)
        let session = TranscriptionSession(pipeline: pipeline)
        session.start(source: ArrayAudioSource(frames(34, 0.5)), label: "test")
        // Bounded poll for the natural end (statically bounded loop — rule 2).
        for i in 0..<600 {
            assert(i < 600)
            if session.status == .stopped { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(session.status, .stopped)
        XCTAssertEqual(session.detail, "Stream ended.")
        XCTAssertEqual(session.records.map(\.text), ["final line"],
                       "a natural stream end must never drop the final drained record")
    }

    @MainActor
    func testExplicitStopStillDropsInFlight() async throws {
        // PRESERVED semantics: a user-initiated stop() sets .stopped immediately and any records
        // still draining are deliberately dropped by append's status guard.
        let pipeline = LivePipeline(transcriber: ScriptedTranscriber(["dropped"]),
                                    context: ATCContext(), diarizationEnabled: false)
        let session = TranscriptionSession(pipeline: pipeline)
        session.start(source: ArrayAudioSource(frames(34, 0.5)), label: "test")
        session.stop()   // synchronous on the main actor — no append can interleave before this
        try await Task.sleep(nanoseconds: 500_000_000)   // let any in-flight drain complete
        XCTAssertEqual(session.status, .stopped)
        XCTAssertTrue(session.records.isEmpty, "explicit stop drops in-flight records (by design)")
    }

    // MARK: - M3: decode failures surface instead of vanishing

    func testThrowingTranscriberSurfacesTroubleAndEmitsNoRecord() async {
        struct DecodeBlewUp: Error {}
        let pipeline = LivePipeline(transcriber: ThrowingTranscriber(DecodeBlewUp()),
                                    context: ATCContext(), diarizationEnabled: false)
        let collector = Collector()
        let trouble = TroubleBox()
        await pipeline.run(source: ArrayAudioSource(frames(34, 0.5) + frames(20, 0))) { record in
            await collector.append(record)
        } onTrouble: { trouble.append($0) }
        let records = await collector.records
        XCTAssertTrue(records.isEmpty, "a failed decode must not fabricate a record")
        XCTAssertEqual(trouble.messages, [LivePipeline.decodeFailureNotice],
                       "the failure must surface exactly one trouble notice")
    }

    func testCancellationDoesNotSurfaceTrouble() async {
        let pipeline = LivePipeline(transcriber: ThrowingTranscriber(CancellationError()),
                                    context: ATCContext(), diarizationEnabled: false)
        let collector = Collector()
        let trouble = TroubleBox()
        await pipeline.run(source: ArrayAudioSource(frames(34, 0.5) + frames(20, 0))) { record in
            await collector.append(record)
        } onTrouble: { trouble.append($0) }
        let records = await collector.records
        XCTAssertTrue(records.isEmpty)
        XCTAssertTrue(trouble.messages.isEmpty,
                      "a user-stop cancellation is not a failure and must stay silent")
    }

    func testLatencyStatsCountsDecodeFailures() {
        var s = LatencyStats()
        XCTAssertEqual(s.decodeFailures, 0)
        s.addDecodeFailure()
        XCTAssertEqual(s.decodeFailures, 1)
        XCTAssertEqual(s.count, 0, "a failed decode is not a transmission")
    }
}
