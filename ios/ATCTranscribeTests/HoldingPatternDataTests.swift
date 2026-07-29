import XCTest
@testable import ATCTranscribe

/// Holding patterns asserted against the REAL bundled `cifp.sqlite`, not fixtures.
///
/// The FAF-deletion regression shipped past a fully green suite because every test asserted on shape
/// rather than on data. These check the actual coded corpus: that holds are found, that their
/// published fields survive the read, and that the shapes which look like fixture edge cases
/// (left-hand turns, two holds at ONE fix, course reversals living on transition rows) are real.
final class HoldingPatternDataTests: XCTestCase {

    /// Every hold leg in the corpus carries the two fields a pattern cannot be drawn or entered
    /// without. Measured at cycle 2607: 16,990 hold legs, 0 missing either. If this ever fails the
    /// builder has regressed, and holds must NOT be silently invented — `HoldingPattern.init?`
    /// returns nil, which this asserts is never needed for real data.
    func testEveryPublishedHoldHasCourseAndTurnDirection() throws {
        var checked = 0, unusable = 0
        for airport in ["K15", "K01", "K09", "PABA", "KBOS", "KDEN", "KSFO"] {
            for proc in CIFP.procedures(airport: airport) where proc.kind == "IAP" {
                for leg in CIFP.legs(procedureID: proc.id) where ["HF", "HM", "HA"].contains(leg.legType) {
                    checked += 1
                    if HoldingPattern(leg: leg, kind: .enroute) == nil { unusable += 1 }
                }
            }
        }
        try XCTSkipIf(checked == 0, "bundled CIFP unavailable in this environment")
        XCTAssertEqual(unusable, 0, "\(unusable) of \(checked) published holds lacked course or turn direction")
        XCTAssertGreaterThan(checked, 10, "expected a meaningful number of holds in the sample")
    }

    /// THE REGRESSION THAT MADE THE FEATURE INERT. Every HF leg in the corpus lives in a TRANSITION
    /// row — cycle 2607 has 6,689 of them there and ZERO in the approach-proper row (transition = "").
    /// Resolving holds only from the approach proper therefore never found a course reversal, so the
    /// skip control could never appear. This pins the shape of the data that makes that true.
    func testCourseReversalsLiveInTransitionRowsNotTheApproachProper() throws {
        var inTransition = 0, inProper = 0
        for airport in ["K15", "K01", "K09", "KBOS", "KDEN"] {
            for proc in CIFP.procedures(airport: airport) where proc.kind == "IAP" {
                let hf = CIFP.legs(procedureID: proc.id).filter { $0.legType == "HF" }.count
                if proc.transition.isEmpty { inProper += hf } else { inTransition += hf }
            }
        }
        try XCTSkipIf(inTransition + inProper == 0, "no HF legs in this sample/cycle")
        XCTAssertGreaterThan(inTransition, 0, "course reversals are published on transition rows")
        XCTAssertEqual(inProper, 0, "if HF legs ever appear on the approach proper, revisit the resolve path")
    }

    /// K15 "S32" is a real published approach whose HILPT and missed-approach hold sit at the SAME
    /// FIX (SHY) with LEFT turns — both of the shapes most likely to be got wrong. It pins that the
    /// two stay distinguished (id, kind) rather than collapsing into one.
    func testTwoHoldsAtOneFixAreDistinctAndLeftHanded() throws {
        let procs = CIFP.procedures(airport: "K15").filter { $0.kind == "IAP" && $0.ident == "S32" }
        try XCTSkipIf(procs.isEmpty, "K15 S32 not in this cycle")
        let legs = CIFP.legs(procedureID: procs[0].id)
        let holdLegs = legs.filter { ["HF", "HM", "HA"].contains($0.legType) }
        try XCTSkipIf(holdLegs.isEmpty, "K15 S32 has no holds in this cycle")

        // Both published holds are LEFT-hand — the 1-in-6 case a standard-right assumption reverses.
        for leg in holdLegs {
            XCTAssertEqual(leg.turnDirection.uppercased(), "L",
                           "K15 S32 hold at \(leg.fix) seq \(leg.seq) should be left-hand")
        }
        // Same fix, different sequence → different identity. A collision would make skipping one hold
        // silently skip the other.
        let sameFix = holdLegs.filter { $0.fix == "SHY" }
        if sameFix.count >= 2 {
            let ids = Set(sameFix.map { HoldingPattern(leg: $0, kind: .enroute)?.id })
            XCTAssertEqual(ids.count, sameFix.count, "two holds at one fix must not share an id")
        }
    }

    /// The resolver, run over a real approach's real legs, must classify by SEGMENT: anything inside
    /// the missed segment is a missed-approach hold, never a course reversal.
    func testResolverClassifiesARealApproachBySegment() throws {
        let procs = CIFP.procedures(airport: "K15").filter { $0.kind == "IAP" && $0.ident == "S32" }
        try XCTSkipIf(procs.isEmpty, "K15 S32 not in this cycle")
        let legs = CIFP.legs(procedureID: procs[0].id)
        let split = ApproachActivation.splitMissed(
            legs.map { (seq: $0.seq, fix: $0.fix, legType: $0.legType) }, roles: legs.map(\.role))
        let holds = ApproachHolds.resolve(legs: legs, missedSeqs: Set(split.missed), arrivingFrom: nil, variation: { _ in 0 })
        try XCTSkipIf(holds.isEmpty, "no resolvable holds in this cycle")

        for h in holds {
            guard let leg = legs.first(where: { "\($0.fix)-\($0.seq)" == h.pattern.id }) else { continue }
            if split.missed.contains(leg.seq) {
                XCTAssertNotEqual(h.pattern.kind, .holdInLieuOfProcedureTurn,
                                  "\(h.pattern.fix) seq \(leg.seq) is in the missed segment")
                XCTAssertFalse(h.isSkippable, "a missed-approach hold is not routinely skipped")
            }
        }
        // Every resolved pattern draws a closed racetrack that starts and ends at its fix.
        for h in holds {
            let track = h.pattern.racetrack(magneticVariation: 0)
            XCTAssertGreaterThan(track.count, 8, "\(h.pattern.fix) racetrack is degenerate")
            XCTAssertEqual(track.first!.lat, h.pattern.coord.lat, accuracy: 1e-9)
            XCTAssertEqual(track.last!.lat, h.pattern.coord.lat, accuracy: 1e-9)
        }
    }
}
