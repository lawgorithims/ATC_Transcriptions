import XCTest
@testable import ATCTranscribe

/// Gap C: the ownship callsign + next waypoint seed the Whisper DECODE prompt (head-placed so they
/// survive the transcriber's token cap).
final class ATCContextOwnshipTests: XCTestCase {

    func testOwnshipLineInPrompt() {
        let ctx = ATCContext()
        ctx.setOwnship(callsign: "N8925T", nextWaypoint: "BOSOX")
        let prompt = ctx.buildPrompt()
        XCTAssertTrue(prompt.contains("Own aircraft"))
        XCTAssertTrue(prompt.contains("eight nine two five"), "digits spell from the static table")
        XCTAssertTrue(prompt.contains("BOSOX"))
    }

    func testOwnshipLinePrecedesHistory() {
        let ctx = ATCContext()
        ctx.setOwnship(callsign: "N8925T", nextWaypoint: "BOSOX")
        ctx.update("some earlier transmission")
        let prompt = ctx.buildPrompt()
        let own = prompt.range(of: "Own aircraft")
        let hist = prompt.range(of: "Recent transmissions")
        XCTAssertNotNil(own); XCTAssertNotNil(hist)
        if let own, let hist { XCTAssertTrue(own.lowerBound < hist.lowerBound, "ownship line must sit in the prompt head") }
    }

    func testEmptyCallsignClearsOwnshipLine() {
        let ctx = ATCContext()
        ctx.setOwnship(callsign: "N1", nextWaypoint: "X")
        ctx.setOwnship(callsign: "", nextWaypoint: "")
        XCTAssertFalse(ctx.buildPrompt().contains("Own aircraft"))
    }
}
