import XCTest
@testable import ATCTranscribe

/// `ForeFlightExport` — the offline ForeFlight hand-off serializers: route tokens for the
/// `foreflightmobile://` URL scheme, the hand-off guard, and the Garmin FPL v1 XML export.
/// Everything under test is a pure function over value types (no bundle / nav DB needed).
final class ForeFlightExportTests: XCTestCase {

    // MARK: fixtures

    /// KMSP → KORD with a filed enroute middle (no procedures).
    private func basePlan() -> FlightPlan {
        var plan = FlightPlan()
        plan.departure = "KMSP"
        plan.destination = "KORD"
        plan.route = ["GEP", "KAMMA"]
        return plan
    }

    /// A STAR loaded at the plan's ARRIVAL airport (KORD) — the normal, sendable case.
    private func star(_ fixes: [String]) -> LoadedProcedure {
        LoadedProcedure(airport: "KORD", kind: "STAR", ident: "GOPHR1", name: "GOPHER ONE",
                        runway: "", transition: "", fixes: fixes)
    }

    // MARK: route tokens

    func testTokensOrderDepEnrouteDest() {
        XCTAssertEqual(ForeFlightExport.routeTokens(for: basePlan()),
                       ["KMSP", "GEP", "KAMMA", "KORD"])
    }

    func testTokensSpliceLoadedProcedures() {
        // The motivating case: a loaded STAR lives in a procedure SLOT, not route[] — fullRoute
        // omits it, so the builder must splice the captured fixes in itself, in flight order.
        var plan = basePlan()
        plan.arrivalProcedure = star(["GOPHER", "BAINY", "KKILR"])
        plan.departureProcedure = LoadedProcedure(airport: "KMSP", kind: "SID", ident: "MSP7",
                                                  name: "MINNEAPOLIS SEVEN", runway: "", transition: "",
                                                  fixes: ["ZMBRO"])
        XCTAssertEqual(ForeFlightExport.routeTokens(for: plan),
                       ["KMSP", "ZMBRO", "GEP", "KAMMA", "GOPHER", "BAINY", "KKILR", "KORD"])
    }

    func testTokensNeverIncludeApproachFixes() {
        // A CIFP approach record carries the missed-approach segment too — serializing its fixes
        // as enroute waypoints would draw a route doubling back through the missed hold. Never sent.
        var plan = basePlan()
        plan.approachProcedure = LoadedProcedure(airport: "KORD", kind: "IAP", ident: "I27L",
                                                 name: "ILS 27L", runway: "27L", transition: "",
                                                 fixes: ["CERTL", "MISSD"])
        XCTAssertEqual(ForeFlightExport.routeTokens(for: plan),
                       ["KMSP", "GEP", "KAMMA", "KORD"])
    }

    func testTokensDropStaleProceduresAfterDirectTo() {
        // "Proceed direct BOSOX" clears the route and makes BOSOX the destination, but the old
        // arrival stays in its slot. Its airport (KORD) no longer matches the destination, so its
        // fixes must not be sent as though still cleared.
        var plan = basePlan()
        plan.arrivalProcedure = star(["GOPHER", "BAINY"])
        plan.directTo("BOSOX")
        XCTAssertEqual(ForeFlightExport.routeTokens(for: plan), ["KMSP", "BOSOX"])
    }

    func testSendablePlanDropsOrphanedSID() {
        var plan = basePlan()
        plan.departureProcedure = LoadedProcedure(airport: "KSTP", kind: "SID", ident: "X1",
                                                  name: "X ONE", runway: "", transition: "",
                                                  fixes: ["AAA"])   // loaded at a DIFFERENT airport
        let sendable = ForeFlightExport.sendablePlan(plan)
        XCTAssertNil(sendable.departureProcedure, "SID at KSTP doesn't belong to a KMSP departure")
        XCTAssertEqual(ForeFlightExport.routeTokens(for: plan), ["KMSP", "GEP", "KAMMA", "KORD"])
    }

    func testTokensCollapseConsecutiveDuplicates() {
        // A STAR's entry fix often repeats the last enroute fix — send it once.
        var plan = basePlan()
        plan.route = ["GEP", "GOPHER"]
        plan.arrivalProcedure = star(["GOPHER", "BAINY"])
        XCTAssertEqual(ForeFlightExport.routeTokens(for: plan),
                       ["KMSP", "GEP", "GOPHER", "BAINY", "KORD"])
    }

    func testTokensDropFillerAndBlanks() {
        var plan = basePlan()
        plan.route = ["DCT", "GEP", "", "direct", "KAMMA"]
        XCTAssertEqual(ForeFlightExport.routeTokens(for: plan),
                       ["KMSP", "GEP", "KAMMA", "KORD"])
    }

    func testTokensConvertUserWaypoint() {
        // A dropped map waypoint is stored as "lat,lon"; ForeFlight's route grammar wants "lat/lon".
        var plan = basePlan()
        plan.route = ["44.500,-93.250"]
        XCTAssertEqual(ForeFlightExport.routeTokens(for: plan),
                       ["KMSP", "44.500/-93.250", "KORD"])
    }

    func testTokensEmptyPlan() {
        XCTAssertTrue(ForeFlightExport.routeTokens(for: FlightPlan()).isEmpty)
    }

    func testTokensDirectToShape() {
        // After "proceed direct BOSOX" the plan is departure → BOSOX (directTo clears the middle
        // and makes the fix the destination) — the tokens mirror that exactly.
        var plan = basePlan()
        plan.directTo("BOSOX")
        XCTAssertEqual(ForeFlightExport.routeTokens(for: plan), ["KMSP", "BOSOX"])
    }

    func testTokensRespectBound() {
        // Every section clips independently (route → 256, each procedure's fixes → 128), and the
        // total stays under maxTokens even with every section oversized simultaneously.
        var plan = basePlan()
        plan.route = (0..<700).map { "EFIX\($0)" }
        plan.departureProcedure = LoadedProcedure(airport: "KMSP", kind: "SID", ident: "S1",
                                                  name: "S", runway: "", transition: "",
                                                  fixes: (0..<200).map { "SFIX\($0)" })
        plan.arrivalProcedure = LoadedProcedure(airport: "KORD", kind: "STAR", ident: "A1",
                                                name: "A", runway: "", transition: "",
                                                fixes: (0..<200).map { "AFIX\($0)" })
        let tokens = ForeFlightExport.routeTokens(for: plan)
        XCTAssertLessThanOrEqual(tokens.count, ForeFlightExport.maxTokens)
        XCTAssertEqual(tokens.count, 2 + 128 + 256 + 128, "dep + SID(128) + enroute(256) + STAR(128) + dest")
        XCTAssertEqual(tokens.filter { $0.hasPrefix("EFIX") }.count, 256, "enroute clipped to 256")
        XCTAssertEqual(tokens.filter { $0.hasPrefix("SFIX") }.count, 128, "SID fixes clipped to 128")
        XCTAssertEqual(tokens.last, "KORD", "destination survives when the total fits the cap")
    }

    // MARK: URL

    func testURLShape() {
        let url = ForeFlightExport.url(for: basePlan())
        XCTAssertEqual(url?.absoluteString, "foreflightmobile://maps/search?q=KMSP+GEP+KAMMA+KORD")
    }

    func testURLNilWhenNothingToSend() {
        XCTAssertNil(ForeFlightExport.url(for: FlightPlan()), "empty plan → no URL")
        var single = FlightPlan()
        single.destination = "KORD"
        XCTAssertNil(ForeFlightExport.url(for: single), "a single point is not a route")
    }

    func testURLKeepsUserWaypointCharacters() {
        var plan = basePlan()
        plan.route = ["44.500,-93.250"]
        let url = ForeFlightExport.url(for: plan)
        XCTAssertEqual(url?.absoluteString,
                       "foreflightmobile://maps/search?q=KMSP+44.500/-93.250+KORD")
    }

    func testURLPercentEncodesHostileTokens() {
        // The plan's fields are free-form text; reserved URL characters must not smuggle extra
        // query parameters or break the URL. (Real idents are [A-Z0-9], but inputs are validated,
        // not trusted.)
        var plan = basePlan()
        plan.route = ["A&Q=1", "B C?", "%00"]
        guard let url = ForeFlightExport.url(for: plan) else { return XCTFail("URL must build") }
        let s = url.absoluteString
        XCTAssertTrue(s.contains("A%26Q%3D1"), "& and = must be escaped: \(s)")
        XCTAssertTrue(s.contains("B%20C%3F"), "space and ? must be escaped: \(s)")
        XCTAssertTrue(s.contains("%2500"), "a literal % must be escaped, not passed through: \(s)")
        XCTAssertEqual(s.components(separatedBy: "?").count - 1, 1, "exactly one query delimiter")
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.count, 1,
                       "hostile tokens must not create extra query items")
    }

    // MARK: hand-off guard

    func testShouldHandoffOnRealAmendment() {
        let before = basePlan()
        var after = before
        after.directTo("BOSOX")
        XCTAssertTrue(ForeFlightExport.shouldHandoff(before: before, after: after))
    }

    func testShouldHandoffFalseWhenAcceptWasANoOp() {
        // Accepting a STAR clearance with no CIFP match leaves the plan untouched — don't switch
        // the pilot into ForeFlight with an unamended route.
        let plan = basePlan()
        XCTAssertFalse(ForeFlightExport.shouldHandoff(before: plan, after: plan))
    }

    func testShouldHandoffFalseWhenNothingSendable() {
        XCTAssertFalse(ForeFlightExport.shouldHandoff(before: basePlan(), after: nil))
        XCTAssertFalse(ForeFlightExport.shouldHandoff(before: nil, after: FlightPlan()))
    }

    func testShouldHandoffTrueFromNoPlan() {
        XCTAssertTrue(ForeFlightExport.shouldHandoff(before: nil, after: basePlan()))
    }

    // MARK: Garmin FPL

    private let legs = [
        ResolvedLeg(ident: "KMSP", kind: .airport, coord: Coord(lat: 44.881944, lon: -93.221667)),
        ResolvedLeg(ident: "GEP", kind: .vor, coord: Coord(lat: 45.145833, lon: -93.373611)),
        ResolvedLeg(ident: "KAMMA", kind: .waypoint, coord: Coord(lat: 44.5, lon: -92.9)),
        ResolvedLeg(ident: "KORD", kind: .airport, coord: Coord(lat: 41.978611, lon: -87.904722)),
    ]

    func testFPLStructure() {
        let xml = ForeFlightExport.fplXML(for: legs, routeName: "KMSP KORD")
        XCTAssertTrue(xml.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>"))
        XCTAssertTrue(xml.contains("<flight-plan xmlns=\"http://www8.garmin.com/xmlschemas/FlightPlan/v1\">"))
        XCTAssertTrue(xml.contains("<route-name>KMSP KORD</route-name>"))
        XCTAssertTrue(xml.contains("<identifier>KMSP</identifier>"))
        XCTAssertTrue(xml.contains("<type>AIRPORT</type>"))
        XCTAssertTrue(xml.contains("<type>VOR</type>"))
        XCTAssertTrue(xml.contains("<type>INT</type>"))
        XCTAssertTrue(xml.contains("<lat>44.881944</lat>"))
        XCTAssertTrue(xml.contains("<lon>-87.904722</lon>"))
        XCTAssertEqual(xml.components(separatedBy: "<route-point>").count - 1, 4,
                       "every leg becomes a route point")
        XCTAssertTrue(xml.hasSuffix("</flight-plan>\n"))
    }

    func testFPLDedupesWaypointTableButKeepsRouteOrder() {
        // An out-and-back touches KMSP twice: once in the table, twice in the route.
        let outAndBack = legs + [ResolvedLeg(ident: "KMSP", kind: .airport,
                                             coord: Coord(lat: 44.881944, lon: -93.221667))]
        let xml = ForeFlightExport.fplXML(for: outAndBack, routeName: "loop")
        XCTAssertEqual(xml.components(separatedBy: "<identifier>KMSP</identifier>").count - 1, 1)
        XCTAssertEqual(xml.components(separatedBy: "<waypoint-identifier>KMSP</waypoint-identifier>").count - 1, 2)
    }

    func testFPLNamesUserWaypoints() {
        // FPL requires an identifier per waypoint; a "lat,lon" map point gets a synthesized WPnn,
        // consistently between the table and the route.
        let user = [
            ResolvedLeg(ident: "KMSP", kind: .airport, coord: Coord(lat: 44.88, lon: -93.22)),
            ResolvedLeg(ident: "44.500,-93.250", kind: .waypoint, coord: Coord(lat: 44.5, lon: -93.25)),
        ]
        let xml = ForeFlightExport.fplXML(for: user, routeName: "user")
        XCTAssertTrue(xml.contains("<identifier>WP01</identifier>"))
        XCTAssertTrue(xml.contains("<type>USER WAYPOINT</type>"))
        XCTAssertTrue(xml.contains("<waypoint-identifier>WP01</waypoint-identifier>"))
        XCTAssertFalse(xml.contains("44.500,-93.250"), "the raw comma token must not leak into FPL")
    }

    func testFPLEmptyLegs() {
        XCTAssertEqual(ForeFlightExport.fplXML(for: [], routeName: "x"), "")
    }

    func testFPLRoutePointTypeMatchesDedupedTable() {
        // The same ident can arrive with two classifications: GEP filed enroute resolves as a VOR,
        // but a procedure leg through GEP is classified .waypoint (INT). The table keeps only the
        // first (VOR); every route-point must reference the TABLE's type or the FPL is
        // self-inconsistent (a (GEP, INT) route-point with no matching waypoint entry).
        let mixed = [
            ResolvedLeg(ident: "GEP", kind: .vor, coord: Coord(lat: 45.145833, lon: -93.373611)),
            ResolvedLeg(ident: "KAMMA", kind: .waypoint, coord: Coord(lat: 44.5, lon: -92.9)),
            ResolvedLeg(ident: "GEP", kind: .waypoint, coord: Coord(lat: 45.145833, lon: -93.373611)),
        ]
        let xml = ForeFlightExport.fplXML(for: mixed, routeName: "mixed")
        XCTAssertEqual(xml.components(separatedBy: "<identifier>GEP</identifier>").count - 1, 1,
                       "table deduped by identifier")
        XCTAssertEqual(xml.components(separatedBy: "<waypoint-identifier>GEP</waypoint-identifier>").count - 1, 2,
                       "both route occurrences kept")
        XCTAssertFalse(xml.contains("<waypoint-identifier>GEP</waypoint-identifier>\n      <waypoint-type>INT</waypoint-type>"),
                       "no route-point may carry a type absent from the table")
        XCTAssertEqual(xml.components(separatedBy: "<waypoint-type>VOR</waypoint-type>").count - 1, 2,
                       "both GEP route-points use the table's VOR type")
    }

    func testFPLEscapesRouteName() {
        let xml = ForeFlightExport.fplXML(for: legs, routeName: "A<B&C>")
        XCTAssertTrue(xml.contains("<route-name>A&lt;B&amp;C&gt;</route-name>"))
    }

    func testXMLEscape() {
        XCTAssertEqual(ForeFlightExport.xmlEscape("A&B<C>\"D'"), "A&amp;B&lt;C&gt;&quot;D&apos;")
        XCTAssertEqual(ForeFlightExport.xmlEscape("KMSP"), "KMSP")
    }
}
