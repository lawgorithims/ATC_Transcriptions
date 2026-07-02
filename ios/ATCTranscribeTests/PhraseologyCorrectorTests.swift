import XCTest
@testable import ATCTranscribe

/// The conservative multi-word ATC phraseology corrector (BB3): it must fix recognized mis-hears and
/// NEVER touch a correct readback or an ordinary use of an ambiguous word.
final class PhraseologyCorrectorTests: XCTestCase {
    private func fix(_ s: String) async -> Correction { await PhraseologyCorrector().correct(s, history: []) }

    func testHoldShortMishearsRepaired() async {
        let cases = [
            ("heal short of runway 4 left", "hold short of runway 4 left"),   // confirmed live mis-hear
            ("hill short of runway 27", "hold short of runway 27"),
            ("hole short of 9", "hold short of 9"),
            ("hold shore of runway 22 right", "hold short of runway 22 right"),
            ("heal short", "hold short"),
        ]
        for (input, expect) in cases {
            let c = await fix(input)
            XCTAssertTrue(c.changed, "should repair: \(input)")
            XCTAssertEqual(c.corrected, expect)
        }
    }

    func testFlightLevelAndLineUp() async {
        let fl = await fix("climb and maintain flight lever 350")
        XCTAssertEqual(fl.corrected, "climb and maintain flight level 350")
        let lu = await fix("runway 4 left line up and wait")
        XCTAssertFalse(lu.changed, "already-correct phraseology is untouched")
        let lu2 = await fix("runway 4 left line up in wait")
        XCTAssertEqual(lu2.corrected, "runway 4 left line up and wait")
    }

    func testInSightGatedByAtcSubject() async {
        XCTAssertEqual((await fix("traffic insight")).corrected, "traffic in sight")
        XCTAssertEqual((await fix("airport insight")).corrected, "airport in sight")
        // The ordinary word "insight" with no ATC subject must be left alone.
        XCTAssertFalse((await fix("thanks for the insight")).changed)
        XCTAssertFalse((await fix("insight is valuable")).changed)
    }

    func testCorrectReadbacksUntouched() async {
        for s in [
            "hold short of runway 4 left",
            "cleared to land runway 27",
            "climb and maintain flight level 240",
            "line up and wait runway 33 left",
            "november one two three four five contact ground",
            "descend and maintain three thousand",
        ] {
            let c = await fix(s)
            XCTAssertFalse(c.changed, "must not alter a correct transmission: \(s)")
            XCTAssertEqual(c.corrected, s)
        }
    }

    func testEditsAreRecorded() async {
        let c = await fix("heal short of runway 4 left")
        XCTAssertEqual(c.edits.count, 1)
        XCTAssertEqual(c.edits.first?.to, "hold short of")
    }
}
