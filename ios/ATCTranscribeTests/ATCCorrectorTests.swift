import XCTest
@testable import ATCTranscribe

/// These tests encode the observed behavior of `atc_corrector.py` so the Swift port
/// stays faithful. Each assertion corresponds to a documented rule in the Python.
/// `correct` is `async` (the on-device LLM backend is async), so the deterministic
/// assertions `await` it — the math is unchanged.
final class ATCCorrectorTests: XCTestCase {

    private func det(vocab: [String] = [],
                     threshold: Double = 0.84,
                     phonetic: Bool = true,
                     phoneticMin: Double = 0.62) -> DeterministicCorrector {
        DeterministicCorrector(vocabProvider: { vocab }, threshold: threshold,
                               phonetic: phonetic, phoneticMin: phoneticMin, numbers: true)
    }

    // MARK: hallucination filter

    func testHallucinationFilterRemovesPhantomPhrase() async {
        let r = await HallucinationFilter().correct("contact no call of departure", history: [])
        XCTAssertTrue(r.changed)
        XCTAssertEqual(r.corrected, "contact departure")
    }

    func testHallucinationFilterLeavesCleanText() async {
        let r = await HallucinationFilter().correct("contact departure", history: [])
        XCTAssertFalse(r.changed)
    }

    // A wholly-phantom transmission deletes to empty (the pipeline then drops it) — not resurrected.
    func testHallucinationFilterDeletesWhollyPhantom() async {
        let r = await HallucinationFilter().correct("no call of", history: [])
        XCTAssertTrue(r.changed)
        XCTAssertEqual(r.corrected, "")
    }

    // MARK: SequenceMatcher.ratio() vs known difflib values

    func testRatioMatchesDifflib() {
        XCTAssertEqual(SequenceMatcher("maverik", "maverick").ratio(), 14.0 / 15.0, accuracy: 1e-9)
        XCTAssertEqual(SequenceMatcher("golf", "gulf").ratio(), 0.75, accuracy: 1e-9)
        XCTAssertEqual(SequenceMatcher("", "").ratio(), 1.0, accuracy: 0.0)
        XCTAssertEqual(SequenceMatcher("abc", "xyz").ratio(), 0.0, accuracy: 0.0)
    }

    // MARK: number normalization (vocab-independent)

    func testIcaoNumberWords() async {
        // "niner" -> 9; "thousand" is not a number word so it terminates the run.
        let r = await det().correct("descend niner thousand")
        XCTAssertTrue(r.changed)
        XCTAssertEqual(r.corrected, "descend 9 thousand")
        XCTAssertEqual(r.edits.first?.reason, "number")
    }

    func testGroupedTensAndUnit() async {
        // 9 + (seventy + five = 75) -> "975".
        let r = await det().correct("climbing nine seventy five")
        XCTAssertEqual(r.corrected, "climbing 975")
    }

    func testNoNumbersIsUnchanged() async {
        let r = await det().correct("contact tower")
        XCTAssertFalse(r.changed)
        XCTAssertEqual(r.display, "contact tower")
    }

    // MARK: vocab matching

    func testCharacterNearMiss() async {
        let r = await det(vocab: ["Maverick"]).correct("inbound maverik")
        XCTAssertTrue(r.changed)
        XCTAssertEqual(r.corrected, "inbound Maverick")
        XCTAssertEqual(r.edits.first?.reason, "vocab match")
        XCTAssertEqual(r.edits.first?.to, "Maverick")
    }

    func testPhoneticFallback() async {
        // "golf" vs "Gulf": char ratio 0.75 < 0.84, but same phonetic key ("glf")
        // and ratio >= 0.62 -> phonetic match.
        let r = await det(vocab: ["Gulf"]).correct("over golf intersection")
        XCTAssertTrue(r.changed)
        XCTAssertEqual(r.corrected, "over Gulf intersection")
        XCTAssertEqual(r.edits.first?.reason, "phonetic match")
    }

    func testStopwordsAreProtected() async {
        // "right" is a stopword: never corrected even toward a close vocab term.
        let r = await det(vocab: ["Bright"]).correct("turn right")
        XCTAssertFalse(r.changed)
    }

    func testShortTokensSkipped() async {
        // "fix" is 3 chars (< min token length) -> never fuzzy-matched.
        let r = await det(vocab: ["six"]).correct("fix")
        XCTAssertFalse(r.changed)
    }

    func testKnownTermLeftAsIs() async {
        // A token already equal to a vocab term is not "corrected" onto itself.
        let r = await det(vocab: ["Maverick"]).correct("Maverick")
        XCTAssertFalse(r.changed)
    }

    // MARK: factory & chain

    func testDisabledConfigIsNullCorrector() async {
        let c = buildCorrector(config: CorrectionConfig(), vocab: { ["Maverick"] })
        XCTAssertTrue(c is NullCorrector)
        let r = await c.correct("inbound maverik")
        XCTAssertFalse(r.changed)
    }

    func testEnabledDeterministicCorrects() async {
        var cfg = CorrectionConfig()
        cfg.enabled = true
        let c = buildCorrector(config: cfg, vocab: { ["Maverick"] })
        let r = await c.correct("inbound maverik")
        XCTAssertEqual(r.corrected, "inbound Maverick")
    }
}
