import XCTest
@testable import ATCTranscribe

/// The two paths that can activate an approach must publish the SAME holds.
///
/// An approach becomes active either because the pilot hand-activated it (`activateApproach`) or
/// because ATC cleared them for it over the air and the transcription was accepted
/// (`acceptEFBSuggestion` → `loadApproachForRunway`). The second path shipped without resolving holds
/// at all, so the racetrack, the entry statement and the skip control appeared only for the first —
/// on the path a pilot is LESS likely to use. Both now read the approach-proper row through one
/// shared helper; these tests pin that they agree, so the two cannot drift apart again.
///
/// Asserted against the REAL bundled `cifp.sqlite`, not fixtures: KBED "RNAV (GPS) RWY 23" (ident
/// R23) publishes exactly one hold on its approach-proper row — an `HM` at WHYBE, inbound 268°,
/// RIGHT turns — and runway 23 at KBED has exactly ONE published approach, so the runway match
/// cannot pick a different procedure and make the comparison meaningless.
@MainActor
final class ApproachHoldParityTests: XCTestCase {

    private let airport = "KBED"
    private let ident = "R23"
    private let runway = "23"

    override func setUp() {
        super.setUp()
        // Keep the model hermetic: constructing AppModel reconciles its live services, and the TFR
        // layer defaults ON — which would fire a real FAA fetch from a unit test.
        UserDefaults.standard.set(false, forKey: "atc.map.tfrs")
        UserDefaults.standard.set(false, forKey: "atc.autoPackBag")
        FlightPlan.clear()          // both paths file a plan; start each test from nothing
        MagneticVariation.resetForTests()
    }

    /// The unit bundle is APP-HOSTED, so `UserDefaults.standard` here IS the app's own preferences.
    /// Without this, a test run leaves the simulator with the live TFR layer switched OFF, Flight Bag
    /// auto-pack off, KBED in the airport box and an approach filed — state no user chose, inherited
    /// by the next launch and by the UI suite. Removing the keys restores the shipped defaults
    /// (both read as "absent means ON"). Same reason `FlightPlanTests` clears its plan.
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "atc.map.tfrs")
        UserDefaults.standard.removeObject(forKey: "atc.autoPackBag")
        UserDefaults.standard.removeObject(forKey: "atc.airport")
        FlightPlan.clear()
        MagneticVariation.resetForTests()
        super.tearDown()
    }

    /// A model that will not reach the network. Assigning `flightPlan` fires `prefetchRouteCharts()`
    /// and the Flight Bag auto-pack, so activating an approach from a test would hit the live chart
    /// catalog and could pull a ~28 MB sectional. `diagnosticActive` is the flag the didSet already
    /// consults for exactly this reason (see AppModel's plan didSet). It also suppresses
    /// `reconcileActiveApproach`, which is a no-op here — `activeApproach` is still nil when the plan
    /// is edited on both paths — and is not what these tests assert.
    private func sandboxedModel() -> AppModel {
        let m = AppModel()
        m.diagnosticActive = true
        m.airport = airport
        return m
    }

    /// The approach used here must keep the shape the comparison depends on. If the cycle changes and
    /// this stops holding, the parity tests below are asserting nothing and must be re-pointed.
    private func requireFixture() throws -> CIFPProcedure {
        let iaps = CIFP.procedures(airport: airport).filter { $0.kind == "IAP" }
        try XCTSkipIf(iaps.isEmpty, "bundled CIFP unavailable in this environment")
        let onRunway = Set(iaps.filter { $0.runway == runway }.map(\.ident))
        try XCTSkipIf(onRunway.isEmpty, "\(airport) publishes no approach to runway \(runway) this cycle")
        XCTAssertEqual(onRunway, [ident],
                       "runway \(runway) must have exactly one approach or the runway match is ambiguous")
        let proper = try XCTUnwrap(CIFP.approachProper(airport: airport, ident: ident))
        return proper
    }

    /// The ATC-cleared path, driven through its REAL entry point: an accepted EFB suggestion carrying
    /// a `.clearedApproach` instruction, exactly as an accepted transcription produces.
    private func activeApproachFromATCClearance(_ model: AppModel) -> ActiveApproach? {
        let instruction = ATCInstruction(kind: .clearedApproach, target: runway, qualifier: "RNAV",
                                         rawTranscript: "cleared rnav runway two three approach",
                                         confidence: .high, addressedToOwnship: true)
        model.efbSuggestion = EFBSuggestion.make(id: "test-cleared", instruction: instruction,
                                                 source: "test")
        model.acceptEFBSuggestion()
        return model.activeApproach
    }

    func testBothPathsPublishTheSameHolds() throws {
        let proc = try requireFixture()

        let handModel = sandboxedModel()
        handModel.activateApproach(proc, entry: .vectors)
        let handHolds = try XCTUnwrap(handModel.activeApproach).holds

        FlightPlan.clear()                       // the two models must not inherit each other's plan
        let atcModel = sandboxedModel()
        let cleared = try XCTUnwrap(activeApproachFromATCClearance(atcModel),
                                    "the clearance did not activate an approach at all")
        XCTAssertEqual(cleared.ident, ident, "the clearance loaded a different approach")

        // The whole point: same approach, same join, same holds — pattern, entry, arrival origin and
        // the magnetic variation used to pick the entry.
        XCTAssertEqual(cleared.holds, handHolds, "the two activation paths disagree about the holds")
        XCTAssertFalse(handHolds.isEmpty, "this approach publishes a hold — a passing empty comparison "
                       + "would assert nothing")
    }

    /// The regression itself, stated directly: a cleared approach carries its published hold. Kept
    /// separate from the parity test so a future change that broke BOTH paths equally still fails.
    func testATCClearedApproachCarriesItsPublishedHold() throws {
        _ = try requireFixture()
        let model = sandboxedModel()
        let cleared = try XCTUnwrap(activeApproachFromATCClearance(model))

        XCTAssertEqual(cleared.holds.count, 1, "R23 publishes exactly one hold on the approach proper")
        let hold = try XCTUnwrap(cleared.holds.first)
        XCTAssertEqual(hold.pattern.fix, "WHYBE")
        XCTAssertEqual(hold.pattern.turn, .right)
        XCTAssertEqual(hold.pattern.inboundCourseMag, 268, accuracy: 0.5)
        // It is the published END OF THE GO-AROUND, not a course reversal — so it must not be
        // offered as skippable, and the missed-approach accessor must find it.
        XCTAssertEqual(hold.pattern.kind, .missedApproach)
        XCTAssertFalse(hold.isSkippable, "a missed-approach hold is not routinely skipped")
        XCTAssertNotNil(cleared.missedHold)
        XCTAssertNil(cleared.courseReversalHold, "a vectors join offers no course reversal")
    }

    /// A vectors join drops the hold in lieu of procedure turn on BOTH paths. Asserted on the shared
    /// filter directly, because the course reversal lives on transition rows that neither path reads
    /// for a vectors join — so the corpus alone cannot demonstrate the rule.
    func testVectorsJoinDropsTheCourseReversalOnBothPaths() {
        let coord = Coord(lat: 42.47, lon: -71.29)
        let hilpt = ApproachHold(
            pattern: HoldingPattern(id: "X-10", fix: "X", coord: coord, inboundCourseMag: 90,
                                    turn: .right, kind: .holdInLieuOfProcedureTurn),
            entry: nil, arrivingFrom: "present position", magneticVariation: nil)
        let missed = ApproachHold(
            pattern: HoldingPattern(id: "Y-20", fix: "Y", coord: coord, inboundCourseMag: 268,
                                    turn: .right, kind: .missedApproach),
            entry: nil, arrivingFrom: "present position", magneticVariation: nil)

        let vectors = ApproachHolds.applicable([hilpt, missed], joinIsVectors: true)
        XCTAssertEqual(vectors, [missed], "a vectors join must not offer a course reversal")
        let viaIAF = ApproachHolds.applicable([hilpt, missed], joinIsVectors: false)
        XCTAssertEqual(viaIAF, [hilpt, missed], "an IAF join keeps the published course reversal")
    }
}
