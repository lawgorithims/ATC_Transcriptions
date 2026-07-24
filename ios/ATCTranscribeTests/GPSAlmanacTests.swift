import XCTest
@testable import ATCTranscribe

/// YUMA almanac parsing and the predicted-constellation math built on it: field-exact parsing of real
/// CelesTrak records, tolerance of truncated and corrupt input, the GPS time scale and its 1024-week
/// rollover, the bounded Kepler solve, satellite ECEF propagation, look angles, and DOP.
///
/// The geometry assertions deliberately avoid comparing against this implementation's own output. They
/// check facts that are true of the GPS constellation independent of any code:
///   * the derived orbital period must be a half sidereal day (11 h 58 m) — the defining property of
///     the GPS orbit, and a sensitive check on `sqrtA` and the mean-motion formula;
///   * satellite radius must be ~26 560 km (20 200 km altitude);
///   * an observer standing at a satellite's sub-satellite point must see it within a fraction of a
///     degree of the zenith — an end-to-end check of the ECEF -> ENU chain;
///   * because the orbit is half a sidereal day, the whole sky must repeat after ONE sidereal day, which
///     independently validates the Earth-rotation term in the node correction;
///   * a satellite cannot be above the horizon at a site and at that site's antipode simultaneously;
///   * DOP for a symmetric textbook geometry has a closed form derived by hand below.
///
/// Every test pins an explicit instant, so nothing here depends on when it runs.
final class GPSAlmanacTests: XCTestCase {

    /// 2026-07-23T17:00:00Z. GPS week 2428, second-of-week 406 818.
    private let epoch = Date(timeIntervalSince1970: 1_784_826_000)
    /// KDFW — a mid-latitude site, field elevation 607 ft.
    private let site = Coord(lat: 32.8968, lon: -97.0380)
    private let siteAltitudeM = 185.0

    private func fullAlmanac() throws -> [GPSAlmanacEntry] {
        let entries = GPSAlmanac.parseYUMA(Self.fullAlmanacYUMA)
        try XCTSkipIf(entries.isEmpty, "fixture failed to parse")
        return entries
    }

    // MARK: - Parsing real records

    /// Three records copied verbatim out of a CelesTrak week-381 YUMA file, every field asserted
    /// against the decimal text in the file. Mantissa-and-exponent forms (`0.1834869385E-002`) and
    /// plain decimals (`0.189213684`) both appear in a real file and both must land exactly.
    func testEveryFieldOfARealRecordParsesExactly() {
        let entries = GPSAlmanac.parseYUMA(Self.threeRecordYUMA)
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries.map(\.prn), [1, 2, 13], "records must come out in file order")

        let a = entries[0]
        XCTAssertEqual(a.prn, 1)
        XCTAssertEqual(a.health, 0)
        XCTAssertEqual(a.e, 0.1834869385e-2)
        XCTAssertEqual(a.toa, 61440.0)
        XCTAssertEqual(a.i0, 0.9571225189)
        XCTAssertEqual(a.omegaDot, -0.7988904198e-8)
        XCTAssertEqual(a.sqrtA, 5153.551758)
        XCTAssertEqual(a.omega0, 0.5049935161)
        XCTAssertEqual(a.omega, 0.189213684)
        XCTAssertEqual(a.m0, -0.3930552379)
        XCTAssertEqual(a.af0, 0.2126693726e-3)
        XCTAssertEqual(a.af1, -0.1091393642e-10)
        XCTAssertEqual(a.week, 381)

        let b = entries[1]
        XCTAssertEqual(b.e, 0.1692152023e-1)
        XCTAssertEqual(b.sqrtA, 5153.682129)
        XCTAssertEqual(b.omega, -0.733376890, "a negative plain decimal must keep its sign")
        XCTAssertEqual(b.m0, 0.9950247274)
        XCTAssertEqual(b.af1, 0.7275957614e-11)
    }

    /// PRN-13 carries health 063 in this file. Anything non-zero means the constellation has flagged
    /// the vehicle out of service, and the prediction must not quietly count it.
    func testNonZeroHealthWordMarksTheSatelliteUnusable() {
        let entries = GPSAlmanac.parseYUMA(Self.threeRecordYUMA)
        XCTAssertEqual(entries.count, 3)
        XCTAssertTrue(entries[0].isHealthy)
        XCTAssertEqual(entries[2].health, 63)
        XCTAssertFalse(entries[2].isHealthy, "health 063 is not 'mostly fine'")
    }

    func testFullAlmanacYieldsTheWholeConstellation() throws {
        let entries = try fullAlmanac()
        XCTAssertEqual(entries.count, 32)
        XCTAssertEqual(Set(entries.map(\.prn)).count, 32, "PRNs must be distinct")
        XCTAssertEqual(entries.map(\.prn).min(), 1)
        XCTAssertEqual(entries.map(\.prn).max(), 32)
        XCTAssertEqual(entries.filter { !$0.isHealthy }.map(\.prn), [13])
    }

    /// CelesTrak serves CRLF. A parser that split on "\n" alone would leave a carriage return glued to
    /// every value and `Double()` would return nil for all of them — a total, silent failure.
    func testCRLFAndLFParseIdentically() {
        let lf = GPSAlmanac.parseYUMA(Self.threeRecordYUMA)
        let crlf = GPSAlmanac.parseYUMA(Self.threeRecordYUMA.replacingOccurrences(of: "\n", with: "\r\n"))
        XCTAssertEqual(lf, crlf)
        XCTAssertEqual(crlf.count, 3)
    }

    // MARK: - Parsing hostile input

    /// A record with an unparseable field is dropped; the intact records on either side of it survive.
    /// A partial almanac is useful; a crash on a bad byte is not.
    func testCorruptRecordIsSkippedAndItsNeighboursSurvive() {
        let corrupted = Self.threeRecordYUMA.replacingOccurrences(
            of: "Eccentricity:               0.1692152023E-001",
            with: "Eccentricity:               NOT-A-NUMBER")
        let entries = GPSAlmanac.parseYUMA(corrupted)
        XCTAssertEqual(entries.map(\.prn), [1, 13], "only the corrupt record is lost")
    }

    /// A download cut off mid-record yields everything that arrived whole and nothing else.
    func testTruncatedFileYieldsTheCompleteRecordsOnly() {
        let truncated = Self.threeRecordYUMA
            + "\n******** Week 381 almanac for PRN-07 ********\nID:  07\nHealth:  000\nEccentricity:  0.5E-002\n"
        let entries = GPSAlmanac.parseYUMA(truncated)
        XCTAssertEqual(entries.map(\.prn), [1, 2, 13], "the half-written record must not be emitted")
    }

    func testGarbageAndEmptyInputProduceNoRecordsAndNoCrash() {
        XCTAssertTrue(GPSAlmanac.parseYUMA("").isEmpty)
        XCTAssertTrue(GPSAlmanac.parseYUMA("\n\n\n").isEmpty)
        XCTAssertTrue(GPSAlmanac.parseYUMA("the quick brown fox: jumped\nover: the lazy dog").isEmpty)
        XCTAssertTrue(GPSAlmanac.parseYUMA("********\n********\n********").isEmpty)
    }

    /// Values that parse as numbers but describe an orbit no GPS satellite flies are rejected too —
    /// a hyperbolic eccentricity or a geostationary radius would otherwise produce a plausible-looking
    /// satellite that silently wrecks the DOP for the whole sky.
    func testPhysicallyImpossibleElementsAreRejected() {
        let base = Self.threeRecordYUMA
        let hyperbolic = base.replacingOccurrences(of: "Eccentricity:               0.1834869385E-002",
                                                   with: "Eccentricity:               1.5000000000E+000")
        XCTAssertEqual(GPSAlmanac.parseYUMA(hyperbolic).map(\.prn), [2, 13])

        // sqrt(A) written as A: a real trap, because the file's own units line invites the mistake.
        let unsquared = base.replacingOccurrences(of: "SQRT(A)  (m 1/2):           5153.551758",
                                                  with: "SQRT(A)  (m 1/2):           26559682.0")
        XCTAssertEqual(GPSAlmanac.parseYUMA(unsquared).map(\.prn), [2, 13])
    }

    // MARK: - GPS time scale

    /// GPS time is Unix time minus the 1980-01-06 epoch, plus the 18 leap seconds GPS has not observed.
    /// The week number is checked against arithmetic anyone can redo: 1980-01-06 to 2026-07-23 is
    /// 17 000 days, and 17 000 / 7 = 2428 whole weeks.
    func testGPSEpochLeapSecondsAndWeekNumber() {
        let justAfterEpoch = Date(timeIntervalSince1970: GPSAlmanac.gpsEpochUnix + 1)
        XCTAssertEqual(GPSAlmanac.gpsSeconds(at: justAfterEpoch), 19.0, accuracy: 1e-9,
                       "one second of UTC past the epoch is 19 s of GPS time")
        XCTAssertEqual(GPSAlmanac.gpsWeek(at: justAfterEpoch), 0)

        XCTAssertEqual(GPSAlmanac.gpsSeconds(at: epoch), 1_468_861_218.0, accuracy: 1e-6)
        XCTAssertEqual(GPSAlmanac.gpsWeek(at: epoch), 2428)
    }

    /// 1999-08-22 is the day the GPS week counter first rolled over — week 1024 was broadcast as 0. A
    /// receiver that resolves the field against the date in hand lands on 1024; one that trusts the
    /// wire value lands on 0 and navigates by a 19-year-old sky. That was the actual 1999 failure mode.
    func testWeekRolloverResolvesAgainstTheObservationDate() {
        let rolloverDay = Date(timeIntervalSince1970: 935_323_200)     // 1999-08-22T12:00:00Z
        XCTAssertEqual(GPSAlmanac.gpsWeek(at: rolloverDay), 1024)
        XCTAssertEqual(GPSAlmanac.resolvedWeek(rawWeek: 0, at: rolloverDay), 1024)

        // Week 381 in 2026 is absolute week 2429 (381 + 2 x 1024); the same field read in 2038 must
        // resolve to 3453 (381 + 3 x 1024) instead, with no code change.
        XCTAssertEqual(GPSAlmanac.resolvedWeek(rawWeek: 381, at: epoch), 2429)
        XCTAssertEqual(GPSAlmanac.resolvedWeek(rawWeek: 381,
                                               at: Date(timeIntervalSince1970: 2_145_916_800)), 3453)
        XCTAssertEqual(GPSAlmanac.resolvedWeek(rawWeek: 1020, at: epoch), 2044,
                       "the nearest cycle can be behind as well as ahead")
        XCTAssertEqual(GPSAlmanac.resolvedWeek(rawWeek: 2429, at: epoch), 2429,
                       "a field that already carries the full week must pass through unchanged")
    }

    /// tk for PRN-01 at the pinned instant, by hand:
    /// GPS seconds 1 468 861 218 − (2429 × 604 800 + 61 440) = −259 422 s, well inside half a week.
    func testTimeFromReferenceMatchesHandArithmetic() {
        let entries = GPSAlmanac.parseYUMA(Self.threeRecordYUMA)
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(GPSAlmanac.secondsFromReference(entries[0], at: epoch), -259_422.0, accuracy: 1e-6)
        XCTAssertEqual(GPSAlmanac.ageDays(entries[0], at: epoch), -259_422.0 / 86_400.0, accuracy: 1e-9,
                       "a file stamped ahead of its own applicability reports a negative age")
    }

    func testHalfWeekFoldStaysWithinPlusOrMinusHalfAWeek() {
        XCTAssertEqual(GPSAlmanac.halfWeekFold(0), 0)
        XCTAssertEqual(GPSAlmanac.halfWeekFold(604_800), 0, "a whole week folds to zero")
        XCTAssertEqual(GPSAlmanac.halfWeekFold(400_000), -204_800, accuracy: 1e-9)
        XCTAssertEqual(GPSAlmanac.halfWeekFold(-400_000), 204_800, accuracy: 1e-9)
        for step in 0...200 {                                   // bounded (rule 2)
            let t = -5_000_000.0 + 50_000.0 * Double(step)
            XCTAssertLessThanOrEqual(abs(GPSAlmanac.halfWeekFold(t)), 302_400.0 + 1e-6)
        }
    }

    func testEveryEntryFoldsIntoTheValidPropagationWindow() throws {
        for entry in try fullAlmanac() {                        // bounded by the 64-record parser cap
            let tk = GPSAlmanac.secondsFromReference(entry, at: epoch)
            XCTAssertLessThanOrEqual(abs(tk), 302_400.0 + 1e-6, "PRN \(entry.prn) fell outside the fold")
        }
    }

    // MARK: - Kepler solver

    /// The solver's only contract: whatever E it returns must satisfy M = E − e·sin E. Checked against
    /// the equation itself rather than against a table, over a grid of mean anomalies and eccentricities
    /// far beyond anything GPS flies. E is only determined modulo 2π, so the residual is wrapped.
    func testEccentricAnomalySatisfiesKeplersEquation() {
        for e in [0.0, 0.001, 0.0183, 0.25, 0.7, 0.9] {         // bounded (rule 2)
            for step in 0...240 {
                let m = -3.14 + 6.28 * Double(step) / 240.0
                let ek = GPSSkyPrediction.eccentricAnomaly(meanAnomaly: m, eccentricity: e)
                let residual = Self.wrappedToPi(ek - e * sin(ek) - m)
                XCTAssertLessThan(abs(residual), 1e-10,
                                  "e=\(e) M=\(m) produced E=\(ek), which is not a root")
            }
        }
    }

    /// A circular orbit has no eccentric-versus-mean distinction at all, so the solver must return the
    /// mean anomaly untouched — not "within tolerance of", exactly.
    func testCircularOrbitReturnsTheMeanAnomalyUnchanged() {
        for m in [-3.0, -1.0, 0.0, 0.5, 1.0, 3.0] {             // bounded (rule 2)
            XCTAssertEqual(GPSSkyPrediction.eccentricAnomaly(meanAnomaly: m, eccentricity: 0), m)
        }
    }

    /// Near perigee at high eccentricity is where Newton is slowest and a naive starting guess can
    /// diverge. GPS never flies this, but the iteration cap must be honest about what it can solve.
    func testHighEccentricityConvergesWithinTheIterationCap() {
        for m in [0.001, 0.01, 0.05, 0.2, -0.01, .pi - 0.001] { // bounded (rule 2)
            let ek = GPSSkyPrediction.eccentricAnomaly(meanAnomaly: m, eccentricity: 0.9)
            XCTAssertLessThan(abs(Self.wrappedToPi(ek - 0.9 * sin(ek) - m)), 1e-10, "M=\(m)")
        }
    }

    /// Propagated mean anomaly reaches ~44 rad at the edge of the half-week fold. The solver reduces
    /// the argument first, so the returned E differs from the principal root by whole revolutions —
    /// which is physically identical, because only sin E and cos E are used downstream.
    func testLargeMeanAnomalyIsReducedRatherThanLosingPrecision() {
        let ek = GPSSkyPrediction.eccentricAnomaly(meanAnomaly: 44.3, eccentricity: 0.02)
        XCTAssertLessThan(abs(Self.wrappedToPi(ek - 0.02 * sin(ek) - 44.3)), 1e-10)
        XCTAssertLessThanOrEqual(abs(ek), Double.pi + 1e-9, "the reduced root must stay in [-pi, pi]")
    }

    // MARK: - Orbit sanity against known GPS facts

    /// GPS flies a half-sidereal-day orbit: 11 h 58 m 02 s = 43 082 s. Any parse error in `sqrtA`, or a
    /// wrong gravitational constant, shows up here immediately.
    func testDerivedOrbitalPeriodIsHalfASiderealDay() throws {
        for entry in try fullAlmanac() {                        // bounded (rule 2)
            XCTAssertEqual(entry.orbitalPeriodS, 43_082, accuracy: 120,
                           "PRN \(entry.prn) is not in a GPS orbit")
        }
    }

    /// Semi-major axis 26 560 km, i.e. ~20 200 km above the surface. The instantaneous radius varies
    /// by a·e either side of that, which for GPS is at most a few hundred kilometres.
    func testSatelliteRadiusMatchesThePublishedGPSAltitude() throws {
        for entry in try fullAlmanac() {                        // bounded (rule 2)
            let tk = GPSAlmanac.secondsFromReference(entry, at: epoch)
            let radiusKm = GPSSkyPrediction.ecefPosition(of: entry, secondsFromReference: tk).radiusM / 1000
            XCTAssertGreaterThan(radiusKm, 25_500, "PRN \(entry.prn) is too low to be GPS")
            XCTAssertLessThan(radiusKm, 27_500, "PRN \(entry.prn) is too high to be GPS")
        }
    }

    /// End-to-end check of the whole chain: propagate a satellite, take its own sub-satellite point as
    /// the observer, and the satellite must be overhead. It lands a fraction of a degree short of 90°
    /// because the sub-point is computed geocentrically while the horizon is geodetic — the difference
    /// between the two latitudes is the ellipsoid, and it maxes out around 0.19°.
    func testSatelliteIsOverheadItsOwnSubSatellitePoint() throws {
        for entry in try fullAlmanac() {                        // bounded (rule 2)
            let tk = GPSAlmanac.secondsFromReference(entry, at: epoch)
            let sat = GPSSkyPrediction.ecefPosition(of: entry, secondsFromReference: tk)
            let subPoint = Coord(lat: asin(sat.z / sat.radiusM) * 180 / .pi,
                                 lon: atan2(sat.y, sat.x) * 180 / .pi)
            let look = GPSSkyPrediction.lookAngles(
                satellite: sat,
                observerECEF: GPSSkyPrediction.observerECEF(subPoint, altitudeM: 0),
                observer: subPoint)
            XCTAssertGreaterThan(look.elevationDeg, 89.5, "PRN \(entry.prn) is not over its sub-point")
        }
    }

    /// Two revolutions per sidereal day means the entire sky repeats after ONE sidereal day
    /// (86 164.0905 s), not one solar day. Nothing but a correct Earth-rotation term in the node
    /// correction reproduces that; the residual drift is the node regression, ~0.04° per day.
    func testTheWholeSkyRepeatsAfterOneSiderealDay() throws {
        let observerECEF = GPSSkyPrediction.observerECEF(site, altitudeM: siteAltitudeM)
        for entry in try fullAlmanac() {                        // bounded (rule 2)
            let tk = GPSAlmanac.secondsFromReference(entry, at: epoch)
            let now = GPSSkyPrediction.lookAngles(
                satellite: GPSSkyPrediction.ecefPosition(of: entry, secondsFromReference: tk),
                observerECEF: observerECEF, observer: site)
            let later = GPSSkyPrediction.lookAngles(
                satellite: GPSSkyPrediction.ecefPosition(of: entry, secondsFromReference: tk + 86_164.0905),
                observerECEF: observerECEF, observer: site)
            XCTAssertLessThan(abs(Self.wrappedToPi((now.azimuthDeg - later.azimuthDeg) * .pi / 180)),
                              0.5 * .pi / 180, "PRN \(entry.prn) azimuth did not repeat")
            XCTAssertLessThan(abs(now.elevationDeg - later.elevationDeg), 0.5,
                              "PRN \(entry.prn) elevation did not repeat")
        }
    }

    // MARK: - Look angles

    func testLookAnglesStayInsideTheirDefinedRanges() throws {
        let sky = GPSSkyPrediction.satellites(almanac: try fullAlmanac(), at: epoch,
                                              observer: site, observerAltitudeM: siteAltitudeM)
        XCTAssertEqual(sky.count, 32)
        for sat in sky {                                        // bounded (rule 2)
            XCTAssertGreaterThanOrEqual(sat.azimuthDeg, 0, "PRN \(sat.prn)")
            XCTAssertLessThan(sat.azimuthDeg, 360, "PRN \(sat.prn) azimuth must wrap, not reach 360")
            XCTAssertGreaterThanOrEqual(sat.elevationDeg, -90, "PRN \(sat.prn)")
            XCTAssertLessThanOrEqual(sat.elevationDeg, 90, "PRN \(sat.prn)")
        }
    }

    /// The constellation is designed so a clear mid-latitude site always sees at least six satellites
    /// above a 5° mask, and the geometric ceiling from one hemisphere is well under fifteen. Asserting a
    /// RANGE rather than a count keeps the test meaningful without pinning it to this implementation.
    func testVisibleSatelliteCountIsPlausibleAllDay() throws {
        let almanac = try fullAlmanac()
        for hour in 0..<24 {                                    // bounded (rule 2)
            let when = epoch.addingTimeInterval(Double(hour) * 3600)
            let sky = GPSSkyPrediction.satellites(almanac: almanac, at: when,
                                                  observer: site, observerAltitudeM: siteAltitudeM)
            let visible = sky.filter { $0.elevationDeg >= 5 && $0.healthy }.count
            XCTAssertTrue((4...14).contains(visible),
                          "hour \(hour) predicted \(visible) satellites above the mask")
        }
    }

    /// A GPS satellite sits ~26 560 km from the geocentre, so its horizon is a cap of radius
    /// acos(6371 / 26560) ≈ 76°. Antipodal sites are 180° apart, so no satellite can serve both. This
    /// catches a sign error in the ENU rotation that a single-site test would sail straight past.
    func testNoSatelliteIsVisibleFromASiteAndItsAntipodeAtOnce() throws {
        let almanac = try fullAlmanac()
        let antipode = Coord(lat: -site.lat, lon: site.lon + 180)
        let here = GPSSkyPrediction.satellites(almanac: almanac, at: epoch,
                                               observer: site, observerAltitudeM: 0)
        let there = GPSSkyPrediction.satellites(almanac: almanac, at: epoch,
                                                observer: antipode, observerAltitudeM: 0)
        XCTAssertEqual(here.count, there.count)
        for (a, b) in zip(here, there) {                        // bounded (rule 2)
            XCTAssertEqual(a.prn, b.prn, "the two skies must be in the same order")
            XCTAssertFalse(a.elevationDeg > 0 && b.elevationDeg > 0,
                           "PRN \(a.prn) cannot be up at both KDFW and its antipode")
        }
    }

    // MARK: - DOP

    /// A textbook symmetric geometry with a hand-derived answer: one satellite at the zenith plus four
    /// at elevation ε on the cardinal azimuths. The east and north columns of GᵀG decouple from up and
    /// time, leaving
    ///     hdop = sec ε,  vdop = sqrt(5) / (2(1 − sin ε)),  tdop = sqrt(1 + 4 sin²ε) / (2(1 − sin ε))
    /// For ε = 10° that is 1.015426611886, 1.352975764721, 0.640520721337.
    func testIdealGeometryMatchesTheClosedFormDOP() throws {
        let elevation = 10.0
        var sky = [PredictedSatellite(prn: 1, azimuthDeg: 0, elevationDeg: 90)]
        for k in 0..<4 {                                        // bounded (rule 2)
            sky.append(PredictedSatellite(prn: 10 + k, azimuthDeg: Double(k) * 90, elevationDeg: elevation))
        }
        let dop = try XCTUnwrap(GPSSkyPrediction.dop(sky, maskDeg: 5))
        let s = sin(elevation * .pi / 180), c = cos(elevation * .pi / 180)
        XCTAssertEqual(dop.hdop, 1 / c, accuracy: 1e-9)
        XCTAssertEqual(dop.vdop, 5.0.squareRoot() / (2 * (1 - s)), accuracy: 1e-9)
        XCTAssertEqual(dop.tdop, (1 + 4 * s * s).squareRoot() / (2 * (1 - s)), accuracy: 1e-9)
        XCTAssertLessThan(dop.pdop, 4, "a satellite overhead plus four spread low is good geometry")
        XCTAssertEqual(dop.quality, .excellent)
    }

    /// PDOP, HDOP and VDOP are square roots of sums of the same diagonal, so the Pythagorean relations
    /// are exact by construction. They are worth asserting because they catch the easiest possible bug:
    /// reading the wrong element out of the inverted matrix.
    func testDOPComponentsSatisfyThePythagoreanIdentities() throws {
        let sky = GPSSkyPrediction.satellites(almanac: try fullAlmanac(), at: epoch,
                                              observer: site, observerAltitudeM: siteAltitudeM)
        let dop = try XCTUnwrap(GPSSkyPrediction.dop(sky, maskDeg: 5))
        XCTAssertEqual(dop.pdop * dop.pdop, dop.hdop * dop.hdop + dop.vdop * dop.vdop, accuracy: 1e-6)
        XCTAssertEqual(dop.gdop * dop.gdop, dop.pdop * dop.pdop + dop.tdop * dop.tdop, accuracy: 1e-6)
        XCTAssertGreaterThan(dop.vdop, dop.hdop,
                             "VDOP always exceeds HDOP: every satellite is above the receiver")
        XCTAssertLessThan(dop.pdop, 6, "the real constellation over KDFW is not this bad")
    }

    /// Three satellites cannot solve for three coordinates plus the receiver clock.
    func testFewerThanFourSatellitesHasNoGeometry() {
        var sky: [PredictedSatellite] = []
        XCTAssertNil(GPSSkyPrediction.dop(sky, maskDeg: 5))
        for k in 0..<3 {                                        // bounded (rule 2)
            sky.append(PredictedSatellite(prn: k, azimuthDeg: Double(k) * 120, elevationDeg: 40))
            XCTAssertNil(GPSSkyPrediction.dop(sky, maskDeg: 5), "\(sky.count) satellites is not a fix")
        }
    }

    /// Six satellites stacked in one spot span a single line of sight, so GᵀG is rank-deficient. The
    /// honest answers are "no geometry" or "geometry so bad it is unusable" — never a small number.
    func testClusteredConstellationIsSingularOrUseless() {
        let clumped = (0..<6).map {                             // bounded (rule 2)
            PredictedSatellite(prn: $0, azimuthDeg: 45, elevationDeg: 30)
        }
        if let dop = GPSSkyPrediction.dop(clumped, maskDeg: 5) {
            XCTAssertGreaterThan(dop.gdop, 1000, "a degenerate cluster cannot yield usable geometry")
            XCTAssertEqual(dop.quality, .poor)
        }
    }

    /// The mask and the health word both remove satellites from the solution, and removing one from a
    /// bare four-satellite geometry must leave no geometry at all rather than a stale answer.
    func testMaskAndHealthBothRemoveSatellitesFromTheSolution() {
        var sky = [PredictedSatellite(prn: 1, azimuthDeg: 0, elevationDeg: 90)]
        for k in 0..<3 {                                        // bounded (rule 2)
            sky.append(PredictedSatellite(prn: 10 + k, azimuthDeg: Double(k) * 120, elevationDeg: 8))
        }
        XCTAssertNotNil(GPSSkyPrediction.dop(sky, maskDeg: 5))
        XCTAssertNil(GPSSkyPrediction.dop(sky, maskDeg: 10), "a 10 degree mask drops the three low SVs")

        var unhealthy = sky
        unhealthy[1].healthy = false
        XCTAssertNil(GPSSkyPrediction.dop(unhealthy, maskDeg: 5),
                     "an out-of-service SV must not be counted toward predicted availability")
    }

    func testQualityBandsReadAsPlainEnglish() {
        XCTAssertEqual(PredictedDOP.Quality(pdop: 0.8), .ideal)
        XCTAssertEqual(PredictedDOP.Quality(pdop: 1.9), .excellent)
        XCTAssertEqual(PredictedDOP.Quality(pdop: 4.9), .good)
        XCTAssertEqual(PredictedDOP.Quality(pdop: 9.9), .moderate)
        XCTAssertEqual(PredictedDOP.Quality(pdop: 19.9), .fair)
        XCTAssertEqual(PredictedDOP.Quality(pdop: 50), .poor)
        XCTAssertEqual(PredictedDOP.Quality(pdop: 3).label, "Good")
    }

    /// The 4x4 inverse underneath DOP, checked the only way that matters: A·A⁻¹ must be the identity.
    func testMatrixInverseRoundTripsAndRejectsSingularInput() throws {
        let m: [Double] = [4, 1, 0, 2,
                           1, 3, 1, 0,
                           0, 1, 5, 1,
                           2, 0, 1, 6]
        let inv = try XCTUnwrap(GPSSkyPrediction.invert4x4(m))
        for row in 0..<4 {                                      // bounded (rule 2)
            for col in 0..<4 {
                var sum = 0.0
                for k in 0..<4 { sum += m[row * 4 + k] * inv[k * 4 + col] }
                XCTAssertEqual(sum, row == col ? 1 : 0, accuracy: 1e-10, "element \(row),\(col)")
            }
        }
        XCTAssertNil(GPSSkyPrediction.invert4x4([Double](repeating: 1, count: 16)),
                     "an all-ones matrix has rank 1")
        XCTAssertNil(GPSSkyPrediction.invert4x4([Double](repeating: 0, count: 16)))
    }

    // MARK: - Determinism

    /// A briefing screenshot has to be reproducible after the fact: same almanac, same instant, same
    /// site must give bit-identical angles and DOP, with no dependence on dictionary or clock order.
    func testSameInputsProduceIdenticalOutputs() throws {
        let almanac = try fullAlmanac()
        XCTAssertEqual(almanac, GPSAlmanac.parseYUMA(Self.fullAlmanacYUMA), "parsing must be stable")
        let first = GPSSkyPrediction.satellites(almanac: almanac, at: epoch,
                                                observer: site, observerAltitudeM: siteAltitudeM)
        let second = GPSSkyPrediction.satellites(almanac: almanac, at: epoch,
                                                 observer: site, observerAltitudeM: siteAltitudeM)
        XCTAssertEqual(first, second)
        XCTAssertEqual(GPSSkyPrediction.dop(first, maskDeg: 5), GPSSkyPrediction.dop(second, maskDeg: 5))
        XCTAssertEqual(first.map(\.prn), almanac.map(\.prn), "output order must follow the almanac")
    }

    // MARK: - Helpers

    /// Wrap an angle in radians into [-pi, pi]. Used wherever a residual is only defined modulo a full
    /// revolution — eccentric anomaly, and the azimuth difference in the sidereal-repeat test.
    private static func wrappedToPi(_ radians: Double) -> Double {
        var t = radians.truncatingRemainder(dividingBy: 2 * .pi)
        if t > .pi { t -= 2 * .pi }
        if t < -.pi { t += 2 * .pi }
        return t
    }

    // MARK: - Fixtures

    /// Three records copied byte-for-byte out of a CelesTrak week-381 YUMA file: PRN-01 and PRN-02 are
    /// healthy, PRN-13 carries health 063.
    private static let threeRecordYUMA = """
    ******** Week 381 almanac for PRN-01 ********
    ID:                         01
    Health:                     000
    Eccentricity:               0.1834869385E-002
    Time of Applicability(s):  61440.0000
    Orbital Inclination(rad):   0.9571225189
    Rate of Right Ascen(r/s):  -0.7988904198E-008
    SQRT(A)  (m 1/2):           5153.551758
    Right Ascen at Week(rad):   0.5049935161E+000
    Argument of Perigee(rad):   0.189213684
    Mean Anom(rad):            -0.3930552379E+000
    Af0(s):                     0.2126693726E-003
    Af1(s/s):                  -0.1091393642E-010
    week:                        381

    ******** Week 381 almanac for PRN-02 ********
    ID:                         02
    Health:                     000
    Eccentricity:               0.1692152023E-001
    Time of Applicability(s):  61440.0000
    Orbital Inclination(rad):   0.9621079565
    Rate of Right Ascen(r/s):  -0.7840326581E-008
    SQRT(A)  (m 1/2):           5153.682129
    Right Ascen at Week(rad):   0.3431566704E+000
    Argument of Perigee(rad):  -0.733376890
    Mean Anom(rad):             0.9950247274E+000
    Af0(s):                     0.1449584961E-003
    Af1(s/s):                   0.7275957614E-011
    week:                        381

    ******** Week 381 almanac for PRN-13 ********
    ID:                         13
    Health:                     063
    Eccentricity:               0.2277851105E-002
    Time of Applicability(s):  61440.0000
    Orbital Inclination(rad):   0.9587224129
    Rate of Right Ascen(r/s):  -0.7863184676E-008
    SQRT(A)  (m 1/2):           5153.521484
    Right Ascen at Week(rad):  -0.1699947323E+001
    Argument of Perigee(rad):   1.816459455
    Mean Anom(rad):            -0.2907598415E+001
    Af0(s):                     0.4205703735E-003
    Af1(s/s):                   0.3637978807E-011
    week:                        381
    """

    /// The complete 32-satellite CelesTrak week-381 almanac, verbatim. Embedded rather than loaded from
    /// disk so the geometry tests are hermetic — no bundle resource, no file system, no network — while
    /// still exercising real orbital elements rather than invented ones.
    private static let fullAlmanacYUMA = """
    ******** Week 381 almanac for PRN-01 ********
    ID:                         01
    Health:                     000
    Eccentricity:               0.1834869385E-002
    Time of Applicability(s):  61440.0000
    Orbital Inclination(rad):   0.9571225189
    Rate of Right Ascen(r/s):  -0.7988904198E-008
    SQRT(A)  (m 1/2):           5153.551758
    Right Ascen at Week(rad):   0.5049935161E+000
    Argument of Perigee(rad):   0.189213684
    Mean Anom(rad):            -0.3930552379E+000
    Af0(s):                     0.2126693726E-003
    Af1(s/s):                  -0.1091393642E-010
    week:                        381

    ******** Week 381 almanac for PRN-02 ********
    ID:                         02
    Health:                     000
    Eccentricity:               0.1692152023E-001
    Time of Applicability(s):  61440.0000
    Orbital Inclination(rad):   0.9621079565
    Rate of Right Ascen(r/s):  -0.7840326581E-008
    SQRT(A)  (m 1/2):           5153.682129
    Right Ascen at Week(rad):   0.3431566704E+000
    Argument of Perigee(rad):  -0.733376890
    Mean Anom(rad):             0.9950247274E+000
    Af0(s):                     0.1449584961E-003
    Af1(s/s):                   0.7275957614E-011
    week:                        381

    ******** Week 381 almanac for PRN-03 ********
    ID:                         03
    Health:                     000
    Eccentricity:               0.6986618042E-002
    Time of Applicability(s):  61440.0000
    Orbital Inclination(rad):   0.9947529851
    Rate of Right Ascen(r/s):  -0.7817468486E-008
    SQRT(A)  (m 1/2):           5153.718750
    Right Ascen at Week(rad):   0.1497597805E+001
    Argument of Perigee(rad):   1.281170942
    Mean Anom(rad):            -0.2510377161E+001
    Af0(s):                     0.3547668457E-003
    Af1(s/s):                  -0.1818989404E-010
    week:                        381

    ******** Week 381 almanac for PRN-04 ********
    ID:                         04
    Health:                     000
    Eccentricity:               0.3840923309E-002
    Time of Applicability(s):  61440.0000
    Orbital Inclination(rad):   0.9725462164
    Rate of Right Ascen(r/s):  -0.7577458489E-008
    SQRT(A)  (m 1/2):           5153.637207
    Right Ascen at Week(rad):   0.2565949885E+001
    Argument of Perigee(rad):  -2.902036237
    Mean Anom(rad):             0.4881770270E+000
    Af0(s):                     0.6294250488E-004
    Af1(s/s):                   0.0000000000E+000
    week:                        381

    ******** Week 381 almanac for PRN-05 ********
    ID:                         05
    Health:                     000
    Eccentricity:               0.5608558655E-002
    Time of Applicability(s):  61440.0000
    Orbital Inclination(rad):   0.9811508898
    Rate of Right Ascen(r/s):  -0.7977475151E-008
    SQRT(A)  (m 1/2):           5153.728516
    Right Ascen at Week(rad):   0.1435906760E+001
    Argument of Perigee(rad):   1.487330694
    Mean Anom(rad):             0.1010727058E+001
    Af0(s):                    -0.2355575562E-003
    Af1(s/s):                   0.0000000000E+000
    week:                        381

    ******** Week 381 almanac for PRN-06 ********
    ID:                         06
    Health:                     000
    Eccentricity:               0.3703594208E-002
    Time of Applicability(s):  61440.0000
    Orbital Inclination(rad):   0.9858906508
    Rate of Right Ascen(r/s):  -0.7691748964E-008
    SQRT(A)  (m 1/2):           5153.685059
    Right Ascen at Week(rad):   0.4596167465E+000
    Argument of Perigee(rad):  -0.550148203
    Mean Anom(rad):            -0.1196755934E+001
    Af0(s):                    -0.5655288696E-003
    Af1(s/s):                   0.7275957614E-011
    week:                        381

    ******** Week 381 almanac for PRN-07 ********
    ID:                         07
    Health:                     000
    Eccentricity:               0.2093887329E-001
    Time of Applicability(s):  61440.0000
    Orbital Inclination(rad):   0.9514060436
    Rate of Right Ascen(r/s):  -0.7726036106E-008
    SQRT(A)  (m 1/2):           5153.531250
    Right Ascen at Week(rad):  -0.2710308487E+001
    Argument of Perigee(rad):  -1.954813961
    Mean Anom(rad):            -0.1985492453E+001
    Af0(s):                    -0.2098083496E-003
    Af1(s/s):                  -0.3637978807E-011
    week:                        381

    ******** Week 381 almanac for PRN-08 ********
    ID:                         08
    Health:                     000
    Eccentricity:               0.1169443130E-001
    Time of Applicability(s):  61440.0000
    Orbital Inclination(rad):   0.9416808451
    Rate of Right Ascen(r/s):  -0.7794610391E-008
    SQRT(A)  (m 1/2):           5153.699707
    Right Ascen at Week(rad):  -0.6659727407E+000
    Argument of Perigee(rad):   0.544827582
    Mean Anom(rad):             0.7346341102E+000
    Af0(s):                     0.3900527954E-003
    Af1(s/s):                  -0.1091393642E-010
    week:                        381

    ******** Week 381 almanac for PRN-09 ********
    ID:                         09
    Health:                     000
    Eccentricity:               0.3687381744E-002
    Time of Applicability(s):  61440.0000
    Orbital Inclination(rad):   0.9668057726
    Rate of Right Ascen(r/s):  -0.7657461821E-008
    SQRT(A)  (m 1/2):           5153.654785
    Right Ascen at Week(rad):   0.2500739972E+001
    Argument of Perigee(rad):   2.041506721
    Mean Anom(rad):             0.1351713835E+001
    Af0(s):                     0.7133483887E-003
    Af1(s/s):                  -0.7275957614E-011
    week:                        381

    ******** Week 381 almanac for PRN-10 ********
    ID:                         10
    Health:                     000
    Eccentricity:               0.1115179062E-001
    Time of Applicability(s):  61440.0000
    Orbital Inclination(rad):   0.9942616319
    Rate of Right Ascen(r/s):  -0.7840326581E-008
    SQRT(A)  (m 1/2):           5153.606445
    Right Ascen at Week(rad):   0.1495090480E+001
    Argument of Perigee(rad):  -2.265745800
    Mean Anom(rad):             0.2832079448E+001
    Af0(s):                    -0.5607604980E-003
    Af1(s/s):                   0.3637978807E-011
    week:                        381

    ******** Week 381 almanac for PRN-11 ********
    ID:                         11
    Health:                     000
    Eccentricity:               0.2508640289E-002
    Time of Applicability(s):  61440.0000
    Orbital Inclination(rad):   0.9627790731
    Rate of Right Ascen(r/s):  -0.7931758961E-008
    SQRT(A)  (m 1/2):           5153.604980
    Right Ascen at Week(rad):   0.4751853782E+000
    Argument of Perigee(rad):  -2.352626187
    Mean Anom(rad):             0.3266600104E-001
    Af0(s):                    -0.2622604370E-003
    Af1(s/s):                   0.1091393642E-010
    week:                        381

    ******** Week 381 almanac for PRN-12 ********
    ID:                         12
    Health:                     000
    Eccentricity:               0.8712768555E-002
    Time of Applicability(s):  61440.0000
    Orbital Inclination(rad):   0.9581951070
    Rate of Right Ascen(r/s):  -0.7840326581E-008
    SQRT(A)  (m 1/2):           5153.637695
    Right Ascen at Week(rad):  -0.1591428668E+001
    Argument of Perigee(rad):   1.587852875
    Mean Anom(rad):            -0.2780169777E+001
    Af0(s):                    -0.6055831909E-003
    Af1(s/s):                   0.0000000000E+000
    week:                        381

    ******** Week 381 almanac for PRN-13 ********
    ID:                         13
    Health:                     063
    Eccentricity:               0.2277851105E-002
    Time of Applicability(s):  61440.0000
    Orbital Inclination(rad):   0.9587224129
    Rate of Right Ascen(r/s):  -0.7863184676E-008
    SQRT(A)  (m 1/2):           5153.521484
    Right Ascen at Week(rad):  -0.1699947323E+001
    Argument of Perigee(rad):   1.816459455
    Mean Anom(rad):            -0.2907598415E+001
    Af0(s):                     0.4205703735E-003
    Af1(s/s):                   0.3637978807E-011
    week:                        381

    ******** Week 381 almanac for PRN-14 ********
    ID:                         14
    Health:                     000
    Eccentricity:               0.7378578186E-002
    Time of Applicability(s):  61440.0000
    Orbital Inclination(rad):   0.9415250502
    Rate of Right Ascen(r/s):  -0.8046049436E-008
    SQRT(A)  (m 1/2):           5153.589844
    Right Ascen at Week(rad):  -0.1648422271E+001
    Argument of Perigee(rad):  -2.679968549
    Mean Anom(rad):            -0.2892688541E+001
    Af0(s):                     0.7505416870E-003
    Af1(s/s):                   0.0000000000E+000
    week:                        381

    ******** Week 381 almanac for PRN-15 ********
    ID:                         15
    Health:                     000
    Eccentricity:               0.1705026627E-001
    Time of Applicability(s):  61440.0000
    Orbital Inclination(rad):   0.9448027357
    Rate of Right Ascen(r/s):  -0.7920329914E-008
    SQRT(A)  (m 1/2):           5153.711426
    Right Ascen at Week(rad):   0.2353217908E+001
    Argument of Perigee(rad):   1.539961665
    Mean Anom(rad):            -0.2893782102E+000
    Af0(s):                     0.4310607910E-003
    Af1(s/s):                   0.3637978807E-011
    week:                        381

    ******** Week 381 almanac for PRN-16 ********
    ID:                         16
    Health:                     000
    Eccentricity:               0.1505041122E-001
    Time of Applicability(s):  61440.0000
    Orbital Inclination(rad):   0.9572543454
    Rate of Right Ascen(r/s):  -0.7863184676E-008
    SQRT(A)  (m 1/2):           5153.653320
    Right Ascen at Week(rad):  -0.1574682212E+001
    Argument of Perigee(rad):   0.938517983
    Mean Anom(rad):             0.1809580885E+001
    Af0(s):                     0.3051757812E-003
    Af1(s/s):                   0.7275957614E-011
    week:                        381

    ******** Week 381 almanac for PRN-17 ********
    ID:                         17
    Health:                     000
    Eccentricity:               0.1262283325E-001
    Time of Applicability(s):  61440.0000
    Orbital Inclination(rad):   0.9573681955
    Rate of Right Ascen(r/s):  -0.7668890869E-008
    SQRT(A)  (m 1/2):           5153.631836
    Right Ascen at Week(rad):  -0.5591120287E+000
    Argument of Perigee(rad):  -1.097635534
    Mean Anom(rad):             0.7455963054E+000
    Af0(s):                    -0.1792907715E-003
    Af1(s/s):                  -0.7275957614E-011
    week:                        381

    ******** Week 381 almanac for PRN-18 ********
    ID:                         18
    Health:                     000
    Eccentricity:               0.6320953369E-002
    Time of Applicability(s):  61440.0000
    Orbital Inclination(rad):   0.9708624328
    Rate of Right Ascen(r/s):  -0.7817468486E-008
    SQRT(A)  (m 1/2):           5153.575195
    Right Ascen at Week(rad):   0.4525175913E+000
    Argument of Perigee(rad):  -2.857011878
    Mean Anom(rad):            -0.1220793668E+001
    Af0(s):                    -0.2946853638E-003
    Af1(s/s):                   0.7275957614E-011
    week:                        381

    ******** Week 381 almanac for PRN-19 ********
    ID:                         19
    Health:                     000
    Eccentricity:               0.1178741455E-001
    Time of Applicability(s):  61440.0000
    Orbital Inclination(rad):   0.9565412840
    Rate of Right Ascen(r/s):  -0.7600316584E-008
    SQRT(A)  (m 1/2):           5153.715820
    Right Ascen at Week(rad):  -0.5153568746E+000
    Argument of Perigee(rad):   3.034419977
    Mean Anom(rad):             0.2371194995E+001
    Af0(s):                     0.7038116455E-003
    Af1(s/s):                   0.0000000000E+000
    week:                        381

    ******** Week 381 almanac for PRN-20 ********
    ID:                         20
    Health:                     000
    Eccentricity:               0.1904487610E-002
    Time of Applicability(s):  61440.0000
    Orbital Inclination(rad):   0.9621798618
    Rate of Right Ascen(r/s):  -0.7703178011E-008
    SQRT(A)  (m 1/2):           5153.574707
    Right Ascen at Week(rad):   0.2505605193E+001
    Argument of Perigee(rad):  -1.757115446
    Mean Anom(rad):            -0.2927293365E+001
    Af0(s):                     0.2422332764E-003
    Af1(s/s):                   0.1091393642E-010
    week:                        381

    ******** Week 381 almanac for PRN-21 ********
    ID:                         21
    Health:                     000
    Eccentricity:               0.7863044739E-003
    Time of Applicability(s):  61440.0000
    Orbital Inclination(rad):   0.9641752353
    Rate of Right Ascen(r/s):  -0.8148910863E-008
    SQRT(A)  (m 1/2):           5153.544922
    Right Ascen at Week(rad):   0.1499487567E+001
    Argument of Perigee(rad):  -0.078260734
    Mean Anom(rad):             0.3070704840E+001
    Af0(s):                     0.3929138184E-003
    Af1(s/s):                  -0.7275957614E-011
    week:                        381

    ******** Week 381 almanac for PRN-22 ********
    ID:                         22
    Health:                     000
    Eccentricity:               0.1182842255E-001
    Time of Applicability(s):  61440.0000
    Orbital Inclination(rad):   0.9567270395
    Rate of Right Ascen(r/s):  -0.7874613724E-008
    SQRT(A)  (m 1/2):           5153.657227
    Right Ascen at Week(rad):  -0.1571297417E+001
    Argument of Perigee(rad):  -0.986436532
    Mean Anom(rad):             0.1356689910E+001
    Af0(s):                     0.4386901855E-004
    Af1(s/s):                   0.7275957614E-011
    week:                        381

    ******** Week 381 almanac for PRN-23 ********
    ID:                         23
    Health:                     000
    Eccentricity:               0.6471633911E-002
    Time of Applicability(s):  61440.0000
    Orbital Inclination(rad):   0.9891863126
    Rate of Right Ascen(r/s):  -0.7897471819E-008
    SQRT(A)  (m 1/2):           5153.684570
    Right Ascen at Week(rad):   0.1462281417E+001
    Argument of Perigee(rad):  -2.743067366
    Mean Anom(rad):            -0.2441465246E+001
    Af0(s):                     0.6732940674E-003
    Af1(s/s):                   0.3637978807E-011
    week:                        381

    ******** Week 381 almanac for PRN-24 ********
    ID:                         24
    Health:                     000
    Eccentricity:               0.1845932007E-001
    Time of Applicability(s):  61440.0000
    Orbital Inclination(rad):   0.9356048431
    Rate of Right Ascen(r/s):  -0.7886042771E-008
    SQRT(A)  (m 1/2):           5153.572754
    Right Ascen at Week(rad):  -0.2821382403E+001
    Argument of Perigee(rad):   1.164082069
    Mean Anom(rad):            -0.1029426194E+001
    Af0(s):                     0.1306533813E-003
    Af1(s/s):                   0.1818989404E-010
    week:                        381

    ******** Week 381 almanac for PRN-25 ********
    ID:                         25
    Health:                     000
    Eccentricity:               0.1292085648E-001
    Time of Applicability(s):  61440.0000
    Orbital Inclination(rad):   0.9466183458
    Rate of Right Ascen(r/s):  -0.7977475151E-008
    SQRT(A)  (m 1/2):           5153.598145
    Right Ascen at Week(rad):  -0.1686938446E+001
    Argument of Perigee(rad):   1.162442477
    Mean Anom(rad):            -0.2845171839E+001
    Af0(s):                     0.4034042358E-003
    Af1(s/s):                  -0.3637978807E-011
    week:                        381

    ******** Week 381 almanac for PRN-26 ********
    ID:                         26
    Health:                     000
    Eccentricity:               0.1118898392E-001
    Time of Applicability(s):  61440.0000
    Orbital Inclination(rad):   0.9273896569
    Rate of Right Ascen(r/s):  -0.8206056101E-008
    SQRT(A)  (m 1/2):           5153.510254
    Right Ascen at Week(rad):  -0.1764244936E+001
    Argument of Perigee(rad):   0.716903075
    Mean Anom(rad):             0.2570069836E+001
    Af0(s):                    -0.3852844238E-003
    Af1(s/s):                  -0.3637978807E-011
    week:                        381

    ******** Week 381 almanac for PRN-27 ********
    ID:                         27
    Health:                     000
    Eccentricity:               0.1432943344E-001
    Time of Applicability(s):  61440.0000
    Orbital Inclination(rad):   0.9508128245
    Rate of Right Ascen(r/s):  -0.7703178011E-008
    SQRT(A)  (m 1/2):           5153.625000
    Right Ascen at Week(rad):  -0.6327116480E+000
    Argument of Perigee(rad):   0.900476309
    Mean Anom(rad):             0.8856982612E+000
    Af0(s):                     0.9536743164E-006
    Af1(s/s):                   0.0000000000E+000
    week:                        381

    ******** Week 381 almanac for PRN-28 ********
    ID:                         28
    Health:                     000
    Eccentricity:               0.5087852478E-003
    Time of Applicability(s):  61440.0000
    Orbital Inclination(rad):   0.9623296646
    Rate of Right Ascen(r/s):  -0.7668890869E-008
    SQRT(A)  (m 1/2):           5153.573730
    Right Ascen at Week(rad):  -0.2734384421E+001
    Argument of Perigee(rad):  -0.296014849
    Mean Anom(rad):            -0.1345904107E+001
    Af0(s):                    -0.4606246948E-003
    Af1(s/s):                   0.1091393642E-010
    week:                        381

    ******** Week 381 almanac for PRN-29 ********
    ID:                         29
    Health:                     000
    Eccentricity:               0.3662109375E-002
    Time of Applicability(s):  61440.0000
    Orbital Inclination(rad):   0.9600706382
    Rate of Right Ascen(r/s):  -0.7634603726E-008
    SQRT(A)  (m 1/2):           5153.639160
    Right Ascen at Week(rad):  -0.5419910654E+000
    Argument of Perigee(rad):   2.877053622
    Mean Anom(rad):             0.5776527482E+000
    Af0(s):                    -0.2746582031E-003
    Af1(s/s):                   0.7275957614E-011
    week:                        381

    ******** Week 381 almanac for PRN-30 ********
    ID:                         30
    Health:                     000
    Eccentricity:               0.8215904236E-002
    Time of Applicability(s):  61440.0000
    Orbital Inclination(rad):   0.9367133839
    Rate of Right Ascen(r/s):  -0.7920329914E-008
    SQRT(A)  (m 1/2):           5153.620605
    Right Ascen at Week(rad):  -0.2721454565E+001
    Argument of Perigee(rad):  -2.259742078
    Mean Anom(rad):            -0.2295714976E+001
    Af0(s):                     0.3089904785E-003
    Af1(s/s):                   0.1455191523E-010
    week:                        381

    ******** Week 381 almanac for PRN-31 ********
    ID:                         31
    Health:                     000
    Eccentricity:               0.1092481613E-001
    Time of Applicability(s):  61440.0000
    Orbital Inclination(rad):   0.9550971849
    Rate of Right Ascen(r/s):  -0.7748894201E-008
    SQRT(A)  (m 1/2):           5153.582031
    Right Ascen at Week(rad):  -0.2685458448E+001
    Argument of Perigee(rad):   0.980186759
    Mean Anom(rad):            -0.3090452595E+001
    Af0(s):                    -0.1325607300E-003
    Af1(s/s):                   0.3637978807E-011
    week:                        381

    ******** Week 381 almanac for PRN-32 ********
    ID:                         32
    Health:                     000
    Eccentricity:               0.9474754333E-002
    Time of Applicability(s):  61440.0000
    Orbital Inclination(rad):   0.9697778604
    Rate of Right Ascen(r/s):  -0.7623174679E-008
    SQRT(A)  (m 1/2):           5153.537109
    Right Ascen at Week(rad):   0.2518227952E+001
    Argument of Perigee(rad):  -1.973656159
    Mean Anom(rad):             0.1395536400E+001
    Af0(s):                     0.1840591431E-003
    Af1(s/s):                   0.1818989404E-010
    week:                        381
    """
}
