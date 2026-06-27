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

    // Multi-field fusion fix (see `joinDigitChunks`): a lone digit wedged between two 2-digit
    // groups marks distinct spoken fields, so the run no longer fuses into one implausible blob —
    // while digit-by-digit reads (headings/squawks/tail numbers) and grouped flight numbers stay
    // fused. Battery distilled from a 56-case ATC phraseology review.
    func testNumberNormalizationBattery() async {
        let cases: [(String, String)] = [
            // Reported bug: distinct spoken groups must not fuse into an implausible 5-digit number.
            ("roger fifty six six eighteen", "roger 56 6 18"),
            // Headings — read digit-by-digit and fused (leading zero preserved).
            ("turn left heading three four zero", "turn left heading 340"),
            ("turn right heading zero niner zero", "turn right heading 090"),
            ("fly heading three six zero", "fly heading 360"),
            // Flight levels / speeds.
            ("flight level three five zero", "flight level 350"),
            ("maintain two five zero knots", "maintain 250 knots"),
            // Squawk codes — 4 digits, fused.
            ("squawk four six seven one", "squawk 4671"),
            ("squawk seven seven zero zero", "squawk 7700"),
            ("squawk zero two zero zero", "squawk 0200"),
            // Grouped (paired) flight numbers stay fused.
            ("american twelve thirty four turn left heading one eight zero", "american 1234 turn left heading 180"),
            ("delta eight ninety contact departure", "delta 890 contact departure"),
            ("speedbird two niner heavy contact tower", "speedbird 29 heavy contact tower"),
            // Long pure digit-by-digit tail number stays fused.
            ("november one two three four five descend", "november 12345 descend"),
            // A number run is split at non-number words; tens+unit merge preserved.
            ("traffic twelve o'clock five miles flight level three one zero",
             "traffic 12 o'clock 5 miles flight level 310"),
            ("runway two seven left", "runway 27 left"),
            ("climbing nine seventy five", "climbing 975"),
        ]
        for (input, expected) in cases {
            let r = await det().correct(input)
            XCTAssertEqual(r.display, expected, "input: ‘\(input)’")
        }
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
