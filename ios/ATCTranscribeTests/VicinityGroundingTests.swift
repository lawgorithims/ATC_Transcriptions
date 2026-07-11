import XCTest
@testable import ATCTranscribe

/// Source-aware + GPS-vicinity corrector grounding (the extension of Phase-3 grounding beyond the
/// single typed "Airport context" field). Covers, bottom-up:
///  * the vicinity resolution (`AirportContextStore.nearbyRanked` — nearest-first, radius-trimmed),
///  * the SOFT LLM/Whisper union (`ATCContext.vicinityProcedures` + the prompt/block supersede),
///  * the source classification that routes a feed to the typed vs the vicinity path, and
///  * the HARD path (`LivePipeline.setGroundingAirports`) grounding SlotSnap on the NEAREST airport
///    alone — never the union — and reverting cleanly on `clearGroundingAirports`.
/// SlotSnap.swift itself is unchanged, so its Python byte-parity (`SnapParityTests`) is untouched.
final class VicinityGroundingTests: XCTestCase {

    // MARK: - Source classification (typed feed vs GPS vicinity)

    func testSourceKindInCockpitClassification() {
        // In-cockpit live audio grounds on the GPS vicinity…
        XCTAssertTrue(SourceKind.microphone.isInCockpit)
        XCTAssertTrue(SourceKind.usbAudio.isInCockpit)
        XCTAssertTrue(SourceKind.stratux.isInCockpit)
        // …the internet feed keeps its typed airport; replay has no location.
        XCTAssertFalse(SourceKind.liveFeed.isInCockpit)
        XCTAssertFalse(SourceKind.replay.isInCockpit)
    }

    // MARK: - SOFT vicinity union (LLM block + Whisper decode bias)

    func testVicinityProceduresUnionsFixesRunwaysAndILS() {
        let a = AirportContextData(ident: "KBOS", runways: ["4L", "4R"],
                                   fixes: ["BOSOX"], navFrequencies: [109.3])
        let b = AirportContextData(ident: "KOWD", runways: ["35"],
                                   fixes: ["CRLTN", "BOSOX"], navFrequencies: [110.3])
        let (prompt, block) = ATCContext.vicinityProcedures([a, b])

        XCTAssertTrue(block.contains("Vicinity airports: KBOS, KOWD."), block)
        XCTAssertTrue(block.contains("4L") && block.contains("4R") && block.contains("35"),
                      "runways are unioned across the vicinity: \(block)")
        XCTAssertTrue(block.contains("CRLTN"), "fixes are unioned across the vicinity: \(block)")
        XCTAssertTrue(block.contains("109.30") && block.contains("110.30"),
                      "ILS freqs are unioned across the vicinity: \(block)")
        XCTAssertEqual(block.components(separatedBy: "BOSOX").count - 1, 1,
                       "a fix shared by two vicinity airports appears once (deduped): \(block)")
        XCTAssertTrue(prompt.hasPrefix("Fixes: BOSOX"), "the decode bias leads with the nearest fixes: \(prompt)")
    }

    func testVicinityProceduresEmptyForNoAirports() {
        let (prompt, block) = ATCContext.vicinityProcedures([])
        XCTAssertEqual(prompt, "")
        XCTAssertEqual(block, "")
    }

    func testVicinityProceduresSupersedesTypedInPromptAndBlock() {
        // A bare context (no typed config/grounding) that then receives a pushed vicinity union.
        let ctx = ATCContext(knowledge: .empty)
        ctx.setVicinityProcedures(promptLine: "Fixes: BOSOX, CRLTN.",
                                  block: "Vicinity airports: KBOS, KOWD.")
        XCTAssertTrue(ctx.buildPrompt().contains("Fixes: BOSOX, CRLTN."),
                      "the vicinity decode bias reaches the Whisper prompt")
        XCTAssertTrue(ctx.retrieveKnowledge(for: "cleared direct bosox").block.contains("Vicinity airports: KBOS, KOWD."),
                      "the vicinity block reaches the LLM correction context")

        // Clearing reverts (back to the typed / no-grounding path).
        ctx.setVicinityProcedures(promptLine: "", block: "")
        XCTAssertFalse(ctx.buildPrompt().contains("BOSOX"))
        XCTAssertFalse(ctx.retrieveKnowledge(for: "cleared direct bosox").block.contains("Vicinity airports"))
    }

    // MARK: - GPS-vicinity resolution (nearest-first, radius-trimmed)

    func testNearbyRankedIsNearestFirstWithinRadius() async throws {
        try XCTSkipIf(NavDatabase.count == 0 || BundledAirportContextSource.count == 0,
                      "nav_coords / airport_ctx bundles absent from the test host")
        // Bundled-only chain: deterministic (no CIFP dependency), and every airport with runways resolves.
        let store = AirportContextStore(sources: [BundledAirportContextSource()])
        // Boston Logan (KBOS) position.
        let ranked = await store.nearbyRanked(lat: 42.3656, lon: -71.0096, radiusNm: 40, limit: 6)

        XCTAssertFalse(ranked.isEmpty, "airports resolve around KBOS")
        let dists = ranked.map(\.distanceNm)
        XCTAssertEqual(dists, dists.sorted(), "results are NEAREST-FIRST")
        XCTAssertTrue(dists.allSatisfy { $0 <= 40 }, "the square nav-box is trimmed to the circular radius")
        XCTAssertEqual(ranked.first?.data.ident, "KBOS", "the airport at the query point is nearest")
    }

    // MARK: - HARD grounding (SlotSnap on the nearest airport ALONE)

    private actor ScriptedTranscriber: Transcribing {
        private var script: [String]
        init(_ script: [String]) { self.script = script }
        func transcribe(_ audio: [Float], context: String?) async throws -> TranscriptionOutput {
            TranscriptionOutput(text: script.isEmpty ? "" : script.removeFirst(), asr: .unknown)
        }
    }

    /// One synthetic speech segment (audio is ignored by the scripted transcriber).
    private func segment(_ samples: Int = 16_000) -> SpeechSegment {
        SpeechSegment(audio: [Float](repeating: 0, count: samples),
                      streamStartS: 0, streamEndS: Double(samples) / 16_000, finalizedWallTime: 0)
    }

    func testHardGroundingSnapsAgainstNearestAirportOnly() async {
        // The nearest airport publishes runway 22R (but no 21); a FARTHER vicinity airport publishes 21R.
        // The soft union spans both, but the deterministic SlotSnap must ground on the NEAREST airport
        // ALONE — so a heard "runway 2 1 right" snaps to the unique edit-1 neighbor 22R. Were the union
        // used for hard edits, 21R would be an EXACT match and it would (wrongly) verify-not-snap: the
        // divergent outcome is exactly what proves hard grounding never unions across airports.
        let nearest = AirportContextData(ident: "KAAA", runways: ["22R", "4R"])
        let farther = AirportContextData(ident: "KBBB", runways: ["21R"])
        let pipeline = LivePipeline(transcriber: ScriptedTranscriber(["cleared to land runway 2 1 right"]),
                                    context: ATCContext(knowledge: .empty), diarizationEnabled: false)
        await pipeline.setGroundingAirports(hard: nearest, soft: [nearest, farther])

        let rec = await pipeline.process(segment())
        XCTAssertEqual(rec?.display.contains("runway 2 2 right"), true,
                       "hard SlotSnap grounds on the nearest airport alone: \(rec?.display ?? "nil")")
        XCTAssertTrue(rec?.corrections.contains { $0.reason == "runway snap" } ?? false,
                      "the runway snap is recorded as a slot correction")
    }

    func testClearGroundingLeavesTranscriptUngrounded() async {
        let nearest = AirportContextData(ident: "KAAA", runways: ["22R"])
        let script = ["cleared to land runway 2 1 right", "cleared to land runway 2 1 right"]
        let pipeline = LivePipeline(transcriber: ScriptedTranscriber(script),
                                    context: ATCContext(knowledge: .empty), diarizationEnabled: false)

        await pipeline.setGroundingAirports(hard: nearest, soft: [nearest])
        let grounded = await pipeline.process(segment())
        XCTAssertEqual(grounded?.display.contains("runway 2 2 right"), true, "grounded → snapped")

        await pipeline.clearGroundingAirports()
        let ungrounded = await pipeline.process(segment())
        XCTAssertEqual(ungrounded?.display.contains("runway 2 1 right"), true,
                       "cleared grounding → SlotSnap abstains, transcript left as heard: \(ungrounded?.display ?? "nil")")
        XCTAssertEqual(ungrounded?.display.contains("runway 2 2 right"), false)
    }
}
