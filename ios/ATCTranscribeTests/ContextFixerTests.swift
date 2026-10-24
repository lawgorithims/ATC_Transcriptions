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

    // MARK: LLMRefiner — backpressure, the timeout watchdog (L6 remediation), the serial invariant

    /// The refiner's worker runs at `.background` in the app; these tests run it at `.userInitiated`.
    /// They check the QUEUE'S logic, and the OS starves background work for tens of seconds when every
    /// core is busy — with ten CPU burners running, all four of these tests failed, one finishing 3 of 5
    /// 150 ms generations in 30 s (2026-10-24). That is the app behaving as designed, not a refiner bug.
    ///
    /// Nothing below decides an outcome by the clock. Generations are held at a `Gate` until the test
    /// releases them, so every ordering a test asserts is forced rather than raced, and each wait is a
    /// LIVENESS bound: long, because reaching it means the refiner stalled, not that it was slow.
    private static let liveness: TimeInterval = 60

    private func refiner(_ corrector: LLMCorrector, maxQueue: Int,
                         timeout: TimeInterval = 3600) -> LLMRefiner {
        LLMRefiner(corrector: corrector, maxQueue: maxQueue, timeout: timeout, priority: .userInitiated)
    }

    private func request(_ id: UUID, _ text: String) -> RefinementRequest {
        RefinementRequest(id: id, text: text, history: [], retrieved: ctx())
    }

    /// Holds generations until the test opens it; once open, every waiter and every later arrival passes.
    private actor Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func open() {
            isOpen = true
            for w in waiters { w.resume() }               // bounded by the generations held
            waiters.removeAll()
        }
    }

    /// A generation that cannot finish until its gate opens. Counts starts, completions and the most
    /// generations ever running at once — the llama.cpp KV-cache rule says that must stay 1.
    private actor GatedCorrector: LLMCorrector {
        private let gate: Gate
        private(set) var started = 0
        private(set) var completed = 0
        private(set) var maxActive = 0
        private var active = 0
        init(gate: Gate) { self.gate = gate }
        func correct(text: String, history: [String], retrieved: RetrievedContext) async -> Correction {
            started += 1; active += 1; maxActive = max(maxActive, active)
            await gate.wait()
            active -= 1; completed += 1
            return .unchanged(text, backend: "gated")
        }
    }

    /// Every outcome per request id — proves EXACTLY-ONCE delivery even when the watchdog fires and the
    /// real result arrives afterward.
    private final class CountingSink: @unchecked Sendable {
        private let lock = NSLock()
        private var byId: [UUID: [RefinementOutcome]] = [:]
        func record(_ id: UUID, _ o: RefinementOutcome) { lock.lock(); byId[id, default: []].append(o); lock.unlock() }
        func outcomes(_ id: UUID) -> [RefinementOutcome] { lock.lock(); defer { lock.unlock() }; return byId[id] ?? [] }
        var reports: Int { lock.lock(); defer { lock.unlock() }; return byId.values.reduce(0) { $0 + $1.count } }
        var skipped: Int {
            lock.lock(); defer { lock.unlock() }
            return byId.values.joined().filter { if case .skipped = $0 { return true }; return false }.count
        }

        /// How many of `ids` have an outcome once all do, or once `timeout` passes (a liveness bound).
        func awaitOutcomes(_ ids: [UUID], timeout: TimeInterval) async -> Int {
            let deadline = Date().addingTimeInterval(timeout)
            func have() -> Int { ids.filter { !outcomes($0).isEmpty }.count }
            while have() < ids.count, Date() < deadline {          // bounded by the deadline
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            return have()
        }
        func awaitOutcome(_ id: UUID, timeout: TimeInterval) async -> [RefinementOutcome] {
            _ = await awaitOutcomes([id], timeout: timeout)
            return outcomes(id)
        }
    }

    func testRefinerOverflowDropsOldestNeverBlocks() async {
        let gate = Gate()
        let sink = CountingSink()
        let r = refiner(GatedCorrector(gate: gate), maxQueue: 3)
        await r.setOutcomeHandler { id, outcome in sink.record(id, outcome) }
        let ids = (0..<12).map { _ in UUID() }
        for (i, id) in ids.enumerated() { await r.enqueue(request(id, "msg \(i)")) }
        // The generation is held, so at most one request is in flight and three are queued: the other
        // eight were dropped AT ENQUEUE. That is the property — overflow sheds load without waiting on
        // the worker, however long the worker takes.
        XCTAssertGreaterThanOrEqual(sink.skipped, ids.count - 1 - 3, "overflow must drop, never block")
        await gate.open()
        let reported = await sink.awaitOutcomes(ids, timeout: Self.liveness)
        XCTAssertEqual(reported, ids.count, "every request yields an outcome, dropped or processed")
        XCTAssertEqual(sink.reports, ids.count, "and exactly one each")
    }

    func testRefinerTimeoutReportsSkippedExactlyOnce() async {
        let gate = Gate()
        let sink = CountingSink()
        // A 0.1 s watchdog and a generation HELD until the watchdog has reported: watchdog first, real
        // result second, by construction rather than by a race the host's load could reverse.
        let r = refiner(GatedCorrector(gate: gate), maxQueue: 4, timeout: 0.1)
        await r.setOutcomeHandler { id, outcome in sink.record(id, outcome) }
        let id = UUID()
        await r.enqueue(request(id, "slow one"))
        let outs = await sink.awaitOutcome(id, timeout: Self.liveness)
        XCTAssertEqual(outs.count, 1, "the watchdog must report the timed-out request")
        if case .skipped = outs.first { } else { XCTFail("expected .skipped, got \(String(describing: outs.first))") }

        // Release it: the real result now lands AFTER the report and must be swallowed. The serial
        // drain is the happens-after barrier — a following request cannot produce an outcome until the
        // first generation has returned and `deliver` has run, so seeing the barrier's outcome proves a
        // second report for `id` would already have been recorded.
        await gate.open()
        let barrierID = UUID()
        await r.enqueue(request(barrierID, "barrier"))
        let barrier = await sink.awaitOutcome(barrierID, timeout: Self.liveness)
        XCTAssertFalse(barrier.isEmpty, "the barrier request never completed — the refiner stalled")
        XCTAssertEqual(sink.outcomes(id).count, 1, "a timed-out request must be reported exactly once")
    }

    func testRefinerFastRequestIsNotTimedOut() async {
        let gate = Gate()
        await gate.open()                                     // nothing holds this generation
        let sink = CountingSink()
        // A watchdog an hour out cannot fire inside this test, so the only way to read `.skipped` here
        // is a refiner that reports a FINISHED generation as timed out — the bug this test exists for.
        let r = refiner(GatedCorrector(gate: gate), maxQueue: 4, timeout: 3600)
        await r.setOutcomeHandler { id, outcome in sink.record(id, outcome) }
        let id = UUID()
        await r.enqueue(request(id, "fast one"))
        let outs = await sink.awaitOutcome(id, timeout: Self.liveness)
        XCTAssertEqual(outs.count, 1)
        if case .skipped = outs.first { XCTFail("a fast request must not be timed out") }
    }

    /// The serial one-generation invariant SURVIVES the watchdog: a generation reported timed out still
    /// owns the slot until it returns (the llama.cpp KV-cache rule).
    func testRefinerNeverOverlapsGenerationsAfterTimeout() async {
        let gate = Gate()
        let probe = GatedCorrector(gate: gate)
        let sink = CountingSink()
        let r = refiner(probe, maxQueue: 8, timeout: 0.05)
        await r.setOutcomeHandler { id, outcome in sink.record(id, outcome) }
        let ids = (0..<5).map { _ in UUID() }
        for (i, id) in ids.enumerated() { await r.enqueue(request(id, "m\(i)")) }
        // The first generation is held. Once the watchdog has reported it is the moment a second one
        // would start if a timeout released the slot.
        let first = await sink.awaitOutcome(ids[0], timeout: Self.liveness)
        XCTAssertEqual(first.count, 1, "the watchdog never reported the held generation")
        let startedWhileHeld = await probe.started
        XCTAssertEqual(startedWhileHeld, 1, "a timed-out generation handed the slot to the next one")
        await gate.open()
        // Drained means every generation RAN, not merely that every request was reported: the watchdog
        // can report a request whose generation is still to come.
        let deadline = Date().addingTimeInterval(Self.liveness)
        while await probe.completed < ids.count, Date() < deadline {   // bounded by the deadline
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let completed = await probe.completed
        XCTAssertEqual(completed, ids.count, "all five generations must have run — the drain stalled")
        let maxActive = await probe.maxActive
        XCTAssertEqual(maxActive, 1, "the watchdog must not let a second generation start")
    }
}
