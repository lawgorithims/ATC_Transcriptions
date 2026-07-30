import XCTest
import CoreLocation
@testable import ATCTranscribe

/// "Restore plan" has to be a REAL undo, not just a route undo.
///
/// The engine-out DIRECT is the app's one no-confirm route edit, and the only thing that justifies
/// skipping the confirm is that one tap puts everything back. Engaging re-anchors the plan at present
/// position and drops the loaded procedures, so the `flightPlan` didSet — correctly — reads "no
/// approach is loaded" and clears `activeApproach` plus any armed missed. That reconcile is ONE-WAY:
/// it only ever clears. Restoring the plan therefore used to hand the pilot back their filed route
/// with the approach silently un-armed — no published holds on the map, no ARMED MISSED control — and
/// nothing on screen saying anything was missing. An engine that quits and catches again is exactly
/// when that matters, because the approach being restored is the one about to be flown.
///
/// Asserted against the REAL bundled `cifp.sqlite` on the same fixture as `ApproachHoldParityTests`:
/// KBED "RNAV (GPS) RWY 23" (ident R23), which publishes a hold on its approach-proper row.
@MainActor
final class NRSTRestoreApproachTests: XCTestCase {

    private let airport = "KBED"
    private let ident = "R23"

    override func setUp() {
        super.setUp()
        // Same hermetic setup as ApproachHoldParityTests: constructing AppModel reconciles its live
        // services and the TFR layer defaults ON, which would fire a real FAA fetch from a unit test.
        UserDefaults.standard.set(false, forKey: "atc.map.tfrs")
        UserDefaults.standard.set(false, forKey: "atc.autoPackBag")
        FlightPlan.clear()
        NRSTEngagement.clear()
        MagneticVariation.resetForTests()
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "atc.map.tfrs")
        UserDefaults.standard.removeObject(forKey: "atc.autoPackBag")
        UserDefaults.standard.removeObject(forKey: "atc.airport")
        FlightPlan.clear()
        NRSTEngagement.clear()
        MagneticVariation.resetForTests()
        super.tearDown()
    }

    /// A model that will not reach the network (see ApproachHoldParityTests.sandboxedModel for why),
    /// but with the didSet side effects that this test IS about left switched on.
    ///
    /// `diagnosticActive` is deliberately NOT set here: it suppresses `reconcileActiveApproach` and
    /// `reconcileNRSTEngagement`, which are the exact code paths under test. The network is kept away
    /// by the defaults above instead.
    private func model() -> AppModel {
        let m = AppModel()
        m.airport = airport
        return m
    }

    private func activateFixtureApproach(_ m: AppModel) throws {
        let iaps = CIFP.procedures(airport: airport).filter { $0.kind == "IAP" && $0.ident == ident }
        try XCTSkipIf(iaps.isEmpty, "bundled CIFP unavailable in this environment")
        let proc = try XCTUnwrap(iaps.first)
        m.activateApproach(proc, entry: .vectors)
        try XCTSkipIf(m.activeApproach == nil, "approach did not activate on this cycle")
    }

    /// Give the model a trusted present position by driving `DeviceLocation`'s own CoreLocation delegate
    /// with a synthetic fix — the same entry point a real fix arrives through, so the integrity monitor
    /// sees it exactly as it would in flight. No test-only seam is added to the shipping type for this.
    private func injectFix(_ m: AppModel, lat: Double, lon: Double) {
        let loc = CLLocation(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                             altitude: 1500, horizontalAccuracy: 8, verticalAccuracy: 12,
                             course: 90, speed: 60, timestamp: Date())
        m.deviceLocation.locationManager(CLLocationManager(), didUpdateLocations: [loc])
    }

    /// A ranked candidate for a field far from KBED, so the engage produces a genuinely different
    /// destination and the engagement reconcile has something to compare.
    private func candidate() -> NRSTCandidate {
        let ap = AirportData.Airport(ident: "1B9", icao: "", name: "MANSFIELD MUNI",
                                     coord: Coord(lat: 42.0001, lon: -71.1967), elevationFt: 122,
                                     ownership: "PU", use: "PU", status: "O",
                                     tower: "NON-ATCT", fuel: "100LL", siteType: "A", far139: "")
        return NRSTCandidate(airport: ap, distanceNm: 18, bearingTrueDeg: 200,
                             reachability: .clear, arrivalMarginFt: 2200, category: .vfr,
                             wxAgeMinutes: 5, longestRunwayFt: 3500, longestRunwayPaved: true,
                             longestRunwayLit: true, terrainRiseFt: 120, score: 0.7)
    }

    /// ENGAGE drops the approach — this is correct and is asserted so the fix below cannot be
    /// "achieved" by simply not clearing it, which would leave a live ARMED MISSED pointing at an
    /// approach the plan no longer holds.
    func testEngageClearsTheActiveApproach() throws {
        let m = model()
        try activateFixtureApproach(m)
        XCTAssertNotNil(m.activeApproach)

        injectFix(m, lat: 42.47, lon: -71.29)
        try XCTSkipIf(m.presentPosition == nil, "the integrity monitor rejected the synthetic fix")
        XCTAssertEqual(m.engageNRST(candidate()), .engaged)
        XCTAssertNil(m.activeApproach,
                     "the engage re-anchors at present position and drops the procedures; a stale "
                     + "activeApproach would leave the ARMED MISSED live on an unfiled approach")
    }

    /// RESTORE puts it back — route AND approach — because that is what the banner promises and what
    /// justifies engaging with no confirm alert.
    func testRestorePutsTheApproachBackWithItsHolds() throws {
        let m = model()
        try activateFixtureApproach(m)
        let before = try XCTUnwrap(m.activeApproach)
        let holdsBefore = before.activeHolds.map(\.id)

        injectFix(m, lat: 42.47, lon: -71.29)
        try XCTSkipIf(m.presentPosition == nil, "the integrity monitor rejected the synthetic fix")
        XCTAssertEqual(m.engageNRST(candidate()), .engaged)
        XCTAssertNil(m.activeApproach)

        m.restoreNRSTPlan()
        let after = try XCTUnwrap(m.activeApproach,
                                  "Restore must re-arm the approach the engage dropped — a route-only "
                                  + "undo hands the pilot back a plan whose approach is silently dead")
        XCTAssertEqual(after.airport, before.airport)
        XCTAssertEqual(after.ident, before.ident)
        XCTAssertEqual(after.activeHolds.map(\.id), holdsBefore,
                       "the published holds come back with it — they are what the map draws")
        XCTAssertNil(m.nrstEngagement, "the banner retires with the undo it offered")
    }

    /// RETARGET then restore. This is the case a first pass at the fix missed: `editPlan` is
    /// synchronous, so on a SECOND engage the `flightPlan` didSet runs inside it, reaches
    /// `reconcileNRSTEngagement`, sees the new destination differ from the live engagement's target and
    /// clears the approach snapshot along with the engagement. Re-ranking mid-emergency and tapping a
    /// better field is the ordinary way to reach it — and it silently downgraded Restore to a
    /// route-only undo again, with no ARMED MISSED at minimums.
    func testRestoreAfterRetargetingStillReArmsTheApproach() throws {
        let m = model()
        try activateFixtureApproach(m)
        let before = try XCTUnwrap(m.activeApproach)

        injectFix(m, lat: 42.47, lon: -71.29)
        try XCTSkipIf(m.presentPosition == nil, "the integrity monitor rejected the synthetic fix")
        XCTAssertEqual(m.engageNRST(candidate()), .engaged)
        // A DIFFERENT field, so the reconcile fires on the second engage.
        let second = NRSTCandidate(
            airport: AirportData.Airport(ident: "6B6", icao: "", name: "STOW",
                                         coord: Coord(lat: 42.4600, lon: -71.5150), elevationFt: 269,
                                         ownership: "PU", use: "PU", status: "O",
                                         tower: "NON-ATCT", fuel: "", siteType: "A", far139: ""),
            distanceNm: 11, bearingTrueDeg: 250, reachability: .clear, arrivalMarginFt: 1800,
            category: .vfr, wxAgeMinutes: 3, longestRunwayFt: 2000, longestRunwayPaved: true,
            longestRunwayLit: false, terrainRiseFt: 90, score: 0.6)
        XCTAssertEqual(m.engageNRST(second), .engaged)

        m.restoreNRSTPlan()
        let after = try XCTUnwrap(m.activeApproach,
                                  "retargeting must not cost the approach snapshot — the undo is what "
                                  + "justifies engaging with no confirm alert")
        XCTAssertEqual(after.ident, before.ident)
    }

    /// A pilot's SKIP decision is part of the state being restored: a course reversal they already
    /// declined must not reappear on the map when the plan comes back.
    func testRestoreKeepsTheSkippedHoldDecision() throws {
        let m = model()
        try activateFixtureApproach(m)
        let before = try XCTUnwrap(m.activeApproach)
        guard let skippable = before.holds.first(where: { $0.isSkippable }) else {
            throw XCTSkip("this cycle's fixture publishes no routinely-skipped hold")
        }
        m.setApproachHold(skippable.id, skipped: true)
        let expected = try XCTUnwrap(m.activeApproach).activeHolds.map(\.id)

        injectFix(m, lat: 42.47, lon: -71.29)
        try XCTSkipIf(m.presentPosition == nil, "the integrity monitor rejected the synthetic fix")
        XCTAssertEqual(m.engageNRST(candidate()), .engaged)
        m.restoreNRSTPlan()

        XCTAssertEqual(try XCTUnwrap(m.activeApproach).activeHolds.map(\.id), expected,
                       "a hold the pilot skipped before the emergency stays skipped after the undo")
    }

    /// "Keep" gives up the undo — including the approach. Retiring the banner and then finding the
    /// approach re-armed later would be the worst of both.
    func testKeepDiscardsTheApproachSnapshot() throws {
        let m = model()
        try activateFixtureApproach(m)
        injectFix(m, lat: 42.47, lon: -71.29)
        try XCTSkipIf(m.presentPosition == nil, "the integrity monitor rejected the synthetic fix")
        XCTAssertEqual(m.engageNRST(candidate()), .engaged)

        m.endNRST()
        XCTAssertNil(m.nrstEngagement)
        m.restoreNRSTPlan()                      // no engagement → must be a no-op
        XCTAssertNil(m.activeApproach, "Keep surrendered the undo; nothing may re-arm afterwards")
    }
}
