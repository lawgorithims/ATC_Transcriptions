import XCTest
@testable import ATCTranscribe

/// The two bundled nav tables must be ONE snapshot. Asserted against the SHIPPED resources, in the
/// spirit of `CIFPDataIntegrityTests` — a builder check only runs when someone runs the builder, and
/// none of a hand edit, a partial commit, a cherry-pick or a merge does.
///
/// WHY IT MATTERS. `MagneticVariation` trusts a station's published variation only when its ident is
/// globally unique in `nav_coords.json` (`NavDatabase.candidates(ident).count == 1`), then reads the
/// value from `navaid_meta.json`. That gate was added after ~445 CONUS stations were found carrying a
/// FOREIGN twin's variation — near Boston 8 of the 11 nearest stations read −2° where the truth is
/// −15°. The gate is sound only while the two files describe the same set of stations: regenerate one
/// without the other and an ident that looks unique here can carry a different station's variation
/// from there, silently, which is the exact defect the gate exists to stop. A wrong variation rotates
/// the comparison between a MAGNETIC published hold course and a TRUE great-circle track, and can name
/// the wrong holding entry.
///
/// Enforced by `Tools/navdb.py check_nav_pairing` at build time; this is the shipped-data backstop.
final class NavDataPairingTests: XCTestCase {

    /// The invariant: every navaid the app can plot has metadata, and no metadata describes a navaid
    /// the app cannot plot. Measured at the current snapshot: 6,022 = 6,022, both differences empty.
    func testNavaidIdentSetsAreIdentical() throws {
        let plotted = NavDatabase.idents(ofKind: 1)
        let described = NavMeta.navaidIdents
        try XCTSkipIf(plotted.isEmpty && described.isEmpty, "bundled nav tables unavailable here")

        let onlyPlotted = plotted.subtracting(described)
        let onlyDescribed = described.subtracting(plotted)
        XCTAssertTrue(onlyPlotted.isEmpty,
                      "\(onlyPlotted.count) navaid(s) in nav_coords.json have no navaid_meta.json entry "
                      + "— the tables are not from one snapshot: \(sample(onlyPlotted))")
        XCTAssertTrue(onlyDescribed.isEmpty,
                      "\(onlyDescribed.count) navaid_meta.json entr(ies) are not in nav_coords.json "
                      + "— the tables are not from one snapshot: \(sample(onlyDescribed))")
        XCTAssertEqual(plotted.count, described.count)
        XCTAssertGreaterThan(plotted.count, 5_000, "the navaid table looks truncated")
    }

    /// Every station the variation lookup is willing to TRUST must actually resolve through the same
    /// path the lookup uses. This walks the real trust gate rather than the raw tables, so a table
    /// that pairs by ident but fails to decode would still be caught.
    func testEveryTrustedStationResolvesThroughTheRealLookupPath() throws {
        let plotted = NavDatabase.idents(ofKind: 1)
        try XCTSkipIf(plotted.isEmpty, "bundled nav tables unavailable here")
        var trusted = 0, unresolvable: [String] = []
        for ident in plotted {
            guard NavDatabase.candidates(ident).count == 1 else { continue }   // the app's trust gate
            trusted += 1
            if NavMeta.navaid(ident) == nil { unresolvable.append(ident) }
        }
        XCTAssertTrue(unresolvable.isEmpty,
                      "\(unresolvable.count) uniquely-identified station(s) have no metadata to read a "
                      + "variation from: \(sample(Set(unresolvable)))")
        XCTAssertGreaterThan(trusted, 1_000, "too few uniquely-identified stations to serve CONUS")
    }

    /// Coverage floor: the variation lookup needs `minStations` agreeing values within range, so a
    /// table that paired but lost most of its `mv` values would silently turn every holding entry into
    /// "unavailable" while every other assertion here still passed.
    func testEnoughStationsPublishAMagneticVariation() throws {
        let withMV = NavMeta.identsWithMagVar
        try XCTSkipIf(NavMeta.navaidIdents.isEmpty, "bundled nav tables unavailable here")
        XCTAssertGreaterThan(withMV.count, 3_000,
                             "only \(withMV.count) navaids carry a magnetic variation — the lookup "
                             + "needs \(MagneticVariation.minStations) in range to answer at all")
        // And they must be navaids we actually plot, or they can never be reached.
        XCTAssertTrue(withMV.subtracting(NavDatabase.idents(ofKind: 1)).isEmpty)
    }

    /// The airport half of the same pairing, pinned to the drift that ACTUALLY exists rather than to
    /// the invariant we want.
    ///
    /// The shipped tables are not quite one snapshot on the airport side: `airport_meta.json` was
    /// built from a NEWER OurAirports pull than `nav_coords.json`, leaving 11 idents plotted with no
    /// metadata (8 fields since marked `closed`, 3 demoted from `large_airport`). Both builders now
    /// refuse to write that state, so the next paired rebuild clears it — until then a hard equality
    /// assertion would be permanently red, which trains people to ignore red. So this pins the exact
    /// residue instead: the safety direction is asserted absolutely, and ANY change to the known drift
    /// fails and forces a look. A missing `airport_meta` entry is not a variation hazard — it hides
    /// the field from the Airports tab, favorites and recents.
    func testAirportIdentDriftIsExactlyTheKnownResidue() throws {
        let plotted = NavDatabase.idents(ofKind: 0)
        let described = NavMeta.airportIdents
        try XCTSkipIf(plotted.isEmpty && described.isEmpty, "bundled nav tables unavailable here")

        XCTAssertTrue(described.subtracting(plotted).isEmpty,
                      "airport_meta.json describes airports nav_coords.json cannot plot — the metadata "
                      + "table is NEWER than the coordinate table: \(sample(described.subtracting(plotted)))")
        let known: Set<String> = ["19WI", "2WI9", "5WN8", "69MO", "78TE", "7TA0", "8KS9",
                                  "EFMA", "SAWC", "SD97", "VCRI"]
        let actual = plotted.subtracting(described)
        XCTAssertEqual(actual, known,
                       "the airport ident drift changed. If a paired rebuild cleared it, this set is "
                       + "now empty and the expectation should be too; if it GREW, the tables drifted "
                       + "further apart — run `python3 ios/Tools/navdb.py verify-pairing`.")
    }

    /// A real CONUS airport still gets a variation of the right sign through the whole stack. Cheap
    /// end-to-end proof that the pairing is not just set-equal but usable.
    func testVariationStillResolvesOverCONUS() throws {
        MagneticVariation.resetForTests()
        try XCTSkipIf(NavDatabase.count == 0, "bundled nav tables unavailable here")
        let boston = try XCTUnwrap(MagneticVariation.at(Coord(lat: 42.36, lon: -71.01)))
        XCTAssertLessThan(boston, 0, "Boston is WEST variation")
        XCTAssertEqual(boston, -14.5, accuracy: 4.0)
    }

    private func sample(_ s: Set<String>) -> String {
        s.sorted().prefix(20).joined(separator: ", ")
    }
}
