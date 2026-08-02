import XCTest
@testable import ATCTranscribe

/// The candidate finder, over synthetic ground whose answers are known by hand.
///
/// Two kinds of test here, and the second matters more than the first. The geometry ones check that
/// a run is measured correctly and that ranking prefers reachable, into-wind, high-scoring ground.
/// The CLAIM-STRENGTH ones check that the type cannot be used to overstate what it knows — that a
/// candidate always carries its unknowns, that nothing is offered outside the reachable footprint,
/// and that "nothing good enough" comes back as an empty answer rather than the least-bad patch of
/// forest dressed up as a find.
final class LZSiteFinderTests: XCTestCase {

    private let here = Coord(lat: 32.0, lon: -106.5)

    // MARK: - synthetic ground

    /// A sampler that returns `good` inside a lat/lon box and `bad` everywhere else.
    private func boxSampler(minLat: Double, maxLat: Double, minLon: Double, maxLon: Double,
                            good: Int = 80, bad: Int = 10) -> LZSiteFinder.Sampler {
        { c in
            let inside = c.lat >= minLat && c.lat <= maxLat && c.lon >= minLon && c.lon <= maxLon
            return Self.info(score: inside ? good : bad, vetoed: !inside && bad == 0)
        }
    }

    private static func info(score: Int, vetoed: Bool = false, coarse: Bool = false,
                             rules: [LZFiredRule] = []) -> LZSampleInfo {
        LZSampleInfo(score: vetoed ? 0 : score, vetoed: vetoed, surfaceClass: LZPack.classCrop,
                     slopeDeg: 1.0, roughM: 0.05, hazard: 0.05, confidence: 90,
                     coarseTerrain: coarse, rules: rules)
    }

    /// A footprint that is one comfortable disc of `radius`, centred on the aircraft.
    private func discField(radiusNm: Double,
                           cls: LZEnergyClass = .comfortable) -> LZEnergyField {
        var ring: [Coord] = []
        for a in stride(from: 0.0, to: 360.0, by: 10.0) {
            ring.append(Geo.point(from: here, bearingDeg: a, distanceNm: radiusNm))
        }
        ring.append(ring[0])
        return LZEnergyField(bands: [LZEnergyBand(classification: cls, rings: [ring])],
                             maxRangeNm: radiusNm, usedWind: false, sawHole: false,
                             isDefaultGlideRatio: false)
    }

    private func input(required: Double = 300, wind: Double? = nil) -> LZSiteFinder.Input {
        LZSiteFinder.Input(coord: here, altitudeFtMSL: 8000, headingDeg: 0,
                           windFromDeg: wind, windKts: wind == nil ? nil : 15,
                           requiredRunMetres: required)
    }

    // MARK: - the run measurement

    /// A run is measured BOTH ways from the point. Measuring only forwards reports half the ground
    /// and would reject fields that are perfectly long enough.
    func testARunIsMeasuredInBothDirections() {
        // A wide east-west band through `here`: plenty of run along 090/270, none north-south.
        let sampler = boxSampler(minLat: here.lat - 0.001, maxLat: here.lat + 0.001,
                                 minLon: here.lon - 0.02, maxLon: here.lon + 0.02)
        let (metres, heading) = LZSiteFinder.longestRun(through: here, preferInto: nil,
                                                       sample: sampler)
        XCTAssertGreaterThan(metres, 1000, "the band is ~3 km wide; a one-way walk would report half")
        let h = heading.truncatingRemainder(dividingBy: 180)
        XCTAssertEqual(h, 90, accuracy: 31, "the run should lie roughly east-west, got \(heading)")
    }

    /// Ground that is bad everywhere yields no run at all — not a short one.
    func testNoUsableGroundYieldsNoRun() {
        let sampler: LZSiteFinder.Sampler = { _ in Self.info(score: 5) }
        XCTAssertEqual(LZSiteFinder.longestRun(through: here, preferInto: nil, sample: sampler).metres, 0)
    }

    /// A vetoed cell stops the walk dead, whatever its score would have been.
    func testAVetoStopsTheRun() {
        // Vetoed outside a ~500 m disc. The first version of this vetoed by LONGITUDE only, which
        // a north-south walk never meets — the run correctly ran to the cap and the test was wrong.
        let sampler: LZSiteFinder.Sampler = { c in
            Self.info(score: 90, vetoed: Geo.nmBetween(c, self.here) > 0.27)
        }
        let (metres, _) = LZSiteFinder.longestRun(through: here, preferInto: nil, sample: sampler)
        XCTAssertGreaterThan(metres, 0)
        XCTAssertLessThan(metres, 1200, "the walk ran through a veto")
        XCTAssertLessThan(metres, 12_000 - 1, "the walk hit its step cap instead of the veto")
    }

    // MARK: - wind

    /// A run is a line with two directions; the reported one must be the into-wind direction,
    /// because that is the one an aeroplane would use.
    func testTheReportedHeadingIsIntoWind() {
        XCTAssertEqual(LZSiteFinder.intoWindOrientation(90, 270), 270, accuracy: 0.001)
        XCTAssertEqual(LZSiteFinder.intoWindOrientation(270, 270), 270, accuracy: 0.001)
        // With no wind the heading is left as given, normalised.
        XCTAssertEqual(LZSiteFinder.intoWindOrientation(370, nil), 10, accuracy: 0.001)
    }

    func testAlignmentIsOneIntoWindAndMinusOneDownwind() {
        XCTAssertEqual(LZSiteFinder.alignment(270, 270), 1.0, accuracy: 0.001)
        XCTAssertEqual(LZSiteFinder.alignment(90, 270), -1.0, accuracy: 0.001)
        XCTAssertEqual(LZSiteFinder.alignment(0, 270), 0.0, accuracy: 0.001)
        XCTAssertEqual(LZSiteFinder.alignment(0, nil), 0.0, "no wind must not bias any heading")
    }

    /// Wind breaks TIES; it does not manufacture length. A longer run must still win over a shorter
    /// one that happens to point into wind, or the finder would send a pilot to a field too small.
    func testWindDoesNotBeatLength() {
        // A long north-south band, wind from the east (favouring an east-west run that is short).
        let sampler = boxSampler(minLat: here.lat - 0.02, maxLat: here.lat + 0.02,
                                 minLon: here.lon - 0.0008, maxLon: here.lon + 0.0008)
        let (metres, heading) = LZSiteFinder.longestRun(through: here, preferInto: 90,
                                                        sample: sampler)
        XCTAssertGreaterThan(metres, 2000)
        let h = heading.truncatingRemainder(dividingBy: 180)
        XCTAssertTrue(h < 30 || h > 150, "wind pulled the run off the long axis: \(heading)")
    }

    // MARK: - claim strength

    /// EVERY candidate carries its unknowns, and they name the specific things the data cannot see.
    /// A caller must not be able to render a run length without them.
    func testEveryCandidateCarriesItsUnknowns() {
        let sampler = boxSampler(minLat: here.lat - 0.05, maxLat: here.lat + 0.05,
                                 minLon: here.lon - 0.05, maxLon: here.lon + 0.05)
        let out = LZSiteFinder.find(input(), field: discField(radiusNm: 5), sample: sampler)
        XCTAssertFalse(out.isEmpty, "known-good ground produced no candidate")
        for c in out {
            let u = c.unknowns.lowercased()
            XCTAssertTrue(u.contains("not surveyed"), c.unknowns)
            for missing in ["fences", "ditches", "crop", "wires", "livestock", "surface condition"] {
                XCTAssertTrue(u.contains(missing), "unknowns dropped \(missing): \(c.unknowns)")
            }
        }
    }

    /// NOTHING is offered outside the reachable footprint. A candidate the aeroplane cannot get to
    /// is worse than no candidate.
    func testNothingIsOfferedBeyondTheFootprint() {
        // Good ground everywhere, but a footprint only 2 NM across.
        let sampler: LZSiteFinder.Sampler = { _ in Self.info(score: 90) }
        let out = LZSiteFinder.find(input(), field: discField(radiusNm: 2), sample: sampler)
        for c in out {
            XCTAssertLessThanOrEqual(c.distanceNm, 2.0 + 0.26,
                                     "candidate at \(c.distanceNm) NM is outside a 2 NM footprint")
        }
    }

    /// Blocked ground is never offered, however good the surface is.
    func testBlockedGroundIsNeverOffered() {
        let sampler: LZSiteFinder.Sampler = { _ in Self.info(score: 95) }
        let blocked = discField(radiusNm: 5, cls: .blocked)
        XCTAssertTrue(LZSiteFinder.find(input(), field: blocked, sample: sampler).isEmpty,
                      "ground the energy engine calls blocked was offered as a candidate")
    }

    /// "Nothing good enough" is a real answer. The least-bad patch of forest must NOT be promoted
    /// just because something had to be returned.
    func testPoorGroundYieldsNothingRatherThanTheLeastBadOption() {
        let sampler: LZSiteFinder.Sampler = { _ in Self.info(score: LZSiteFinder.minScore - 1) }
        XCTAssertTrue(LZSiteFinder.find(input(), field: discField(radiusNm: 6), sample: sampler).isEmpty,
                      "sub-threshold ground was offered because the finder wanted an answer")
    }

    /// A field shorter than the aeroplane needs is not a candidate. This is the whole reason
    /// landing distance became a profile field.
    func testGroundTooShortForTheAeroplaneIsRejected() {
        // A ~600 m patch, against an aeroplane needing 2,500 m.
        let sampler = boxSampler(minLat: here.lat - 0.0027, maxLat: here.lat + 0.0027,
                                 minLon: here.lon - 0.0032, maxLon: here.lon + 0.0032)
        let field = discField(radiusNm: 4)
        XCTAssertFalse(LZSiteFinder.find(input(required: 300), field: field, sample: sampler).isEmpty,
                       "a short-landing aeroplane should accept this patch")
        XCTAssertTrue(LZSiteFinder.find(input(required: 2500), field: field, sample: sampler).isEmpty,
                      "a patch far too short was offered anyway")
    }

    /// Candidates are distinct places, not five names for one field.
    func testCandidatesAreNotAllTheSameField() {
        let sampler: LZSiteFinder.Sampler = { _ in Self.info(score: 85) }
        let out = LZSiteFinder.find(input(), field: discField(radiusNm: 10), sample: sampler)
        for a in 0..<out.count {
            for b in (a + 1)..<out.count {
                XCTAssertGreaterThanOrEqual(Geo.nmBetween(out[a].centre, out[b].centre), 1.0,
                                            "two candidates are the same field")   // 10 NM /5 = 2, capped at 1
            }
        }
    }

    /// ⚠️ REGRESSION. The selection loop used to look only at the top 20 scored samples. The
    /// highest-scoring ground is CONTIGUOUS, so that window sat entirely inside one field, the
    /// separation filter threw it away as duplicates, and the search finished with most of the
    /// footprint never examined — two offers over southern New Mexico, which is close to a
    /// best-case for this layer. Nothing was wrong on screen; the list was simply short.
    func testOneStrongFieldDoesNotStarveTheRestOfTheFootprint() {
        // A small blob of the best ground right on the aircraft, everything else merely good. Every
        // sample in the blob outscores every sample outside it, so a score-ordered window fills with
        // the blob alone — and the blob is narrower than the separation radius, so it is worth
        // exactly ONE candidate.
        let sampler: LZSiteFinder.Sampler = { c in
            let blob = Geo.nmBetween(c, self.here) < 0.4
            return Self.info(score: blob ? 95 : 70)
        }
        let out = LZSiteFinder.find(input(), field: discField(radiusNm: 15), sample: sampler)
        XCTAssertEqual(out.count, LZSiteFinder.maxCandidates,
                       "one strong field consumed the search; \(out.count) offered")
        XCTAssertEqual(out.first?.score, 95, "the best ground must still rank first")
    }

    /// The walk budget must be spent on DISTINCT ground. Ground that fails the run test never enters
    /// the result list, so testing separation against accepted candidates alone would let one large
    /// too-short patch be re-measured by every one of its samples until the budget was gone.
    func testALargeTooShortPatchDoesNotConsumeTheSearch() {
        // Inside 3 NM: high-scoring ground broken into ~120 m islands on a 150 m lattice, so no run
        // through it can reach what the aeroplane needs FROM ANY HEADING. (Stripes would not do —
        // a stripe is unbounded along its own axis and measures perfectly long.) Outside: ordinary
        // open ground.
        let lattice = 0.00135                        // ~150 m of latitude at 32°N
        let metresPerDegLat = 111_320.0
        let metresPerDegLon = metresPerDegLat * cos(32.0 * .pi / 180)
        let sampler: LZSiteFinder.Sampler = { c in
            let r = Geo.nmBetween(c, self.here)
            if r < 2.9 {
                let dLat = (c.lat / lattice - (c.lat / lattice).rounded()) * lattice * metresPerDegLat
                let dLon = (c.lon / lattice - (c.lon / lattice).rounded()) * lattice * metresPerDegLon
                let island = (dLat * dLat + dLon * dLon).squareRoot() < 60.0
                return Self.info(score: island ? 90 : 10)
            }
            // An unusable moat, so no run can bridge the patch to the ground beyond it. Without one,
            // a chance corridor of islands near the edge lets a walk escape outward and measure the
            // outside ground — a real run over this synthetic surface, and the test would then be
            // asserting something its own terrain does not guarantee.
            if r < 3.0 { return Self.info(score: 10) }
            return Self.info(score: 70)
        }
        let out = LZSiteFinder.find(input(required: 600), field: discField(radiusNm: 12),
                                    sample: sampler)
        XCTAssertFalse(out.isEmpty, "the too-short patch swallowed the whole search")
        for c in out {
            XCTAssertGreaterThanOrEqual(Geo.nmBetween(c.centre, here), 2.99,
                                        "offered ground inside the too-short patch")
            XCTAssertGreaterThanOrEqual(c.runMetres, 600)
        }
    }

    // MARK: - bounds

    func testTheCandidateCountIsCapped() {
        let sampler: LZSiteFinder.Sampler = { _ in Self.info(score: 95) }
        let out = LZSiteFinder.find(input(), field: discField(radiusNm: 15), sample: sampler)
        XCTAssertLessThanOrEqual(out.count, LZSiteFinder.maxCandidates)
    }

    func testAnEmptyFootprintFindsNothingAndDoesNotTrap() {
        let empty = LZEnergyField(bands: [], maxRangeNm: 0, usedWind: false, sawHole: false,
                                  isDefaultGlideRatio: false)
        let sampler: LZSiteFinder.Sampler = { _ in Self.info(score: 95) }
        XCTAssertTrue(LZSiteFinder.find(input(), field: empty, sample: sampler).isEmpty)
    }

    /// A sampler that knows nothing (no pack for this ground) offers nothing — it must not read
    /// "no data" as "no hazard".
    func testUnknownGroundIsNotTreatedAsGoodGround() {
        let sampler: LZSiteFinder.Sampler = { _ in nil }
        XCTAssertTrue(LZSiteFinder.find(input(), field: discField(radiusNm: 8), sample: sampler).isEmpty,
                      "ground with no data was offered as a candidate")
    }

    /// The search must stay cheap enough to run when a pilot asks.
    func testASweepIsFastEnoughToRunOnDemand() {
        let sampler: LZSiteFinder.Sampler = { _ in Self.info(score: 80) }
        let field = discField(radiusNm: 12)
        _ = LZSiteFinder.find(input(), field: field, sample: sampler)     // warm
        let t0 = CFAbsoluteTimeGetCurrent()
        _ = LZSiteFinder.find(input(), field: field, sample: sampler)
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        XCTAssertLessThan(ms, 800, "a sweep took \(Int(ms)) ms — too slow to run on a tap")
    }

    // MARK: - agreement with the shading

    /// THE LIST AND THE MAP MUST MEAN THE SAME THING BY "too short". The finder's required run and
    /// the shading's extent cap are computed in different files from the same POH number, and if
    /// they drift a pilot gets a candidate the map is simultaneously excluding.
    func testTheFinderAndTheShadingAgreeOnWhatTheAeroplaneNeeds() throws {
        let doc = try XCTUnwrap(LZRulesetCompiler.loadDocument())
        var a = AircraftProfile(); a.vRefKts = 62; a.glideRatio = 9; a.landingOver50Ft = 1250
        let compiled = try XCTUnwrap(LZRulesetCompiler.compile(document: doc, aircraft: a,
                                                               themeKey: "day", packStamp: "t"))
        XCTAssertEqual(LZSiteFinder.requiredRunMetres(for: a), compiled.requiredRunM, accuracy: 1.0,
                       "the ranked list and the shading disagree about the required run")
    }

    /// The unprepared factor is duplicated as a Swift constant so the finder works without a
    /// compiled ruleset. Pinned equal here so the duplication cannot rot.
    func testTheUnpreparedFactorMatchesTheRuleset() throws {
        let doc = try XCTUnwrap(LZRulesetCompiler.loadDocument())
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: doc) as? [String: Any])
        let model = try XCTUnwrap(json["extent_model"] as? [String: Any])
        let factor = try XCTUnwrap(model["unprepared_factor"] as? Double)
        XCTAssertEqual(LZSiteFinder.unpreparedFactor, factor, accuracy: 0.0001,
                       "LZSiteFinder.unpreparedFactor drifted from the ruleset")
    }

    /// A profile with no landing figures still yields a usable requirement rather than zero — which
    /// would make every scrap of ground qualify.
    func testAProfileWithoutLandingFiguresStillHasARequirement() {
        XCTAssertGreaterThan(LZSiteFinder.requiredRunMetres(for: nil), 100)
        var bare = AircraftProfile(); bare.callsign = "N1"
        XCTAssertEqual(LZSiteFinder.requiredRunMetres(for: bare),
                       LZSiteFinder.requiredRunMetres(for: nil), accuracy: 0.001)
    }
}
