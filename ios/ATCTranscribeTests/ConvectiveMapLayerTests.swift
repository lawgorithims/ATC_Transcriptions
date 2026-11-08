import XCTest
import MapKit
@testable import ATCTranscribe

/// What the storm-cell map layer draws, where, and what it answers when a cell is tapped.
///
/// # Why every case is on the equator
///
/// Same reason as `ConvectiveAlertTests`: at latitude 0 a bearing of 090 IS the parallel, and a degree of
/// longitude is exactly 60 NM, so "the ring moved fifteen miles east" is an equality rather than a
/// tolerance. A sign error in the advance has nowhere to hide inside the slop of a bowed great circle.
final class ConvectiveMapLayerTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_793_750_000)

    /// An axis-aligned box centred `eastNm` from the origin on the equator, `halfNm` to a side.
    private func box(eastNm: Double, halfNm: Double) -> [Coord] {
        let c = eastNm / 60, h = halfNm / 60
        return [Coord(lat: -h, lon: c - h), Coord(lat: -h, lon: c + h),
                Coord(lat:  h, lon: c + h), Coord(lat:  h, lon: c - h)]
    }

    private func cell(eastNm: Double = 100, halfNm: Double = 10,
                      fromDeg: Double? = nil, kt: Double? = nil,
                      tops: Double? = 38_000, base: Double? = nil,
                      id: String = "WST-1C", issued: Date? = nil,
                      source: ConvectiveSource = .sigmet,
                      polygon: [Coord]? = nil) -> ConvectiveCell {
        let at = issued ?? t0
        var c = ConvectiveCell(id: id, label: "Convective SIGMET 1C",
                               polygon: polygon ?? box(eastNm: eastNm, halfNm: halfNm),
                               topsFtMSL: tops, baseFtMSL: base,
                               observedAt: at, validUntil: at.addingTimeInterval(7_200),
                               severity: 5, movingFromDeg: fromDeg, motionKt: kt)
        c.source = source
        return c
    }

    private func nm(_ a: Coord, _ b: Coord) -> Double { Geo.nmBetween(a, b) }

    // MARK: the ring, and the instant it is drawn at

    func testAFreshCellIsDrawnExactlyWhereTheProductPutIt() {
        // Age zero: nothing to extrapolate, so the ring must be the bulletin's own vertices. If this
        // ever drifts, every outline on the map is wrong by the drift even with perfect data.
        let c = cell(fromDeg: 270, kt: 45)
        let ring = ConvectiveCellDraw.ring(c, at: t0)
        XCTAssertEqual(ring.count, c.polygon.count)
        for (drawn, observed) in zip(ring, c.polygon) {
            XCTAssertEqual(nm(drawn, observed), 0, accuracy: 1e-6)
        }
    }

    func testAStaleCellIsDrawnDownWindOfTheBulletinNotAtIt() {
        // MOV FROM 270 at 45 kt, read 20 minutes after it was issued: every vertex moves 15 NM, and it
        // moves TOWARD 090.
        //
        // Distances come from `Geo.nmBetween` rather than from degrees × 60. The sphere these helpers
        // share is R = 3440.065 NM, so a degree is 60.0405 NM and the hand conversion is wrong by
        // 0.07% — enough to fail at 1e-6 and nothing to do with the layer. Asserting in the same units
        // the alert reasons in also means this test keeps its meaning if that constant ever changes.
        let c = cell(fromDeg: 270, kt: 45)
        let ring = ConvectiveCellDraw.ring(c, at: t0.addingTimeInterval(20 * 60))
        XCTAssertEqual(ring.count, 4)
        for (drawn, observed) in zip(ring, c.polygon) {
            XCTAssertEqual(nm(observed, drawn), 15, accuracy: 1e-6)
            XCTAssertEqual(Geo.bearing(observed, drawn), 90, accuracy: 0.01)
            XCTAssertGreaterThan(drawn.lon, observed.lon, "a cell moving FROM the west goes EAST")
        }
    }

    func testTheRingIsNeverRunBackwardsByAClockAheadOfTheBulletin() {
        // A stated issue time can sit ahead of the device clock, and a wrong clock can put it hours
        // ahead. A negative age fed to `advance` would march the storm backwards down its own vector —
        // the one direction guaranteed to be wrong — so it is clamped and the cell draws where observed.
        let c = cell(fromDeg: 270, kt: 45)
        for ahead in [-1.0, -60.0, -86_400.0] {
            let ring = ConvectiveCellDraw.ring(c, at: t0.addingTimeInterval(ahead))
            XCTAssertEqual(ConvectiveCellDraw.ageMinutes(c, at: t0.addingTimeInterval(ahead)), 0)
            for (drawn, observed) in zip(ring, c.polygon) {
                XCTAssertEqual(nm(drawn, observed), 0, accuracy: 1e-6, "clock \(ahead)s off")
            }
        }
    }

    func testACellWithNoMotionIsDrawnWhereItWasHoweverStale() {
        let c = cell(fromDeg: nil, kt: nil)
        let ring = ConvectiveCellDraw.ring(c, at: t0.addingTimeInterval(3_600))
        for (drawn, observed) in zip(ring, c.polygon) {
            XCTAssertEqual(nm(drawn, observed), 0, accuracy: 1e-6)
        }
    }

    func testASquallLineSurvivesAsTwoPoints() {
        // A "LINE TS" Convective SIGMET IS a two-point line with no interior. It is also the most
        // dangerous shape in the feed, so the one thing the layer must not do is drop it for want of
        // an area to fill — the caller draws it as a line. See ConvectiveCellDraw.ring.
        let line = [Coord(lat: 0, lon: 1), Coord(lat: 0, lon: 2)]
        let ring = ConvectiveCellDraw.ring(cell(polygon: line), at: t0)
        XCTAssertEqual(ring.count, 2, "a squall line must not be discarded")
    }

    func testASingleVertexIsNotDrawable() {
        XCTAssertTrue(ConvectiveCellDraw.ring(cell(polygon: [Coord(lat: 0, lon: 1)]), at: t0).isEmpty)
        XCTAssertTrue(ConvectiveCellDraw.ring(cell(polygon: []), at: t0).isEmpty)
    }

    func testTheRingIsClampedToTheAlertsVertexCap() {
        // The map must not draw more of a polygon than the alert tested against.
        let many = (0..<(ConvectiveAlert.maxVertices * 3)).map { Coord(lat: 0, lon: Double($0) / 600) }
        XCTAssertEqual(ConvectiveCellDraw.ring(cell(polygon: many), at: t0).count,
                       ConvectiveAlert.maxVertices)
    }

    // MARK: the motion arrow

    func testTheArrowPointsWhereTheCellIsGoingAndNotWhereItCameFrom() {
        // The inverted-sign failure this guards is total: every storm on the map would appear to be
        // leaving, and the one closing on the aircraft would look like the safe one.
        let c = cell(fromDeg: 270, kt: 60)
        let a = ConvectiveCellDraw.motionArrow(c, at: t0)
        XCTAssertEqual(a.count, 5, "shaft plus a barb either side, retracing the tip")
        let tail = a[0], tip = a[1]
        XCTAssertGreaterThan(tip.lon, tail.lon, "FROM 270 means travelling toward 090")
        XCTAssertEqual(Geo.bearing(tail, tip), 90, accuracy: 0.01)
    }

    func testTheArrowIsAsLongAsTheAlertsOwnLookAhead() {
        // 60 kt over the alert's 20-minute window is 20 NM, so the arrowhead lands exactly where the
        // alert stopped projecting. A shaft of some other length would invite reading distance off it.
        let a = ConvectiveCellDraw.motionArrow(cell(fromDeg: 270, kt: 60), at: t0)
        XCTAssertEqual(nm(a[0], a[1]), 60 * (ConvectiveAlert.lookAheadMin / 60), accuracy: 0.01)
    }

    func testTheArrowStartsOnTheCellAsDrawnNotWhereItWasObserved() {
        // A 20-minute-old bulletin draws its ring 15 NM downwind; an arrow still rooted at the
        // observed centroid would float behind the outline with a visible gap between them.
        let c = cell(fromDeg: 270, kt: 45)
        let at = t0.addingTimeInterval(20 * 60)
        let ring = ConvectiveCellDraw.ring(c, at: at)
        let tail = ConvectiveCellDraw.motionArrow(c, at: at)[0]
        let drawnCentroid = Coord(lat: ring.map(\.lat).reduce(0, +) / Double(ring.count),
                                  lon: ring.map(\.lon).reduce(0, +) / Double(ring.count))
        // Within feet, not exactly: each vertex is advanced along its OWN great circle, so the moved
        // ring's vertex-mean and the moved centroid differ by about 25 ft over a 15 NM step. That is
        // the shortcut the arrow's tail takes, and it is three orders of magnitude inside the cell.
        XCTAssertEqual(nm(tail, drawnCentroid), 0, accuracy: 0.01)
        XCTAssertEqual(nm(tail, c.centroid), 15, accuracy: 0.01, "and 15 NM clear of where it was")
    }

    func testTheBarbsFoldBackFromTheTip() {
        // A barb drawn forward of the tip would read as a second, longer shaft pointing somewhere else.
        let a = ConvectiveCellDraw.motionArrow(cell(fromDeg: 270, kt: 60), at: t0)
        let tail = a[0], tip = a[1], left = a[2], right = a[4]
        XCTAssertEqual(a[3].lon, tip.lon, accuracy: 1e-9, "the tip is retraced between the barbs")
        for barb in [left, right] {
            XCTAssertLessThan(nm(tail, barb), nm(tail, tip), "a barb sits behind the tip")
            XCTAssertGreaterThan(nm(tip, barb), 0)
        }
        XCTAssertGreaterThan(left.lat, right.lat, "one barb each side of the shaft")
        XCTAssertEqual(nm(tip, left), nm(tip, right), accuracy: 1e-6, "symmetric about the shaft")
    }

    func testTheBarbIsClampedSoAFastLineDoesNotGrowASecondPolygon() {
        let a = ConvectiveCellDraw.motionArrow(cell(fromDeg: 270, kt: 120), at: t0)
        XCTAssertEqual(nm(a[1], a[2]), ConvectiveCellDraw.maxBarbNm, accuracy: 0.05)
    }

    func testNoArrowWithoutUsableMotion() {
        // A stub too short to show a direction is worse than nothing: it still reads as information.
        XCTAssertTrue(ConvectiveCellDraw.motionArrow(cell(fromDeg: nil, kt: nil), at: t0).isEmpty)
        XCTAssertTrue(ConvectiveCellDraw.motionArrow(cell(fromDeg: 270, kt: nil), at: t0).isEmpty)
        XCTAssertTrue(ConvectiveCellDraw.motionArrow(cell(fromDeg: 270, kt: 0), at: t0).isEmpty)
        XCTAssertTrue(ConvectiveCellDraw.motionArrow(cell(fromDeg: 270, kt: 4.9), at: t0).isEmpty)
        XCTAssertTrue(ConvectiveCellDraw.motionArrow(cell(fromDeg: 270, kt: .nan), at: t0).isEmpty)
        XCTAssertTrue(ConvectiveCellDraw.motionArrow(cell(fromDeg: 270, kt: .infinity), at: t0).isEmpty)
        XCTAssertFalse(ConvectiveCellDraw.motionArrow(cell(fromDeg: 270, kt: 5), at: t0).isEmpty)
    }

    // MARK: the altitude block

    func testAnUnstatedTopReadsAsADashAndNotAsANumber() {
        // `VerticalRelation.topsUnknown` is a THREATENING case: a product that did not measure a top is
        // not evidence of a low one. A confident number here would say the opposite of the alert.
        XCTAssertEqual(ConvectiveCellDraw.topsText(cell(tops: nil)), "—")
        XCTAssertEqual(ConvectiveCellDraw.topsText(cell(tops: 45_000)), "FL450")
        XCTAssertEqual(ConvectiveCellDraw.topsText(cell(tops: 12_000)), "120")
    }

    func testAnAbsentBaseReadsSurfaceBecauseThatIsWhatItMeans() {
        // nil base is a STATED fact — the hazard reaches the ground — not a gap in the product, so it
        // must not print the same dash an unknown top does.
        XCTAssertEqual(ConvectiveCellDraw.baseText(cell(base: nil)), "SFC")
        XCTAssertEqual(ConvectiveCellDraw.baseText(cell(base: 8_000)), "80")
        XCTAssertEqual(ConvectiveCellDraw.altBlock(cell(tops: 45_000, base: nil)), "FL450\nSFC")
    }

    func testTheBlockSitsOnTheNorthernmostVertexLikeATFRsLimits() {
        let ring = [Coord(lat: 1, lon: 0), Coord(lat: 3, lon: 1), Coord(lat: 2, lon: 2)]
        XCTAssertEqual(ConvectiveCellDraw.labelCoord(ring)?.lat, 3)
        XCTAssertNil(ConvectiveCellDraw.labelCoord([]))
    }

    // MARK: the drawn set

    func testTheMapCannotDrawMoreCellsThanTheAlertReasonedAbout() {
        // Deliberately the alert's cap and not a number of its own — otherwise the map could outline a
        // cell no warning was computed for, or stay silent about one that was.
        XCTAssertEqual(ConvectiveCellDraw.maxDrawn, ConvectiveAlert.maxCells)
        let many = (0..<200).map { cell(id: String(format: "C%03d", $0)) }
        XCTAssertEqual(ConvectiveCellDraw.drawable(many).count, ConvectiveAlert.maxCells)
    }

    func testTheDrawnSetIsDedupedAndStablyOrdered() {
        // An unstable order would make the cap itself flicker over which cells it kept, so a cell at
        // the boundary would blink in and out while nothing about the weather changed.
        let cells = [cell(id: "C"), cell(id: "A"), cell(id: "B"), cell(id: "A")]
        let out = ConvectiveCellDraw.drawable(cells)
        XCTAssertEqual(out.map(\.id), ["A", "B", "C"])
        XCTAssertEqual(ConvectiveCellDraw.drawable(cells.shuffled()).map(\.id), out.map(\.id))
    }

    func testACellWithNothingDrawableIsLeftOut() {
        let out = ConvectiveCellDraw.drawable([cell(id: "ok"),
                                               cell(id: "point", polygon: [Coord(lat: 0, lon: 0)]),
                                               cell(id: "empty", polygon: [])])
        XCTAssertEqual(out.map(\.id), ["ok"])
    }

    // MARK: the change digest — what makes the layer stop blinking

    func testAnUnchangedCellAtTheSameInstantHasAnUnchangedDigest() {
        // This is the whole no-blink property: `updateUIView` runs on any published change, traffic
        // moves every second, and a digest that wobbled would tear down and rebuild every outline.
        let c = cell(fromDeg: 270, kt: 45)
        XCTAssertEqual(ConvectiveCellDraw.digest(c, at: t0, isThreat: false),
                       ConvectiveCellDraw.digest(c, at: t0, isThreat: false))
    }

    func testAReissuedProductThatKeptItsIdAndVertexCountStillRedraws() {
        // The trap `updateTFRs` records: a re-issue keeps its id and often its vertex count while the
        // boundary moves, and a count-only digest leaves the old shape drawn in the old place.
        let a = cell(eastNm: 100)
        let b = cell(eastNm: 140)
        XCTAssertEqual(a.id, b.id)
        XCTAssertEqual(a.polygon.count, b.polygon.count)
        XCTAssertNotEqual(ConvectiveCellDraw.digest(a, at: t0, isThreat: false),
                          ConvectiveCellDraw.digest(b, at: t0, isThreat: false))
    }

    func testTheDigestMovesWhenTheThreatStatusFlips() {
        // Emphasis is carried by weight, so a cell that becomes the one being warned about has to be
        // re-added to pick up the bolder stroke and the fill you can see.
        let c = cell()
        XCTAssertNotEqual(ConvectiveCellDraw.digest(c, at: t0, isThreat: false),
                          ConvectiveCellDraw.digest(c, at: t0, isThreat: true))
    }

    func testTheDigestMovesWithTheDrawInstantTopsAndMotion() {
        let c = cell(fromDeg: 270, kt: 45)
        let base = ConvectiveCellDraw.digest(c, at: t0, isThreat: false)
        XCTAssertNotEqual(base, ConvectiveCellDraw.digest(c, at: t0.addingTimeInterval(60),
                                                          isThreat: false),
                          "a later instant draws the ring further along its vector")
        XCTAssertNotEqual(base, ConvectiveCellDraw.digest(cell(fromDeg: 270, kt: 45, tops: 51_000),
                                                          at: t0, isThreat: false))
        XCTAssertNotEqual(base, ConvectiveCellDraw.digest(cell(fromDeg: 180, kt: 45),
                                                          at: t0, isThreat: false))
        XCTAssertNotEqual(base, ConvectiveCellDraw.digest(cell(fromDeg: 270, kt: 70),
                                                          at: t0, isThreat: false))
    }

    // MARK: the renderer's side map

    func testTheDerivedMotionFlagFollowsTheRadarSource() {
        // A dashed shaft says "this vector was computed here": `RadarCellFinder.fieldMotion` reads
        // speed 20–25% low, every time, so the arrow is a floor on the speed rather than a measurement.
        XCTAssertTrue(ConvectiveOverlayStyle(isThreat: true, isDerivedMotion: true).isDerivedMotion)
        XCTAssertEqual(cell(source: .radar).source, .radar)
        XCTAssertEqual(cell(source: .sigmet).source, .sigmet)
    }

    // MARK: tapping a cell

    /// The test this whole hit-test exists for. A 20-minute-old cell at 45 kt is DRAWN 15 NM east of
    /// where the bulletin put it, and the box is only 10 NM to a side — so the observed footprint and
    /// the drawn one do not even overlap. Testing `cell.polygon` would open a card for a cell whose
    /// outline is fifteen miles away and refuse the one under the finger.
    func testATapHitsTheRingAsDrawnNotAsIssued() {
        let c = cell(eastNm: 100, halfNm: 10, fromDeg: 270, kt: 45)
        let read = t0.addingTimeInterval(20 * 60)
        let observedCentre = Coord(lat: 0, lon: 100 / 60.0405)
        let drawnCentre = Coord(lat: 0, lon: 115 / 60.0405)
        XCTAssertTrue(ConvectiveCellDraw.contains(c, at: read, drawnCentre),
                      "the outline the pilot can see has to be the one that answers")
        XCTAssertFalse(ConvectiveCellDraw.contains(c, at: read, observedCentre),
                       "the issued footprint is not on the screen any more")
        // And at age zero the two are the same point, so nothing is lost for a fresh bulletin.
        XCTAssertTrue(ConvectiveCellDraw.contains(c, at: t0, observedCentre))
    }

    func testACellWithNoMotionIsTappedWhereItWasObserved() {
        let c = cell(eastNm: 100, halfNm: 10)                     // no vector stated
        let centre = Coord(lat: 0, lon: 100 / 60.0405)
        XCTAssertTrue(ConvectiveCellDraw.contains(c, at: t0.addingTimeInterval(3_600), centre))
    }

    /// A 2-point LINE TS has no interior, so containment is false along its whole length — by design,
    /// not by omission. Each engine reaches it by ON-SCREEN distance to the segment instead, which is
    /// the only way a finger-sized target works on a shape with no area.
    func testASquallLineHasNoInteriorToBeInside() {
        let line = cell(polygon: [Coord(lat: 0, lon: 0), Coord(lat: 0, lon: 1)])
        XCTAssertTrue(ConvectiveCellDraw.ring(line, at: t0).count == 2, "it is still drawn")
        XCTAssertFalse(ConvectiveCellDraw.contains(line, at: t0, Coord(lat: 0, lon: 0.5)))
    }

    func testContainingAnswersOnlyForCellsTheMapWouldDraw() {
        let drawn = cell(eastNm: 100, halfNm: 10, id: "DRAWN")
        let onePoint = cell(id: "STUB", polygon: [Coord(lat: 0, lon: 100 / 60.0405)])
        let hits = ConvectiveCellDraw.containing([drawn, onePoint], at: t0, Coord(lat: 0, lon: 100 / 60.0405))
        XCTAssertEqual(hits.map(\.id), ["DRAWN"], "a cell that is not drawn cannot answer a tap on it")
    }

    func testEveryOverlappingCellIsOffered() {
        // Two boxes sharing ground: the chooser is the only way the pilot sees the second one.
        let a = cell(eastNm: 100, halfNm: 20, id: "A")
        let b = cell(eastNm: 110, halfNm: 20, id: "B")
        let hits = ConvectiveCellDraw.containing([b, a], at: t0, Coord(lat: 0, lon: 105 / 60.0405))
        XCTAssertEqual(hits.map(\.id), ["A", "B"], "both, and in a stable order")
    }

    func testOverlappingHitsAreCappedWithTheDrawnLayer() {
        let many = (0..<(ConvectiveCellDraw.maxDrawn + 8)).map {
            cell(eastNm: 100, halfNm: 20, id: String(format: "C%03d", $0))
        }
        let hits = ConvectiveCellDraw.containing(many, at: t0, Coord(lat: 0, lon: 100 / 60.0405))
        XCTAssertEqual(hits.count, ConvectiveCellDraw.maxDrawn)
        XCTAssertEqual(hits.map(\.id), hits.map(\.id).sorted())
    }

    /// One point for the arrow's root and the card's bearing anchor. A card and an arrow disagreeing
    /// about where the middle of the storm is would be a strange thing to ship.
    func testTheDrawnCentroidIsWhereTheArrowIsRooted() {
        let c = cell(eastNm: 100, halfNm: 10, fromDeg: 270, kt: 45)
        let read = t0.addingTimeInterval(20 * 60)
        let arrow = ConvectiveCellDraw.motionArrow(c, at: read)
        XCTAssertEqual(nm(ConvectiveCellDraw.drawnCentroid(c, at: read), arrow[0]), 0, accuracy: 1e-9)
        XCTAssertEqual(nm(ConvectiveCellDraw.drawnCentroid(c, at: read), c.centroid), 15, accuracy: 0.01)
    }

    func testTheDrawnCentroidNeverRunsTheStormBackwards() {
        let c = cell(eastNm: 100, halfNm: 10, fromDeg: 270, kt: 45)
        for ahead in [-1.0, -60.0, -86_400.0] {      // a device clock ahead of the stated issue time
            let at = t0.addingTimeInterval(ahead)
            XCTAssertEqual(nm(ConvectiveCellDraw.drawnCentroid(c, at: at), c.centroid), 0, accuracy: 1e-9)
        }
        XCTAssertEqual(nm(ConvectiveCellDraw.drawnCentroid(cell(), at: t0.addingTimeInterval(3_600)),
                          cell().centroid), 0, accuracy: 1e-9, "no vector, no drift")
    }

    func testTheTappedObjectCarriesTheCellAndRefusesToBeFiled() {
        let c = cell(eastNm: 100, halfNm: 10, fromDeg: 270, kt: 45, id: "WST-7C")
        let read = t0.addingTimeInterval(20 * 60)
        let o = ConvectiveCellDraw.object(c, at: read)
        XCTAssertEqual(o.kind, .convective)
        XCTAssertEqual(o.ident, "WST-7C")
        XCTAssertEqual(o.cell?.id, "WST-7C", "the card reads the cell off the object")
        XCTAssertFalse(o.onRoute)
        XCTAssertFalse(o.kind.isRoutable, "\"Add to route\" on a thunderstorm")
        XCTAssertEqual(nm(o.coord, ConvectiveCellDraw.drawnCentroid(c, at: read)), 0, accuracy: 1e-9)
    }

    // MARK: what the card says

    /// The banner has one line and states the vector the bulletin's way, so it can be read against the
    /// printed text. The card has two columns and gives both ends — *from* is not where it is going,
    /// and a pilot choosing which way to turn needs *toward*.
    func testTheCardStatesBothEndsOfTheMotionVector() {
        let c = cell(fromDeg: 240, kt: 35)
        XCTAssertEqual(ConvectiveAlertText.motionLine(c), "From 240° at 35 kt · toward 060°")
    }

    func testADerivedVectorSaysItsSpeedIsAFloor() {
        let radar = cell(fromDeg: 255, kt: 28, source: .radar)
        XCTAssertEqual(ConvectiveAlertText.motionLine(radar), "From 255° at 28 kt or more · toward 075°")
    }

    /// Two different silences, and a pilot can act on the difference: a bulletin that stated no vector
    /// may still have one in its text, a radar frame pair that could not recover one will not.
    func testTheCardSaysWhichKindOfSilenceAMissingVectorIs() {
        XCTAssertEqual(ConvectiveAlertText.motionLine(cell()), "Not stated by the bulletin")
        XCTAssertEqual(ConvectiveAlertText.motionLine(cell(kt: nil, source: .radar)),
                       "Not measurable from the radar frames")
        // A stated direction with no speed is as useless as neither, and must not print "at 0 kt".
        XCTAssertEqual(ConvectiveAlertText.motionLine(cell(fromDeg: 240, kt: 0)),
                       "Not stated by the bulletin")
    }

    /// The AWC states `altitudeLow` as 0 for a surface-based cell, which is most of them. A card that
    /// only special-cased nil would print "0 ft" beside a map label reading SFC for the same storm.
    func testAStatedZeroBaseIsTheSurface() {
        XCTAssertEqual(ConvectiveAlertText.baseLine(0), "Surface")
        XCTAssertEqual(ConvectiveAlertText.baseLine(nil), "Surface")
        XCTAssertEqual(ConvectiveAlertText.baseLine(-50), "Surface", "below sea level is still the ground")
        XCTAssertEqual(ConvectiveAlertText.baseLine(12_000), "12,000 ft")
        XCTAssertEqual(ConvectiveAlertText.baseLine(24_000), "FL240")
        // And it agrees with the altitude block the map draws for the same cell.
        XCTAssertEqual(ConvectiveCellDraw.baseText(cell(base: nil)), "SFC")
        XCTAssertEqual(ConvectiveCellDraw.baseText(cell(base: 0)), "SFC")
    }

    func testTheAgeRowReadsLikeAClock() {
        let c = cell()
        XCTAssertEqual(ConvectiveAlertText.observedAgeText(c, now: t0), "just now")
        XCTAssertEqual(ConvectiveAlertText.observedAgeText(c, now: t0.addingTimeInterval(-600)), "just now",
                       "a device clock ahead of the stated issue time is not a storm from the future")
        XCTAssertEqual(ConvectiveAlertText.observedAgeText(c, now: t0.addingTimeInterval(18 * 60)), "18 min ago")
        XCTAssertEqual(ConvectiveAlertText.observedAgeText(c, now: t0.addingTimeInterval(90 * 60)), "1 h 30 min ago")
        XCTAssertEqual(ConvectiveAlertText.observedAgeText(c, now: t0.addingTimeInterval(7_200)), "2 h ago")
    }

    /// What this reads determines what it can miss, and that varies per cell — so the line is built
    /// from the CELL, which is what lets a card name the source of a storm the alert raised nothing
    /// about. That is exactly the cell whose provenance a pilot is most likely to be asking after.
    func testTheSourceLineNamesTheProductAndItsLimitation() {
        XCTAssertTrue(ConvectiveAlertText.sourceLine(cell(source: .sigmet)).hasPrefix("Convective SIGMET"))
        XCTAssertTrue(ConvectiveAlertText.sourceLine(cell(source: .cwa)).hasPrefix("Center Weather Advisory"))
        XCTAssertTrue(ConvectiveAlertText.sourceLine(cell(source: .warning)).contains("tops not stated"))
        XCTAssertTrue(ConvectiveAlertText.sourceLine(cell(kt: 28, source: .radar)).contains("estimated from radar"))
        XCTAssertTrue(ConvectiveAlertText.sourceLine(cell(kt: nil, source: .radar)).contains("movement unknown"))
    }
}

#if canImport(MapLibre)
import MapLibre

/// The MapLibre engine's features for the same storms. Both engines take every geometric decision from
/// `ConvectiveCellDraw`, so what is checked here is the GeoJSON wrapping: the attributes the style
/// layers key their weight and their dash off, and the shape kind a squall line becomes.
final class MapLibreStormFeatureTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_793_750_000)

    private func cell(id: String, polygon: [Coord], kt: Double? = 45, fromDeg: Double? = 270,
                      source: ConvectiveSource = .sigmet) -> ConvectiveCell {
        var c = ConvectiveCell(id: id, label: id, polygon: polygon,
                               topsFtMSL: 41_000, baseFtMSL: nil,
                               observedAt: t0, validUntil: t0.addingTimeInterval(7_200),
                               severity: 5, movingFromDeg: fromDeg, motionKt: kt)
        c.source = source
        return c
    }

    private let square = [Coord(lat: 0, lon: 1), Coord(lat: 0, lon: 2),
                          Coord(lat: 1, lon: 2), Coord(lat: 1, lon: 1)]

    func testTheWeightAttributeMarksOnlyTheCellsTheBannerIsWarningAbout() {
        let cells = [cell(id: "A", polygon: square), cell(id: "B", polygon: square)]
        let f = MapLibreChartView.Coordinator.stormFeatures(cells, threatIDs: ["A"], at: t0)
        XCTAssertEqual(f.shapes.count, 2)
        let wt = Dictionary(uniqueKeysWithValues: f.shapes.compactMap { s -> (String, String)? in
            guard let a = (s as? MLNFeature)?.attributes,
                  let id = a["id"] as? String, let w = a["wt"] as? String else { return nil }
            return (id, w)
        })
        XCTAssertEqual(wt["A"], "threat")
        XCTAssertEqual(wt["B"], "known")
    }

    func testADerivedVectorIsTaggedForTheDashedArrowLayer() {
        // The two arrow layers are split by a filter on this attribute, because line-dasharray is not
        // data-driven in the style spec. A wrong value here silently solid-lines a derived vector.
        let f = MapLibreChartView.Coordinator.stormFeatures(
            [cell(id: "R", polygon: square, source: .radar),
             cell(id: "S", polygon: square, source: .sigmet)], threatIDs: [], at: t0)
        let derived = Dictionary(uniqueKeysWithValues: f.arrows.compactMap { s -> (String, String)? in
            guard let a = (s as? MLNFeature)?.attributes,
                  let id = a["id"] as? String, let d = a["derived"] as? String else { return nil }
            return (id, d)
        })
        XCTAssertEqual(derived["R"], "yes")
        XCTAssertEqual(derived["S"], "no")
    }

    func testASquallLineBecomesALineFeatureAndASolidCellAPolygon() {
        let f = MapLibreChartView.Coordinator.stormFeatures(
            [cell(id: "LINE", polygon: [Coord(lat: 0, lon: 1), Coord(lat: 0, lon: 2)]),
             cell(id: "AREA", polygon: square)], threatIDs: [], at: t0)
        let kinds = Dictionary(uniqueKeysWithValues: f.shapes.compactMap { s -> (String, String)? in
            guard let id = (s as? MLNFeature)?.attributes["id"] as? String else { return nil }
            return (id, s is MLNPolygonFeature ? "polygon" : "line")
        })
        XCTAssertEqual(kinds["LINE"], "line", "a LINE TS has no interior to fill")
        XCTAssertEqual(kinds["AREA"], "polygon")
    }

    func testTheTopsBlockRidesOnItsOwnPointFeature() {
        let f = MapLibreChartView.Coordinator.stormFeatures([cell(id: "A", polygon: square)],
                                                            threatIDs: [], at: t0)
        XCTAssertEqual(f.labels.count, 1)
        XCTAssertEqual(f.labels[0].attributes["alt"] as? String, "FL410\nSFC")
        XCTAssertEqual(f.labels[0].coordinate.latitude, 1, accuracy: 1e-9, "northernmost vertex")
    }

    func testACellWithNoMotionContributesAnOutlineButNoArrow() {
        let f = MapLibreChartView.Coordinator.stormFeatures(
            [cell(id: "A", polygon: square, kt: nil, fromDeg: nil)], threatIDs: [], at: t0)
        XCTAssertEqual(f.shapes.count, 1)
        XCTAssertTrue(f.arrows.isEmpty)
    }

    func testNothingIsEmittedForAnEmptyCellList() {
        let f = MapLibreChartView.Coordinator.stormFeatures([], threatIDs: [], at: t0)
        XCTAssertTrue(f.shapes.isEmpty && f.arrows.isEmpty && f.labels.isEmpty)
    }
}
#endif
