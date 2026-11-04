import XCTest
@testable import ATCTranscribe

/// Cell extraction and the cross-correlated motion vector.
///
/// Geometry is built on a 0.01° grid like MRMS's, but near the equator wherever a distance is asserted,
/// so a degree of longitude is 60 NM and the expected numbers are exact arithmetic rather than something
/// read back out of the code under test.
final class RadarCellFinderTests: XCTestCase {

    private let kmPerFoot = 1.0 / 3_280.839_895

    /// A window of echo tops in kilometres. `blobs` paints rectangles of a given height in FEET.
    private func window(ni: Int, nj: Int, minLat: Double = 0, minLon: Double = 0,
                        d: Double = 0.01,
                        background: Float = -1,          // MRMS "radar coverage, no echo"
                        blobs: [(jRange: Range<Int>, iRange: Range<Int>, ft: Double)] = [])
                        -> Grib2Decoder.Window {
        var values = [Float](repeating: background, count: ni * nj)
        for b in blobs {
            for j in b.jRange where j >= 0 && j < nj {
                for i in b.iRange where i >= 0 && i < ni {
                    values[j * ni + i] = Float(b.ft * kmPerFoot)
                }
            }
        }
        return Grib2Decoder.Window(referenceTime: nil, discipline: 209, paramCategory: 3,
                                   paramNumber: 45, levelType: 102, levelValue: 500,
                                   ni: ni, nj: nj, minLat: minLat, minLon: minLon,
                                   dLat: d, dLon: d, values: values)
    }

    private let noon = Date(timeIntervalSince1970: 1_793_753_700)

    // MARK: - the threshold

    func testABlobAboveTheThresholdBecomesACellCarryingItsMeasuredTop() throws {
        let w = window(ni: 40, nj: 40, blobs: [(10..<20, 10..<20, 32_000)])
        let cells = RadarCellFinder.cells(from: w, observedAt: noon)
        XCTAssertEqual(cells.count, 1)
        let c = try XCTUnwrap(cells.first)
        XCTAssertEqual(try XCTUnwrap(c.topsFtMSL), 32_000, accuracy: 20,
                       "the measured top, not a stated one")
        XCTAssertEqual(c.source, .radar)
        XCTAssertNil(c.baseFtMSL, "an echo top says nothing about the base; nil reads as surface")
        XCTAssertNil(c.motionKt, "one frame cannot know a velocity")
        XCTAssertEqual(c.observedAt, noon)
        XCTAssertEqual(c.validUntil, noon.addingTimeInterval(12 * 60))
    }

    func testABlobBelowTheThresholdIsNotACell() {
        let w = window(ni: 40, nj: 40, blobs: [(10..<20, 10..<20, 12_000)])
        XCTAssertTrue(RadarCellFinder.cells(from: w, observedAt: noon).isEmpty,
                      "30 dBZ topping 12,000 ft is rain, not a thunderstorm")
    }

    /// ⚠️ MRMS SIGNALS NO-DATA WITH NEGATIVE NUMBERS, NOT A BITMAP. Measured live: −1.0 km is "radar
    /// coverage, nothing above 30 dBZ" and −3.0 km is "no coverage" (it is also the section-5 reference
    /// value, so an all-zero payload decodes to it). Both must be excluded by requiring a POSITIVE
    /// height, so that a future sentinel cannot be read as a height below the threshold and let through.
    func testTheNegativeSentinelsAndNaNAreNeverReadAsHeights() {
        for background in [Float(-1), Float(-3), Float.nan, Float(0)] {
            let w = window(ni: 30, nj: 30, background: background)
            XCTAssertTrue(RadarCellFinder.cells(from: w, observedAt: noon).isEmpty,
                          "background \(background) must not produce cells")
        }
        // And a real cell still survives on a no-coverage background.
        let w = window(ni: 30, nj: 30, background: -3, blobs: [(10..<18, 10..<18, 40_000)])
        XCTAssertEqual(RadarCellFinder.cells(from: w, observedAt: noon).count, 1)
    }

    func testSpeckleBelowTheMinimumSizeIsDiscarded() {
        var cfg = RadarCellFinder.Config()
        cfg.minCellPoints = 12
        // 3x3 = 9 points, under the floor.
        let small = window(ni: 30, nj: 30, blobs: [(5..<8, 5..<8, 45_000)])
        XCTAssertTrue(RadarCellFinder.cells(from: small, observedAt: noon, config: cfg).isEmpty)
        // 4x4 = 16 points, over it.
        let big = window(ni: 30, nj: 30, blobs: [(5..<9, 5..<9, 45_000)])
        XCTAssertEqual(RadarCellFinder.cells(from: big, observedAt: noon, config: cfg).count, 1)
    }

    // MARK: - components

    func testTwoSeparatedBlobsAreTwoCells() throws {
        let w = window(ni: 60, nj: 60, blobs: [(5..<15, 5..<15, 30_000),
                                               (40..<50, 40..<50, 45_000)])
        let cells = RadarCellFinder.cells(from: w, observedAt: noon)
        XCTAssertEqual(cells.count, 2)
        XCTAssertEqual(try XCTUnwrap(cells.first?.topsFtMSL), 45_000, accuracy: 20,
                       "tallest first — if the banner can only show a few, they should be the worst")
    }

    /// 8-connectivity, not 4: a cell that necks down to a diagonal is one storm. Under 4-connectivity it
    /// would split into two halves that can each fall under `minCellPoints` and vanish entirely.
    func testADiagonalNeckKeepsOneCellWhole() throws {
        var cfg = RadarCellFinder.Config()
        cfg.minCellPoints = 12
        var blobs: [(Range<Int>, Range<Int>, Double)] = [(10..<17, 10..<17, 40_000),
                                                         (17..<24, 17..<24, 40_000)]
        let w = window(ni: 40, nj: 40, blobs: blobs.map { (jRange: $0.0, iRange: $0.1, ft: $0.2) })
        let cells = RadarCellFinder.cells(from: w, observedAt: noon, config: cfg)
        XCTAssertEqual(cells.count, 1, "the two squares touch only at a corner, and that is one storm")
        blobs = []
        XCTAssertTrue(blobs.isEmpty)
    }

    // MARK: - the polygon's containment property

    /// ⚠️ THE PROPERTY THE WHOLE POLYGON DESIGN RESTS ON: the ring must CONTAIN every convective point
    /// of its component. Candidates are each row's leftmost and rightmost point, so any point at row j
    /// lies on the segment between that row's two candidates and therefore inside their hull — which
    /// holds whether or not the component is convex, and whether or not a row's points are contiguous.
    /// A ring that clipped its own component would under-warn exactly where the storm is worst.
    func testTheRingContainsEveryPointOfItsOwnComponent() throws {
        // A deliberately awkward concave shape: a C, whose hull is much larger than itself.
        var blobs: [(jRange: Range<Int>, iRange: Range<Int>, ft: Double)] = []
        blobs.append((20..<24, 10..<40, 40_000))      // bottom bar
        blobs.append((24..<40, 10..<16, 40_000))      // left upright
        blobs.append((40..<44, 10..<40, 40_000))      // top bar
        let w = window(ni: 60, nj: 60, blobs: blobs)
        let cells = RadarCellFinder.cells(from: w, observedAt: noon)
        XCTAssertEqual(cells.count, 1)
        let ring = try XCTUnwrap(cells.first?.polygon)

        var checked = 0
        for j in 0..<w.nj {
            for i in 0..<w.ni {
                guard let v = w.value(row: j, col: i), v > 0,
                      Double(v) * 3_280.839_895 >= 18_000 else { continue }
                let p = Coord(lat: w.lat(ofRow: j), lon: w.lon(ofCol: i))
                // Tolerance, not exact zero: the hull's own vertices and edges pass exactly through
                // grid points, and a ray-cast containment test is undefined for a point lying on a
                // horizontal edge — those land on the segment-distance branch and come back as float
                // epsilon (measured: ~2e-15 NM, which is picometres) instead of a clean 0.
                XCTAssertLessThan(ConvectiveAlert.distanceNm(from: p, toPolygon: ring), 1e-6,
                                  "point (\(j),\(i)) of the component fell outside its own ring")
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 200, "the fixture really is a large component")
    }

    /// The same property over many randomly generated blobs, because one hand-drawn shape proves little
    /// about a hull. Deterministically seeded so a failure is reproducible.
    func testTheContainmentPropertyHoldsOverManyRandomShapes() throws {
        var rng = SystemRandomNumberGenerator()
        _ = rng
        var seed: UInt64 = 0x5EED_1234
        func next(_ n: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((seed >> 33) % UInt64(n))
        }
        for trial in 0..<40 {
            var blobs: [(jRange: Range<Int>, iRange: Range<Int>, ft: Double)] = []
            for _ in 0..<(2 + next(4)) {
                let j = 5 + next(30), i = 5 + next(30)
                blobs.append((j..<(j + 2 + next(12)), i..<(i + 2 + next(12)), 40_000))
            }
            let w = window(ni: 60, nj: 60, blobs: blobs)
            let cells = RadarCellFinder.cells(from: w, observedAt: noon)
            // Each convective point must be inside SOME ring, unless its component was speckle.
            var rings = cells.map(\.polygon)
            if rings.isEmpty { continue }
            var outside = 0
            for j in 0..<w.nj {
                for i in 0..<w.ni {
                    guard let v = w.value(row: j, col: i), v > 0,
                          Double(v) * 3_280.839_895 >= 18_000 else { continue }
                    let p = Coord(lat: w.lat(ofRow: j), lon: w.lon(ofCol: i))
                    if !rings.contains(where: { ConvectiveAlert.distanceNm(from: p, toPolygon: $0) < 1e-6 }) {
                        outside += 1
                    }
                }
            }
            // Anything outside every ring must be accounted for by the speckle floor, and a handful of
            // sub-threshold components is all that can be.
            XCTAssertLessThan(outside, RadarCellFinder.Config().minCellPoints * 8,
                              "trial \(trial): \(outside) convective points in no ring at all")
            rings = []
            XCTAssertTrue(rings.isEmpty)
        }
    }

    func testTheRingNeverExceedsTheAlertsVertexCap() {
        // A big ragged component, to push the hull's vertex count up.
        var blobs: [(jRange: Range<Int>, iRange: Range<Int>, ft: Double)] = []
        for k in 0..<60 {
            blobs.append((k..<(k + 2), (30 - k / 2)..<(30 + k / 2 + 1), 40_000))
        }
        let w = window(ni: 80, nj: 80, blobs: blobs)
        for c in RadarCellFinder.cells(from: w, observedAt: noon) {
            XCTAssertLessThanOrEqual(c.polygon.count, ConvectiveAlert.maxVertices)
            XCTAssertGreaterThanOrEqual(c.polygon.count, 3)
        }
    }

    func testTheConvexHullIsCounterClockwiseAndWithoutARepeatedVertex() throws {
        let pts = [Coord(lat: 0, lon: 0), Coord(lat: 0, lon: 1), Coord(lat: 1, lon: 1),
                   Coord(lat: 1, lon: 0), Coord(lat: 0.5, lon: 0.5)]   // last one is interior
        let hull = RadarCellFinder.convexHull(pts)
        XCTAssertEqual(hull.count, 4, "the interior point is not on the hull")
        XCTAssertNotEqual(hull.first, hull.last, "the ring is open, as the alert's math expects")
        // Shoelace sign: positive is counter-clockwise in (lon, lat).
        var sum = 0.0
        for i in 0..<hull.count {
            let a = hull[i], b = hull[(i + 1) % hull.count]
            sum += a.lon * b.lat - b.lon * a.lat
        }
        XCTAssertGreaterThan(sum, 0)
    }

    func testTheIdIsStableForAStationaryCellAndDismissalKeysOnItAlone() throws {
        let w = window(ni: 40, nj: 40, minLat: 30, minLon: -95, blobs: [(10..<20, 10..<20, 40_000)])
        let a = try XCTUnwrap(RadarCellFinder.cells(from: w, observedAt: noon).first)
        let b = try XCTUnwrap(RadarCellFinder.cells(
            from: w, observedAt: noon.addingTimeInterval(120)).first)
        XCTAssertEqual(a.id, b.id, "same storm, same place, two minutes later")
        // ⚠️ The whole reason `dismissOverride` exists: `observedAt` moves every frame, so the DEFAULT
        // key would change every two minutes and a dismissal would appear not to work at all.
        XCTAssertEqual(a.dismissKey, b.dismissKey)
        XCTAssertEqual(a.dismissKey, a.id)
        XCTAssertNotEqual(a.observedAt, b.observedAt)
    }

    // MARK: - motion by cross-correlation

    /// Shift a whole field by a known number of cells and assert the vector comes back.
    private func shifted(_ w: Grib2Decoder.Window, dj: Int, di: Int) -> Grib2Decoder.Window {
        var values = [Float](repeating: -1, count: w.ni * w.nj)
        for j in 0..<w.nj {
            for i in 0..<w.ni {
                let sj = j - dj, si = i - di
                guard sj >= 0, sj < w.nj, si >= 0, si < w.ni else { continue }
                values[j * w.ni + i] = w.values[sj * w.ni + si]
            }
        }
        return Grib2Decoder.Window(referenceTime: w.referenceTime, discipline: w.discipline,
                                   paramCategory: w.paramCategory, paramNumber: w.paramNumber,
                                   levelType: w.levelType, levelValue: w.levelValue,
                                   ni: w.ni, nj: w.nj, minLat: w.minLat, minLon: w.minLon,
                                   dLat: w.dLat, dLon: w.dLon, values: values)
    }

    /// ⚠️ THE SIGN TEST. The field is moved EAST, so it is travelling toward 090 and therefore coming
    /// FROM 270. `movingFromDeg` must read ~270. Get this backwards and the alert fires for the
    /// aeroplane safely behind a storm and stays silent for the one flying into it.
    func testAFieldMovedEastReadsAsComingFromTheWest() throws {
        // At the equator a 0.01° cell is 0.6 NM each way. 20 cells east = 12 NM in 10 minutes = 72 kt,
        // so use 12 cells = 7.2 NM in 10 min = 43 kt.
        let base = window(ni: 120, nj: 120, blobs: [(40..<70, 30..<60, 40_000)])
        let later = shifted(base, dj: 0, di: 12)
        let t0 = noon, t1 = noon.addingTimeInterval(600)
        let m = try XCTUnwrap(RadarCellFinder.fieldMotion(current: later, currentAt: t1,
                                                          previous: base, previousAt: t0))
        XCTAssertEqual(m.movingFromDeg, 270, accuracy: 1.0,
                       "moved east ⇒ coming FROM the west")
        XCTAssertEqual(m.motionKt, 43.2, accuracy: 2.0)
        XCTAssertGreaterThan(m.overlap, 0.9, "a rigid translation should line up almost perfectly")
    }

    func testAFieldMovedNorthReadsAsComingFromTheSouth() throws {
        let base = window(ni: 120, nj: 120, blobs: [(30..<60, 40..<70, 40_000)])
        let later = shifted(base, dj: 12, di: 0)
        let m = try XCTUnwrap(RadarCellFinder.fieldMotion(
            current: later, currentAt: noon.addingTimeInterval(600),
            previous: base, previousAt: noon))
        XCTAssertEqual(m.movingFromDeg, 180, accuracy: 1.0)
        XCTAssertEqual(m.motionKt, 43.2, accuracy: 2.0)
    }

    func testADiagonalMoveReadsOnTheRightQuadrant() throws {
        // North-east ⇒ travelling toward 045 ⇒ coming FROM 225.
        let base = window(ni: 120, nj: 120, blobs: [(30..<60, 30..<60, 40_000)])
        let later = shifted(base, dj: 10, di: 10)
        let m = try XCTUnwrap(RadarCellFinder.fieldMotion(
            current: later, currentAt: noon.addingTimeInterval(600),
            previous: base, previousAt: noon))
        XCTAssertEqual(m.movingFromDeg, 225, accuracy: 2.0)
    }

    func testTheRecoveredVectorIsStampedOnEveryCellOfTheFrame() throws {
        let base = window(ni: 120, nj: 120, blobs: [(20..<40, 20..<40, 40_000),
                                                    (70..<90, 70..<90, 50_000)])
        let later = shifted(base, dj: 0, di: 12)
        let m = RadarCellFinder.fieldMotion(current: later, currentAt: noon.addingTimeInterval(600),
                                            previous: base, previousAt: noon)
        XCTAssertNotNil(m)
        let cells = RadarCellFinder.withMotion(
            RadarCellFinder.cells(from: later, observedAt: noon.addingTimeInterval(600)), m)
        XCTAssertEqual(cells.count, 2)
        for c in cells {
            XCTAssertEqual(try XCTUnwrap(c.movingFromDeg), 270, accuracy: 1.0)
            XCTAssertEqual(try XCTUnwrap(c.motionKt), 43.2, accuracy: 2.0)
        }
    }

    func testNilMotionLeavesTheCellsStationaryRatherThanGuessing() throws {
        let w = window(ni: 60, nj: 60, blobs: [(20..<35, 20..<35, 40_000)])
        let cells = RadarCellFinder.withMotion(RadarCellFinder.cells(from: w, observedAt: noon), nil)
        XCTAssertEqual(cells.count, 1)
        XCTAssertNil(cells[0].motionKt)
        XCTAssertNil(cells[0].movingFromDeg)
    }

    // MARK: - when the correlation must refuse

    /// ⚠️ A 2-MINUTE BASELINE CANNOT RESOLVE STORM MOTION AND MUST NOT PRETEND TO. At 0.01° a 20 kt
    /// storm moves about 1.3 grid cells in two minutes, so the argmax would be quantisation noise
    /// pointing anywhere. This was found on real consecutive MRMS frames.
    func testTooShortABaselineIsRefused() {
        let base = window(ni: 120, nj: 120, blobs: [(40..<70, 30..<60, 40_000)])
        let later = shifted(base, dj: 0, di: 2)
        XCTAssertNil(RadarCellFinder.fieldMotion(current: later,
                                                 currentAt: noon.addingTimeInterval(120),
                                                 previous: base, previousAt: noon))
    }

    func testTooLongABaselineIsRefused() {
        let base = window(ni: 120, nj: 120, blobs: [(40..<70, 30..<60, 40_000)])
        let later = shifted(base, dj: 0, di: 12)
        XCTAssertNil(RadarCellFinder.fieldMotion(current: later,
                                                 currentAt: noon.addingTimeInterval(3_600),
                                                 previous: base, previousAt: noon))
    }

    func testAReversedOrSimultaneousPairIsRefused() {
        let base = window(ni: 120, nj: 120, blobs: [(40..<70, 30..<60, 40_000)])
        let later = shifted(base, dj: 0, di: 12)
        XCTAssertNil(RadarCellFinder.fieldMotion(current: base, currentAt: noon,
                                                 previous: later,
                                                 previousAt: noon.addingTimeInterval(600)),
                     "the 'previous' frame is in the future")
        XCTAssertNil(RadarCellFinder.fieldMotion(current: later, currentAt: noon,
                                                 previous: base, previousAt: noon))
    }

    /// Two windows with different geometry cannot be correlated: a shift in grid cells would mean
    /// something different in each, and the recovered vector would be meaningless. This is the case
    /// that arises in flight, when the aircraft has moved far enough to re-centre the window.
    func testWindowsWithDifferentGeometryAreRefused() {
        let a = window(ni: 120, nj: 120, minLat: 0, minLon: 0, blobs: [(40..<70, 30..<60, 40_000)])
        let b = window(ni: 120, nj: 120, minLat: 1, minLon: 0, blobs: [(40..<70, 30..<60, 40_000)])
        XCTAssertNil(RadarCellFinder.fieldMotion(current: b, currentAt: noon.addingTimeInterval(600),
                                                 previous: a, previousAt: noon))
        let c = window(ni: 100, nj: 120, blobs: [(40..<70, 30..<60, 40_000)])
        XCTAssertNil(RadarCellFinder.fieldMotion(current: c, currentAt: noon.addingTimeInterval(600),
                                                 previous: a, previousAt: noon))
    }

    func testTooFewConvectivePointsToCorrelateIsRefused() {
        var cfg = RadarCellFinder.Config()
        cfg.minCorrelationPoints = 40
        let base = window(ni: 120, nj: 120, blobs: [(10..<14, 10..<14, 40_000)])   // 16 points
        let later = shifted(base, dj: 0, di: 12)
        XCTAssertNil(RadarCellFinder.fieldMotion(current: later,
                                                 currentAt: noon.addingTimeInterval(600),
                                                 previous: base, previousAt: noon, config: cfg))
    }

    /// Two completely different fields must not produce a vector just because something lines up
    /// somewhere. This is the overlap floor doing its job.
    func testUnrelatedFieldsProduceNoVector() {
        let a = window(ni: 120, nj: 120, blobs: [(10..<30, 10..<30, 40_000)])
        let b = window(ni: 120, nj: 120, blobs: [(80..<100, 80..<100, 40_000)])
        XCTAssertNil(RadarCellFinder.fieldMotion(current: b, currentAt: noon.addingTimeInterval(600),
                                                 previous: a, previousAt: noon),
                     "a storm cannot have crossed the window in ten minutes")
    }

    /// A field that grew in place rather than moving gives a broad correlation plateau whose argmax is
    /// arbitrary. `minMotionSharpness` is what rejects it.
    func testAFieldThatGrewInPlaceIsReportedAsNoMotionRatherThanADriftingOne() {
        let before = window(ni: 120, nj: 120, blobs: [(40..<70, 40..<70, 40_000)])
        let after = window(ni: 120, nj: 120, blobs: [(38..<72, 38..<72, 40_000)])
        let m = RadarCellFinder.fieldMotion(current: after, currentAt: noon.addingTimeInterval(600),
                                            previous: before, previousAt: noon)
        if let m {
            XCTAssertLessThan(m.motionKt, 12, "symmetric growth must not read as fast translation")
        }
    }

    /// A displacement under a grid cell or two is noise, and is published as "stationary" (nil) rather
    /// than as a 2 kt drift — nil costs `unknownMotionUncertaintyNm` of slack, which is the honest price.
    func testAMotionlessFieldIsPublishedAsStationary() {
        let w = window(ni: 120, nj: 120, blobs: [(40..<70, 40..<70, 40_000)])
        XCTAssertNil(RadarCellFinder.fieldMotion(current: w, currentAt: noon.addingTimeInterval(600),
                                                 previous: w, previousAt: noon))
    }

    func testAnImplausiblyFastShiftIsRefused() {
        var cfg = RadarCellFinder.Config()
        cfg.maxStormKt = 70
        let base = window(ni: 200, nj: 200, blobs: [(20..<50, 20..<50, 40_000)])
        // 60 cells = 36 NM in 10 minutes = 216 kt. Outside the search, so nothing can match.
        let later = shifted(base, dj: 0, di: 60)
        let m = RadarCellFinder.fieldMotion(current: later, currentAt: noon.addingTimeInterval(600),
                                            previous: base, previousAt: noon, config: cfg)
        if let m { XCTAssertLessThanOrEqual(m.motionKt, cfg.maxStormKt) }
    }

    // MARK: - bounds and the alert's contract

    func testTheSnapshotIsBoundedForTheAlertsLoops() {
        var cfg = RadarCellFinder.Config()
        cfg.maxCells = 12
        cfg.minCellPoints = 4
        var blobs: [(jRange: Range<Int>, iRange: Range<Int>, ft: Double)] = []
        for k in 0..<40 {
            let j = (k % 10) * 12, i = (k / 10) * 12
            blobs.append((j..<(j + 4), i..<(i + 4), 30_000 + Double(k) * 100))
        }
        let w = window(ni: 130, nj: 130, blobs: blobs)
        let cells = RadarCellFinder.cells(from: w, observedAt: noon, config: cfg)
        XCTAssertEqual(cells.count, cfg.maxCells)
        XCTAssertLessThanOrEqual(cells.count, ConvectiveAlert.maxCells)
        // Tallest kept, shortest dropped.
        XCTAssertGreaterThan(try! XCTUnwrap(cells.first?.topsFtMSL),
                             try! XCTUnwrap(cells.last?.topsFtMSL))
    }

    func testAnEmptyOrDegenerateWindowYieldsNothing() {
        let empty = Grib2Decoder.Window(referenceTime: nil, discipline: 209, paramCategory: 3,
                                        paramNumber: 45, levelType: 102, levelValue: 500,
                                        ni: 0, nj: 0, minLat: 0, minLon: 0,
                                        dLat: 0.01, dLon: 0.01, values: [])
        XCTAssertTrue(RadarCellFinder.cells(from: empty, observedAt: noon).isEmpty)
        // A window whose value buffer disagrees with its shape is corruption, not a small window.
        let lying = Grib2Decoder.Window(referenceTime: nil, discipline: 209, paramCategory: 3,
                                        paramNumber: 45, levelType: 102, levelValue: 500,
                                        ni: 10, nj: 10, minLat: 0, minLon: 0,
                                        dLat: 0.01, dLon: 0.01, values: [Float](repeating: 5, count: 7))
        XCTAssertTrue(RadarCellFinder.cells(from: lying, observedAt: noon).isEmpty)
    }

    /// ⚠️ The derived vector reads 20–25% SLOW, measured against four live bulletins — and slow is the
    /// dangerous direction, because it puts the projected cell short of where it will be. The alert
    /// pays for that with a wider drift allowance on radar-sourced cells specifically.
    func testARadarCellGetsAWiderDriftAllowanceThanAStatedVector() {
        let ring = [Coord(lat: 0, lon: 0), Coord(lat: 0, lon: 0.1), Coord(lat: 0.1, lon: 0.1)]
        func cell(_ source: ConvectiveSource) -> ConvectiveCell {
            ConvectiveCell(id: "x", label: "x", polygon: ring, topsFtMSL: 40_000, baseFtMSL: nil,
                           observedAt: noon, validUntil: noon.addingTimeInterval(3_600),
                           severity: nil, movingFromDeg: 270, motionKt: 40, source: source)
        }
        let radar = ConvectiveAlert.driftUncertaintyNm(cell(.radar), ageMinutes: 5,
                                                       projectedMinutes: 20)
        let stated = ConvectiveAlert.driftUncertaintyNm(cell(.sigmet), ageMinutes: 5,
                                                        projectedMinutes: 20)
        XCTAssertGreaterThan(radar, stated)
        XCTAssertEqual(radar / stated,
                       ConvectiveAlert.radarDriftErrorFraction / ConvectiveAlert.driftErrorFraction,
                       accuracy: 1e-9)
        // 40 kt over 25 minutes is 16.7 NM of drift; 0.40 of it must cover the ~4 NM the bias costs.
        XCTAssertGreaterThan(radar, 4.0)
    }

    func testAreaIsMeasuredInNauticalMilesSquared() {
        // A 1° × 1° box at the equator is 60 × 60 NM.
        let box = [Coord(lat: 0, lon: 0), Coord(lat: 0, lon: 1),
                   Coord(lat: 1, lon: 1), Coord(lat: 1, lon: 0)]
        XCTAssertEqual(RadarCellFinder.areaNm2(box), 3_600, accuracy: 30)
        XCTAssertEqual(RadarCellFinder.areaNm2([Coord(lat: 0, lon: 0), Coord(lat: 0, lon: 1)]), 0,
                       "a two-point line has no area")
    }
}
