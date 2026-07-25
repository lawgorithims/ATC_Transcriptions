import XCTest
@testable import ATCTranscribe

/// Assertions against the SHIPPED `cifp.sqlite` itself, not against the shape of the code that reads it.
///
/// These exist because of a failure this suite could not see. A build change dropped 6,741 approach
/// legs — every one of them the FINAL APPROACH FIX, two thirds of all published US approaches — and the
/// entire unit suite stayed green, the builder printed a clean run, and the provenance badge certified
/// the result as current. Every test here would have failed loudly.
///
/// The invariants are the FAA's own, so they hold across cycles: an approach has exactly one published
/// missed-approach point, and an approach that publishes a final approach fix must still have it after
/// ingest. Data tests are cheap insurance against a build that silently loses records.
final class CIFPDataIntegrityTests: XCTestCase {

    /// Airports spread across regions, approach types and coding styles.
    private let airports = ["KBOS", "KJFK", "KDFW", "KLAX", "KSFO", "KDEN", "KORD", "KMDW",
                            "KEGE", "PADK", "KBAM", "KOVL", "PANC", "PHNL", "KTCS"]

    /// The marker the missed-approach split reads. Exactly one per approach — no marker means the split
    /// silently falls back to guessing, two means it picks the wrong one.
    func testEveryApproachPublishesExactlyOneMissedApproachPoint() {
        var checked = 0
        for apt in airports {
            for proc in CIFP.approaches(airport: apt).prefix(128) {
                guard let proper = CIFP.approachProper(airport: apt, ident: proc.ident) else { continue }
                let legs = CIFP.legs(procedureID: proper.id)
                guard !legs.isEmpty else { continue }
                let maps = legs.filter { $0.role == .missedApproachPoint }
                XCTAssertEqual(maps.count, 1, "\(apt) \(proc.ident) must publish one missed-approach point")
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 100, "the fixture airports must actually carry coded approaches")
    }

    /// THE regression. An RNAV approach's final approach fix is coded on a record that carries a
    /// continuation; a builder that mistakes "has continuations" for "is a continuation" deletes it.
    func testRnavApproachesStillCarryTheirFinalApproachFix() {
        var withFAF = 0, rnav = 0
        for apt in airports {
            for proc in CIFP.approaches(airport: apt).prefix(128)
            where proc.ident.hasPrefix("R") || proc.ident.hasPrefix("H") {
                guard let proper = CIFP.approachProper(airport: apt, ident: proc.ident) else { continue }
                let legs = CIFP.legs(procedureID: proper.id)
                guard !legs.isEmpty else { continue }
                rnav += 1
                if legs.contains(where: { $0.role == .finalApproachFix }) { withFAF += 1 }
            }
        }
        XCTAssertGreaterThan(rnav, 40, "the fixture airports must carry RNAV approaches")
        XCTAssertEqual(withFAF, rnav, "every coded RNAV approach publishes a final approach fix")
    }

    /// KBOS RNAV (RNP) RWY 33L, verbatim from the source: the FAF is SHUSH at 1,400 ft, between the
    /// intermediate fix CRLTN and the runway. It went missing entirely, altitude and all.
    func testKBOSRnav33LCarriesItsPublishedFinalApproachFix() {
        guard let proper = CIFP.approachProper(airport: "KBOS", ident: "H33LX") else {
            return XCTFail("KBOS H33LX approach-proper row is missing")
        }
        let legs = CIFP.legs(procedureID: proper.id)
        guard let faf = legs.first(where: { $0.role == .finalApproachFix }) else {
            return XCTFail("H33LX has no final approach fix — the legs are \(legs.map(\.fix))")
        }
        XCTAssertEqual(faf.fix, "SHUSH")
        XCTAssertTrue(faf.altitude.contains("1400"), "the FAF's published crossing altitude travels with it")
        XCTAssertNotNil(faf.coord, "the FAF must be drawable")

        let idents = legs.map(\.fix)
        guard let f = idents.firstIndex(of: "SHUSH"), let m = idents.firstIndex(of: "RW33L") else {
            return XCTFail("expected SHUSH and RW33L in \(idents)")
        }
        XCTAssertLessThan(f, m, "the final approach fix precedes the missed-approach point")
    }

    /// RNP AR approaches require specific operator and aircrew authorization. Labelling one "RNAV (GPS)"
    /// invites a pilot to fly an approach they are not approved for, and the plate matcher scores
    /// against exactly this string.
    func testRnpAndGpsApproachesAreNotMislabelled() {
        let names = Dictionary(CIFP.approaches(airport: "KMDW").map { ($0.ident, $0.name) },
                               uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(names["H22LX"], "RNAV (RNP) RWY 22L", "H idents are the RNP AR approaches")
        XCTAssertEqual(names["R22LZ"], "RNAV (GPS) RWY 22L", "R idents are the ordinary RNAV (GPS) ones")
        XCTAssertEqual(names["R22R"],  "RNAV (GPS) RWY 22R")
    }

    /// Real navaids whose ident happens to begin "RW". A prefix test deleted all three from the spoken
    /// fix vocabulary, and blanked KOVL VOR-A's coded missed approach, which is flown to RWF.
    func testNavaidsBeginningRWAreNotFilteredAsRunwayThresholds() {
        let fixes = Set(CIFP.fixes(airport: "KOVL"))
        XCTAssertTrue(fixes.contains("RWF"), "RWF is the Redwood Falls VOR, not a runway threshold")
        XCTAssertFalse(fixes.contains(where: { CIFP.isRunwayPseudoFix($0) }),
                       "actual runway thresholds stay out of the spoken vocabulary")
    }

    /// A named, selectable procedure with no legs is a path a pilot cannot fly. 706 SIDs once shipped
    /// this way.
    func testNoShippedProcedureHasZeroLegs() {
        for apt in airports {
            for proc in CIFP.procedures(airport: apt).prefix(512) {
                XCTAssertFalse(CIFP.legs(procedureID: proc.id).isEmpty,
                               "\(apt) \(proc.kind) \(proc.ident)/\(proc.transition) has no legs")
            }
        }
    }
}
