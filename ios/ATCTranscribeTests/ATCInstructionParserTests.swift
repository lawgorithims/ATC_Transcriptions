import XCTest
@testable import ATCTranscribe

/// The structured instruction parser: numeric kinds + legacy passthrough + ownship binding.
/// Inputs are already NORMALIZED (single spaced digits), as the pipeline feeds it.
final class ATCInstructionParserTests: XCTestCase {

    private let noGrounding = ATCCommandParser.Grounding()
    private let callsignStarts: Set<String> = ["american", "delta", "united", "november"]
    private func addr(_ own: String) -> ATCCommandParser.Addressee {
        ATCCommandParser.Addressee(ownshipVariants: [own.split(separator: " ").map(String.init)],
                                   callsignStarts: callsignStarts)
    }
    private func parse(_ s: String, grounding: ATCCommandParser.Grounding? = nil,
                       addressee: ATCCommandParser.Addressee? = nil) -> ATCInstruction? {
        ATCInstructionParser.parse(s, grounding: grounding ?? noGrounding, snap: nil, asr: .unknown, addressee: addressee)
    }

    // MARK: numeric kinds (no addressee → whole transmission)

    func testAltitudeDescendAndMaintain() {
        let ins = parse("american 1 2 3 descend and maintain 8 thousand")
        XCTAssertEqual(ins?.kind, .altitude)
        XCTAssertEqual(ins?.value, 8000)
        XCTAssertEqual(ins?.target, "8000")
        XCTAssertEqual(ins?.modifier, "descend")
    }

    func testAltitudeFlightLevel() {
        XCTAssertEqual(parse("climb and maintain flight level 1 8 0")?.value, 18000)
    }

    func testTurnLeftHeading() {
        let ins = parse("turn left heading 0 9 0")
        XCTAssertEqual(ins?.kind, .heading)
        XCTAssertEqual(ins?.target, "090")
        XCTAssertEqual(ins?.modifier, "left")
    }

    func testFlyHeadingNoModifier() {
        let ins = parse("fly heading 2 7 0")
        XCTAssertEqual(ins?.kind, .heading)
        XCTAssertEqual(ins?.value, 270)
        XCTAssertEqual(ins?.modifier, "")
    }

    func testMaintainSpeed() {
        let ins = parse("maintain 2 5 0 knots")
        XCTAssertEqual(ins?.kind, .speed)
        XCTAssertEqual(ins?.value, 250)
    }

    func testMaintainAltitudeNotSpeedWhenNoKnots() {
        XCTAssertEqual(parse("maintain 5 thousand")?.kind, .altitude)
    }

    func testSquawk() {
        let ins = parse("squawk 4 2 3 1")
        XCTAssertEqual(ins?.kind, .squawk)
        XCTAssertEqual(ins?.target, "4231")
    }

    func testContactFrequency() {
        let ins = parse("contact tower 1 2 4 point 5")
        XCTAssertEqual(ins?.kind, .frequencyChange)
        XCTAssertEqual(ins?.target, "124.5")
        XCTAssertEqual(ins?.modifier, "tower")
    }

    // MARK: legacy passthrough

    func testLegacyDirectToPassthrough() {
        let ins = parse("american 1 2 3 cleared direct bosox", grounding: .init(fixes: ["BOSOX"]))
        XCTAssertEqual(ins?.kind, .directTo)
        XCTAssertEqual(ins?.target, "BOSOX")
    }

    func testLegacyApproachPassthrough() {
        let ins = parse("cleared ils runway 4 right", grounding: .init())
        XCTAssertEqual(ins?.kind, .clearedApproach)
        XCTAssertEqual(ins?.target, "04R")
        XCTAssertEqual(ins?.qualifier, "ILS")
    }

    // MARK: multi-aircraft ownship binding

    func testNumericBindsToOwnshipClause() {
        // heading is American 456's; altitude is ownship's (American 123) → altitude fires, not heading.
        let ins = parse("american 4 5 6 turn left heading 2 7 0 american 1 2 3 maintain 5 thousand",
                        addressee: addr("american 1 2 3"))
        XCTAssertEqual(ins?.kind, .altitude)
        XCTAssertEqual(ins?.value, 5000)
    }

    func testNumericToOtherAircraftAbstains() {
        // ownship (American 123) gets only an acknowledgement; the heading belongs to American 456 → nil.
        let ins = parse("american 1 2 3 roger american 4 5 6 turn left heading 2 7 0",
                        addressee: addr("american 1 2 3"))
        XCTAssertNil(ins, "an instruction to the other aircraft must not fire for ownship")
    }

    func testNumericToOwnshipFiresWithAddressee() {
        let ins = parse("american 1 2 3 turn left heading 2 7 0", addressee: addr("american 1 2 3"))
        XCTAssertEqual(ins?.kind, .heading)
        XCTAssertEqual(ins?.target, "270")
    }

    func testRetractionAbstains() {
        XCTAssertNil(parse("descend and maintain 8 thousand disregard maintain 6 thousand"),
                     "a retraction anywhere → abstain")
    }
}
