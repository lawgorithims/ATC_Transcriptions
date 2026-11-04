import XCTest
@testable import ATCTranscribe

/// Tests for the AWC convective-SIGMET parse.
///
/// The fixtures below are the real field set from `aviationweather.gov/api/data/airsigmet?format=json
/// &hazard=conv`, captured live: `seriesId`, `hazard`, `validTimeFrom`/`To` as epoch seconds,
/// `altitudeHi1`/`Hi2`, `altitudeLow1`/`Low2`, `movementDir`, `movementSpd`, `severity` and `coords` as
/// `{lat, lon}` objects. Null bases and absent fields are reproduced because the live feed emits them.
final class ConvectiveSigmetParserTests: XCTestCase {

    /// 2026-11-04T00:55Z, the issue time of the bulletin these fixtures are modelled on.
    private let issued = 1_793_753_700
    private let expires = 1_793_760_900

    private func json(_ records: String) -> Data {
        Data("[\(records)]".utf8)
    }

    private func record(series: String = "1C", hazard: String = "CONVECTIVE",
                        from: Int? = nil, to: Int? = nil, nullFrom: Bool = false,
                        hi1: Int? = 38_000, hi2: Int? = 38_000,
                        low1: Int? = nil, low2: Int? = nil,
                        dir: Int? = 210, spd: Int? = 45, severity: Int? = 5,
                        coords: String = """
                        [{"lon":-90.08,"lat":40.233},{"lon":-88.726,"lat":37.601},
                         {"lon":-88.964,"lat":35.056},{"lon":-90.996,"lat":35.056},
                         {"lon":-90.877,"lat":38.900}]
                        """) -> String {
        func num(_ v: Int?) -> String { v.map(String.init) ?? "null" }
        return """
        {"icaoId":"KKCI","seriesId":"\(series)","hazard":"\(hazard)","airSigmetType":"SIGMET",
         "validTimeFrom":\(nullFrom ? "null" : num(from ?? issued)),"validTimeTo":\(num(to ?? expires)),
         "altitudeHi1":\(num(hi1)),"altitudeHi2":\(num(hi2)),
         "altitudeLow1":\(num(low1)),"altitudeLow2":\(num(low2)),
         "movementDir":\(num(dir)),"movementSpd":\(num(spd)),"severity":\(num(severity)),
         "rawAirSigmet":"MKCC WST 040055\\nCONVECTIVE SIGMET \(series)\\nMOV FROM 21045KT.",
         "coords":\(coords)}
        """
    }

    // MARK: A whole record

    func testAGoodRecordMapsEveryFieldTheAlertNeeds() throws {
        let cells = ConvectiveSigmetParser.cells(json(record()))
        XCTAssertEqual(cells.count, 1)
        let c = try XCTUnwrap(cells.first)
        XCTAssertEqual(c.id, "WST-1C")
        XCTAssertEqual(c.label, "Convective SIGMET 1C")
        XCTAssertEqual(c.polygon.count, 5)
        XCTAssertEqual(c.polygon.first?.lat ?? 0, 40.233, accuracy: 1e-6)
        XCTAssertEqual(c.polygon.first?.lon ?? 0, -90.08, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(c.topsFtMSL), 38_000, accuracy: 1e-9)
        XCTAssertNil(c.baseFtMSL, "a null low altitude means surface, not zero-as-a-number")
        XCTAssertEqual(try XCTUnwrap(c.movingFromDeg), 210, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(c.motionKt), 45, accuracy: 1e-9)
        XCTAssertEqual(c.observedAt, Date(timeIntervalSince1970: Double(issued)))
        XCTAssertEqual(c.validUntil, Date(timeIntervalSince1970: Double(expires)))
        XCTAssertEqual(c.severity, 5)
    }

    /// ⚠️ The field is "MOV **FROM**", so the direction the storm travels is the reciprocal. This is the
    /// parse-side half of the assertion that `ConvectiveAlertTests` makes behaviourally.
    func testTheMotionFieldIsReadAsAFromDirection() throws {
        let c = try XCTUnwrap(ConvectiveSigmetParser.cells(json(record(dir: 210))).first)
        XCTAssertEqual(try XCTUnwrap(c.movingFromDeg), 210, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(c.movingTowardDeg), 30, accuracy: 1e-9,
                       "a storm reported as FROM 210 is travelling TOWARD 030")
    }

    // MARK: The altitude pair

    /// Tops take the HIGHER of the two and bases the LOWER, because a SIGMET area can state different
    /// altitudes at its two ends and the whole column has to be treated as hazardous.
    func testTopsTakeTheHigherOfThePairAndBasesTheLower() throws {
        let c = try XCTUnwrap(ConvectiveSigmetParser.cells(
            json(record(hi1: 28_000, hi2: 45_000, low1: 12_000, low2: 6_000))).first)
        XCTAssertEqual(try XCTUnwrap(c.topsFtMSL), 45_000, accuracy: 1e-9,
                       "averaging would invent an FL365 top that is wrong at both ends and too low at one")
        XCTAssertEqual(try XCTUnwrap(c.baseFtMSL), 6_000, accuracy: 1e-9)
    }

    func testOneStatedTopIsEnough() throws {
        let c = try XCTUnwrap(ConvectiveSigmetParser.cells(json(record(hi1: 41_000, hi2: nil))).first)
        XCTAssertEqual(try XCTUnwrap(c.topsFtMSL), 41_000, accuracy: 1e-9)
    }

    /// No stated tops at all is left nil rather than defaulted, so the alert can apply its
    /// fail-toward-warning rule instead of being handed a number nobody published.
    func testNoStatedTopsStaysNil() throws {
        let c = try XCTUnwrap(ConvectiveSigmetParser.cells(json(record(hi1: nil, hi2: nil))).first)
        XCTAssertNil(c.topsFtMSL)
        XCTAssertEqual(ConvectiveAlert.verticalRelation(cell: c, altitudeFtMSL: 41_000), .topsUnknown)
    }

    // MARK: What gets dropped

    func testANonConvectiveHazardIsRejected() {
        XCTAssertTrue(ConvectiveSigmetParser.cells(json(record(hazard: "ICING"))).isEmpty,
                      "icing tops are not thunderstorm tops, whatever the query asked for")
    }

    /// Without an issue time there is no way to age the motion vector, and an un-aged vector is the one
    /// thing this alert must never extrapolate from.
    func testARecordWithNoIssueTimeIsRejected() {
        XCTAssertTrue(ConvectiveSigmetParser.cells(json(record(nullFrom: true))).isEmpty)
    }

    /// ⚠️ WHERE THE RECENCY JUDGEMENT LIVES, and it is not here.
    ///
    /// The parser has no clock, deliberately — it validates STRUCTURE so it can stay pure and be tested
    /// without one. A structurally valid bulletin stamped 1970 therefore parses, and it is
    /// `ConvectiveAlert.expiredGraceMinutes` that throws it out, because that is the layer holding the
    /// clock. The first draft of this test asserted the parser rejected an issue time of 0, which it does
    /// not and should not: 0 is a perfectly valid epoch, just a very old one.
    func testAnAbsurdlyOldBulletinIsDroppedByTheAlertNotTheParser() throws {
        let c = try XCTUnwrap(ConvectiveSigmetParser.cells(json(record(from: 0, to: 7_200))).first,
                              "structurally valid, so the parser keeps it")
        let own = ConvectiveOwnship(position: Coord(lat: 0, lon: 0), altitudeFtMSL: 30_000,
                                    trackDeg: 90, groundSpeedKt: 300)
        XCTAssertNil(ConvectiveAlert.threat(cell: c, ownship: own, now: Date()),
                     "and the alert drops it, because its validity lapsed decades ago")
    }

    func testARecordWhoseValidityRunsBackwardsIsRejected() {
        XCTAssertTrue(ConvectiveSigmetParser.cells(
            json(record(from: expires, to: issued))).isEmpty)
    }

    func testAPolygonTooSmallToMeasureIsRejected() {
        XCTAssertTrue(ConvectiveSigmetParser.cells(
            json(record(coords: #"[{"lon":-90.0,"lat":40.0}]"#))).isEmpty)
        XCTAssertTrue(ConvectiveSigmetParser.cells(json(record(coords: "[]"))).isEmpty)
    }

    /// A two-point "LINE TS" is kept, and measured as a segment rather than as a point.
    func testATwoPointLineIsKeptAndMeasuredAsALine() throws {
        let c = try XCTUnwrap(ConvectiveSigmetParser.cells(json(record(
            coords: #"[{"lon":-1.0,"lat":0.0},{"lon":1.0,"lat":0.0}]"#))).first)
        XCTAssertEqual(c.polygon.count, 2)
        // Abeam the middle of the line, 60 NM north of it. Measured to the first vertex instead, this
        // would read as 84 NM and under-warn.
        XCTAssertEqual(ConvectiveAlert.distanceNm(from: Coord(lat: 1, lon: 0), toPolygon: c.polygon),
                       60, accuracy: 1.0)
    }

    /// One malformed record must not take the snapshot with it.
    func testAMalformedRecordIsDroppedWithoutLosingTheGoodOnes() {
        let mixed = "\(record(series: "1C")), {\"seriesId\": }, \(record(series: "2C"))"
        // A syntactically broken array cannot be recovered at all, so the realistic case is a record
        // whose FIELDS are wrong rather than whose JSON is: a string where a number belongs.
        XCTAssertTrue(ConvectiveSigmetParser.cells(json(mixed)).isEmpty,
                      "invalid JSON yields nothing rather than a partial guess")

        let typeMismatch = """
        \(record(series: "1C")),
        {"seriesId":"BAD","hazard":"CONVECTIVE","validTimeFrom":"not-a-number","validTimeTo":1,
         "coords":[{"lon":-90.0,"lat":40.0},{"lon":-89.0,"lat":40.0},{"lon":-89.0,"lat":41.0}]},
        \(record(series: "2C"))
        """
        let cells = ConvectiveSigmetParser.cells(json(typeMismatch))
        XCTAssertEqual(cells.map(\.id), ["WST-1C", "WST-2C"],
                       "the bad record is dropped; the two good ones survive")
    }

    func testAnEmptyFeedIsAnEmptyList() {
        XCTAssertTrue(ConvectiveSigmetParser.cells(json("")).isEmpty)
        XCTAssertTrue(ConvectiveSigmetParser.cells(Data()).isEmpty)
        XCTAssertTrue(ConvectiveSigmetParser.cells(Data("not json at all".utf8)).isEmpty)
    }

    // MARK: Bounds

    func testTheSnapshotIsBoundedForTheAlertsLoops() {
        let many = (0..<(ConvectiveAlert.maxCells + 20))
            .map { record(series: "\($0)C") }.joined(separator: ",")
        XCTAssertEqual(ConvectiveSigmetParser.cells(json(many)).count, ConvectiveAlert.maxCells)
    }

    func testAnOverlongPolygonIsClamped() {
        let pts = (0..<(ConvectiveAlert.maxVertices + 30))
            .map { #"{"lon":\#(-100 + Double($0) * 0.1),"lat":40.0}"# }.joined(separator: ",")
        let c = ConvectiveSigmetParser.cells(json(record(coords: "[\(pts)]"))).first
        XCTAssertEqual(c?.polygon.count, ConvectiveAlert.maxVertices)
    }

    // MARK: The dismiss key

    /// ⚠️ Series numbers recycle hourly. The dismiss key must therefore change when the bulletin is
    /// reissued, or one tap mutes that series for the rest of the session.
    func testTheDismissKeyChangesWhenTheSameSeriesIsReissued() throws {
        let noon = try XCTUnwrap(ConvectiveSigmetParser.cells(json(record(series: "1C"))).first)
        let later = try XCTUnwrap(ConvectiveSigmetParser.cells(
            json(record(series: "1C", from: issued + 3_600, to: expires + 3_600))).first)
        XCTAssertEqual(noon.id, later.id, "same series number")
        XCTAssertNotEqual(noon.dismissKey, later.dismissKey,
                          "but a different storm, so dismissing the first must not mute the second")
    }
}
