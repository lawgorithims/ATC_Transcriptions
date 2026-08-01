import XCTest
@testable import ATCTranscribe

/// Assembling a departure or arrival from its several ARINC rows.
///
/// A SID and a STAR are each coded as multiple `procedure` rows — a runway transition, an optional
/// common route, and enroute transitions — and loading one row draws a fragment. Arrivals were fixed
/// for this once; departures were left on the `default:` branch and drew a median of 20% of their legs,
/// with 82.5% of every coded SID leg in the cycle never reaching the map.
final class ProcedureAssemblyTests: XCTestCase {

    // MARK: - segment classification (the column that was never read)

    private func proc(_ kind: String, _ rt: String, transition: String = "") -> CIFPProcedure {
        CIFPProcedure(id: 1, airport: "KTST", kind: kind, ident: "TEST1", name: "TEST ONE",
                      runway: "", transition: transition, routeType: rt)
    }

    func testCommonSegmentIsReadFromRouteTypeNotTheTransitionName() {
        // THE bug: 1,469 STAR and 990 SID common rows are named "ALL" rather than left blank, so an
        // `isEmpty` test on the transition dropped them entirely.
        for rt in ["2", "5"] {
            XCTAssertTrue(proc("STAR", rt, transition: "ALL").isCommonSegment,
                          "a common row named ALL must still be recognised")
            XCTAssertTrue(proc("SID", rt, transition: "ALL").isCommonSegment)
        }
    }

    func testSIDAndSTARSegmentRolesAreMirrored() {
        // You exit via a SID transition and enter via a STAR transition, so the same route-type digits
        // mean opposite ends. Reading one convention for both finds nothing.
        XCTAssertTrue(proc("SID", "4").isRunwayTransition)
        XCTAssertTrue(proc("SID", "6").isEnrouteTransition)
        XCTAssertTrue(proc("STAR", "4").isEnrouteTransition)
        XCTAssertTrue(proc("STAR", "6").isRunwayTransition)
        XCTAssertFalse(proc("SID", "4").isEnrouteTransition)
        XCTAssertFalse(proc("STAR", "4").isRunwayTransition)
    }

    func testNoSegmentIsBothEndsAtOnce() {
        for kind in ["SID", "STAR"] {
            for rt in ["1", "2", "3", "4", "5", "6", "T", "V", "F", ""] {
                let p = proc(kind, rt)
                XCTAssertFalse(p.isRunwayTransition && p.isEnrouteTransition, "\(kind)/\(rt) is both ends")
                XCTAssertFalse(p.isCommonSegment && p.isRunwayTransition, "\(kind)/\(rt) is common and runway")
                XCTAssertFalse(p.isCommonSegment && p.isEnrouteTransition, "\(kind)/\(rt) is common and enroute")
            }
        }
    }

    func testAnUnknownRouteTypeClaimsNoSegment() {
        // A future cycle introducing a new code must fall through to "single row", not be misfiled.
        let p = proc("SID", "Z")
        XCTAssertFalse(p.isCommonSegment || p.isRunwayTransition || p.isEnrouteTransition)
    }

    // MARK: - against the shipped cycle

    func testADepartureNowAssemblesMoreThanOneRow() throws {
        try XCTSkipUnless(CIFP.available, "cifp.sqlite not present")
        // KDEN BAYLR6 publishes 11 rows / 36 legs; the single-row path drew 5.
        let rows = CIFP.procedures(airport: "KDEN").filter { $0.kind == "SID" && $0.ident == "BAYLR6" }
        try XCTSkipIf(rows.isEmpty, "BAYLR6 not in this cycle")
        XCTAssertGreaterThan(rows.count, 1, "the fixture is only meaningful on a multi-row SID")
        let exits = rows.filter { $0.isEnrouteTransition }
        XCTAssertFalse(exits.isEmpty, "BAYLR6 publishes enroute transitions")
        let loaded = LoadedProcedure(airport: "KDEN", kind: "SID", ident: "BAYLR6",
                                     name: "BAYLR SIX", runway: "", transition: "", fixes: [])
        // Join at the exit's own LAST fix — the SID naming convention.
        let want = CIFP.legs(procedureID: exits[0].id).last?.fix ?? ""
        let assembled = ProcedureRoute.sidLegs(loaded, connectingFix: want, departureRunway: nil)
        let single = CIFP.legs(airport: "KDEN", ident: "BAYLR6", transition: "")
        XCTAssertGreaterThan(assembled.count, single.count,
                             "assembly must draw more of the departure than one row")
    }

    func testAnUnmatchableConnectingFixFallsBackRatherThanGuessing() throws {
        try XCTSkipUnless(CIFP.available, "cifp.sqlite not present")
        let loaded = LoadedProcedure(airport: "KDEN", kind: "SID", ident: "BAYLR6",
                                     name: "BAYLR SIX", runway: "", transition: "", fixes: [])
        let assembled = ProcedureRoute.sidLegs(loaded, connectingFix: "ZZZZZ", departureRunway: nil)
        // The common route is still certain and may be appended; what must NOT happen is an arbitrary
        // enroute transition being spliced on because none matched.
        let exitFixes = Set(CIFP.procedures(airport: "KDEN")
            .filter { $0.kind == "SID" && $0.ident == "BAYLR6" && $0.isEnrouteTransition }
            .compactMap { CIFP.legs(procedureID: $0.id).last?.fix })
        for leg in assembled where exitFixes.contains(leg.fix) {
            XCTFail("an enroute transition was spliced on with no matching connecting fix: \(leg.fix)")
        }
    }
}
