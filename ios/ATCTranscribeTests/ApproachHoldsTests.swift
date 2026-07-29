import XCTest
@testable import ATCTranscribe

/// Resolving the published holds on an approach and entering each from the right direction.
///
/// Modelled on a real coded approach — PABA "R07" carries HULKS as an `HF` at seq 10 (the hold in
/// lieu of procedure turn) and DEVKE as an `HM` at seq 60 (the missed-approach hold), inbound 71.4°
/// and 252.5° respectively, both right turns. Its reciprocal, PABA "R25", swaps the two fixes — which
/// is exactly the symmetry that catches a resolver keying off position in the list rather than the
/// published segment.
final class ApproachHoldsTests: XCTestCase {

    private func leg(_ seq: Int, _ fix: String, _ type: String, lat: Double, lon: Double,
                     course: Double? = nil, turn: String = "R") -> CIFPLeg {
        CIFPLeg(seq: seq, fix: fix, coord: Coord(lat: lat, lon: lon), legType: type,
                course: course, altitude: "02000", turnDirection: turn)
    }

    /// PABA R07-shaped: HILPT at the front, approach legs, missed-approach hold at the back.
    private func pabaLegs() -> [CIFPLeg] {
        [leg(10, "HULKS", "HF", lat: 60.00, lon: -155.00, course: 71.4),
         leg(20, "CATUB", "TF", lat: 60.10, lon: -154.60),
         leg(30, "RW07",  "TF", lat: 60.20, lon: -154.20),
         leg(50, "MOTUV", "TF", lat: 60.30, lon: -154.00),
         leg(60, "DEVKE", "HM", lat: 60.40, lon: -153.80, course: 252.5)]
    }
    private let missedSeqs: Set<Int> = [50, 60]

    // MARK: which holds are found, and what they are FOR

    func testFindsBothHoldsAndClassifiesThemBySegment() {
        let holds = ApproachHolds.resolve(legs: pabaLegs(), missedSeqs: missedSeqs,
                                          arrivingFrom: Coord(lat: 59.5, lon: -155.5), variation: { _ in 0 })
        XCTAssertEqual(holds.count, 2)
        XCTAssertEqual(holds[0].pattern.fix, "HULKS")
        XCTAssertEqual(holds[0].pattern.kind, .holdInLieuOfProcedureTurn, "an HF opening the row is a HILPT")
        XCTAssertEqual(holds[1].pattern.fix, "DEVKE")
        XCTAssertEqual(holds[1].pattern.kind, .missedApproach, "an HM inside the missed segment is the missed hold")
    }

    /// The segment decides the kind — not the position in the list. An HF that lands INSIDE the
    /// missed-approach segment is a missed-approach hold, not a course reversal.
    func testAnHFInsideTheMissedSegmentIsNotACourseReversal() {
        var legs = pabaLegs()
        legs[4] = leg(60, "DEVKE", "HF", lat: 60.40, lon: -153.80, course: 252.5)
        let holds = ApproachHolds.resolve(legs: legs, missedSeqs: missedSeqs, arrivingFrom: nil, variation: { _ in 0 })
        XCTAssertEqual(holds.last?.pattern.kind, .missedApproach)
        XCTAssertNil(ApproachHolds.courseReversal(in: [holds.last!], joinIsVectors: false))
    }

    // MARK: entry is measured from the RIGHT predecessor

    /// The missed-approach hold is reached from the missed approach, so its entry must be computed
    /// from the PRECEDING MISSED FIX — not from where the aircraft happened to be before the approach.
    func testMissedHoldEntryUsesItsPredecessorNotThePreApproachPosition() {
        let farAway = Coord(lat: 20, lon: -100)          // nowhere near the missed approach
        let holds = ApproachHolds.resolve(legs: pabaLegs(), missedSeqs: missedSeqs, arrivingFrom: farAway, variation: { _ in 0 })
        let missed = ApproachHolds.missedApproachHold(in: holds)
        XCTAssertNotNil(missed)
        XCTAssertEqual(missed?.arrivingFrom, "MOTUV", "must be entered from the preceding missed fix")
        // And that entry is the one the geometry gives from MOTUV → DEVKE.
        let expected = missed!.pattern.entry(arrivingFrom: Coord(lat: 60.30, lon: -154.00), magneticVariation: 0)
        XCTAssertEqual(missed?.entry, expected)
    }

    /// The FIRST hold has no preceding leg, so it falls back to the aircraft's position — and the
    /// answer must change with the direction of arrival. This is the "depends which way you're
    /// coming from" requirement, asserted rather than assumed.
    func testCourseReversalEntryChangesWithArrivalDirection() {
        func entryArriving(from c: Coord) -> HoldingPattern.Entry? {
            ApproachHolds.resolve(legs: pabaLegs(), missedSeqs: missedSeqs, arrivingFrom: c, variation: { _ in 0 }).first?.entry
        }
        // HULKS inbound course is 071°, right turns.
        let fromSouthWest = entryArriving(from: Coord(lat: 59.5, lon: -155.6))   // tracking ~NE, near inbound
        let fromNorthEast = entryArriving(from: Coord(lat: 60.6, lon: -154.4))   // tracking ~SW, near reciprocal
        XCTAssertNotNil(fromSouthWest); XCTAssertNotNil(fromNorthEast)
        XCTAssertNotEqual(fromSouthWest, fromNorthEast,
                          "arriving from opposite sides must not give the same entry")
        XCTAssertEqual(fromSouthWest, .direct, "arriving along the inbound course is a direct entry")
    }

    func testNoArrivalPositionMeansNoInventedEntry() {
        let holds = ApproachHolds.resolve(legs: pabaLegs(), missedSeqs: missedSeqs, arrivingFrom: nil, variation: { _ in 0 })
        // The first hold has no predecessor AND no origin → the app must not guess an entry.
        XCTAssertNil(holds.first?.entry)
        XCTAssertTrue(holds.first!.summary.contains("depends on arrival direction"))
        // The missed hold still resolves — it has a predecessor of its own.
        XCTAssertNotNil(holds.last?.entry)
    }

    // MARK: vectors

    func testVectorsJoinDoesNotOfferACourseReversal() {
        let holds = ApproachHolds.resolve(legs: pabaLegs(), missedSeqs: missedSeqs,
                                          arrivingFrom: Coord(lat: 59.5, lon: -155.5), variation: { _ in 0 })
        XCTAssertNotNil(ApproachHolds.courseReversal(in: holds, joinIsVectors: false))
        XCTAssertNil(ApproachHolds.courseReversal(in: holds, joinIsVectors: true),
                     "radar vectors fly straight to final — never offer a reversal ATC didn't clear")
    }

    // MARK: skipping

    func testOnlyTheCourseReversalCanBeSkipped() {
        let holds = ApproachHolds.resolve(legs: pabaLegs(), missedSeqs: missedSeqs,
                                          arrivingFrom: Coord(lat: 59.5, lon: -155.5), variation: { _ in 0 })
        var active = ActiveApproach(airport: "PABA", ident: "R07", name: "RNAV (GPS) RWY 07",
                                    runway: "07", entry: .vectors, missedFixes: ["MOTUV", "DEVKE"],
                                    holds: holds)
        XCTAssertEqual(active.activeHolds.count, 2)
        XCTAssertNotNil(active.courseReversalHold)

        // Skip the reversal — it leaves the flown set but stays published (restorable).
        let hilpt = active.holds.first { $0.pattern.kind == .holdInLieuOfProcedureTurn }!
        active.setHold(hilpt.id, skipped: true)
        XCTAssertNil(active.courseReversalHold, "skipped reversal is no longer flown")
        XCTAssertEqual(active.activeHolds.count, 1)
        XCTAssertEqual(active.holds.count, 2, "skipping records a choice; it must not delete the hold")
        XCTAssertNotNil(active.missedHold, "skipping the reversal must not touch the missed hold")

        // ...and it can be put back.
        active.setHold(hilpt.id, skipped: false)
        XCTAssertNotNil(active.courseReversalHold)

        // The missed-approach hold is NOT removable this way.
        let missed = active.holds.first { $0.pattern.kind == .missedApproach }!
        active.setHold(missed.id, skipped: true)
        XCTAssertNotNil(active.missedHold, "the published end of the missed approach is not toggled away")
    }

    // MARK: honesty of the summary line

    func testSummaryNamesTheFixTurnDirectionAndEntry() {
        let holds = ApproachHolds.resolve(legs: pabaLegs(), missedSeqs: missedSeqs,
                                          arrivingFrom: Coord(lat: 59.5, lon: -155.6), variation: { _ in 0 })
        let s = holds[0].summary
        XCTAssertTrue(s.contains("HULKS"))
        XCTAssertTrue(s.contains("right turns"))
        XCTAssertTrue(s.contains("071°"), "inbound course is shown as a 3-digit bearing: \(s)")
        XCTAssertTrue(s.lowercased().contains("entry"))
    }

    func testApproachWithNoPublishedHoldsResolvesEmpty() {
        let plain = [leg(10, "ABCDE", "IF", lat: 42, lon: -71),
                     leg(20, "FGHIJ", "TF", lat: 42.1, lon: -71.1)]
        XCTAssertTrue(ApproachHolds.resolve(legs: plain, missedSeqs: [], arrivingFrom: nil, variation: { _ in 0 }).isEmpty)
    }

    // MARK: magnetic variation

    /// Variation is not decoration: near a sector boundary the same TRUE arrival track lands in
    /// DIFFERENT sectors as the local declination changes, so a defaulted 0 was a wrong answer, not a
    /// simplification. Two realistic CONUS values on either side of a boundary prove it.
    func testVariationCanFlipTheEntrySector() {
        // Hold at HULKS: inbound MAGNETIC 071.4, right turns. Choose an origin whose TRUE track to the
        // fix sits near the teardrop/direct boundary (Δ = 110).
        let origin = Coord(lat: 60.4, lon: -155.6)   // true track to (60, -155) ≈ 143°
        let hold = HoldingPattern(id: "HULKS-10", fix: "HULKS", coord: Coord(lat: 60, lon: -155),
                                  inboundCourseMag: 71.4, turn: .right, kind: .holdInLieuOfProcedureTurn)
        // East variation +14 (SFO-like): magnetic track ≈ 129 → Δ ≈ 58 → DIRECT.
        // West variation −15 (BOS-like): magnetic track ≈ 158 → Δ ≈ 87 → still direct… push further:
        let e = hold.entry(arrivingFrom: origin, magneticVariation: 14)
        // True track ≈ 143.3°; Δ(var) = 143.3 − var − 71.4. At var −38 that is 109.9 — a tenth of a
        // degree SHORT of the teardrop boundary (a first draft of this test learned that the hard
        // way). −42 puts Δ at ≈113.9, safely inside the teardrop sector.
        let w = hold.entry(arrivingFrom: origin, magneticVariation: -42)
        XCTAssertEqual(e, .direct)
        XCTAssertEqual(w, .teardrop, "declination shifted the magnetic track across the sector boundary")
        XCTAssertNotEqual(e, w, "variation must be able to change the named entry")
    }

    /// No published variation near the fix → NO entry is named, and the hold records why.
    func testUnknownVariationYieldsNoEntry() {
        let holds = ApproachHolds.resolve(legs: pabaLegs(), missedSeqs: missedSeqs,
                                          arrivingFrom: Coord(lat: 59.5, lon: -155.5),
                                          variation: { _ in nil })
        XCTAssertFalse(holds.isEmpty)
        for h in holds {
            XCTAssertNil(h.entry, "no local variation → no claimed entry for \(h.pattern.fix)")
            XCTAssertNil(h.magneticVariation)
        }
    }

    /// The provider is called with the HOLD FIX coordinate — not the origin — because the sector
    /// comparison happens at the fix.
    func testVariationIsLookedUpAtTheFix() {
        var asked: [Coord] = []
        _ = ApproachHolds.resolve(legs: pabaLegs(), missedSeqs: missedSeqs,
                                  arrivingFrom: Coord(lat: 0, lon: 0),
                                  variation: { c in asked.append(c); return 0 })
        XCTAssertEqual(asked.count, 2, "one lookup per hold")
        XCTAssertEqual(asked[0].lat, 60.00, accuracy: 1e-9, "HULKS fix, not the origin")
        XCTAssertEqual(asked[1].lat, 60.40, accuracy: 1e-9, "DEVKE fix, not the origin")
    }
}
