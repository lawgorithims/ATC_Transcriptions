import XCTest
@testable import ATCTranscribe

/// Tests for the storm-penetration alert.
///
/// # Why every case is on the equator
///
/// At latitude 0 a great circle on bearing 090 IS the line of constant latitude, and one degree of
/// longitude is exactly 60 NM. So `Geo.point` walks a test aircraft due east along the same parallel the
/// cell box is built on, and every expected time below is arithmetic rather than an approximation. Run the
/// same geometry at 35° N and the great-circle track bows south of the box, which would turn these
/// equalities into tolerances and let a real sign error hide inside the slop.
final class ConvectiveAlertTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_793_750_000)

    /// An axis-aligned box whose centre is `eastNm` from the origin, `halfNm` to a side, on the equator.
    private func box(eastNm: Double, halfNm: Double) -> [Coord] {
        let c = eastNm / 60, h = halfNm / 60
        return [Coord(lat: -h, lon: c - h), Coord(lat: -h, lon: c + h),
                Coord(lat:  h, lon: c + h), Coord(lat:  h, lon: c - h)]
    }

    /// The same box pushed `northNm` off the equator, for the cases that must pass abeam.
    private func box(eastNm: Double, halfNm: Double, northNm: Double) -> [Coord] {
        box(eastNm: eastNm, halfNm: halfNm).map { Coord(lat: $0.lat + northNm / 60, lon: $0.lon) }
    }

    private func cell(eastNm: Double, halfNm: Double = 10, northNm: Double = 0,
                      fromDeg: Double? = nil, kt: Double? = nil,
                      tops: Double? = 38_000, base: Double? = nil,
                      id: String = "WST-1C", label: String = "Convective SIGMET 1C",
                      severity: Int? = 5,
                      issued: Date? = nil, validFor: TimeInterval = 7_200) -> ConvectiveCell {
        let at = issued ?? t0
        return ConvectiveCell(id: id, label: label,
                              polygon: box(eastNm: eastNm, halfNm: halfNm, northNm: northNm),
                              topsFtMSL: tops, baseFtMSL: base,
                              observedAt: at, validUntil: at.addingTimeInterval(validFor),
                              severity: severity, movingFromDeg: fromDeg, motionKt: kt)
    }

    private func ownship(trackDeg: Double? = 90, kt: Double? = 300,
                         altFt: Double? = 30_000) -> ConvectiveOwnship {
        ConvectiveOwnship(position: Coord(lat: 0, lon: 0), altitudeFtMSL: altFt,
                          trackDeg: trackDeg, groundSpeedKt: kt)
    }

    // MARK: The sign of the motion vector

    /// ⚠️ THE TEST THAT PINS "FROM" RATHER THAN "TOWARD", HALF ONE.
    ///
    /// Aircraft tracking 090 at 300 kt. The cell's west edge is 50 NM east, and the cell is "MOV FROM
    /// 090" at 60 kt — travelling TOWARD 270, straight at the aircraft. They close at 360 kt, so entry is
    /// at 50/360 h = 8.33 min, landing on the 8.5 min step.
    ///
    /// Read the field as a heading instead and the cell runs away east at 60 kt, closing drops to 240 kt
    /// and entry slips to 12.5 min. Both still alert, which is exactly why this asserts the TIME and not
    /// the mere existence of a threat.
    func testACellMovingFromTheEastClosesOnTheAircraft() throws {
        let threat = try XCTUnwrap(ConvectiveAlert.threat(cell: cell(eastNm: 60, fromDeg: 90, kt: 60),
                                                          ownship: ownship(), now: t0))
        XCTAssertEqual(threat.kind, .penetration)
        XCTAssertEqual(try XCTUnwrap(threat.minutesToPenetration), 8.5, accuracy: 0.01,
                       "closing at 300+60 kt over 50 NM — a receding cell would give 12.5")
    }

    /// ⚠️ THE TEST THAT PINS IT, HALF TWO — and the decisive half, because here a sign flip changes
    /// whether there is an alert at all, not merely when.
    ///
    /// Aircraft tracking 090 at only 100 kt. The cell's west edge is 80 NM east and it is "MOV FROM 270"
    /// at 150 kt — travelling TOWARD 090, away, far faster than the aircraft can follow. The gap only
    /// widens, so there must be no threat. Invert the sign and the cell charges west at 150 kt, the gap
    /// closes at 250 kt, and the aircraft is inside it before the window is out.
    func testACellOutrunningTheAircraftIsNotAThreat() {
        XCTAssertNil(ConvectiveAlert.threat(cell: cell(eastNm: 90, fromDeg: 270, kt: 150),
                                            ownship: ownship(kt: 100), now: t0),
                     "a cell receding at 150 kt from a 100 kt aeroplane can never be reached")
    }

    func testMovingTowardIsTheReciprocalOfMovingFrom() throws {
        XCTAssertEqual(try XCTUnwrap(cell(eastNm: 60, fromDeg: 210).movingTowardDeg), 30, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(cell(eastNm: 60, fromDeg: 30).movingTowardDeg), 210, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(cell(eastNm: 60, fromDeg: 0).movingTowardDeg), 180, accuracy: 1e-9)
        XCTAssertNil(cell(eastNm: 60, fromDeg: nil).movingTowardDeg)
    }

    // MARK: Both encounters are reported

    /// The other regression this file exists for: a track aimed through a cell must report the entry, not
    /// just the earlier 20 NM crossing that necessarily precedes it.
    func testAPenetrationReportsEntryAndTheEarlierBreach() throws {
        let threat = try XCTUnwrap(ConvectiveAlert.threat(cell: cell(eastNm: 60, fromDeg: 90, kt: 60),
                                                          ownship: ownship(), now: t0))
        XCTAssertEqual(threat.kind, .penetration)
        XCTAssertEqual(threat.minutesToBreach, 5.0, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(threat.minutesToPenetration), 8.5, accuracy: 0.01)
        XCTAssertLessThan(threat.minutesToBreach, threat.minutesAway,
                          "the headline leads with entry; the breach is the earlier turn-by time")
    }

    /// A track that passes abeam must stay a proximity call and never claim an entry. The box sits 15 NM
    /// north and is 5 NM to a side, so its south edge is 10 NM above the equator the aircraft flies along.
    func testATrackPassingAbeamIsProximityNotPenetration() throws {
        let c = cell(eastNm: 60, halfNm: 5, northNm: 15, id: "WST-2C")
        let threat = try XCTUnwrap(ConvectiveAlert.threat(cell: c, ownship: ownship(), now: t0))
        XCTAssertEqual(threat.kind, .proximity)
        XCTAssertNil(threat.minutesToPenetration)
        XCTAssertEqual(threat.closestApproachNm, 10, accuracy: 0.5)
    }

    // MARK: Altitude

    func testSafelyAboveTheTopsIsNotAThreat() {
        XCTAssertNil(ConvectiveAlert.threat(cell: cell(eastNm: 30, fromDeg: 90, kt: 30, tops: 18_000),
                                            ownship: ownship(altFt: 41_000), now: t0),
                     "FL410 over an FL180 top clears it by 23,000 ft")
    }

    func testSkimmingTheTopsStillAlerts() throws {
        let c = cell(eastNm: 30, fromDeg: 90, kt: 30, tops: 40_000)
        let threat = try XCTUnwrap(ConvectiveAlert.threat(cell: c, ownship: ownship(altFt: 41_000),
                                                          now: t0))
        XCTAssertEqual(threat.vertical, .nearTops(marginFt: 1_000),
                       "1,000 ft of clearance is well inside the 5,000 ft minimum")
    }

    func testTheClearanceBoundaryIsFiveThousandFeet() {
        let c = cell(eastNm: 30, tops: 30_000)
        XCTAssertEqual(ConvectiveAlert.verticalRelation(cell: c, altitudeFtMSL: 34_999),
                       .nearTops(marginFt: 4_999))
        XCTAssertEqual(ConvectiveAlert.verticalRelation(cell: c, altitudeFtMSL: 35_000),
                       .clearAbove(marginFt: 5_000), "exactly 5,000 ft satisfies the AIM floor")
    }

    /// Unknowns alert. A product that omits tops is not evidence of a low cell, and a missing GPS
    /// altitude is not evidence of a safe one.
    func testUnknownTopsAndUnknownAltitudeBothAlert() {
        let noTops = cell(eastNm: 30, fromDeg: 90, kt: 30, tops: nil)
        XCTAssertEqual(ConvectiveAlert.verticalRelation(cell: noTops, altitudeFtMSL: 41_000),
                       .topsUnknown)
        XCTAssertNotNil(ConvectiveAlert.threat(cell: noTops, ownship: ownship(altFt: 41_000), now: t0))

        let known = cell(eastNm: 30, fromDeg: 90, kt: 30, tops: 18_000)
        XCTAssertEqual(ConvectiveAlert.verticalRelation(cell: known, altitudeFtMSL: nil),
                       .altitudeUnknown)
        XCTAssertNotNil(ConvectiveAlert.threat(cell: known, ownship: ownship(altFt: nil), now: t0))
    }

    /// Underneath is not a let-off — that is where the microburst and the falling hail are.
    func testFlyingUnderTheBaseStillAlerts() throws {
        let c = cell(eastNm: 30, fromDeg: 90, kt: 30, tops: 45_000, base: 8_000)
        let threat = try XCTUnwrap(ConvectiveAlert.threat(cell: c, ownship: ownship(altFt: 3_000),
                                                          now: t0))
        XCTAssertEqual(threat.vertical, .belowBase(marginFt: 5_000))
    }

    // MARK: Recency

    /// The bulletin's age moves the CELL, not just the caveat text: a 20-minute-old 60 kt vector has
    /// already carried the storm 20 NM, and the alert must look where it is now, not where it was found.
    ///
    /// A parked aircraft isolates the effect — nothing here moves except the weather. The box's west edge
    /// starts 30 NM east, which is outside 20 NM when fresh and 10 NM away once the age is applied.
    func testTheBulletinsAgeAdvancesTheCell() throws {
        let c = cell(eastNm: 40, fromDeg: 90, kt: 60)
        let parked = ownship(trackDeg: nil, kt: 0)
        XCTAssertNil(ConvectiveAlert.threat(cell: c, ownship: parked, now: t0),
                     "30 NM away when issued — outside 20 NM, and a fresh bulletin adds no slack")
        let aged = try XCTUnwrap(ConvectiveAlert.threat(cell: c, ownship: parked,
                                                        now: t0.addingTimeInterval(20 * 60)),
                                 "20 min later it has closed to 10 NM")
        XCTAssertEqual(aged.dataAgeMin, 20, accuracy: 0.01)
        XCTAssertEqual(aged.closestApproachNm, 10, accuracy: 1.0)
    }

    /// Drift uncertainty grows with elapsed AND projected time, and the two add.
    func testDriftUncertaintyGrowsWithAgeAndWithProjection() {
        let c = cell(eastNm: 60, fromDeg: 90, kt: 60)
        XCTAssertEqual(ConvectiveAlert.driftUncertaintyNm(c, ageMinutes: 0, projectedMinutes: 0),
                       0, accuracy: 1e-9)
        XCTAssertEqual(ConvectiveAlert.driftUncertaintyNm(c, ageMinutes: 20, projectedMinutes: 0),
                       5, accuracy: 1e-9, "60 kt for 20 min = 20 NM of drift, a quarter of it")
        XCTAssertEqual(ConvectiveAlert.driftUncertaintyNm(c, ageMinutes: 0, projectedMinutes: 20),
                       5, accuracy: 1e-9, "a fresh bulletin read far ahead is just as uncertain")
        XCTAssertEqual(ConvectiveAlert.driftUncertaintyNm(c, ageMinutes: 20, projectedMinutes: 20),
                       10, accuracy: 1e-9, "they add")
    }

    func testACellWithNoStatedMotionGetsAFixedBuffer() {
        XCTAssertEqual(ConvectiveAlert.driftUncertaintyNm(cell(eastNm: 60, fromDeg: nil, kt: nil),
                                                          ageMinutes: 45, projectedMinutes: 20),
                       ConvectiveAlert.unknownMotionUncertaintyNm, accuracy: 1e-9,
                       "nothing to extrapolate, so the buffer is flat rather than zero")
    }

    // MARK: Expiry

    /// The bulletin expires; the thunderstorm does not. Inside the grace window it still alerts, flagged.
    ///
    /// The box starts 175 NM east so that two hours and five minutes of westward drift at 60 kt — 125 NM —
    /// brings its edge to 50 NM, which also exercises the geometry at a large age rather than a token one.
    func testAnExpiredBulletinStillAlertsInsideTheGraceWindow() throws {
        let c = cell(eastNm: 185, fromDeg: 90, kt: 60, validFor: 7_200)
        let justExpired = t0.addingTimeInterval(7_200 + 5 * 60)
        let threat = try XCTUnwrap(ConvectiveAlert.threat(cell: c, ownship: ownship(), now: justExpired))
        XCTAssertTrue(threat.isExpired)
        XCTAssertEqual(threat.dataAgeMin, 125, accuracy: 0.01)
        XCTAssertTrue(ConvectiveAlertText.detail(threat).contains("expired"),
                      "the pilot is told the data lapsed rather than being quietly shown it")
    }

    func testLongAfterExpiryTheCellIsDropped() {
        let c = cell(eastNm: 60, fromDeg: 90, kt: 60, validFor: 7_200)
        XCTAssertNil(ConvectiveAlert.threat(cell: c, ownship: ownship(),
                                            now: t0.addingTimeInterval(7_200 + 30 * 60)),
                     "past the grace window an hour-old vector is fiction, not caution")
    }

    // MARK: A stopped aircraft

    func testAParkedAircraftInsideACellSaysSoWithoutClaimingATime() throws {
        let threat = try XCTUnwrap(ConvectiveAlert.threat(cell: cell(eastNm: 0),
                                                          ownship: ownship(trackDeg: nil, kt: 0),
                                                          now: t0))
        XCTAssertEqual(threat.kind, .penetration)
        XCTAssertEqual(threat.minutesAway, 0)
        XCTAssertEqual(ConvectiveAlertText.minutesText(threat.minutesAway), "now")
    }

    func testAParkedAircraftFarFromEverythingIsNotAlerted() {
        XCTAssertNil(ConvectiveAlert.threat(cell: cell(eastNm: 200),
                                            ownship: ownship(trackDeg: nil, kt: 0), now: t0))
    }

    // MARK: Ordering

    func testPenetrationOutranksASoonerProximity() {
        let willEnter = cell(eastNm: 60, fromDeg: 90, kt: 60)                      // entry ~8.5 min
        let nearMiss = cell(eastNm: 25, halfNm: 5, northNm: 15, id: "WST-9C",
                            label: "Convective SIGMET 9C", severity: 1)            // abeam, already close
        let out = ConvectiveAlert.threats(cells: [nearMiss, willEnter], ownship: ownship(), now: t0)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].cell.id, "WST-1C", "the one needing a turn comes first")
        XCTAssertEqual(out[0].kind, .penetration)
        XCTAssertEqual(out[1].kind, .proximity)
        XCTAssertLessThan(out[1].minutesAway, out[0].minutesAway,
                          "and it outranks the near miss despite the near miss being sooner")
    }

    func testTheThreatListIsCapped() {
        let many = (0..<ConvectiveAlert.maxCells).map {
            cell(eastNm: 5, id: "c\($0)", label: "Cell \($0)")
        }
        XCTAssertEqual(ConvectiveAlert.threats(cells: many, ownship: ownship(), now: t0).count,
                       ConvectiveAlert.maxThreats)
    }

    // MARK: Geometry primitives

    func testDistanceIsZeroInsideAndPerpendicularOutside() {
        let b = box(eastNm: 60, halfNm: 10)
        XCTAssertEqual(ConvectiveAlert.distanceNm(from: Coord(lat: 0, lon: 1), toPolygon: b), 0)
        XCTAssertEqual(ConvectiveAlert.distanceNm(from: Coord(lat: 0, lon: 0), toPolygon: b),
                       50, accuracy: 0.5, "to the west edge, not to the centre or a corner")
    }

    func testAdvancingACellWithNoMotionLeavesItWhereItIs() {
        let b = box(eastNm: 60, halfNm: 10)
        XCTAssertEqual(ConvectiveAlert.advance(b, of: cell(eastNm: 60), byMinutes: 20), b)
    }

    func testAdvancingMovesTheWholePolygonTheRightWay() {
        let b = box(eastNm: 60, halfNm: 10)
        let moved = ConvectiveAlert.advance(b, of: cell(eastNm: 60, fromDeg: 90, kt: 60),
                                            byMinutes: 30)      // toward 270 — west
        XCTAssertEqual(moved.count, b.count)
        for (before, after) in zip(b, moved) {
            XCTAssertLessThan(after.lon, before.lon, "every vertex went west")
            XCTAssertEqual(Geo.nmBetween(before, after), 30, accuracy: 0.5, "60 kt for 30 min = 30 NM")
        }
    }

    // MARK: Text

    func testAltitudesReadAsFlightLevelsAboveEighteenThousand() {
        XCTAssertEqual(ConvectiveAlertText.altitudeText(38_000), "FL380")
        XCTAssertEqual(ConvectiveAlertText.altitudeText(18_000), "FL180")
        XCTAssertEqual(ConvectiveAlertText.altitudeText(17_000), "17,000 ft")
        XCTAssertEqual(ConvectiveAlertText.altitudeText(8_500), "8,500 ft")
    }

    func testMinutesNeverReadAsZero() {
        XCTAssertEqual(ConvectiveAlertText.minutesText(0), "now")
        XCTAssertEqual(ConvectiveAlertText.minutesText(0.4), "now")
        XCTAssertEqual(ConvectiveAlertText.minutesText(1), "1 min")
        XCTAssertEqual(ConvectiveAlertText.minutesText(12.4), "12 min")
    }

    func testTheHeadlineNamesTheCellAndTheAction() throws {
        let threat = try XCTUnwrap(ConvectiveAlert.threat(cell: cell(eastNm: 60, fromDeg: 90, kt: 60),
                                                          ownship: ownship(), now: t0))
        XCTAssertEqual(ConvectiveAlertText.headline(threat),
                       "Entering Convective SIGMET 1C in 9 min")
    }

    /// The detail line has to carry tops, motion and age — and state motion the way the bulletin states
    /// it, so it can be read straight against the printed text without reversing a heading in your head.
    func testTheDetailCarriesTopsMotionAndAge() throws {
        let c = cell(eastNm: 30, fromDeg: 210, kt: 45)
        let threat = try XCTUnwrap(ConvectiveAlert.threat(cell: c, ownship: ownship(),
                                                          now: t0.addingTimeInterval(12 * 60)))
        let detail = ConvectiveAlertText.detail(threat)
        XCTAssertTrue(detail.contains("tops FL380"), detail)
        XCTAssertTrue(detail.contains("moving from 210° at 45 kt"), detail)
        XCTAssertTrue(detail.contains("issued 12 min ago"), detail)
    }
}
