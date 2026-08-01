import XCTest
@testable import ATCTranscribe

/// The K00R-vs-00R namespace split.
///
/// `nav_coords.json` and the UI key an airport by ICAO ("K0A9"); `cifp.sqlite` and `procedures.json`
/// key the same field by its bare FAA code ("0A9"). 707 charted airports exist in only one form on each
/// side, so every lookup returned nothing — silently, which is the dangerous part: an empty result is
/// indistinguishable from "this airport publishes no procedures".
final class AirportKeyTests: XCTestCase {

    func testAFourCharacterCodeOffersItsBareForm() {
        XCTAssertEqual(AirportKey.forms("K0A9").alternate, "0A9")
        XCTAssertEqual(AirportKey.forms("K00R").alternate, "00R")
    }

    func testTheUSPrefixIsNotOnlyK() {
        // Stripping only a leading K left Alaska, Hawaii, Guam and Puerto Rico resolving to nothing.
        XCTAssertEqual(AirportKey.forms("PANC").alternate, "NC")
        XCTAssertEqual(AirportKey.forms("PHNL").alternate, "NL")
        XCTAssertEqual(AirportKey.forms("TJSJ").alternate, "SJ")
    }

    func testAThreeCharacterCodeIsLeftAlone() {
        let f = AirportKey.forms("BOS")
        XCTAssertEqual(f.asGiven, f.alternate, "nothing to strip — the caller must not query twice")
    }

    func testWhitespaceAndCaseAreNormalised() {
        XCTAssertEqual(AirportKey.forms(" k0a9 ").asGiven, "K0A9")
    }

    func testTheAlternateIsOnlyUSEDWhenTheFirstFormMISSES() {
        // The safety property: this can only ever REACH rows that were previously unreachable. It must
        // never redirect an airport that already resolves.
        var asked: [String] = []
        let out = AirportKey.resolving("K0A9") { key -> [String] in
            asked.append(key)
            return key == "K0A9" ? ["hit"] : ["wrong"]
        }
        XCTAssertEqual(out, ["hit"])
        XCTAssertEqual(asked, ["K0A9"], "the alternate must not be consulted after a hit")
    }

    func testTheAlternateIsTriedWhenTheFirstFormIsEmpty() {
        var asked: [String] = []
        let out = AirportKey.resolving("K0A9") { key -> [String] in
            asked.append(key)
            return key == "0A9" ? ["found"] : []
        }
        XCTAssertEqual(out, ["found"])
        XCTAssertEqual(asked, ["K0A9", "0A9"])
    }

    func testAThreeLetterIdentIsNeverQueriedTwice() {
        var calls = 0
        _ = AirportKey.resolving("BOS") { _ -> [String] in calls += 1; return [] }
        XCTAssertEqual(calls, 1)
    }

    // MARK: - against the shipped data

    func testAPreviouslyUnreachableAirportNowResolves() throws {
        try XCTSkipUnless(CIFP.available, "cifp.sqlite not present")
        // K0A9 (Elizabethton) filled its Info tab but reported no coded runways, no charts and no
        // activatable approach, while both thresholds sat in cifp.runway.
        XCTAssertFalse(CIFP.runways(airport: "K0A9").isEmpty,
                       "K0A9's coded runways must be reachable by its ICAO ident")
        XCTAssertFalse(CIFP.procedures(airport: "K0A9").isEmpty,
                       "K0A9's coded procedures must be reachable by its ICAO ident")
    }

    func testItsPublishedPlatesAreReachableToo() throws {
        try XCTSkipIf(Procedures.airportCount == 0, "procedures.json not present")
        XCTAssertFalse(Procedures.forAirport("K0A9").isEmpty)
        XCTAssertTrue(Procedures.hasAirport("K0A9"))
    }

    func testAnOrdinaryICAOAirportIsUnaffected() throws {
        try XCTSkipUnless(CIFP.available, "cifp.sqlite not present")
        XCTAssertFalse(CIFP.procedures(airport: "KBOS").isEmpty)
        XCTAssertFalse(Procedures.forAirport("KBOS").isEmpty)
    }
}
