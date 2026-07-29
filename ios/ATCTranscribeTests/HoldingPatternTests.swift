import XCTest
@testable import ATCTranscribe

/// The published holding-pattern entry rule (AIM 5-3-8) and the racetrack geometry.
///
/// Entry selection is the safety-relevant part: fly a parallel entry where a teardrop was required
/// and you leave protected airspace on the non-holding side. The sector table is therefore pinned
/// against hand-worked cases, at the boundaries, and mirrored for left-hand patterns — not just
/// spot-checked in the middle of each sector.
final class HoldingPatternTests: XCTestCase {

    private func hold(inbound: Double, turn: HoldingPattern.Turn = .right,
                      kind: HoldingPattern.Kind = .holdInLieuOfProcedureTurn) -> HoldingPattern {
        HoldingPattern(id: "TEST-10", fix: "TEST", coord: Coord(lat: 42, lon: -71),
                       inboundCourseMag: inbound, turn: turn, kind: kind)
    }

    // MARK: the sector table (standard, right-hand)

    func testDirectEntryCoversTheHoldingSideAndStraightIn() {
        let h = hold(inbound: 90)                       // inbound 090, right turns, pattern south
        // Arriving on the inbound course — you simply cross and turn right onto the outbound.
        XCTAssertEqual(h.entry(arrivingOn: 90), .direct)
        // Arriving southbound: cross, turn right onto 270. Still direct.
        XCTAssertEqual(h.entry(arrivingOn: 180), .direct)
        // Just inside the direct sector on each side of the inbound course.
        XCTAssertEqual(h.entry(arrivingOn: 199), .direct)   // Δ=109
        XCTAssertEqual(h.entry(arrivingOn: 20), .direct)    // Δ=290 (boundary, inclusive)
        XCTAssertEqual(h.entry(arrivingOn: 80), .direct)    // Δ=350
    }

    func testTeardropSectorIsThe70DegreeWedge() {
        let h = hold(inbound: 90)
        // Δ ∈ [110,180): approaching from the holding side, near the outbound direction.
        XCTAssertEqual(h.entry(arrivingOn: 200), .teardrop)   // Δ=110 (boundary, inclusive)
        XCTAssertEqual(h.entry(arrivingOn: 250), .teardrop)   // Δ=160
        XCTAssertEqual(h.entry(arrivingOn: 269), .teardrop)   // Δ=179
    }

    func testParallelSectorIsThe110DegreeWedge() {
        let h = hold(inbound: 90)
        // Δ ∈ [180,290): approaching on the NON-holding side of the outbound.
        XCTAssertEqual(h.entry(arrivingOn: 270), .parallel)   // Δ=180 (boundary, inclusive)
        XCTAssertEqual(h.entry(arrivingOn: 300), .parallel)   // Δ=210
        XCTAssertEqual(h.entry(arrivingOn: 19), .parallel)    // Δ=289
    }

    /// Every one of the 360 whole-degree arrival tracks lands in exactly one sector, and the sectors
    /// are the published widths: 180° direct, 70° teardrop, 110° parallel.
    func testSectorWidthsMatchThePublishedGeometry() {
        for inbound in [0.0, 45, 90, 187, 270, 359] {
            let h = hold(inbound: inbound)
            var counts: [HoldingPattern.Entry: Int] = [:]
            for t in 0..<360 { counts[h.entry(arrivingOn: Double(t)), default: 0] += 1 }
            XCTAssertEqual(counts[.direct], 180, "direct sector width, inbound \(inbound)")
            XCTAssertEqual(counts[.teardrop], 70, "teardrop sector width, inbound \(inbound)")
            XCTAssertEqual(counts[.parallel], 110, "parallel sector width, inbound \(inbound)")
        }
    }

    // MARK: left-hand (non-standard) patterns are the mirror image

    func testLeftHandPatternMirrorsTheSectors() {
        let r = hold(inbound: 90, turn: .right)
        let l = hold(inbound: 90, turn: .left)
        // Mirroring the arrival track about the inbound course must give the same entry.
        for t in stride(from: 0.0, to: 360.0, by: 1) {
            let mirrored = HoldingPattern.normalize(2 * 90 - t)
            XCTAssertEqual(r.entry(arrivingOn: t), l.entry(arrivingOn: mirrored),
                           "left-hand mirror broke at track \(t)")
        }
        // And the widths are still the published ones.
        var counts: [HoldingPattern.Entry: Int] = [:]
        for t in 0..<360 { counts[l.entry(arrivingOn: Double(t)), default: 0] += 1 }
        XCTAssertEqual(counts[.direct], 180)
        XCTAssertEqual(counts[.teardrop], 70)
        XCTAssertEqual(counts[.parallel], 110)
    }

    /// A left-hand hold must NOT return the same entry as the right-hand one for an asymmetric track —
    /// the regression guard against "turn direction ignored".
    func testTurnDirectionActuallyChangesTheAnswer() {
        let r = hold(inbound: 90, turn: .right)
        let l = hold(inbound: 90, turn: .left)
        XCTAssertEqual(r.entry(arrivingOn: 250), .teardrop)
        XCTAssertEqual(l.entry(arrivingOn: 250), .parallel, "left-hand pattern must mirror, not copy")
    }

    // MARK: arriving from a point

    func testEntryFromAnOriginUsesTheCourseToTheFix() {
        // Fix due north of the origin → arrival track 000. Inbound course 000 → direct.
        let h = HoldingPattern(id: "F-10", fix: "F", coord: Coord(lat: 43, lon: -71),
                               inboundCourseMag: 0, turn: .right, kind: .missedApproach)
        XCTAssertEqual(h.entry(arrivingFrom: Coord(lat: 42, lon: -71), magneticVariation: 0), .direct)
        // Arriving from the north (track 180) → Δ=180 → parallel.
        XCTAssertEqual(h.entry(arrivingFrom: Coord(lat: 44, lon: -71), magneticVariation: 0), .parallel)
    }

    func testEntryFromACoincidentPointIsNil() {
        let h = hold(inbound: 90)
        XCTAssertNil(h.entry(arrivingFrom: h.coord, magneticVariation: 0), "no course exists from the fix to itself")
    }

    // MARK: outbound course + racetrack geometry

    func testOutboundIsTheReciprocal() {
        XCTAssertEqual(hold(inbound: 90).outboundCourseMag, 270, accuracy: 1e-9)
        XCTAssertEqual(hold(inbound: 350).outboundCourseMag, 170, accuracy: 1e-9)
        XCTAssertEqual(hold(inbound: 0).outboundCourseMag, 180, accuracy: 1e-9)
    }

    func testRacetrackClosesAtTheFixAndSitsOnTheHoldingSide() {
        let h = hold(inbound: 90, turn: .right)          // right turns → pattern SOUTH of the fix
        let pts = h.racetrack(magneticVariation: 0, groundSpeedKt: 150)
        XCTAssertGreaterThan(pts.count, 8, "racetrack should be a real polyline, not a stub")
        XCTAssertEqual(pts.first!.lat, h.coord.lat, accuracy: 1e-9, "must start at the fix")
        XCTAssertEqual(pts.last!.lat, h.coord.lat, accuracy: 1e-9, "must close at the fix")
        XCTAssertEqual(pts.last!.lon, h.coord.lon, accuracy: 1e-9)
        // Inbound 090 with right turns puts the whole pattern south of the inbound course line.
        let southish = pts.filter { $0.lat < h.coord.lat - 1e-6 }.count
        XCTAssertGreaterThan(southish, pts.count / 3, "right-hand pattern should lie south of inbound 090")
        XCTAssertEqual(pts.filter { $0.lat > h.coord.lat + 1e-3 }.count, 0,
                       "no part of a right-hand 090 pattern belongs north of the fix")
    }

    func testLeftHandRacetrackMirrorsToTheOtherSide() {
        let l = hold(inbound: 90, turn: .left).racetrack(magneticVariation: 0, groundSpeedKt: 150)
        let fixLat = 42.0
        XCTAssertEqual(l.filter { $0.lat < fixLat - 1e-3 }.count, 0,
                       "a left-hand 090 pattern belongs north of the fix")
    }

    func testRacetrackScalesWithSpeedAndLegTime() {
        var h = hold(inbound: 90)
        let slow = h.racetrack(magneticVariation: 0, groundSpeedKt: 100)
        let fast = h.racetrack(magneticVariation: 0, groundSpeedKt: 250)
        func span(_ p: [Coord]) -> Double { (p.map(\.lon).max()! - p.map(\.lon).min()!) }
        XCTAssertGreaterThan(span(fast), span(slow), "a faster hold is a bigger racetrack")
        h.legMinutes = 1.5
        XCTAssertGreaterThan(span(h.racetrack(magneticVariation: 0, groundSpeedKt: 150)),
                             span(hold(inbound: 90).racetrack(magneticVariation: 0, groundSpeedKt: 150)),
                             "1½-minute legs are longer than 1-minute legs")
    }

    // MARK: kind + skippability

    func testKindFromPathTerminatorAndSegment() {
        XCTAssertEqual(HoldingPattern.kind(legType: "HF", isMissedApproachSegment: false), .holdInLieuOfProcedureTurn)
        XCTAssertEqual(HoldingPattern.kind(legType: "HF", isMissedApproachSegment: true), .missedApproach)
        XCTAssertEqual(HoldingPattern.kind(legType: "HM", isMissedApproachSegment: true), .missedApproach)
        XCTAssertEqual(HoldingPattern.kind(legType: "HA", isMissedApproachSegment: false), .holdToAltitude)
        XCTAssertEqual(HoldingPattern.kind(legType: "TF", isMissedApproachSegment: false), .enroute)
    }

    /// Only the course-reversal hold is offered as routinely skippable — dropping the published
    /// missed-approach hold by default would leave the missed approach without its termination.
    func testOnlyTheHILPTIsRoutinelySkipped() {
        XCTAssertTrue(HoldingPattern.Kind.holdInLieuOfProcedureTurn.isRoutinelySkipped)
        XCTAssertFalse(HoldingPattern.Kind.missedApproach.isRoutinelySkipped)
        XCTAssertFalse(HoldingPattern.Kind.holdToAltitude.isRoutinelySkipped)
    }

    // MARK: building from a coded leg — read, never guess

    func testBuildsFromACodedHoldLeg() {
        let leg = CIFPLeg(seq: 10, fix: "HULKS", coord: Coord(lat: 60, lon: -155),
                          legType: "HF", course: 71.4, altitude: "02000",
                          turnDirection: "R")
        let h = HoldingPattern(leg: leg, kind: .holdInLieuOfProcedureTurn)
        XCTAssertNotNil(h)
        XCTAssertEqual(h?.fix, "HULKS")
        XCTAssertEqual(h?.inboundCourseMag ?? 0, 71.4, accuracy: 1e-9)
        XCTAssertEqual(h?.turn, .right)
        XCTAssertEqual(h?.altitudeText, "02000")
    }

    func testNonHoldLegsAndMissingGeometryProduceNoPattern() {
        // A normal track leg is not a hold.
        XCTAssertNil(HoldingPattern(leg: CIFPLeg(seq: 20, fix: "X", coord: Coord(lat: 1, lon: 1),
                                                 legType: "TF", course: 90, altitude: "",
                                                 turnDirection: "R"), kind: .enroute))
        // A hold with NO published turn direction must not be invented as standard-right.
        XCTAssertNil(HoldingPattern(leg: CIFPLeg(seq: 10, fix: "X", coord: Coord(lat: 1, lon: 1),
                                                 legType: "HM", course: 90, altitude: "",
                                                 turnDirection: ""), kind: .missedApproach))
        // A hold with no course, and one with no coordinate, likewise.
        XCTAssertNil(HoldingPattern(leg: CIFPLeg(seq: 10, fix: "X", coord: Coord(lat: 1, lon: 1),
                                                 legType: "HM", course: nil, altitude: "",
                                                 turnDirection: "R"), kind: .missedApproach))
        XCTAssertNil(HoldingPattern(leg: CIFPLeg(seq: 10, fix: "X", coord: nil,
                                                 legType: "HM", course: 90, altitude: "",
                                                 turnDirection: "R"), kind: .missedApproach))
    }

    // MARK: the pilot-facing text names the right turn direction

    /// THE TEARDROP-SIDE REGRESSION. The 30° offset must go toward the HOLDING side. Inbound 090 with
    /// right turns holds SOUTH of the inbound track, so the teardrop is 240° — not 300°, which points
    /// north into the unprotected non-holding side. Asserted as a SIDE, not just a number, because the
    /// original bug was a sign that still produced a plausible-looking heading.
    func testTeardropHeadingIsOnTheHoldingSide() {
        // Right-hand, inbound 090 → outbound 270, holding side south.
        XCTAssertEqual(HoldingPattern.teardropHeading(outbound: 270, turn: .right), 240, accuracy: 1e-9)
        // Left-hand mirrors: holding side north → 300.
        XCTAssertEqual(HoldingPattern.teardropHeading(outbound: 270, turn: .left), 300, accuracy: 1e-9)
        // Wraps correctly.
        XCTAssertEqual(HoldingPattern.teardropHeading(outbound: 10, turn: .right), 340, accuracy: 1e-9)
        XCTAssertEqual(HoldingPattern.teardropHeading(outbound: 350, turn: .left), 20, accuracy: 1e-9)

        // Independent geometric check: the teardrop heading must point to the SAME side of the inbound
        // course as the racetrack itself, for every inbound course and both turn directions.
        for inbound in stride(from: 0.0, to: 360.0, by: 15) {
            for turn in [HoldingPattern.Turn.right, .left] {
                let outbound = HoldingPattern.normalize(inbound + 180)
                let td = HoldingPattern.teardropHeading(outbound: outbound, turn: turn)
                // Angle from the INBOUND course to the teardrop heading, signed into ±180.
                var rel = HoldingPattern.normalize(td - inbound)
                if rel > 180 { rel -= 360 }
                // Right-hand holds lie to the right of the inbound course → positive relative angle.
                if turn == .right {
                    XCTAssertGreaterThan(rel, 0, "right-hand teardrop must lie right of inbound \(inbound)")
                } else {
                    XCTAssertLessThan(rel, 0, "left-hand teardrop must lie left of inbound \(inbound)")
                }
            }
        }
    }

    /// The pilot-facing sentence must carry the corrected heading, not just the helper.
    func testTeardropDetailTextQuotesTheHoldingSideHeading() {
        let text = HoldingPattern.Entry.teardrop.detail(inbound: 90, outbound: 270, turn: .right)
        XCTAssertTrue(text.contains("240"), "teardrop detail should say 240°, got: \(text)")
        XCTAssertFalse(text.contains("300"), "300° is the non-holding side: \(text)")
    }

    func testEntryDetailNamesTheCorrectTurns() {
        let h = hold(inbound: 90, turn: .right)
        XCTAssertTrue(HoldingPattern.Entry.direct
            .detail(inbound: 90, outbound: 270, turn: .right).contains("turn right"))
        XCTAssertTrue(HoldingPattern.Entry.parallel
            .detail(inbound: 90, outbound: 270, turn: .right).contains("turn left"),
                      "a parallel entry turns AWAY from the holding side first")
        XCTAssertTrue(HoldingPattern.Entry.direct
            .detail(inbound: 90, outbound: 270, turn: .left).contains("turn left"))
        XCTAssertFalse(h.entry(arrivingOn: 90).label.isEmpty)
    }
}
