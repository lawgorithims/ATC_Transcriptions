import XCTest
@testable import ATCTranscribe

/// The prompt budget is a CORRECTNESS boundary, not a nicety.
///
/// WhisperKit's text decoder re-trims the prompt with `promptTokens.suffix(maxTokenContext/2 - 1)`.
/// Anything longer therefore loses its FRONT inside WhisperKit — which silently deleted every
/// priming section we build head-first (facility, procedures, ownship, plate fixes, and the live
/// ADS-B "Aircraft on frequency" bias), forwarding only rolling history to the model.
///
/// These tests pin the two halves of the fix: we never hand WhisperKit more than it keeps (so its
/// `suffix()` is a no-op), and when the budget binds it is the HISTORY that gives way, not the priming.
final class PromptBudgetTests: XCTestCase {

    private let budget = ATCTranscriber.maxPromptTokens

    func testBudgetIsDerivedFromWhisperKitsOwnLimit() {
        // If a dependency bump changes maxTokenContext, this must move with it — never drift back
        // to a hard-coded value larger than what WhisperKit keeps.
        XCTAssertEqual(budget, 111, "WhisperKit keeps suffix(maxTokenContext/2 - 1) = 111 prompt tokens")
    }

    func testNeverExceedsBudgetSoWhisperKitsTrimIsANoOp() {
        let cases: [(head: Int, tail: Int)] = [(0, 0), (5, 5), (200, 0), (0, 300), (200, 300), (111, 1), (110, 50)]
        for c in cases {
            let ids = ATCTranscriber.assemblePromptIds(head: Array(repeating: 1, count: c.head),
                                                       tail: Array(repeating: 2, count: c.tail),
                                                       budget: budget)
            XCTAssertLessThanOrEqual(ids.count, budget, "head \(c.head)/tail \(c.tail) overflowed the budget")
        }
    }

    func testHeadKeepsItsFrontAndWinsTheBudget() {
        // Priming order IS priority order, so an oversized head keeps its opening tokens.
        let head = Array(0..<200)                       // 0..199
        let tailSentinel = 9_999                        // disjoint from the head's value range
        let ids = ATCTranscriber.assemblePromptIds(head: head,
                                                   tail: Array(repeating: tailSentinel, count: 50),
                                                   budget: budget)
        XCTAssertEqual(ids.count, budget)
        XCTAssertEqual(ids.first, 0, "the head's first token (facility priming) must survive")
        XCTAssertEqual(ids, Array(0..<budget), "an oversized head fills the budget from its front")
        XCTAssertFalse(ids.contains(tailSentinel), "history must not displace priming")
    }

    func testHistoryFillsTheRemainderWithItsMOSTRECENTTokens() {
        // History's value is recency, so it is trimmed from the FRONT (oldest first).
        let head = Array(repeating: 7, count: 11)          // 11 tokens of priming
        let tail = Array(0..<500)                          // "oldest ... newest"
        let ids = ATCTranscriber.assemblePromptIds(head: head, tail: tail, budget: budget)
        XCTAssertEqual(ids.count, budget)
        XCTAssertEqual(Array(ids.prefix(11)), head, "priming stays at the front, intact")
        XCTAssertEqual(ids.last, 499, "the newest transmission token must survive")
        XCTAssertEqual(Array(ids.suffix(budget - 11)), Array(tail.suffix(budget - 11)))
    }

    func testEmptyAndDegenerateInputs() {
        XCTAssertTrue(ATCTranscriber.assemblePromptIds(head: [], tail: [], budget: budget).isEmpty)
        XCTAssertTrue(ATCTranscriber.assemblePromptIds(head: [1, 2], tail: [3], budget: 0).isEmpty)
        XCTAssertEqual(ATCTranscriber.assemblePromptIds(head: [], tail: [1, 2, 3], budget: budget), [1, 2, 3])
        XCTAssertEqual(ATCTranscriber.assemblePromptIds(head: [1, 2, 3], tail: [], budget: budget), [1, 2, 3])
    }

    // MARK: - the composer half: PromptParts budgets head-first at the CHARACTER level too

    func testPromptPartsKeepsPrimingWhenHistoryIsHuge() {
        // Tight char budget + long history = the exact condition that used to delete the priming.
        let ctx = ATCContext(maxPromptChars: 120)
        ctx.setPlatePriming(promptLine: "Chart fixes: WAXEN, IRSEW, BOSOX.", block: "")
        for i in 0..<6 {
            ctx.update("american \(i) turn left heading two seven zero descend and maintain three thousand")
        }
        let parts = ctx.buildPromptParts()
        XCTAssertTrue(parts.head.contains("Chart fixes: WAXEN"),
                      "priming must survive a flood of history — this is the bug being fixed")
        XCTAssertLessThanOrEqual(parts.joined.count, 121, "combined prompt stays within the char budget")
        if !parts.tail.isEmpty {
            XCTAssertTrue(parts.tail.contains("american 5"),
                          "retained history must be the most RECENT, not the oldest")
        }
    }

    func testJoinedMatchesBuildPromptSoTheRecordFormatIsUnchanged() {
        let ctx = ATCContext()
        ctx.setPlatePriming(promptLine: "Chart fixes: WAXEN.", block: "")
        ctx.update("delta one two three cleared to land")
        XCTAssertEqual(ctx.buildPromptParts().joined, ctx.buildPrompt())
    }
}
