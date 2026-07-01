import XCTest
@testable import ATCTranscribe

/// Covers the slow-tier context fixer pieces that don't need a model: repetition collapse, the
/// output guardrails, the local LLM corrector (with a stub engine), and the background refiner's
/// backpressure.
final class ContextFixerTests: XCTestCase {

    // MARK: RepetitionCollapse

    private func collapse(_ s: String) async -> Correction { await RepetitionCollapse().correct(s, history: []) }

    func testPhraseRepeatCollapsed() async {
        let c = await collapse("cleared to land cleared to land")
        XCTAssertTrue(c.changed)
        XCTAssertEqual(c.corrected, "cleared to land")
        XCTAssertEqual(c.edits.first?.reason, "repeat")
    }

    func testSingleTokenLoopCollapsed() async {
        let c = await collapse("runway runway runway three")   // 3x single token -> 1
        XCTAssertEqual(c.corrected, "runway three")
    }

    func testTwoTokenNumberPreserved() async {
        // "three three" (a legitimate 33 readback) must NOT collapse — single tokens need 3+ reps.
        let c = await collapse("runway three three")
        XCTAssertFalse(c.changed)
    }

    func testNoRepeatUnchanged() async {
        let c = await collapse("delta eight ninety contact ground")
        XCTAssertFalse(c.changed)
    }

    // MARK: CorrectionValidator

    private func validator(allowed: [String], maxEdits: Int = 8) -> CorrectionValidator {
        let norm = allowed.map { String($0.lowercased().filter { $0.isLetter || $0.isNumber }) }
        return CorrectionValidator(allowed: Set(norm), maxEdits: maxEdits)
    }
    private func edit(_ from: String, _ to: String) -> CorrectionEdit {
        CorrectionEdit(from: from, to: to, reason: "test", backend: "test")
    }

    func testNumberChangeDropped() {
        let c = validator(allowed: []).validate(raw: "runway 34 cleared", edits: [edit("34", "35")], backend: "test")
        XCTAssertFalse(c.changed)   // digit change rejected -> no surviving edit
    }

    func testHallucinationDropped() {
        // "pasta" is neither a known term nor close to "bonham" -> dropped.
        let c = validator(allowed: ["kennedy"]).validate(raw: "proceed bonham then", edits: [edit("bonham", "pasta")], backend: "test")
        XCTAssertFalse(c.changed)
    }

    func testAllowedVocabFixApplied() {
        let c = validator(allowed: ["kennedy"]).validate(raw: "contact kenedy tower", edits: [edit("kenedy", "kennedy")], backend: "test")
        XCTAssertTrue(c.changed)
        XCTAssertEqual(c.corrected, "contact kennedy tower")
        XCTAssertEqual(c.edits.count, 1)
    }

    func testNearMissFixAppliedViaRatio() {
        // Not in the allowed set, but close enough to the transcribed token to be a plausible fix.
        let c = validator(allowed: []).validate(raw: "inbound maverik now", edits: [edit("maverik", "maverick")], backend: "test")
        XCTAssertEqual(c.corrected, "inbound maverick now")
    }

    func testTooManyEditsRejected() {
        let many = (0..<9).map { _ in edit("x", "y") }
        let c = validator(allowed: ["y"]).validate(raw: "x x x", edits: many, backend: "test")
        XCTAssertFalse(c.changed)
    }

    func testAllowedTermsBuilder() {
        let kb = ATCKnowledgeBase(airlineTelephony: ["DAL": "Delta"], spokenNamesByAirport: [:],
                                  spokenBaseByAirport: [:], phrasesByType: ["tower": ["cleared to land"]],
                                  spellingByType: ["tower": ["niner"]], phonetic: ["A": "alpha"], digits: [:])
        let retrieved = RetrievedContext(block: "", vocab: ["Kennedy", "4L"], languageSuspect: false)
        let allowed = CorrectionValidator.allowedTerms(retrieved: retrieved, knowledge: kb, freqType: "tower")
        XCTAssertTrue(allowed.contains("kennedy"))
        XCTAssertTrue(allowed.contains("delta"))
        XCTAssertTrue(allowed.contains("clearedtoland"))  // whole-phrase key
        XCTAssertTrue(allowed.contains("cleared"))         // per-word key
        XCTAssertTrue(allowed.contains("4l"))
    }

    // MARK: Callsign integrity (findings #4 traffic-code denylist, #9 filed-callsign misattribution)

    func testTrafficCodeDeniedAsEditTarget() {
        // A raw in-range ADS-B code (AAL1234) is context for the LLM but must never be the applied
        // output form — even though "american 1234" → "AAL1234" preserves digits and passes the ratio.
        let v = CorrectionValidator(allowed: [], deniedTargets: ["aal1234"])
        let c = v.validate(raw: "american 1234 turn left", edits: [edit("american 1234", "AAL1234")], backend: "test")
        XCTAssertFalse(c.changed)
    }

    func testTrafficCodeAllowedWhenItIsAlsoTheFiledCallsign() {
        // If the code is independently allowed (it's the pilot's own filed callsign), the denylist
        // doesn't block it — the phonetic/ratio check still governs, and a near-string form snaps.
        let v = CorrectionValidator(allowed: ["aal1234"], deniedTargets: ["aal1234"])
        let c = v.validate(raw: "aa1234 heavy", edits: [edit("aa1234", "AAL1234")], backend: "test")
        XCTAssertTrue(c.changed)   // "aa1234" ~ "aal1234" is a near neighbour → allowed
    }

    func testFiledCallsignMisattributionBlocked() {
        // A DIFFERENT aircraft's spoken callsign must not be snapped onto the pilot's filed one just
        // because the digits coincide. Filed: N345AB; heard: "november 345 charlie delta" (N345CD).
        let phonetic = ["november": "n", "alpha": "a", "bravo": "b", "charlie": "c", "delta": "d"]
        let v = CorrectionValidator(allowed: ["n345ab"], phonetic: phonetic)
        let c = v.validate(raw: "november 345 charlie delta heavy",
                           edits: [edit("november 345 charlie delta", "N345AB")], backend: "test")
        XCTAssertFalse(c.changed)
    }

    func testFiledCallsignGenuineMishearAllowed() {
        // The pilot's OWN callsign, phonetically spelled, still snaps onto the filed form.
        let phonetic = ["november": "n", "alpha": "a", "bravo": "b", "charlie": "c", "delta": "d"]
        let v = CorrectionValidator(allowed: ["n345ab"], phonetic: phonetic)
        let c = v.validate(raw: "november 345 alpha bravo heavy",
                           edits: [edit("november 345 alpha bravo", "N345AB")], backend: "test")
        XCTAssertTrue(c.changed)
        XCTAssertEqual(c.corrected, "N345AB heavy")
    }

    func testRunwayDesignatorStillSnaps() {
        // Runways lead with a DIGIT, so the callsign-integrity gate never touches them: "28 right" →
        // "28R" must still snap when 28R is a known runway (guards against over-blocking). (The digit
        // string is preserved, so the numbers-preserved guard is satisfied.)
        let v = CorrectionValidator(allowed: ["28r"])
        let c = v.validate(raw: "cleared to land 28 right",
                           edits: [edit("28 right", "28R")], backend: "test")
        XCTAssertTrue(c.changed)
        XCTAssertEqual(c.corrected, "cleared to land 28R")
    }

    // MARK: LocalLLMCorrector (stub engine — no model)

    private struct StubEngine: LLMEngine {
        let response: String
        func generate(prompt: String, grammar: String?, maxTokens: Int, stop: [String]) async throws -> String { response }
    }
    private func ctx(_ vocab: [String] = []) -> RetrievedContext {
        RetrievedContext(block: "", vocab: vocab, languageSuspect: false)
    }

    func testLocalCorrectorAppliesValidEdit() async {
        let json = #"{"corrected":"contact kennedy tower","edits":[{"from":"kenedy","to":"kennedy","reason":"facility"}]}"#
        let kb = ATCKnowledgeBase(airlineTelephony: [:], spokenNamesByAirport: ["KJFK": ["Kennedy"]],
                                  spokenBaseByAirport: [:], phrasesByType: [:], spellingByType: [:],
                                  phonetic: [:], digits: [:])
        let corrector = LocalLLMCorrector(engine: StubEngine(response: json), knowledge: kb, feedKey: "tower")
        let c = await corrector.correct(text: "contact kenedy tower", history: [], retrieved: ctx(["Kennedy"]))
        XCTAssertTrue(c.changed)
        XCTAssertEqual(c.corrected, "contact kennedy tower")
    }

    func testLocalCorrectorRejectsNumberChange() async {
        let json = #"{"corrected":"cleared runway 35","edits":[{"from":"34","to":"35","reason":"x"}]}"#
        let corrector = LocalLLMCorrector(engine: StubEngine(response: json), knowledge: .empty, feedKey: nil)
        let c = await corrector.correct(text: "cleared runway 34", history: [], retrieved: ctx())
        XCTAssertFalse(c.changed)
    }

    func testLocalCorrectorUnparseableIsUnchanged() async {
        let corrector = LocalLLMCorrector(engine: StubEngine(response: "sorry, I cannot do that"),
                                          knowledge: .empty, feedKey: nil)
        let c = await corrector.correct(text: "delta eight ninety", history: [], retrieved: ctx())
        XCTAssertFalse(c.changed)
    }

    func testLocalCorrectorEmptyInputIsUnchanged() async {
        let corrector = LocalLLMCorrector(engine: StubEngine(response: "{}"), knowledge: .empty, feedKey: nil)
        let c = await corrector.correct(text: "   ", history: [], retrieved: ctx())
        XCTAssertFalse(c.changed)
    }

    // MARK: LLMRefiner backpressure

    private struct SlowCorrector: LLMCorrector {
        let delayMs: UInt64
        func correct(text: String, history: [String], retrieved: RetrievedContext) async -> Correction {
            try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
            return .unchanged(text, backend: "slow")
        }
    }

    private final class OutcomeSink: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var total = 0
        private(set) var skipped = 0
        private let target: Int
        private let expectation: XCTestExpectation
        init(target: Int, expectation: XCTestExpectation) { self.target = target; self.expectation = expectation }
        func record(_ outcome: RefinementOutcome) {
            lock.lock()
            total += 1
            if case .skipped = outcome { skipped += 1 }
            let done = total == target
            lock.unlock()
            if done { expectation.fulfill() }
        }
    }

    func testRefinerOverflowDropsOldestNeverBlocks() async {
        let n = 12
        let exp = expectation(description: "every request yields exactly one outcome")
        let sink = OutcomeSink(target: n, expectation: exp)
        let refiner = LLMRefiner(corrector: SlowCorrector(delayMs: 80), maxQueue: 3)
        await refiner.setOutcomeHandler { _, outcome in sink.record(outcome) }

        for i in 0..<n {
            await refiner.enqueue(RefinementRequest(id: UUID(), text: "msg \(i)", history: [],
                                                    retrieved: ctx()))
        }
        await fulfillment(of: [exp], timeout: 10)
        XCTAssertEqual(sink.total, n)            // dropped or processed — each delivered once
        XCTAssertGreaterThan(sink.skipped, 0)    // under load some were dropped, not blocked
    }
}
