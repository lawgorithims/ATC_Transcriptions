import XCTest
@testable import ATCTranscribe

/// The one ordering policy for a tap result. These call the PRODUCTION merge — the previous tests for
/// this behaviour re-declared the class set and the opacity numbers inside the test body and asserted
/// against their own literals, so they passed while the ordering and de-dupe regressions shipped.
final class MapProbeMergeTests: XCTestCase {

    private func airspace(_ name: String, _ cls: String, floor: Int? = 0, ceil: Int? = 10000) -> IdentifiedObject {
        IdentifiedObject(kind: .airspace, ident: name, coord: Coord(lat: 33, lon: -107), onRoute: false,
                         airspace: Airspace(id: abs(name.hashValue) &+ (floor ?? 0), cls: cls, name: name,
                                            floorFt: floor, ceilingFt: ceil,
                                            bb: BBox(minLat: 32, minLon: -108, maxLat: 34, maxLon: -106),
                                            rings: []))
    }
    private func fix(_ ident: String) -> IdentifiedObject {
        IdentifiedObject(kind: .fix, ident: ident, coord: Coord(lat: 33, lon: -107), onRoute: false)
    }

    /// The regression build 93 shipped: it inserted standing airspace at index 0 AFTER appending live
    /// TFRs, so a live NOTAM — the only object carrying a reason and an expiry — sank below permanent
    /// chart furniture AND below every nearby VOR. MapObjectKind.priority already said the opposite.
    func testALiveTfrOutranksAStandingRestriction() {
        let tfr = IdentifiedObject(kind: .tfr, ident: "VIP-1", coord: Coord(lat: 33, lon: -107), onRoute: false)
        let out = MapProbe.merge(ranked: [fix("DUCAS")], liveTFRs: [tfr],
                                 airspaces: [airspace("BEALE AFB NATIONAL DEFENSE AIRSPACE TFR", "TFR")])
        XCTAssertEqual(out.first?.kind, .tfr, "a live NOTAM must open first")
        XCTAssertEqual(out.map(\.kind), [.tfr, .airspace, .fix])
    }

    /// …and what build 93 got right must stay right: a restriction outranks a nearby waypoint.
    func testAStandingRestrictionOutranksNearbyFixes() {
        let out = MapProbe.merge(ranked: [fix("DUCAS"), fix("LAYEN")], liveTFRs: [],
                                 airspaces: [airspace("R-5111C", "R")])
        XCTAssertEqual(out.first?.ident, "R-5111C")
    }

    /// Ambient airspace must NOT be promoted — burying the airport you tapped under the Class B you are
    /// standing in is the same mistake in reverse.
    func testAmbientAirspaceStaysBelowWhatYouTapped() {
        let out = MapProbe.merge(ranked: [fix("KDFW")], liveTFRs: [],
                                 airspaces: [airspace("DALLAS-FORT WORTH CLASS B", "B")])
        XCTAssertEqual(out.map(\.ident), ["KDFW", "DALLAS-FORT WORTH CLASS B"])
    }

    /// White Sands publishes R-5111C as separate SHELVES. Both must survive — collapsing them by name
    /// silently dropped the 45,000-to-unlimited one — but a genuinely duplicated record must collapse.
    func testTwoShelvesOfOneAreaSurviveButAnExactDuplicateCollapses() {
        let kept = MapProbe.merge(ranked: [], liveTFRs: [],
                                  airspaces: [airspace("R-5111C", "R", floor: 13000, ceil: 24000),
                                              airspace("R-5111C", "R", floor: 45000, ceil: 99999)])
        XCTAssertEqual(kept.count, 2, "different altitude bands are different restrictions")
        XCTAssertEqual(Set(kept.map(\.id)).count, 2, "and they must not share a ForEach id")

        let name = "GRAND FORKS NATIONAL DEFENSE AIRSPACE TFR"
        let collapsed = MapProbe.merge(ranked: [], liveTFRs: [],
                                       airspaces: [airspace(name, "TFR", floor: 0, ceil: 99999),
                                                   airspace(name, "TFR", floor: 0, ceil: 99999)])
        XCTAssertEqual(collapsed.count, 1, "the same area listed twice is clutter, not information")
    }

    /// Every id in a result must be unique — SwiftUI leaves duplicate ForEach ids undefined, and this
    /// list is how a pilot chooses which restriction to read.
    func testEveryResultCarriesAUniqueIdentity() {
        let out = MapProbe.merge(
            ranked: [fix("DUCAS")], liveTFRs: [],
            airspaces: [airspace("R-5111C", "R", floor: 13000, ceil: 24000),
                        airspace("R-5111C", "R", floor: 45000, ceil: 99999),
                        airspace("DALLAS CLASS B", "B")])
        XCTAssertEqual(Set(out.map(\.id)).count, out.count)
    }

    /// The promotion set is read from production, not re-declared here.
    func testProhibitiveClassesComeFromProduction() {
        XCTAssertTrue(MapProbe.isProhibitive("TFR"))
        XCTAssertTrue(MapProbe.isProhibitive("p"), "class matching must be case-insensitive")
        XCTAssertTrue(MapProbe.isProhibitive("R"))
        for c in ["B", "C", "D", "MOA", "W", "A"] { XCTAssertFalse(MapProbe.isProhibitive(c)) }
    }
}
