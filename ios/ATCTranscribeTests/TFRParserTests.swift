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

    func testCodableRoundTripPreservesNewFields() throws {
        // The disk cache (TFRService) encodes + decodes TFR — the custom Decodable must not break Encodable.
        let orig = TFR(id: "6/6409", type: .hazards, title: "Wildfire",
                       polygon: [Coord(lat: 39, lon: -77), Coord(lat: 39, lon: -76), Coord(lat: 40, lon: -76)],
                       floorFt: 0, ceilingFt: 18000, facility: "ZOA", state: "CA",
                       effective: Date(timeIntervalSince1970: 1_784_246_400),
                       expires: Date(timeIntervalSince1970: 1_785_000_000))
        let data = try JSONEncoder().encode(orig)
        let back = try JSONDecoder().decode(TFR.self, from: data)
        XCTAssertEqual(back, orig, "round-trip must preserve facility/state/effective/expires")
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

    // MARK: multi-area NOTAMs (the DC SFRA "pizza slice" regression)

    /// Two `<TFRAreaGroup>` blocks with different altitude bands — the FDC 4/9383 shape (Area A + B).
    /// The old parser concatenated every <Avx> in the document into ONE ring, drawing a wedge that
    /// bridged the areas.
    private let twoAreaXML = """
    <TFR>
      <dateEffective>2026-07-17T04:39:00</dateEffective>
      <TFRAreaGroup>
        <aseTFRArea>
          <valDistVerUpper>17999</valDistVerUpper><uomDistVerUpper>FT</uomDistVerUpper>
          <valDistVerLower>0</valDistVerLower><uomDistVerLower>FT</uomDistVerLower>
        </aseTFRArea>
        <Abd>
          <Avx><codeType>GRC</codeType><geoLat>39.00000000N</geoLat><geoLong>077.00000000W</geoLong></Avx>
          <Avx><codeType>GRC</codeType><geoLat>39.00000000N</geoLat><geoLong>076.00000000W</geoLong></Avx>
          <Avx><codeType>GRC</codeType><geoLat>40.00000000N</geoLat><geoLong>076.00000000W</geoLong></Avx>
          <Avx><codeType>GRC</codeType><geoLat>40.00000000N</geoLat><geoLong>077.00000000W</geoLong></Avx>
        </Abd>
      </TFRAreaGroup>
      <TFRAreaGroup>
        <aseTFRArea>
          <valDistVerUpper>50</valDistVerUpper><uomDistVerUpper>FL</uomDistVerUpper>
          <valDistVerLower>2000</valDistVerLower><uomDistVerLower>FT</uomDistVerLower>
        </aseTFRArea>
        <Abd>
          <Avx><codeType>GRC</codeType><geoLat>30.00000000N</geoLat><geoLong>080.00000000W</geoLong></Avx>
          <Avx><codeType>GRC</codeType><geoLat>30.00000000N</geoLat><geoLong>079.00000000W</geoLong></Avx>
          <Avx><codeType>GRC</codeType><geoLat>31.00000000N</geoLat><geoLong>079.50000000W</geoLong></Avx>
        </Abd>
      </TFRAreaGroup>
    </TFR>
    """

    func testMultiAreaGroupsParseAsSeparateAreas() throws {
        let tfr = try XCTUnwrap(TFRParser.detail(twoAreaXML, stub: .init(id: "4/9383", type: "SECURITY", title: "DC")))
        XCTAssertEqual(tfr.areas.count, 2, "one area per TFRAreaGroup — never concatenated")
        XCTAssertEqual(tfr.areas[0].ring.count, 4)
        XCTAssertEqual(tfr.areas[1].ring.count, 3)
        // THE WEDGE REGRESSION GUARD: no ring may mix vertices of both areas.
        XCTAssertTrue(tfr.areas[0].ring.allSatisfy { $0.lat >= 38 }, "area 1 stays in its own latitudes")
        XCTAssertTrue(tfr.areas[1].ring.allSatisfy { $0.lat <= 32 }, "area 2 stays in its own latitudes")
        // Per-area bands survive; the TFR-level band is the envelope (lowest floor, highest ceiling).
        XCTAssertEqual(tfr.areas[0].ceilingFt, 17_999)
        XCTAssertEqual(tfr.areas[1].ceilingFt, 5_000, "FL50 → 5000 ft")
        XCTAssertEqual(tfr.areas[1].floorFt, 2_000)
        XCTAssertEqual(tfr.floorFt, 0); XCTAssertEqual(tfr.ceilingFt, 17_999)
        XCTAssertTrue(tfr.altitudesVaryByArea)
        // Containment covers BOTH areas, and the bridge between them contains nothing.
        XCTAssertTrue(tfr.contains(Coord(lat: 39.5, lon: -76.5)))
        XCTAssertTrue(tfr.contains(Coord(lat: 30.3, lon: -79.5)))
        XCTAssertFalse(tfr.contains(Coord(lat: 35.0, lon: -78.0)), "midway between the areas is OUTSIDE")
    }

    /// The dominant live-feed shape (62 of 126 NOTAMs on 2026-07-27): the boundary carries the SAME
    /// circle twice — a tessellated vertex ring AND a trailing symbolic CIR. The duplicate must be
    /// dropped, not appended (appending doubled the ring and, when the circle differed, drew a spike).
    func testDuplicateInlineCircleIsDeduped() throws {
        let clat = 34.0, clon = -118.0, r = 5.0
        let dLat = r / 60, cosLat = cos(clat * .pi / 180)
        var avx = ""
        for k in 0..<8 {
            let a = Double(k) * 45 * .pi / 180
            let la = clat + dLat * cos(a), lo = clon + dLat / cosLat * sin(a)
            avx += "<Avx><codeType>GRC</codeType><geoLat>\(String(format: "%.8f", la))N</geoLat>"
                 + "<geoLong>\(String(format: "%.8f", abs(lo)))W</geoLong></Avx>"
        }
        avx += "<Avx><codeType>CIR</codeType><geoLat>34.00000000N</geoLat><geoLong>118.00000000W</geoLong>"
             + "<valRadiusArc>5.0</valRadiusArc></Avx>"
        let xml = "<TFR><valDistVerUpper>5000</valDistVerUpper><uomDistVerUpper>FT</uomDistVerUpper>\(avx)</TFR>"
        let tfr = try XCTUnwrap(TFRParser.detail(xml, stub: .init(id: "6/9104", type: "HAZARDS", title: "Fire")))
        XCTAssertEqual(tfr.areas.count, 1, "the coincident CIR is a duplicate encoding — dropped")
        XCTAssertEqual(tfr.areas[0].ring.count, 8, "the vertex ring stands alone, not doubled")
    }

    /// A CIR that does NOT coincide with the path ring is real geometry — its own standalone ring,
    /// never vertices spliced into the path (the spike bug).
    func testDistinctInlineCircleBecomesOwnRing() throws {
        let xml = polygonXML.replacingOccurrences(of: "</TFR>", with: """
        <Avx><codeType>CIR</codeType><geoLat>34.00000000N</geoLat><geoLong>118.00000000W</geoLong>
        <valRadiusArc>5.0</valRadiusArc></Avx></TFR>
        """)
        let tfr = try XCTUnwrap(TFRParser.detail(xml, stub: .init(id: "x", type: "SECURITY", title: "t")))
        XCTAssertEqual(tfr.areas.count, 2, "path ring + distinct circle ring")
        XCTAssertEqual(tfr.areas[0].ring.count, 4)
        XCTAssertEqual(tfr.areas[1].ring.count, 36, "the circle is its own 36-point ring")
        // No spike: the path ring contains no circle vertices and vice versa.
        XCTAssertTrue(tfr.areas[0].ring.allSatisfy { $0.lon > -80 })
        XCTAssertTrue(tfr.areas[1].ring.allSatisfy { $0.lon < -117 })
    }

    func testMultiAreaCodableRoundTrip() throws {
        let tfr = try XCTUnwrap(TFRParser.detail(twoAreaXML, stub: .init(id: "4/9383", type: "SECURITY", title: "DC")))
        let back = try JSONDecoder().decode(TFR.self, from: JSONEncoder().encode(tfr))
        XCTAssertEqual(back, tfr, "areas + per-area bands survive the disk cache")
        XCTAssertEqual(back.areas.count, 2)
    }

    func testLegacyCacheDecodesAsSingleArea() throws {
        // The pre-areas snapshot in testDecodesOldCachedTFRWithoutNewFields — its polygon becomes one area.
        let json = #"{"id":"1/1","type":"security","title":"t","polygon":[{"lat":39,"lon":-77},{"lat":39,"lon":-76},{"lat":40,"lon":-76}],"floorFt":0,"ceilingFt":18000}"#
        let tfr = try JSONDecoder().decode(TFR.self, from: Data(json.utf8))
        XCTAssertEqual(tfr.areas.count, 1)
        XCTAssertEqual(tfr.areas[0].ring.count, 3)
        XCTAssertEqual(tfr.areas[0].ceilingFt, 18_000, "legacy TFR-level band lands on the single area")
        XCTAssertTrue(tfr.contains(Coord(lat: 39.4, lon: -76.4)))
    }

    // MARK: reason extraction

    private func xmlWithBody(_ body: String) -> String {
        polygonXML.replacingOccurrences(of: "</TFR>", with: "<txtDescrTraditional>\(body)</txtDescrTraditional></TFR>")
    }

    func testReasonFirePurposePhrase() {
        let xml = xmlWithBody("""
        !FDC 6/9104 ZAB NM..AIRSPACE 14NM N LOS ALAMOS, NM..TEMPORARY FLIGHT RESTRICTION. PURSUANT TO \
        14 CFR SECTION 91.137(A)(2), TEMPORARY FLIGHT RESTRICTIONS ARE IN EFFECT. TO PROVIDE A SAFE \
        ENVIRONMENT FOR FIRE FIGHTING ACFT OPS. PUEBLO DISPATCH, TEL 719-553-1600, IS IN CHARGE.
        """)
        let tfr = TFRParser.detail(xml, stub: .init(id: "6/9104", type: "HAZARDS", title: "Fire"))
        XCTAssertEqual(tfr?.reason, "To provide a safe environment for fire fighting aircraft operations",
                       "purpose phrase wins over the statute; ACFT/OPS expanded")
    }

    func testReasonPurposePhraseCutsAtAreaBoilerplate() {
        // No period after the purpose — the phrase runs into the area definition. Cut at the first digit.
        let xml = xmlWithBody("TO PROVIDE A SAFE ENVIRONMENT FOR FIRE FIGHTING ACFT OPS 5NM RADIUS OF 360300N1062130W (SAF322033.8).")
        let tfr = TFRParser.detail(xml, stub: .init(id: "x", type: "HAZARDS", title: "t"))
        XCTAssertEqual(tfr?.reason, "To provide a safe environment for fire fighting aircraft operations")
    }

    func testReasonSecurityStatuteFallback() {
        let xml = xmlWithBody("""
        !FDC 4/9383 ZDC DC..AIRSPACE WASHINGTON, DC. PURSUANT TO 49 USC 40103(B)(3), THE FAA CLASSIFIES \
        THE AIRSPACE DEFINED IN THIS NOTAM AS 'NTL DEFENSE AIRSPACE'.
        """)
        let tfr = TFRParser.detail(xml, stub: .init(id: "4/9383", type: "SECURITY", title: "DC"))
        XCTAssertEqual(tfr?.reason, "National defense airspace — security restriction (49 USC 40103(b)(3))")
    }

    func testReasonUASProtectionOfGathering() {
        let xml = xmlWithBody("""
        PURSUANT TO 49 U.S.C. SECTION 44812 AS AMENDED BY SECTION 935 OF THE FAA REAUTHORIZATION ACT \
        OF 2024 FOR PROTECTION OF LARGE PUBLIC GATHERINGS. UAS FLT OPS ARE PROHIBITED.
        """)
        let tfr = TFRParser.detail(xml, stub: .init(id: "6/8932", type: "UAS PUBLIC GATHERING", title: "STL"))
        // The 44812 statute outranks the free-text phrase: statutes are checked before the generic
        // phrases so an EXEMPTION clause ("…IN SUPPORT OF EVENT OPS ARE AUTHORIZED") can never
        // masquerade as the reason. The statute text carries the same meaning here.
        XCTAssertEqual(tfr?.reason, "UAS restriction — protection of a large public gathering")
    }

    /// THE EXEMPTION-HARVEST REGRESSION: a security NOTAM whose exemption clause says flights
    /// "IN SUPPORT OF EVENT OPS" are authorized must be labelled by its STATUTE, not its exemption.
    func testSecurityExemptionClauseIsNotHarvestedAsTheReason() {
        let xml = xmlWithBody("""
        PURSUANT TO 49 USC 40103(B)(3), THE FAA CLASSIFIES THE AIRSPACE DEFINED IN THIS NOTAM AS \
        'NTL DEFENSE AIRSPACE'. ONLY APPROVED AIRCRAFT IN SUPPORT OF EVENT OPS ARE AUTHORIZED.
        """)
        let tfr = TFRParser.detail(xml, stub: .init(id: "6/8923", type: "SECURITY", title: "PA"))
        XCTAssertEqual(tfr?.reason, "National defense airspace — security restriction (49 USC 40103(b)(3))")
        XCTAssertFalse(tfr?.reason?.hasPrefix("In support") ?? true,
                       "the exemption clause must never become the reason")
    }

    func testReasonHazardStatuteWhenNoPurposePhrase() {
        let xml = xmlWithBody("PURSUANT TO 14 CFR SECTION 91.137(A)(2), TEMPORARY FLIGHT RESTRICTIONS ARE IN EFFECT.")
        let tfr = TFRParser.detail(xml, stub: .init(id: "x", type: "HAZARDS", title: "t"))
        XCTAssertEqual(tfr?.reason, "Hazard area — safety of persons and property on the surface (14 CFR 91.137(a)(2))")
    }

    func testReasonAbsentStaysNil() {
        // No txtDescrTraditional at all (the FAA's own "TFR TYPE UNKNOWN" placeholder shape).
        let tfr = TFRParser.detail(polygonXML, stub: .init(id: "x", type: "SPECIAL", title: "t"))
        XCTAssertNil(tfr?.reason, "no NOTAM text → no reason row, never a guess")
    }
}
