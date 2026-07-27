import XCTest
@testable import ATCTranscribe

/// Red-hat safety-audit regressions in the parse + route-assembly paths, asserted against callable
/// production APIs (and the shipped nav databases), not against literals.
final class ParseApproachGroundingTests: XCTestCase {

    /// A misheard runway digit ("one six" → "three six") must not stage a clearance to a runway the
    /// active field has no approach to. parseApproach used to shape-check 1..36 only.
    func testApproachRunwayIsGroundedAgainstTheField() {
        let toks = "cleared ils runway 3 6".split(separator: " ").map(String.init)
        XCTAssertNil(ATCCommandParser.parseApproach(toks, runways: ["16"]),
                     "runway 36 has no approach here — abstain rather than stage the reciprocal")
        let cmd = ATCCommandParser.parseApproach(toks, runways: ["36"])
        XCTAssertEqual(cmd?.kind, .clearedApproach)
        XCTAssertEqual(cmd?.target, "36")
    }

    /// An omitted side must not reject a valid clearance: grounding is on the runway NUMBER.
    func testAnOmittedRunwaySideStillMatches() {
        let toks = "cleared for the ils runway 1 6".split(separator: " ").map(String.init)
        XCTAssertNotNil(ATCCommandParser.parseApproach(toks, runways: ["16"]),
                        "the field publishes 16L/16R; 'runway 16' must still ground")
    }

    /// An uncoded field (no grounding data) keeps the shape-check so approach clearances still work.
    func testNoGroundingDataFallsBackToShapeCheck() {
        let toks = "cleared rnav runway 0 4".split(separator: " ").map(String.init)
        XCTAssertNotNil(ATCCommandParser.parseApproach(toks, runways: []))
    }
}

/// The STAR assembler draws the full flown arrival, not a 2-leg stub. Asserted against the SHIPPED
/// cifp.sqlite, so it is a claim about real data.
final class STARAssemblyTests: XCTestCase {

    private func star(_ apt: String, _ ident: String, via: String, to runway: String?) -> [String] {
        let proc = LoadedProcedure(airport: apt, kind: "STAR", ident: ident, name: ident,
                                   runway: runway ?? "", transition: via, fixes: [])
        return ProcedureRoute.starLegs(proc, connectingFix: via, landingRunway: runway)
            .map { $0.fix }.filter { !$0.isEmpty }
    }

    func testKBOSStarAssemblesEnrouteCommonAndRunway() {
        let legs = star("KBOS", "JFUND2", via: "PONCT", to: "33L")
        XCTAssertGreaterThan(legs.count, 7, "a 2-leg stub would mean the assembly failed")
        XCTAssertEqual(legs.first, "PONCT", "starts at the enroute transition that joins the route")
        XCTAssertTrue(legs.contains("JFUND"), "runs through the common junction")
        XCTAssertTrue(legs.contains("SCITU"), "ends on the RWY33L transition")
    }

    /// A connecting fix that matches no enroute transition falls back to the single loaded row rather
    /// than drawing a guessed connected path.
    func testUnmatchedConnectingFixFallsBackSafely() {
        let proc = LoadedProcedure(airport: "KBOS", kind: "STAR", ident: "JFUND2", name: "JFUND2",
                                   runway: "", transition: "PONCT", fixes: [])
        let fallback = ProcedureRoute.starLegs(proc, connectingFix: "ZZZZZ", landingRunway: nil).map { $0.fix }
        let single = CIFP.legs(airport: "KBOS", ident: "JFUND2", transition: "PONCT").map { $0.fix }
        XCTAssertEqual(fallback, single, "an unmatched connecting fix must not invent a path")
    }
}
