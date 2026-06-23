import XCTest
@testable import ATCTranscribe

/// These tests encode the observed behavior of `atc_corrector.py` so the Swift port
/// stays faithful. Each assertion corresponds to a documented rule in the Python.
final class ATCCorrectorTests: XCTestCase {

    private func det(vocab: [String] = [],
                     threshold: Double = 0.84,
                     phonetic: Bool = true,
                     phoneticMin: Double = 0.62) -> DeterministicCorrector {
        DeterministicCorrector(vocabProvider: { vocab }, threshold: threshold,
                               phonetic: phonetic, phoneticMin: phoneticMin, numbers: true)
    }

    // MARK: SequenceMatcher.ratio() vs known difflib values

    func testRatioMatchesDifflib() {
        XCTAssertEqual(SequenceMatcher("maverik", "maverick").ratio(), 14.0 / 15.0, accuracy: 1e-9)
        XCTAssertEqual(SequenceMatcher("golf", "gulf").ratio(), 0.75, accuracy: 1e-9)
        XCTAssertEqual(SequenceMatcher("", "").ratio(), 1.0, accuracy: 0.0)
        XCTAssertEqual(SequenceMatcher("abc", "xyz").ratio(), 0.0, accuracy: 0.0)
    }

    // MARK: number normalization (vocab-independent)

    func testIcaoNumberWords() {
        // "niner" -> 9; "thousand" is not a number word so it terminates the run.
        let r = det().correct("descend niner thousand")
        XCTAssertTrue(r.changed)
        XCTAssertEqual(r.corrected, "descend 9 thousand")
        XCTAssertEqual(r.edits.first?.reason, "number")
    }

    func testGroupedTensAndUnit() {
        // 9 + (seventy + five = 75) -> "975".
        XCTAssertEqual(det().correct("climbing nine seventy five").corrected, "climbing 975")
    }

    func testNoNumbersIsUnchanged() {
        let r = det().correct("contact tower")
        XCTAssertFalse(r.changed)
        XCTAssertEqual(r.display, "contact tower")
    }

    // MARK: vocab matching

    func testCharacterNearMiss() {
        let r = det(vocab: ["Maverick"]).correct("inbound maverik")
        XCTAssertTrue(r.changed)
        XCTAssertEqual(r.corrected, "inbound Maverick")
        XCTAssertEqual(r.edits.first?.reason, "vocab match")
        XCTAssertEqual(r.edits.first?.to, "Maverick")
    }

    func testPhoneticFallback() {
        // "golf" vs "Gulf": char ratio 0.75 < 0.84, but same phonetic key ("glf")
        // and ratio >= 0.62 -> phonetic match.
        let r = det(vocab: ["Gulf"]).correct("over golf intersection")
        XCTAssertTrue(r.changed)
        XCTAssertEqual(r.corrected, "over Gulf intersection")
        XCTAssertEqual(r.edits.first?.reason, "phonetic match")
    }

    func testStopwordsAreProtected() {
        // "right" is a stopword: never corrected even toward a close vocab term.
        let r = det(vocab: ["Bright"]).correct("turn right")
        XCTAssertFalse(r.changed)
    }

    func testShortTokensSkipped() {
        // "fix" is 3 chars (< min token length) -> never fuzzy-matched.
        XCTAssertFalse(det(vocab: ["six"]).correct("fix").changed)
    }

    func testKnownTermLeftAsIs() {
        // A token already equal to a vocab term is not "corrected" onto itself.
        XCTAssertFalse(det(vocab: ["Maverick"]).correct("Maverick").changed)
    }

    // MARK: factory & chain

    func testDisabledConfigIsNullCorrector() {
        let c = buildCorrector(config: CorrectionConfig(), vocab: { ["Maverick"] })
        XCTAssertTrue(c is NullCorrector)
        XCTAssertFalse(c.correct("inbound maverik").changed)
    }

    func testEnabledDeterministicCorrects() {
        var cfg = CorrectionConfig()
        cfg.enabled = true
        let c = buildCorrector(config: cfg, vocab: { ["Maverick"] })
        XCTAssertEqual(c.correct("inbound maverik").corrected, "inbound Maverick")
    }
}
