import XCTest
@testable import ATCTranscribe

/// TFR feed parsing: the `exportTfrList` JSON → stubs, the NOTAM-id → detail-filename mapping, and the
/// AIXM detail → `TFR` (GRC polygon vertices, a CIR circle expanded to a ring, hemisphere-signed
/// coordinates, FL → feet altitudes, and the no-geometry → nil guard). All pure, no network.
final class TFRParserTests: XCTestCase {

    // MARK: list JSON → stubs

    private let listJSON = """
    [
      {"notam_id":"6/5198","type":"SECURITY","facility":"ZDC","state":"DC",
       "description":"WASHINGTON DC SFRA"},
      {"notam_id":"1/2345","type":"HAZARDS","facility":"ZLA","state":"CA",
       "description":"WILDFIRE FIREFIGHTING"},
      {"notam_id":"","type":"VIP","description":"no id — dropped"}
    ]
    """.data(using: .utf8)!

    func testListParsesStubsAndDropsEmptyID() {
        let stubs = TFRParser.list(listJSON)
        XCTAssertEqual(stubs.count, 2, "the id-less row is dropped")
        XCTAssertEqual(stubs[0].id, "6/5198")
        XCTAssertEqual(stubs[0].type, "SECURITY")
        XCTAssertEqual(stubs[0].title, "WASHINGTON DC SFRA")
        XCTAssertEqual(stubs[1].id, "1/2345")
    }

    func testListRejectsNonArray() {
        XCTAssertTrue(TFRParser.list(#"{"notam_id":"x"}"#.data(using: .utf8)!).isEmpty)
    }

    func testDetailFileMapsSlashToUnderscore() {
        XCTAssertEqual(TFRParser.detailFile("6/5198"), "6_5198")
        XCTAssertEqual(TFRParser.detailFile("1/2345"), "1_2345")
    }

    // MARK: AIXM detail → TFR

    /// A four-vertex polygon TFR, floor 0 (SFC) / ceiling FL180, in the western hemisphere.
    private let polygonXML = """
    <TFR>
      <valDistVerUpper>180</valDistVerUpper><uomDistVerUpper>FL</uomDistVerUpper>
      <valDistVerLower>0</valDistVerLower><uomDistVerLower>FT</uomDistVerLower>
      <Avx><codeType>GRC</codeType><geoLat>39.00000000N</geoLat><geoLong>077.00000000W</geoLong></Avx>
      <Avx><codeType>GRC</codeType><geoLat>39.00000000N</geoLat><geoLong>076.00000000W</geoLong></Avx>
      <Avx><codeType>GRC</codeType><geoLat>40.00000000N</geoLat><geoLong>076.00000000W</geoLong></Avx>
      <Avx><codeType>GRC</codeType><geoLat>40.00000000N</geoLat><geoLong>077.00000000W</geoLong></Avx>
    </TFR>
    """

    func testPolygonDetailParses() {
        let stub = TFRParser.Stub(id: "1/2345", type: "HAZARDS", title: "Wildfire")
        let tfr = TFRParser.detail(polygonXML, stub: stub)
        XCTAssertNotNil(tfr)
        XCTAssertEqual(tfr?.polygon.count, 4)
        XCTAssertEqual(tfr?.type, .hazards)
        XCTAssertEqual(tfr?.floorFt, 0, "SFC floor")
        XCTAssertEqual(tfr?.ceilingFt, 18_000, "FL180 → 18000 ft")
        // western hemisphere → negative longitude, northern → positive latitude
        XCTAssertEqual(tfr?.polygon.first?.lat ?? 0, 39.0, accuracy: 1e-6)
        XCTAssertEqual(tfr?.polygon.first?.lon ?? 0, -77.0, accuracy: 1e-6)
        // northernmost vertex drives the altitude label
        XCTAssertEqual(tfr?.labelCoord?.lat ?? 0, 40.0, accuracy: 1e-6)
    }

    func testEffectiveTimesFacilityAndStateParsed() throws {
        let xml = polygonXML.replacingOccurrences(of: "</TFR>",
            with: "<dateEffective>2026-07-17T04:39:00</dateEffective><dateExpire>2026-07-30T07:00:00</dateExpire></TFR>")
        let stub = TFRParser.Stub(id: "6/6409", type: "HAZARDS", title: "Wildfire", facility: "ZOA", state: "CA")
        let tfr = try XCTUnwrap(TFRParser.detail(xml, stub: stub))
        XCTAssertEqual(tfr.facility, "ZOA")
        XCTAssertEqual(tfr.state, "CA")
        let eff = try XCTUnwrap(tfr.effective), exp = try XCTUnwrap(tfr.expires)
        XCTAssertLessThan(eff, exp)
        // A time inside the window is active; before it is not.
        XCTAssertTrue(tfr.isActive(at: eff.addingTimeInterval(3600)))
        XCTAssertFalse(tfr.isActive(at: eff.addingTimeInterval(-3600)))
        XCTAssertFalse(tfr.isActive(at: exp.addingTimeInterval(3600)))
    }

    func testDecodesOldCachedTFRWithoutNewFields() throws {
        // A pre-enrichment snapshot has no facility/state/effective/expires — must still decode.
        let json = #"{"id":"1/1","type":"security","title":"t","polygon":[{"lat":39,"lon":-77},{"lat":39,"lon":-76},{"lat":40,"lon":-76}],"floorFt":0,"ceilingFt":18000}"#
        let tfr = try JSONDecoder().decode(TFR.self, from: Data(json.utf8))
        XCTAssertEqual(tfr.id, "1/1")
        XCTAssertNil(tfr.effective); XCTAssertNil(tfr.facility)
        XCTAssertTrue(tfr.isActive(at: Date()), "no window → treated as active")
    }

    /// A circular TFR (5 NM radius) — one CIR vertex expands into a full ring.
    private let circleXML = """
    <TFR>
      <valDistVerUpper>5000</valDistVerUpper><uomDistVerUpper>FT</uomDistVerUpper>
      <valDistVerLower>0</valDistVerLower><uomDistVerLower>FT</uomDistVerLower>
      <Avx><codeType>CIR</codeType>
        <geoLat>34.00000000N</geoLat><geoLong>118.00000000W</geoLong>
        <geoLatArc>34.00000000N</geoLatArc><geoLongArc>118.00000000W</geoLongArc>
        <valRadiusArc>5.0</valRadiusArc></Avx>
    </TFR>
    """

    func testCircleDetailExpandsToRing() {
        let stub = TFRParser.Stub(id: "1/9999", type: "AIR SHOWS/SPORTS", title: "Air show")
        let tfr = TFRParser.detail(circleXML, stub: stub)
        XCTAssertNotNil(tfr)
        XCTAssertEqual(tfr?.polygon.count, 36, "36-point circle (10° steps)")
        XCTAssertEqual(tfr?.type, .airshow)
        XCTAssertEqual(tfr?.ceilingFt, 5000)
        // every ring point sits ~5 NM (≈0.083°) from the centre — sanity on the geometry
        let center = Coord(lat: 34, lon: -118)
        for p in tfr?.polygon ?? [] {
            let nm = Geo.nmBetween(center, p)
            XCTAssertEqual(nm, 5.0, accuracy: 0.3)
        }
    }

    /// A boundary that mixes GRC vertices with a CWA (clockwise) arc, structured like a real FAA
    /// space-ops TFR: the CWA <Avx> has NO top-level geoLat — only geoLatArc (centre) + valRadiusArc —
    /// plus a nested Frd whose geoLat is ALSO the centre. The old first-match parser planted a boundary
    /// vertex at that centre (a ~radius-NM interior gouge); the arc must instead be tessellated.
    private let arcXML = """
    <TFR>
      <valDistVerUpper>180</valDistVerUpper><uomDistVerUpper>FL</uomDistVerUpper>
      <valDistVerLower>0</valDistVerLower><uomDistVerLower>FT</uomDistVerLower>
      <Avx><codeType>GRC</codeType><geoLat>34.16666667N</geoLat><geoLong>118.00000000W</geoLong></Avx>
      <Avx><codeType>CWA</codeType>
        <geoLatArc>34.00000000N</geoLatArc><geoLongArc>118.00000000W</geoLongArc>
        <valRadiusArc>10.0</valRadiusArc><uomRadiusArc>NM</uomRadiusArc>
        <Frd><FrdUid><DpnUid><geoLat>34.00000000N</geoLat><geoLong>118.00000000W</geoLong></DpnUid></FrdUid>
          <txtRmk>CENTER FIX</txtRmk></Frd></Avx>
      <Avx><codeType>GRC</codeType><geoLat>34.00000000N</geoLat><geoLong>117.79880000W</geoLong></Avx>
      <Avx><codeType>GRC</codeType><geoLat>33.80000000N</geoLat><geoLong>118.00000000W</geoLong></Avx>
    </TFR>
    """

    func testCWAArcIsTessellatedNotChordedToCenter() {
        let tfr = TFRParser.detail(arcXML, stub: .init(id: "6/5192", type: "SPACE OPERATIONS", title: "Launch"))
        XCTAssertNotNil(tfr)
        let poly = tfr?.polygon ?? []
        XCTAssertGreaterThan(poly.count, 4, "the arc adds intermediate vertices beyond the 3 GRC points")
        // THE REGRESSION GUARD: no boundary vertex may sit at the arc centre (the old ~10 NM gouge).
        let center = Coord(lat: 34, lon: -118)
        for p in poly {
            XCTAssertGreaterThan(Geo.nmBetween(center, p), 1.0, "no vertex at the arc centre \(p)")
        }
        // The tessellated arc rides the 10 NM circle; its midpoint should be out near the NE diagonal.
        let neArc = poly.contains { Geo.nmBetween(center, $0) > 9 && $0.lat > 34.02 && $0.lon > -117.95 }
        XCTAssertTrue(neArc, "an arc vertex should bulge out toward the NE, not cut a chord")
    }

    func testUnlimitedAltitudeSentinel() {
        let xml = """
        <TFR><valDistVerUpper>-1</valDistVerUpper><uomDistVerUpper>FT</uomDistVerUpper>
        <Avx><codeType>GRC</codeType><geoLat>39N</geoLat><geoLong>077W</geoLong></Avx>
        <Avx><codeType>GRC</codeType><geoLat>39N</geoLat><geoLong>076W</geoLong></Avx>
        <Avx><codeType>GRC</codeType><geoLat>40N</geoLat><geoLong>076W</geoLong></Avx></TFR>
        """
        let tfr = TFRParser.detail(xml, stub: .init(id: "x", type: "SECURITY", title: "t"))
        XCTAssertEqual(tfr?.ceilingFt, 99_999, "negative sentinel → unlimited")
    }

    func testNoGeometryReturnsNil() {
        let xml = "<TFR><valDistVerUpper>100</valDistVerUpper></TFR>"
        XCTAssertNil(TFRParser.detail(xml, stub: .init(id: "x", type: "SECURITY", title: "t")),
                     "a reference-only security NOTAM with no inline boundary is skipped")
    }

    func testTypeMappingCoversKnownAndFallsBack() {
        XCTAssertEqual(TFRType(raw: "SECURITY"), .security)
        XCTAssertEqual(TFRType(raw: "SPACE OPERATIONS"), .space)
        XCTAssertEqual(TFRType(raw: "totally unknown"), .other)
        XCTAssertEqual(TFRType(raw: "vip").label, "VIP Movement")
    }
}
