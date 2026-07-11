import XCTest
@testable import ATCTranscribe

/// Perf-batch pure-logic tests (L9 transcript ordering + equality, L10 traffic reconcile).
final class PerfBatchTests: XCTestCase {

    // MARK: - L9: transcript ordering + Equatable repaint semantics

    private func record(_ text: String, callsign: String? = nil) -> TranscriptRecord {
        TranscriptRecord(text: text, streamStartS: 0, streamEndS: 0, audioDurationMs: 0,
                         captureToTextMs: 0, transcribeMs: 0, realTimeFactor: 0, prompt: "",
                         corrected: "", corrections: [], timestamp: "00:00", callsign: callsign)
    }

    func testOrderedNewestLastIsIdentity() {
        let recs = [record("a"), record("b"), record("c")]
        let out = TranscriptListSection.ordered(recs, filter: nil, newestFirst: false)
        XCTAssertEqual(out.map(\.text), ["a", "b", "c"])
    }

    func testOrderedNewestFirstReverses() {
        let recs = [record("a"), record("b"), record("c")]
        let out = TranscriptListSection.ordered(recs, filter: nil, newestFirst: true)
        XCTAssertEqual(out.map(\.text), ["c", "b", "a"])
    }

    func testOrderedFilterKeepsOneAircraftThenReverses() {
        let recs = [record("a", callsign: "N1"), record("b", callsign: "N2"), record("c", callsign: "N1")]
        XCTAssertEqual(TranscriptListSection.ordered(recs, filter: "N1", newestFirst: false).map(\.text), ["a", "c"])
        XCTAssertEqual(TranscriptListSection.ordered(recs, filter: "N1", newestFirst: true).map(\.text), ["c", "a"])
        XCTAssertTrue(TranscriptListSection.ordered(recs, filter: "N9", newestFirst: false).isEmpty)
    }

    func testRecordEqualityDetectsInPlaceRefinement() {
        // The Equatable list section compares the FULL records array — an in-place refinement
        // (same id, new llmCorrected) must compare UNEQUAL so the row repaints.
        var a = record("cleared to land")
        var b = a                                  // same id — a copy of the same record
        XCTAssertEqual(a, b)
        b.llmCorrected = "cleared to land runway 4"
        XCTAssertNotEqual(a, b, "an in-place refinement must not be swallowed by ==")
        a.refinementState = .refined
        XCTAssertNotEqual(a, b)
    }

    // MARK: - L10: traffic reconcile set-diff

    func testReconcileDisjointSets() {
        let p = TrafficReconcile.plan(existing: ["a", "b"], incoming: ["c", "d"])
        XCTAssertEqual(p.add, ["c", "d"])
        XCTAssertEqual(p.remove, ["a", "b"])       // sorted
        XCTAssertTrue(p.update.isEmpty)
    }

    func testReconcileOverlap() {
        let p = TrafficReconcile.plan(existing: ["a", "b", "c"], incoming: ["b", "c", "d"])
        XCTAssertEqual(p.add, ["d"])
        XCTAssertEqual(p.remove, ["a"])
        XCTAssertEqual(p.update, ["b", "c"])       // preserves incoming order
    }

    func testReconcileAllSurvive() {
        let p = TrafficReconcile.plan(existing: ["a", "b"], incoming: ["a", "b"])
        XCTAssertTrue(p.add.isEmpty)
        XCTAssertTrue(p.remove.isEmpty)
        XCTAssertEqual(p.update, ["a", "b"])
    }

    func testReconcileEmptyIncomingRemovesAll() {
        let p = TrafficReconcile.plan(existing: ["a", "b"], incoming: [])
        XCTAssertTrue(p.add.isEmpty)
        XCTAssertEqual(p.remove, ["a", "b"])
        XCTAssertTrue(p.update.isEmpty)
    }

    func testReconcileFromEmptyExistingAddsAll() {
        let p = TrafficReconcile.plan(existing: [], incoming: ["x", "y"])
        XCTAssertEqual(p.add, ["x", "y"])
        XCTAssertTrue(p.remove.isEmpty)
        XCTAssertTrue(p.update.isEmpty)
    }

    // MARK: - L4: EFB grounding builder (off-main, dedupe/uppercase)

    func testBuildEFBGroundingDedupesAndUppercasesRouteAndEndpoints() {
        // Empty ident → no CIFP scan needed, so this runs without the bundled db: it exercises the
        // route-fix + endpoint-airport merge (the part that doesn't touch SQLite).
        // endpointAirports is always exactly [departure, destination, alternate] (≤3).
        let g = AppModel.buildEFBGrounding(ident: "",
                                           routeIdents: ["bosox", "BOSOX", "crltn", ""],
                                           endpointAirports: ["kbos", "KBOS", "kord"])
        XCTAssertEqual(g.fixes, ["BOSOX", "CRLTN"], "route fixes uppercased + de-duped, empties dropped")
        XCTAssertEqual(g.airports, ["KBOS", "KORD"], "endpoints uppercased + de-duped (kbos == KBOS)")
        XCTAssertTrue(g.sids.isEmpty)   // no ident → no CIFP procedures
        XCTAssertTrue(g.stars.isEmpty)
    }

    func testBuildEFBGroundingEmptyInputsYieldEmptyGrounding() {
        let g = AppModel.buildEFBGrounding(ident: "", routeIdents: [], endpointAirports: [])
        XCTAssertTrue(g.fixes.isEmpty && g.airports.isEmpty && g.sids.isEmpty && g.stars.isEmpty)
    }
}
