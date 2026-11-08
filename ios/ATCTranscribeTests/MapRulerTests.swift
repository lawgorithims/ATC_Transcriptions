import XCTest
import CoreGraphics
@testable import ATCTranscribe

/// The measuring ruler: what it reads out, and how the store behaves while fingers are on it.
///
/// The gesture arbitration itself (`TwoFingerRulerRecognizer`, `MapRulerController`) needs real
/// touches on a real map view and is exercised by hand; what IS testable here is everything the
/// pilot actually reads — the distance, the time, the bearing and which speed they came from — plus
/// the store rules that decide what a touch takes hold of.
@MainActor
final class MapRulerTests: XCTestCase {

    // Two points about 60 NM apart, due north: the arithmetic is checkable by hand.
    private let south = Coord(lat: 32.0, lon: -97.0)
    private let north = Coord(lat: 33.0, lon: -97.0)

    private func readout(_ a: Coord, _ b: Coord,
                         gs: Double? = nil, cruise: Int? = nil,
                         variation: @escaping (Coord) -> Double? = { _ in nil }) -> MapRulerReadout {
        MapRulerMath.readout(MapRuler(a: a, b: b), groundSpeedKt: gs, cruiseKt: cruise,
                             variation: variation)
    }

    // MARK: Distance and bearing

    /// One degree of latitude is 60 NM by definition, so this one can be checked without a chart.
    func testDistanceAndBearingDueNorth() {
        let r = readout(south, north)
        XCTAssertEqual(r.distanceNm, 60, accuracy: 0.3, "a degree of latitude is 60 NM")
        XCTAssertEqual(r.bearingTrue, 0, accuracy: 0.1, "due north")
    }

    func testBearingReversesWithTheEnds() {
        XCTAssertEqual(readout(north, south).bearingTrue, 180, accuracy: 0.1)
    }

    /// A ruler the pilot has not dragged out yet reads zero rather than NaN — the label is drawn from
    /// these numbers the moment the ruler appears.
    func testACollapsedRulerReadsZeroAndNotNaN() {
        let r = readout(south, south, gs: 120)
        XCTAssertEqual(r.distanceNm, 0, accuracy: 0.0001)
        XCTAssertEqual(r.minutes ?? -1, 0, accuracy: 0.0001)
        XCTAssertFalse(r.distanceNm.isNaN)
    }

    // MARK: Magnetic vs true

    /// `true = magnetic + variation` (east positive), the same convention `VectorProcedureView` plots
    /// published courses with. Getting the sign backwards would be a double error — in Texas, 8°.
    func testMagneticBearingSubtractsEastVariation() {
        let r = readout(south, north, variation: { _ in 4.0 })
        XCTAssertEqual(r.bearingTrue, 0, accuracy: 0.1)
        XCTAssertEqual(r.bearingMag ?? -1, 356, accuracy: 0.1,
                       "000 true with 4°E variation is 356 magnetic")
        XCTAssertEqual(MapRulerMath.bearingText(r), "356°M")
    }

    /// Where no bundled navaid publishes a variation the label must say TRUE rather than pass a true
    /// bearing off as magnetic — a pilot steering a magnetic heading off a true number is the whole
    /// reason this distinction is carried through.
    func testWithoutAVariationTheLabelSaysTrue() {
        let r = readout(south, north)
        XCTAssertNil(r.bearingMag)
        XCTAssertEqual(MapRulerMath.bearingText(r), "000°T")
    }

    func testBearingTextIsAlwaysThreeDigits() {
        let r = readout(Coord(lat: 32, lon: -97), Coord(lat: 32.1, lon: -96.9))
        XCTAssertEqual(MapRulerMath.bearingText(r).count, 5, "three digits, a degree sign and T/M")
    }

    // MARK: Time, and what it rests on

    func testTimeUsesTheGroundSpeedTheAircraftIsMaking() {
        let r = readout(south, north, gs: 120, cruise: 90)
        XCTAssertEqual(r.speedSource, .groundSpeed, "the pilot's own speed wins over a planning number")
        XCTAssertEqual(r.minutes ?? 0, 30, accuracy: 0.2, "60 NM at 120 kt is half an hour")
        XCTAssertEqual(MapRulerMath.timeText(r.minutes), "30 min")
    }

    /// ⚠️ A STATIONARY AIRCRAFT MUST NOT DRIVE THE CLOCK. At 2 kt a 60 NM ruler reads thirty hours,
    /// which is not a wrong number so much as a meaningless one. Same threshold as `RouteETAs`, and
    /// deliberately so: the two must not disagree about whether the aircraft is moving.
    func testASittingAircraftFallsBackToPlannedCruise() {
        let r = readout(south, north, gs: 2, cruise: 120)
        XCTAssertEqual(r.speedSource, .cruise)
        XCTAssertEqual(r.minutes ?? 0, 30, accuracy: 0.2)
        XCTAssertEqual(MapRulerMath.speedNote(r), "at 120 kt planned cruise",
                       "and the label says so, because 30 min from a profile is not 30 min from a GPS")
    }

    /// No speed anywhere: distance and bearing still read, and no time is invented.
    func testWithNoSpeedAtAllThereIsNoTime() {
        let r = readout(south, north)
        XCTAssertEqual(r.speedSource, .none)
        XCTAssertNil(r.minutes)
        XCTAssertNil(MapRulerMath.timeText(r.minutes))
        XCTAssertNil(MapRulerMath.speedNote(r))
        XCTAssertFalse(MapRulerMath.summary(r).contains("min"), "no time in the summary either")
        XCTAssertTrue(MapRulerMath.summary(r).contains("60 NM"))
    }

    func testTimeTextFormats() {
        XCTAssertEqual(MapRulerMath.timeText(0.4), "<1 min", "never '0 min' for a real distance")
        XCTAssertEqual(MapRulerMath.timeText(7.2), "7 min")
        XCTAssertEqual(MapRulerMath.timeText(83), "1:23", "'83 min' is a number you have to convert")
        XCTAssertNil(MapRulerMath.timeText(nil))
        XCTAssertNil(MapRulerMath.timeText(.nan))
    }

    /// Under 10 NM the decimal is kept, because that is the range at which a ruler is being used to
    /// clear terrain or the edge of a TFR and a whole mile is not a fine enough answer.
    func testDistanceTextKeepsADecimalCloseIn() {
        XCTAssertEqual(MapRulerMath.distanceText(4.32), "4.3 NM")
        XCTAssertEqual(MapRulerMath.distanceText(12.6), "13 NM")
        XCTAssertEqual(MapRulerMath.distanceText(.nan), "—")
    }

    func testSummaryReadsFarThenLongThenWhich() {
        let r = readout(south, north, gs: 120, variation: { _ in 4 })
        XCTAssertEqual(MapRulerMath.summary(r), "60 NM  ·  30 min  ·  356°M",
                       "no decimal past 10 NM — see testDistanceTextKeepsADecimalCloseIn")
    }

    // MARK: The store

    func testAddingAndFreezing() {
        let store = MapRulerStore()
        let id = store.add(a: south, b: north, live: true)
        XCTAssertEqual(store.rulers.count, 1)
        XCTAssertEqual(store.liveID, id, "it is live while the fingers are down")
        store.freeze()
        XCTAssertNil(store.liveID, "letting go freezes it")
        XCTAssertEqual(store.rulers.count, 1, "and it stays on the chart")
    }

    /// Another two-finger tap adds another ruler rather than replacing the first.
    func testEachTapAddsAnotherRuler() {
        let store = MapRulerStore()
        store.add(a: south, b: north, live: false)
        store.add(a: Coord(lat: 30, lon: -95), b: Coord(lat: 31, lon: -95), live: false)
        XCTAssertEqual(store.rulers.count, 2)
    }

    /// Bounded, and the oldest goes: a pilot tapping at the chart in turbulence must not end up with
    /// a display they cannot read through.
    func testTheRulerCountIsBoundedAndDropsTheOldest() {
        let store = MapRulerStore()
        var ids: [UUID] = []
        for i in 0..<(MapRulerStore.maxRulers + 3) {
            ids.append(store.add(a: Coord(lat: 32 + Double(i) * 0.1, lon: -97),
                                 b: Coord(lat: 33 + Double(i) * 0.1, lon: -97), live: false))
        }
        XCTAssertEqual(store.rulers.count, MapRulerStore.maxRulers)
        XCTAssertNil(store.ruler(ids.first!), "the first one laid down is the first to go")
        XCTAssertNotNil(store.ruler(ids.last!), "the newest survives")
    }

    func testClearRemovesEverything() {
        let store = MapRulerStore()
        let id = store.add(a: south, b: north, live: true)
        store.setSegments([id: .init(a: .zero, b: CGPoint(x: 10, y: 10))])
        store.clear()
        XCTAssertTrue(store.isEmpty)
        XCTAssertTrue(store.segments.isEmpty, "the projections go with them")
        XCTAssertNil(store.liveID)
    }

    // MARK: What a touch takes hold of

    func testAFingerNearAnEndTakesHoldOfThatEnd() {
        let store = MapRulerStore()
        let id = store.add(a: south, b: north, live: false)
        store.setSegments([id: .init(a: CGPoint(x: 100, y: 100), b: CGPoint(x: 300, y: 100))])

        let grabA = store.grab(near: CGPoint(x: 108, y: 104))
        XCTAssertEqual(grabA?.id, id)
        XCTAssertEqual(grabA?.isEndA, true)

        let grabB = store.grab(near: CGPoint(x: 296, y: 96))
        XCTAssertEqual(grabB?.isEndA, false, "the nearer end wins")
    }

    /// ⚠️ THE RULE THAT KEEPS PINCH-ZOOM WORKING. Two fingers that land away from every ruler take
    /// hold of nothing, the ruler gesture never claims them, and the map zooms exactly as it did
    /// before this feature existed.
    func testFingersAwayFromEveryRulerTakeHoldOfNothing() {
        let store = MapRulerStore()
        let id = store.add(a: south, b: north, live: false)
        store.setSegments([id: .init(a: CGPoint(x: 100, y: 100), b: CGPoint(x: 300, y: 100))])
        XCTAssertNil(store.grab(near: CGPoint(x: 100, y: 400)), "well clear of both ends")
        XCTAssertNil(store.grab(near: CGPoint(x: 200, y: 100)),
                     "even the MIDDLE of the ruler is not an end — grabbing the line is a separate rule")
    }

    /// With two rulers overlapping, the one laid down most recently is the one the pilot is working
    /// on, so it wins.
    func testTheNewestRulerWinsAnOverlappingGrab() {
        let store = MapRulerStore()
        let old = store.add(a: south, b: north, live: false)
        let new = store.add(a: south, b: north, live: false)
        store.setSegments([old: .init(a: CGPoint(x: 100, y: 100), b: CGPoint(x: 300, y: 100)),
                           new: .init(a: CGPoint(x: 100, y: 100), b: CGPoint(x: 300, y: 100))])
        XCTAssertEqual(store.grab(near: CGPoint(x: 100, y: 100))?.id, new)
    }

    func testARulerWithNoProjectionCannotBeGrabbed() {
        let store = MapRulerStore()
        store.add(a: south, b: north, live: false)
        XCTAssertNil(store.grab(near: CGPoint(x: 100, y: 100)),
                     "nothing has told the store where this ruler is on screen yet")
    }

    /// Moving an end changes the measurement, which is the point of being able to drag it.
    func testMovingAnEndChangesTheReading() {
        let store = MapRulerStore()
        let id = store.add(a: south, b: north, live: true)
        let before = MapRulerMath.readout(store.ruler(id)!, groundSpeedKt: nil, cruiseKt: nil,
                                          variation: { _ in nil }).distanceNm
        store.move(id, a: south, b: Coord(lat: 34.0, lon: -97.0))
        let after = MapRulerMath.readout(store.ruler(id)!, groundSpeedKt: nil, cruiseKt: nil,
                                         variation: { _ in nil }).distanceNm
        XCTAssertEqual(before, 60, accuracy: 0.3)
        XCTAssertEqual(after, 120, accuracy: 0.6)
    }
}
