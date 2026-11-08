import XCTest
@testable import ATCTranscribe

/// The two bulletin sources added alongside Convective SIGMETs, the cross-source merge, and the S3
/// listing the radar poller discovers frames with.
///
/// Every fixture below is a REAL payload, captured from the live feeds on 2026-11-03/04 and trimmed only
/// in length. That matters most for the CWA: its shape is not the shape the airsigmet endpoint returns,
/// and a plausible hand-written fixture would have hidden all three of the traps it actually contains.

// MARK: - Center Weather Advisories

final class CWAParserTests: XCTestCase {

    /// Captured verbatim from `aviationweather.gov/api/data/cwa?format=json` for 2026-11-03T23:30Z.
    /// Note what it does NOT have: `hazard` is null on the thunderstorm record, `base`/`top` are null
    /// although the text states tops, and `coords` are strings.
    private let houstonTS = """
    [{"cwsu":"ZHU","name":"Houston","receiptTime":"2026-11-03T23:21:38.767Z",
      "validTimeFrom":1793748060,"validTimeTo":1793750400,"seriesId":"103",
      "hazard":null,"qualifier":null,"base":null,"top":null,"geom":null,
      "coords":[{"lat":"31.886","lon":"-90.953"},{"lat":"31.683","lon":"-90.451"},
                {"lat":"30.370","lon":"-90.706"},{"lat":"30.337","lon":"-91.682"},
                {"lat":"31.886","lon":"-90.953"}],
      "rawText":"FAUS21 KZHU 032321\\nZHU1 CWA 032321 \\nZHU CWA 103 VALID UNTIL 040000\\nFROM 50NW MCB-25NNW MCB-25ESE BTR-30WSW BTR-50NW MCB\\nAREA SEV EMBD TS MOV FROM 24035KT. TOPS ABV FL450. TORNADOES...HAIL \\nTO 1 IN...WIND GUSTS TO 50 KT POSS. LA MS\\n="}]
    """

    /// The Albuquerque mountain-wave advisory from the same response — the record that must NOT come
    /// through as a thunderstorm.
    private let albuquerqueTurb = """
    [{"cwsu":"ZAB","name":"Albuquerque","validTimeFrom":1793744700,"validTimeTo":1793751000,
      "seriesId":"101","hazard":"TURB","qualifier":"MOD/SEV MTN WAVE","base":null,"top":null,
      "coords":[{"lat":"36.219","lon":"-107.444"},{"lat":"35.729","lon":"-107.180"},
                {"lat":"35.252","lon":"-109.140"},{"lat":"35.922","lon":"-109.117"}],
      "rawText":"FAUS21 KZAB 032226\\nZAB CWA 101 VALID UNTIL 040015\\nAREA MOD/SEV MTN WAVE AOB FL450. SPEED CHANGES OF +/-27 KT. ALTITUDE \\nCHANGE OF +/-1000 FT. RPRTD BY ACFT. AZ NM\\n="}]
    """

    /// ⚠️ TRAP 1: `hazard` IS NULL ON A SEVERE EMBEDDED THUNDERSTORM ADVISORY. Other records in the very
    /// same response carry "TURB" and "TS", so filtering on `hazard == "TS"` — the obvious thing to
    /// write — drops the thunderstorm and keeps the mountain wave.
    func testAThunderstormCWAWithANullHazardFieldIsStillRecognised() throws {
        let cells = CWAParser.cells(Data(houstonTS.utf8))
        XCTAssertEqual(cells.count, 1, "a null hazard must fall back to the bulletin text")
        let c = try XCTUnwrap(cells.first)
        XCTAssertEqual(c.id, "CWA-ZHU-103")
        XCTAssertEqual(c.label, "ZHU CWA 103", "worded as the bulletin heads itself")
        XCTAssertEqual(c.source, .cwa)
    }

    func testANonConvectiveCWAIsRejected() {
        XCTAssertTrue(CWAParser.cells(Data(albuquerqueTurb.utf8)).isEmpty,
                      "mountain-wave turbulence is not a thunderstorm, and AOB FL450 is not a top")
    }

    /// ⚠️ THE ONE FIELD NOBODY VALIDATES. `coords` arrive as JSON STRINGS, so a transposed or truncated
    /// value does not fail to decode — it decodes to a latitude that cannot exist. Letting it through
    /// deforms the ring the entry-time estimate is measured against, and trips `distanceNm`'s own
    /// assertion in a debug build. The cell is dropped whole rather than drawn smaller than the storm.
    func testACWAWithAnImpossibleVertexIsDroppedRatherThanDeformed() {
        let bad = houstonTS.replacingOccurrences(of: #""lat":"31.683""#, with: #""lat":"318.683""#)
        XCTAssertNotEqual(bad, houstonTS, "fixture changed: the substitution matched nothing")
        XCTAssertTrue(CWAParser.cells(Data(bad.utf8)).isEmpty,
                      "a latitude of 318° is not a small error, it is a different planet")
    }

    func testAPlausibleVertexIsTheOnlyKindThatPasses() {
        XCTAssertTrue(ConvectiveAlert.isPlausible(Coord(lat: 29.5, lon: -95.2)))
        XCTAssertTrue(ConvectiveAlert.isPlausible(Coord(lat: -90, lon: 180)), "the poles are real places")
        XCTAssertFalse(ConvectiveAlert.isPlausible(Coord(lat: 90.1, lon: 0)))
        XCTAssertFalse(ConvectiveAlert.isPlausible(Coord(lat: 0, lon: -180.5)))
        XCTAssertFalse(ConvectiveAlert.isPlausible(Coord(lat: .nan, lon: 0)))
        XCTAssertFalse(ConvectiveAlert.isPlausible(Coord(lat: 0, lon: .infinity)))
    }

    /// ⚠️ TRAP 3: `coords` are JSON STRINGS here and NUMBERS on the airsigmet endpoint. A strict Double
    /// decode throws, and behind a failable wrapper that means every CWA silently vanishes.
    func testStringCoordinatesAreAccepted() throws {
        let c = try XCTUnwrap(CWAParser.cells(Data(houstonTS.utf8)).first)
        XCTAssertEqual(c.polygon.count, 4, "five coords, with the closing vertex dropped")
        XCTAssertEqual(c.polygon[0].lat, 31.886, accuracy: 1e-9)
        XCTAssertEqual(c.polygon[0].lon, -90.953, accuracy: 1e-9)
    }

    func testTheClosingVertexIsDropped() {
        let ring = [Coord(lat: 1, lon: 1), Coord(lat: 2, lon: 2), Coord(lat: 3, lon: 3),
                    Coord(lat: 1, lon: 1)]
        XCTAssertEqual(CWAParser.openRing(ring).count, 3)
        let open = [Coord(lat: 1, lon: 1), Coord(lat: 2, lon: 2), Coord(lat: 3, lon: 3)]
        XCTAssertEqual(CWAParser.openRing(open).count, 3, "an already-open ring is left alone")
    }

    /// ⚠️ TRAP 2 + THE SAFETY CALL: `base`/`top` are null while the text says TOPS ABV FL450, and
    /// "above FL450" is a LOWER BOUND, not a top. Recording 45,000 from it would let the vertical gate
    /// clear an aircraft at FL500 by the 5,000 ft overflight rule — against a storm whose top the
    /// bulletin has just said it cannot see.
    func testTopsAboveAFlightLevelStaysUnknownSoTheAlertNeverClearsIt() throws {
        let c = try XCTUnwrap(CWAParser.cells(Data(houstonTS.utf8)).first)
        XCTAssertNil(c.topsFtMSL, "ABV FL450 is a floor, not a top")
        XCTAssertEqual(ConvectiveAlert.verticalRelation(cell: c, altitudeFtMSL: 50_000),
                       .topsUnknown,
                       "so FL500 is still warned, instead of being cleared over a storm nobody topped")
    }

    func testTheMotionComesOutOfTheBulletinTextAsAFromDirection() throws {
        let c = try XCTUnwrap(CWAParser.cells(Data(houstonTS.utf8)).first)
        XCTAssertEqual(try XCTUnwrap(c.movingFromDeg), 240, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(c.motionKt), 35, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(c.movingTowardDeg), 60, accuracy: 1e-9,
                       "MOV FROM 240 means travelling toward 060")
    }

    func testTheValidityWindowComesFromTheEpochFields() throws {
        let c = try XCTUnwrap(CWAParser.cells(Data(houstonTS.utf8)).first)
        XCTAssertEqual(c.observedAt, Date(timeIntervalSince1970: 1_793_748_060))
        XCTAssertEqual(c.validUntil, Date(timeIntervalSince1970: 1_793_750_400))
    }

    /// The endpoint answers HTTP 204 with no body on a quiet day, which is most of the time.
    func testAnEmptyOrAbsentBodyIsAnEmptyList() {
        XCTAssertTrue(CWAParser.cells(Data()).isEmpty)
        XCTAssertTrue(CWAParser.cells(Data("[]".utf8)).isEmpty)
        XCTAssertTrue(CWAParser.cells(Data("not json".utf8)).isEmpty)
    }

    func testOneBadRecordDoesNotTakeTheGoodOnesWithIt() {
        let mixed = "[" + houstonTS.dropFirst().dropLast()
                  + ",{\"cwsu\":\"ZZZ\",\"validTimeFrom\":\"nope\",\"hazard\":\"TS\"},"
                  + albuquerqueTurb.dropFirst().dropLast() + "]"
        XCTAssertEqual(CWAParser.cells(Data(mixed.utf8)).map(\.id), ["CWA-ZHU-103"])
    }

    func testTheSnapshotIsBoundedForTheAlertsLoops() {
        let one = String(houstonTS.dropFirst().dropLast())
        let many = "[" + Array(repeating: one, count: ConvectiveAlert.maxCells + 20)
                                .joined(separator: ",") + "]"
        XCTAssertEqual(CWAParser.cells(Data(many.utf8)).count, ConvectiveAlert.maxCells)
    }
}

// MARK: - the bulletin-text scanners

final class CWATextTests: XCTestCase {

    /// ⚠️ THE WORD BOUNDARY. `GUSTS` contains "TS" and must not match; `TS.` at the end of a sentence
    /// must. The Houston bulletin contains both, in one line: "AREA SEV EMBD TS MOV FROM 24035KT.
    /// TOPS ABV FL450. TORNADOES...HAIL TO 1 IN...WIND GUSTS TO 50 KT POSS."
    func testConvectiveDetectionRespectsWordBoundaries() {
        XCTAssertTrue(CWAText.isConvective("AREA SEV EMBD TS MOV FROM 24035KT."))
        XCTAssertTrue(CWAText.isConvective("ISOL TS."))
        XCTAssertTrue(CWAText.isConvective("LN TSTM DVLPG"))
        XCTAssertTrue(CWAText.isConvective("TORNADO RPRTD"))
        XCTAssertTrue(CWAText.isConvective("OCNL CB TOPS TO FL410"))

        XCTAssertFalse(CWAText.isConvective("WIND GUSTS TO 50 KT POSS"),
                       "GUSTS contains TS and is not a thunderstorm")
        XCTAssertFalse(CWAText.isConvective("SFC WIND 25035KTS"), "nor does KTS")
        XCTAssertFalse(CWAText.isConvective("AREA MOD/SEV MTN WAVE AOB FL450. RPRTD BY ACFT."))
        XCTAssertFalse(CWAText.isConvective("MOD ICE BTN FL080 AND FL180"))
        XCTAssertFalse(CWAText.isConvective("PRESFR"))
        XCTAssertFalse(CWAText.isConvective(""))
    }

    func testTokenSearchIsExact() {
        XCTAssertTrue(CWAText.containsToken("A TS B", "TS"))
        XCTAssertTrue(CWAText.containsToken("TS", "TS"))
        XCTAssertTrue(CWAText.containsToken("TS.", "TS"))
        XCTAssertTrue(CWAText.containsToken("...TS...", "TS"))
        XCTAssertFalse(CWAText.containsToken("GUSTS", "TS"))
        XCTAssertFalse(CWAText.containsToken("TSTM", "TS"), "TSTM is its own token")
        XCTAssertFalse(CWAText.containsToken("", "TS"))
    }

    func testMotionIsReadAsAFromBearing() throws {
        let m = try XCTUnwrap(CWAText.motion("AREA SEV EMBD TS MOV FROM 24035KT. TOPS ABV FL450."))
        XCTAssertEqual(m.fromDeg, 240, accuracy: 1e-9)
        XCTAssertEqual(m.kt, 35, accuracy: 1e-9)
    }

    func testMotionHandlesTheFormsTheFeedActuallyUses() throws {
        XCTAssertEqual(try XCTUnwrap(CWAText.motion("TS MOVG FROM 27020KT")).fromDeg, 270, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(CWAText.motion("TS MOVING FROM 09015KT")).fromDeg, 90, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(CWAText.motion("MOV FROM 180105KT")).kt, 105, accuracy: 1e-9,
                       "a three-digit speed")
        XCTAssertEqual(try XCTUnwrap(CWAText.motion("MOV 24035KT")).fromDeg, 240, accuracy: 1e-9,
                       "the FROM keyword is sometimes absent")
        XCTAssertEqual(try XCTUnwrap(CWAText.motion("MOV FROM 36020KT")).fromDeg, 0, accuracy: 1e-9,
                       "360 is north, normalised to 0")
    }

    /// "Little movement" returns nil rather than 0 kt: a stated zero is extrapolated as a stationary
    /// cell with a tight avoidance radius, while nil buys the unknown-motion slack. "Little" is not
    /// "none".
    func testLittleMovementIsNotZeroMovement() {
        XCTAssertNil(CWAText.motion("AREA TS LTL MOV. TOPS FL380."))
        XCTAssertNil(CWAText.motion("TS MOV LTL"))
    }

    func testNoMotionStatedIsNil() {
        XCTAssertNil(CWAText.motion("AREA TS. TOPS TO FL380."))
        XCTAssertNil(CWAText.motion(""))
        XCTAssertNil(CWAText.motion("MOV FROM 999999KT"), "an impossible bearing")
    }

    func testTopsAreReadFromTheFormsTheFeedUses() {
        XCTAssertEqual(CWAText.topsFt("TOPS TO FL450"), 45_000)
        XCTAssertEqual(CWAText.topsFt("TOPS FL380"), 38_000)
        XCTAssertEqual(CWAText.topsFt("TOPS 410"), 41_000)
        XCTAssertEqual(CWAText.topsFt("AREA TS. TOPS AOB FL300."), 30_000)
    }

    /// Repeated from the parser's own test because this is the single most consequential line in the
    /// file: an unbounded top must be nil, not the number next to the word ABOVE.
    func testAnUnboundedTopIsNilRatherThanItsFloor() {
        XCTAssertNil(CWAText.topsFt("TOPS ABV FL450"))
        XCTAssertNil(CWAText.topsFt("TOPS ABOVE FL450"))
        XCTAssertNil(CWAText.topsFt("no tops here at all"))
        XCTAssertNil(CWAText.topsFt(""))
    }
}

// MARK: - NWS Severe Thunderstorm Warnings

final class SevereWarningParserTests: XCTestCase {

    /// Captured verbatim from `api.weather.gov/alerts/active?event=Severe Thunderstorm Warning`
    /// (Rapides Parish, Louisiana, 2026-11-03T17:37-06:00).
    private let rapides = """
    {"type":"FeatureCollection","features":[
     {"type":"Feature",
      "geometry":{"type":"Polygon","coordinates":[[[-92.74,31.17],[-92.8,31.2],
                                                   [-92.73,31.28],[-92.61,31.22],[-92.74,31.17]]]},
      "properties":{
        "id":"urn:oid:2.49.0.1.840.0.15debe26d3aec65cf33f22c013ce6959e8ed3003.001.1",
        "event":"Severe Thunderstorm Warning","messageType":"Update","status":"Actual",
        "sent":"2026-11-03T17:37:00-06:00","effective":"2026-11-03T17:37:00-06:00",
        "onset":"2026-11-03T17:37:00-06:00","expires":"2026-11-03T17:47:00-06:00",
        "ends":"2026-11-03T17:45:00-06:00",
        "severity":"Severe","certainty":"Observed","urgency":"Immediate",
        "areaDesc":"Rapides, LA",
        "parameters":{
          "AWIPSidentifier":["SVSLCH"],
          "eventMotionDescription":["2026-11-03T23:37:00-00:00...storm...270DEG...16KT...31.25,-92.69"],
          "maxHailSize":["1.00"],"maxWindGust":["60 mph"]}}}]}
    """

    func testARealWarningMapsEveryFieldTheAlertNeeds() throws {
        let cells = SevereWarningParser.cells(Data(rapides.utf8))
        XCTAssertEqual(cells.count, 1)
        let c = try XCTUnwrap(cells.first)
        XCTAssertEqual(c.source, .warning)
        XCTAssertTrue(c.id.hasPrefix("SVR-urn:oid:"))
        XCTAssertEqual(c.label, "Severe Tstm Warning (Rapides, LA)")
        XCTAssertEqual(c.severity, 5, "same ordinal scale a convective SIGMET reads")
        XCTAssertEqual(c.polygon.count, 4, "five coordinates, with the closing vertex dropped")
    }

    /// ⚠️ GeoJSON IS [LONGITUDE, LATITUDE]. Reversed, this Louisiana storm lands in the Indian Ocean —
    /// obvious here, and silent for anything near the equator.
    func testGeoJSONCoordinateOrderIsNotReversed() throws {
        let c = try XCTUnwrap(SevereWarningParser.cells(Data(rapides.utf8)).first)
        XCTAssertEqual(c.polygon[0].lat, 31.17, accuracy: 1e-9)
        XCTAssertEqual(c.polygon[0].lon, -92.74, accuracy: 1e-9)
        XCTAssertEqual(c.centroid.lat, 31.2, accuracy: 0.2)
        XCTAssertEqual(c.centroid.lon, -92.7, accuracy: 0.2)
    }

    /// ⚠️ 270DEG IS WHERE THE STORM IS COMING FROM. Checked against each warning's own prose across 12
    /// live warnings: `227DEG` with "moving northeast", `253DEG` with "moving east" — the FROM reading
    /// matched 12 of 12, and the TOWARD reading would have given southwest and west-southwest. A sign
    /// slip here makes the alert fire for the aeroplane behind the storm and stay silent for the one
    /// flying in.
    func testTheMotionBearingIsAFromDirection() throws {
        let c = try XCTUnwrap(SevereWarningParser.cells(Data(rapides.utf8)).first)
        XCTAssertEqual(try XCTUnwrap(c.movingFromDeg), 270, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(c.motionKt), 16, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(c.movingTowardDeg), 90, accuracy: 1e-9,
                       "FROM 270 is travelling east, which is what the warning text says")
    }

    /// The observation time is the one embedded in the motion string, not the alert's issue time,
    /// because that is when the motion was MEASURED — and it is what the alert ages the vector from.
    func testTheObservationTimeComesFromTheMotionStringNotTheAlertHeader() throws {
        let c = try XCTUnwrap(SevereWarningParser.cells(Data(rapides.utf8)).first)
        let expected = ISO8601DateFormatter().date(from: "2026-11-03T23:37:00Z")
        XCTAssertEqual(c.observedAt, expected)
        XCTAssertEqual(c.validUntil, ISO8601DateFormatter().date(from: "2026-11-03T23:45:00Z"),
                       "`ends` is preferred over `expires`")
    }

    func testTheMotionStringIsParsedByFieldSuffixNotByPosition() throws {
        // The NWS emits a varying number of `...`-separated fields; several location pairs appear for a
        // line of storms. Counting positions would break on exactly those.
        let m = try XCTUnwrap(SevereWarningParser.motion(
            "2026-11-03T23:37:00-00:00...storm...227DEG...33KT...33.12,-93.44 33.01,-93.21"))
        XCTAssertEqual(m.fromDeg, 227, accuracy: 1e-9)
        XCTAssertEqual(m.kt, 33, accuracy: 1e-9)
        XCTAssertNil(SevereWarningParser.motion("2026-11-03T23:37:00-00:00...storm"))
        XCTAssertNil(SevereWarningParser.motion(nil))
        XCTAssertNil(SevereWarningParser.motion(""))
    }

    /// ⚠️ NO PRODUCT FIELD STATES A TOP, so nil it is — which lands in `.topsUnknown` and alerts at
    /// every altitude. For a *severe* thunderstorm that is the right default, and the merge fills in a
    /// measured top when MRMS is also running.
    func testNoTopIsStatedAndTheAlertThereforeNeverClearsOne() throws {
        let c = try XCTUnwrap(SevereWarningParser.cells(Data(rapides.utf8)).first)
        XCTAssertNil(c.topsFtMSL)
        XCTAssertNil(c.baseFtMSL)
        XCTAssertEqual(ConvectiveAlert.verticalRelation(cell: c, altitudeFtMSL: 45_000),
                       .topsUnknown)
    }

    /// A zone-based alert has no polygon. Storm-based warnings always do, so a null geometry is skipped
    /// rather than resolved with a second round trip per alert.
    func testAnAlertWithoutAPolygonIsSkipped() {
        let noGeom = """
        {"features":[{"geometry":null,"properties":{"event":"Severe Thunderstorm Warning",
          "sent":"2026-11-03T17:37:00-06:00","expires":"2026-11-03T17:47:00-06:00"}}]}
        """
        XCTAssertTrue(SevereWarningParser.cells(Data(noGeom.utf8)).isEmpty)
    }

    func testANonThunderstormEventIsRejected() {
        let winter = rapides.replacingOccurrences(of: "Severe Thunderstorm Warning",
                                                  with: "Winter Storm Warning")
        XCTAssertTrue(SevereWarningParser.cells(Data(winter.utf8)).isEmpty,
                      "the query asks for one event type; a feed that returns another must not have it "
                      + "read as a thunderstorm")
    }

    func testAnAlertWhoseValidityHasNoEndIsRejected() {
        let noEnd = rapides
            .replacingOccurrences(of: "\"expires\":\"2026-11-03T17:47:00-06:00\",", with: "")
            .replacingOccurrences(of: "\"ends\":\"2026-11-03T17:45:00-06:00\",", with: "")
        XCTAssertTrue(SevereWarningParser.cells(Data(noEnd.utf8)).isEmpty)
    }

    func testSeverityWordsMapToTheSharedOrdinalScale() {
        XCTAssertEqual(SevereWarningParser.severityRank("Extreme"), 6)
        XCTAssertEqual(SevereWarningParser.severityRank("Severe"), 5)
        XCTAssertEqual(SevereWarningParser.severityRank("Moderate"), 3)
        XCTAssertEqual(SevereWarningParser.severityRank("Minor"), 1)
        XCTAssertNil(SevereWarningParser.severityRank("Unknown"))
        XCTAssertNil(SevereWarningParser.severityRank(nil))
    }

    func testAnEmptyFeedIsAnEmptyList() {
        XCTAssertTrue(SevereWarningParser.cells(Data()).isEmpty)
        XCTAssertTrue(SevereWarningParser.cells(Data(#"{"features":[]}"#.utf8)).isEmpty)
        XCTAssertTrue(SevereWarningParser.cells(Data("garbage".utf8)).isEmpty)
    }
}

// MARK: - the cross-source merge

final class ConvectiveCellMergeTests: XCTestCase {

    private let noon = Date(timeIntervalSince1970: 1_793_753_700)

    private func cell(_ id: String, _ source: ConvectiveSource,
                      lat: Double, lon: Double, size: Double = 0.2,
                      tops: Double? = nil, base: Double? = nil,
                      severity: Int? = nil,
                      from: Double? = nil, kt: Double? = nil,
                      observed: Date? = nil, until: Date? = nil) -> ConvectiveCell {
        let h = size / 2
        return ConvectiveCell(
            id: id, label: id,
            polygon: [Coord(lat: lat - h, lon: lon - h), Coord(lat: lat - h, lon: lon + h),
                      Coord(lat: lat + h, lon: lon + h), Coord(lat: lat + h, lon: lon - h)],
            topsFtMSL: tops, baseFtMSL: base,
            observedAt: observed ?? noon,
            validUntil: until ?? noon.addingTimeInterval(3_600),
            severity: severity, movingFromDeg: from, motionKt: kt, source: source)
    }

    func testDisjointCellsAreAllKept() {
        let cells = [cell("a", .sigmet, lat: 30, lon: -95),
                     cell("b", .radar, lat: 40, lon: -85, tops: 40_000)]
        XCTAssertEqual(Set(ConvectiveCellMerge.merge(cells).map(\.id)), ["a", "b"])
    }

    /// ⚠️ THE CASE THIS FILE EXISTS FOR. On an active afternoon one storm appears as a SIGMET area, a
    /// warning polygon and a radar component. Published as-is the pilot reads "Entering Convective
    /// SIGMET 7C in 8 min (+2 more)" where all three are the same weather — which both adds noise and
    /// hides a genuinely separate second storm behind the "+2 more".
    func testThreeDescriptionsOfOneStormBecomeOneCell() {
        let cells = [cell("WST-7C", .sigmet, lat: 30, lon: -95, size: 2.0, tops: 45_000,
                          from: 270, kt: 20),
                     cell("SVR-1", .warning, lat: 30.1, lon: -95.1, size: 0.3,
                          severity: 5, from: 265, kt: 25),
                     cell("RDR-x", .radar, lat: 30.05, lon: -95.05, size: 0.2, tops: 52_000)]
        let merged = ConvectiveCellMerge.merge(cells)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].id, "WST-7C", "identity goes to the highest-ranked source")
    }

    /// Identity to the highest-ranked source, but every NUMBER to whichever source has the conservative
    /// one — so the merge is a union, not a discard.
    func testTheMergedCellCarriesTheBestFieldFromEachSource() throws {
        let sigmet = cell("WST-7C", .sigmet, lat: 30, lon: -95, size: 2.0,
                          tops: 45_000, base: 8_000, from: 270, kt: 20,
                          until: noon.addingTimeInterval(600))
        let warning = cell("SVR-1", .warning, lat: 30.1, lon: -95.1, size: 0.3,
                           severity: 6, until: noon.addingTimeInterval(5_400))
        let radar = cell("RDR-x", .radar, lat: 30.05, lon: -95.05, size: 0.2, tops: 52_000)
        let m = try XCTUnwrap(ConvectiveCellMerge.merge([sigmet, warning, radar]).first)

        XCTAssertEqual(try XCTUnwrap(m.topsFtMSL), 52_000, accuracy: 1e-9,
                       "the measured top is higher than the area's stated one, and higher is the safe "
                       + "direction — the same rule the SIGMET parser applies to its own altitude pair")
        XCTAssertNil(m.baseFtMSL, "a nil base means surface, which is lower than any stated base")
        XCTAssertEqual(m.severity, 6, "the greater severity")
        XCTAssertEqual(m.validUntil, noon.addingTimeInterval(5_400),
                       "the later validity, so the storm is not dropped into an expiry seam")
        XCTAssertEqual(try XCTUnwrap(m.movingFromDeg), 270, accuracy: 1e-9,
                       "the winner's own stated vector is never overwritten")
        XCTAssertEqual(try XCTUnwrap(m.motionKt), 20, accuracy: 1e-9)
    }

    /// A warning states no top. Where MRMS is also running, the merge is what gives that storm a
    /// measured one — which is the difference between alerting at every altitude and alerting usefully.
    func testARadarTopFillsInTheOneFieldAWarningCannotSupply() throws {
        let warning = cell("SVR-1", .warning, lat: 30, lon: -95, size: 0.4, severity: 5,
                           from: 250, kt: 30)
        let radar = cell("RDR-x", .radar, lat: 30.02, lon: -95.02, size: 0.2, tops: 41_000)
        let m = try XCTUnwrap(ConvectiveCellMerge.merge([warning, radar]).first)
        XCTAssertEqual(m.id, "SVR-1")
        XCTAssertEqual(try XCTUnwrap(m.topsFtMSL), 41_000, accuracy: 1e-9)
        XCTAssertEqual(ConvectiveAlert.verticalRelation(cell: m, altitudeFtMSL: 50_000),
                       .clearAbove(marginFt: 9_000),
                       "and FL500 is now correctly quiet, instead of warned on an unknown top")
    }

    /// A radar cell with no recoverable vector gets the warning's measured one.
    func testAStatedVectorFillsInWhatTheRadarCouldNotMeasure() throws {
        let radar = cell("RDR-x", .radar, lat: 30, lon: -95, size: 0.3, tops: 44_000)
        let warning = cell("SVR-1", .warning, lat: 30.02, lon: -95.02, size: 0.3,
                           severity: 5, from: 250, kt: 30)
        let m = try XCTUnwrap(ConvectiveCellMerge.merge([radar, warning]).first)
        XCTAssertEqual(m.id, "SVR-1", "the warning outranks the radar cell")
        XCTAssertEqual(try XCTUnwrap(m.movingFromDeg), 250, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(m.topsFtMSL), 44_000, accuracy: 1e-9,
                       "while keeping the radar's measured top")
    }

    /// ⚠️ `observedAt` IS NEVER MERGED. The dismiss key and the motion-vector ageing are both built on
    /// it, so moving it forward to the fresher source's time would silently un-dismiss a bulletin the
    /// pilot had cleared, and would re-date a 40-minute-old vector as though it had just been measured.
    func testTheObservationTimeIsTheWinnersAndIsNeverMovedForward() throws {
        let old = cell("WST-7C", .sigmet, lat: 30, lon: -95, size: 2.0, tops: 40_000,
                       from: 270, kt: 20, observed: noon.addingTimeInterval(-2_400))
        let fresh = cell("RDR-x", .radar, lat: 30, lon: -95, size: 0.2, tops: 50_000,
                         observed: noon)
        let m = try XCTUnwrap(ConvectiveCellMerge.merge([old, fresh]).first)
        XCTAssertEqual(m.observedAt, noon.addingTimeInterval(-2_400))
        XCTAssertEqual(m.dismissKey, old.dismissKey,
                       "a dismissal of 7C must survive a radar cell joining it")
    }

    /// The outline kept is the LARGER one. A superset can only widen the alert, so folding a small
    /// radar cell into a big SIGMET area cannot lose coverage the radar had.
    func testTheLargerOutlineIsKept() throws {
        let big = cell("WST-7C", .sigmet, lat: 30, lon: -95, size: 2.0, tops: 40_000)
        let small = cell("RDR-x", .radar, lat: 30, lon: -95, size: 0.2, tops: 40_000)
        let m = try XCTUnwrap(ConvectiveCellMerge.merge([big, small]).first)
        XCTAssertGreaterThan(RadarCellFinder.areaNm2(m.polygon),
                             RadarCellFinder.areaNm2(small.polygon) * 10)
        // And the other way round: a radar cell larger than the bulletin's area wins the outline.
        let tinySigmet = cell("WST-9C", .sigmet, lat: 40, lon: -85, size: 0.1, tops: 40_000)
        let bigRadar = cell("RDR-y", .radar, lat: 40, lon: -85, size: 1.0, tops: 40_000)
        let m2 = try XCTUnwrap(ConvectiveCellMerge.merge([tinySigmet, bigRadar]).first)
        XCTAssertEqual(m2.id, "WST-9C", "identity still the bulletin's")
        XCTAssertGreaterThan(RadarCellFinder.areaNm2(m2.polygon),
                             RadarCellFinder.areaNm2(tinySigmet.polygon) * 10,
                             "but the outline is the bigger one")
    }

    /// Outlines drawn by different methods minutes apart can miss each other by a few miles while
    /// plainly being one thunderstorm.
    func testNearbyButNonOverlappingOutlinesAreStillOneStorm() {
        let a = cell("SVR-1", .warning, lat: 30.00, lon: -95.00, size: 0.1)
        let b = cell("RDR-x", .radar, lat: 30.00, lon: -94.90, size: 0.1, tops: 40_000)
        XCTAssertTrue(ConvectiveCellMerge.describeSameStorm(a, b),
                      "about 4 NM apart at this latitude")
        let far = cell("RDR-y", .radar, lat: 30.00, lon: -94.00, size: 0.1, tops: 40_000)
        XCTAssertFalse(ConvectiveCellMerge.describeSameStorm(a, far), "about 52 NM apart")
    }

    func testContainmentIsCheckedBothWays() {
        let area = cell("WST-7C", .sigmet, lat: 30, lon: -95, size: 4.0)
        let inside = cell("RDR-x", .radar, lat: 30.5, lon: -95.5, size: 0.1, tops: 40_000)
        XCTAssertTrue(ConvectiveCellMerge.describeSameStorm(area, inside))
        XCTAssertTrue(ConvectiveCellMerge.describeSameStorm(inside, area),
                      "a small cell inside a big area satisfies containment in only one direction")
    }

    func testTheResultIsBoundedAndOrderedWorstFirst() {
        var cells: [ConvectiveCell] = []
        // ⚠️ LAID OUT AS A GRID, NOT A LINE. Marching `maxCells + 20` cells along one meridian at 1.5°
        // a step walks off the planet at k=47, and `distanceNm` rightly asserts on a latitude that
        // cannot exist — which trapped the test process instead of failing the test, so the suite
        // reported "0 failures" while silently skipping this case. Twelve rows of 1.5° by seven columns
        // of 2.5° keeps every cell real and every pair far enough apart not to be merged.
        for k in 0..<(ConvectiveAlert.maxCells + 20) {
            cells.append(cell("r\(k)", .radar,
                              lat: 25 + Double(k % 12) * 1.5,
                              lon: -120 + Double(k / 12) * 2.5,
                              size: 0.2, tops: 20_000 + Double(k) * 500))
        }
        let merged = ConvectiveCellMerge.merge(cells)
        XCTAssertLessThanOrEqual(merged.count, ConvectiveAlert.maxCells)
        XCTAssertGreaterThan(try! XCTUnwrap(merged.first?.topsFtMSL),
                             try! XCTUnwrap(merged.last?.topsFtMSL))
    }

    /// A cell whose top nobody measured goes to the FRONT, not the back: it is the one the pilot can
    /// least afford to have pushed off the end of a four-line banner.
    func testACellWithNoKnownTopSortsAheadOfOnesWithKnownTops() throws {
        let known = cell("a", .sigmet, lat: 30, lon: -95, tops: 50_000)
        let unknown = cell("b", .warning, lat: 40, lon: -85)
        XCTAssertEqual(ConvectiveCellMerge.merge([known, unknown]).first?.id, "b")
    }

    func testMergingIsANoOpOnASingleCellOrAnEmptyList() {
        XCTAssertTrue(ConvectiveCellMerge.merge([]).isEmpty)
        let one = [cell("a", .sigmet, lat: 30, lon: -95)]
        XCTAssertEqual(ConvectiveCellMerge.merge(one).map(\.id), ["a"])
    }

    func testSourceRankingIsTheOrderTheMergeRelieson() {
        XCTAssertGreaterThan(ConvectiveSource.sigmet.rank, ConvectiveSource.cwa.rank)
        XCTAssertGreaterThan(ConvectiveSource.cwa.rank, ConvectiveSource.warning.rank)
        XCTAssertGreaterThan(ConvectiveSource.warning.rank, ConvectiveSource.radar.rank)
    }
}

// MARK: - frame discovery

final class MRMSKeyListingTests: XCTestCase {

    /// Captured verbatim from the NOAA Open Data bucket. ⚠️ Keys sort lexicographically, which for
    /// these names is chronologically — which is the entire reason `start-after` can return just the
    /// newest handful instead of a 764-entry directory.
    private let listing = """
    <?xml version="1.0" encoding="UTF-8"?>
    <ListBucketResult><Name>noaa-mrms-pds</Name><KeyCount>3</KeyCount><IsTruncated>false</IsTruncated>
    <Contents><Key>CONUS/EchoTop_30_00.50/20261104/MRMS_EchoTop_30_00.50_20261104-032040.grib2.gz</Key>
     <LastModified>2026-11-04T03:22:01.000Z</LastModified><Size>364047</Size></Contents>
    <Contents><Key>CONUS/EchoTop_30_00.50/20261104/MRMS_EchoTop_30_00.50_20261104-032240.grib2.gz</Key>
     <LastModified>2026-11-04T03:24:01.000Z</LastModified><Size>363708</Size></Contents>
    <Contents><Key>CONUS/EchoTop_30_00.50/20261104/MRMS_EchoTop_30_00.50_20261104-032438.grib2.gz</Key>
     <LastModified>2026-11-04T03:26:01.000Z</LastModified><Size>361524</Size></Contents>
    </ListBucketResult>
    """

    func testTheRealListingParsesToFramesWithTimesAndSizes() throws {
        let frames = MRMSKeyListing.frames(Data(listing.utf8),
                                           bucket: "https://example.invalid",
                                           product: "EchoTop_30_00.50")
        XCTAssertEqual(frames.count, 3)
        XCTAssertEqual(frames[0].bytes, 364_047)
        XCTAssertEqual(frames[2].bytes, 361_524)
        XCTAssertEqual(frames[0].url.absoluteString,
                       "https://example.invalid/CONUS/EchoTop_30_00.50/20261104/"
                       + "MRMS_EchoTop_30_00.50_20261104-032040.grib2.gz")
        let expected = DateComponents(calendar: Calendar(identifier: .gregorian),
                                      timeZone: TimeZone(identifier: "UTC"),
                                      year: 2026, month: 11, day: 4,
                                      hour: 3, minute: 20, second: 40).date
        XCTAssertEqual(frames[0].at, expected)
        XCTAssertLessThan(frames[0].at, frames[1].at, "and they really are in time order")
    }

    func testTheTimestampIsReadOutOfTheFilename() throws {
        let t = try XCTUnwrap(MRMSKeyListing.timestamp(
            ofKey: "CONUS/EchoTop_30_00.50/20261104/MRMS_EchoTop_30_00.50_20261104-031643.grib2.gz",
            product: "EchoTop_30_00.50"))
        XCTAssertEqual(ISO8601DateFormatter().string(from: t), "2026-11-04T03:16:43Z")
    }

    /// ⚠️ A name this cannot read means "skip that key", NEVER "use now". A frame stamped with the
    /// current clock would be treated as a fresh observation and its cells dated accordingly.
    func testAnUnreadableKeyIsSkippedRatherThanDefaultedToNow() {
        let product = "EchoTop_30_00.50"
        XCTAssertNil(MRMSKeyListing.timestamp(ofKey: "index.html", product: product))
        XCTAssertNil(MRMSKeyListing.timestamp(ofKey: "CONUS/Other/MRMS_Other_20261104-031643.grib2.gz",
                                              product: product))
        XCTAssertNil(MRMSKeyListing.timestamp(
            ofKey: "CONUS/\(product)/MRMS_\(product)_notatime.grib2.gz", product: product))
        XCTAssertNil(MRMSKeyListing.timestamp(ofKey: "", product: product))
    }

    func testAForeignProductInTheSameListingIsIgnored() {
        let mixed = listing.replacingOccurrences(
            of: "MRMS_EchoTop_30_00.50_20261104-032240.grib2.gz",
            with: "MRMS_MESH_00.50_20261104-032240.grib2.gz")
        let frames = MRMSKeyListing.frames(Data(mixed.utf8), bucket: "https://example.invalid",
                                           product: "EchoTop_30_00.50")
        XCTAssertEqual(frames.count, 2)
    }

    func testGarbageYieldsNothing() {
        XCTAssertTrue(MRMSKeyListing.frames(Data(), bucket: "https://example.invalid",
                                            product: "EchoTop_30_00.50").isEmpty)
        XCTAssertTrue(MRMSKeyListing.frames(Data("<html>nope</html>".utf8),
                                            bucket: "https://example.invalid",
                                            product: "EchoTop_30_00.50").isEmpty)
    }

    func testTheListingIsBounded() {
        var body = "<ListBucketResult>"
        for k in 0..<(MRMSKeyListing.maxKeys + 40) {
            body += "<Contents><Key>CONUS/EchoTop_30_00.50/20261104/"
                 + "MRMS_EchoTop_30_00.50_20261104-\(String(format: "%06d", 30_000 + k))"
                 + ".grib2.gz</Key><Size>1</Size></Contents>"
        }
        body += "</ListBucketResult>"
        let frames = MRMSKeyListing.frames(Data(body.utf8), bucket: "https://example.invalid",
                                           product: "EchoTop_30_00.50")
        XCTAssertLessThanOrEqual(frames.count, MRMSKeyListing.maxKeys)
    }
}

// MARK: - gzip

final class GunzipTests: XCTestCase {

    /// A real gzip member, built by compressing with the system tool at build time is not available, so
    /// this uses a STORED-block DEFLATE stream wrapped in a genuine gzip header and trailer — valid by
    /// RFC 1952, and the same technique `PNGFixture` uses for zlib.
    private func gzipped(_ payload: [UInt8], flags: UInt8 = 0, extra: [UInt8] = []) -> Data {
        var out: [UInt8] = [0x1F, 0x8B, 8, flags, 0, 0, 0, 0, 0, 0]
        out += extra
        var off = 0
        repeat {
            let n = min(0xFFFF, payload.count - off)
            out.append((off + n >= payload.count) ? 1 : 0)
            out.append(UInt8(n & 0xFF)); out.append(UInt8(n >> 8))
            out.append(UInt8(~n & 0xFF)); out.append(UInt8((~n >> 8) & 0xFF))
            out += payload[off..<(off + n)]
            off += n
        } while off < payload.count
        var crc: UInt32 = 0            // not checked by the reader; the LENGTH is what it verifies
        crc = 0
        out += [UInt8(crc & 0xFF), UInt8((crc >> 8) & 0xFF),
                UInt8((crc >> 16) & 0xFF), UInt8((crc >> 24) & 0xFF)]
        let n = UInt32(payload.count)
        out += [UInt8(n & 0xFF), UInt8((n >> 8) & 0xFF),
                UInt8((n >> 16) & 0xFF), UInt8((n >> 24) & 0xFF)]
        return Data(out)
    }

    func testAPlainMemberRoundTrips() throws {
        let payload = (0..<5_000).map { UInt8($0 % 251) }
        let data = gzipped(payload)
        XCTAssertTrue(Gunzip.isGzip(data))
        XCTAssertEqual(try XCTUnwrap(Gunzip.inflate(data)), Data(payload))
    }

    /// The optional header fields have to be walked in the order RFC 1952 fixes them, or the DEFLATE
    /// stream starts at the wrong octet and inflates to nothing.
    func testTheOptionalHeaderFieldsAreSkipped() throws {
        let payload = Array("GRIB....7777".utf8)
        // FNAME (0x08): a NUL-terminated name.
        XCTAssertEqual(try XCTUnwrap(Gunzip.inflate(
            gzipped(payload, flags: 0x08, extra: Array("file.grib2".utf8) + [0]))), Data(payload))
        // FEXTRA (0x04): a little-endian length then that many octets.
        XCTAssertEqual(try XCTUnwrap(Gunzip.inflate(
            gzipped(payload, flags: 0x04, extra: [3, 0, 9, 9, 9]))), Data(payload))
        // FCOMMENT (0x10) and FHCRC (0x02), together with a name.
        XCTAssertEqual(try XCTUnwrap(Gunzip.inflate(
            gzipped(payload, flags: 0x08 | 0x10 | 0x02,
                    extra: Array("n".utf8) + [0] + Array("c".utf8) + [0] + [0xAA, 0xBB]))),
                       Data(payload))
    }

    /// ⚠️ EXACTLY `ISIZE` OR NOTHING. A short inflate is a truncated download, and a weather grid that
    /// is 90% there decodes to a map with a hole in it rather than to an error.
    func testATruncatedMemberIsRejectedRatherThanPartiallyDecoded() {
        let payload = (0..<4_000).map { UInt8($0 % 97) }
        let full = gzipped(payload)
        for cut in [20, 100, 1_000, full.count - 20, full.count - 1] where cut > 0 {
            XCTAssertNil(Gunzip.inflate(full.prefix(cut)), "a member cut at \(cut) must not decode")
        }
    }

    func testAnIsizeThatDisagreesWithTheStreamIsRejected() {
        let payload = (0..<1_000).map { UInt8($0 % 13) }
        var data = [UInt8](gzipped(payload))
        data[data.count - 4] = 0x11          // claim a different uncompressed length
        XCTAssertNil(Gunzip.inflate(Data(data)))
    }

    func testNonGzipAndMalformedInputIsRefused() {
        XCTAssertNil(Gunzip.inflate(Data()))
        XCTAssertNil(Gunzip.inflate(Data([0x1F])))
        XCTAssertNil(Gunzip.inflate(Data(repeating: 0, count: 64)))
        XCTAssertFalse(Gunzip.isGzip(Data("GRIB".utf8)))
        // Compression method 9 does not exist; DEFLATE (8) is the only one defined.
        var bad = [UInt8](gzipped([1, 2, 3]))
        bad[2] = 9
        XCTAssertNil(Gunzip.inflate(Data(bad)))
        // Reserved flag bits set means a format this does not know.
        bad = [UInt8](gzipped([1, 2, 3]))
        bad[3] = 0xE0
        XCTAssertNil(Gunzip.inflate(Data(bad)))
    }

    func testAnAbsurdIsizeIsRefusedBeforeAllocating() {
        var data = [UInt8](gzipped([1, 2, 3, 4]))
        data[data.count - 1] = 0xFF          // ISIZE ≈ 4 GB
        data[data.count - 2] = 0xFF
        data[data.count - 3] = 0xFF
        XCTAssertNil(Gunzip.inflate(Data(data)))
        XCTAssertLessThan(Gunzip.maxOutputBytes, 1 << 30)
        XCTAssertGreaterThan(Gunzip.maxOutputBytes, 401_853,
                             "but it must still fit the MRMS CONUS grid, which is the largest "
                             + "thing this app gunzips")
    }
}
