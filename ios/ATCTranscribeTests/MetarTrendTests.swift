import XCTest
@testable import ATCTranscribe

/// Where the weather is GOING. A pilot 45 minutes out needs the direction, not just the current value.
final class MetarTrendTests: XCTestCase {

    /// Build an observation directly (Metar's init is a decoder, so go through JSON — the same path
    /// the live API takes, which also keeps these tests honest about the real field names).
    private func obs(_ ident: String, minutesAgo: Int, ceiling: Int?, vis: Double?,
                     now: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> Metar {
        let t = Int(now.timeIntervalSince1970) - minutesAgo * 60
        var clouds = "[]"
        if let c = ceiling { clouds = "[{\"cover\":\"OVC\",\"base\":\(c)}]" }
        let json = """
        {"icaoId":"\(ident)","obsTime":\(t),"clouds":\(clouds)\(vis.map { ",\"visib\":\($0)" } ?? "")}
        """
        return try! JSONDecoder().decode(Metar.self, from: Data(json.utf8))
    }

    // MARK: rate of change

    /// The user's own example: is the ceiling falling at 200 ft/hour?
    func testDetectsAFallingCeilingRate() {
        let series = [obs("KBOS", minutesAgo: 180, ceiling: 3000, vis: 10),
                      obs("KBOS", minutesAgo: 120, ceiling: 2600, vis: 10),
                      obs("KBOS", minutesAgo: 60,  ceiling: 2200, vis: 10),
                      obs("KBOS", minutesAgo: 0,   ceiling: 1800, vis: 10)]
        let t = MetarTrend.analyze(ident: "KBOS", observations: series)
        XCTAssertNotNil(t)
        XCTAssertEqual(t!.ceilingRateFtPerHr ?? 0, -400, accuracy: 20, "400 ft/hr down")
        XCTAssertEqual(t!.direction, .deteriorating)
        XCTAssertTrue(t!.isSignificant, "400 ft/hr is past the 200 ft/hr threshold")
    }

    func testDetectsDeterioratingVisibility() {
        let series = [obs("KTCS", minutesAgo: 120, ceiling: nil, vis: 10),
                      obs("KTCS", minutesAgo: 60,  ceiling: nil, vis: 7),
                      obs("KTCS", minutesAgo: 0,   ceiling: nil, vis: 4)]
        let t = MetarTrend.analyze(ident: "KTCS", observations: series)!
        XCTAssertLessThan(t.visRateSmPerHr ?? 0, -1.0, "visibility dropping faster than 1 SM/hr")
        XCTAssertEqual(t.direction, .deteriorating)
        XCTAssertTrue(t.isSignificant)
    }

    func testImprovingConditionsReadAsImproving() {
        let series = [obs("KJFK", minutesAgo: 120, ceiling: 700, vis: 2),
                      obs("KJFK", minutesAgo: 60,  ceiling: 1500, vis: 4),
                      obs("KJFK", minutesAgo: 0,   ceiling: 2500, vis: 8)]
        let t = MetarTrend.analyze(ident: "KJFK", observations: series)!
        XCTAssertEqual(t.direction, .improving)
        XCTAssertFalse(t.isSignificant, "significance flags DETERIORATION, not improvement")
    }

    func testSteadyConditionsReadAsSteady() {
        let series = [obs("KDEN", minutesAgo: 120, ceiling: 5000, vis: 10),
                      obs("KDEN", minutesAgo: 60,  ceiling: 5000, vis: 10),
                      obs("KDEN", minutesAgo: 0,   ceiling: 4950, vis: 10)]
        let t = MetarTrend.analyze(ident: "KDEN", observations: series)!
        XCTAssertEqual(t.direction, .steady)
        XCTAssertFalse(t.isSignificant)
    }

    // MARK: projection — the "will it still be legal when I get there" question

    func testProjectsAVfrFieldIntoMvfrWithinTheHour() {
        // 3,400 ft and coming down 600 ft/hr → below 3,000 within the hour.
        let series = [obs("KABC", minutesAgo: 120, ceiling: 4600, vis: 10),
                      obs("KABC", minutesAgo: 60,  ceiling: 4000, vis: 10),
                      obs("KABC", minutesAgo: 0,   ceiling: 3400, vis: 10)]
        let t = MetarTrend.analyze(ident: "KABC", observations: series)!
        XCTAssertEqual(t.projected1h, .mvfr, "3,400 ft falling 600 ft/hr is MVFR in an hour")
        XCTAssertTrue(t.projectsCategoryDrop)
    }

    func testProjectsThroughMvfrIntoIfrByTwoHours() {
        let series = [obs("KDEF", minutesAgo: 120, ceiling: 3000, vis: 10),
                      obs("KDEF", minutesAgo: 60,  ceiling: 2300, vis: 10),
                      obs("KDEF", minutesAgo: 0,   ceiling: 1600, vis: 10)]
        let t = MetarTrend.analyze(ident: "KDEF", observations: series)!
        XCTAssertEqual(t.projected2h, .lifr, "1,600 ft falling 700 ft/hr is well below 500 ft in 2 hr")
        XCTAssertTrue(t.projectsCategoryDrop)
    }

    func testProjectionIsClampedAndNeverGoesNegative() {
        let series = [obs("KGHI", minutesAgo: 120, ceiling: 900, vis: 3),
                      obs("KGHI", minutesAgo: 60,  ceiling: 500, vis: 2),
                      obs("KGHI", minutesAgo: 0,   ceiling: 200, vis: 1)]
        let t = MetarTrend.analyze(ident: "KGHI", observations: series)!
        XCTAssertEqual(t.projected2h, .lifr, "already LIFR and falling stays LIFR, not a negative ceiling")
    }

    // MARK: guards — never invent a trend

    func testASingleObservationYieldsNoRate() {
        let t = MetarTrend.analyze(ident: "KXYZ", observations: [obs("KXYZ", minutesAgo: 0, ceiling: 1000, vis: 5)])
        XCTAssertNotNil(t, "still reports the current category")
        XCTAssertNil(t!.ceilingRateFtPerHr, "one point is not a trend")
        XCTAssertEqual(t!.direction, .steady)
        XCTAssertFalse(t!.isSignificant)
    }

    /// Two reports minutes apart must not imply a wild hourly rate.
    func testTooShortASpanYieldsNoRate() {
        let series = [obs("KXYZ", minutesAgo: 8, ceiling: 3000, vis: 10),
                      obs("KXYZ", minutesAgo: 0, ceiling: 2800, vis: 10)]
        let t = MetarTrend.analyze(ident: "KXYZ", observations: series)!
        XCTAssertNil(t.ceilingRateFtPerHr, "an 8-minute span can't support an hourly rate")
        XCTAssertFalse(t.isSignificant)
    }

    func testNoObservationsYieldsNoTrend() {
        XCTAssertNil(MetarTrend.analyze(ident: "KXYZ", observations: []))
    }

    /// A clear-sky report has NO ceiling at all. It must still count, or a deck forming over a clear
    /// field would show no trend until the deck already existed.
    func testClearSkyReportsStillContributeToTheFit() {
        let series = [obs("KCLR", minutesAgo: 120, ceiling: nil, vis: 10),
                      obs("KCLR", minutesAgo: 60,  ceiling: 6000, vis: 10),
                      obs("KCLR", minutesAgo: 0,   ceiling: 3200, vis: 10)]
        let t = MetarTrend.analyze(ident: "KCLR", observations: series)!
        XCTAssertNotNil(t.ceilingRateFtPerHr)
        XCTAssertLessThan(t.ceilingRateFtPerHr!, 0, "a deck forming must read as deteriorating")
    }

    func testOnlyTheMostRecentSixObservationsAreUsed() {
        var series: [Metar] = []
        for i in stride(from: 600, through: 0, by: -60) {
            series.append(obs("KLONG", minutesAgo: i, ceiling: 5000, vis: 10))
        }
        let t = MetarTrend.analyze(ident: "KLONG", observations: series)!
        XCTAssertLessThanOrEqual(t.sampleCount, 6)
    }

    func testUnorderedInputIsSortedBeforeFitting() {
        let a = obs("KMIX", minutesAgo: 0,   ceiling: 1800, vis: 10)
        let b = obs("KMIX", minutesAgo: 120, ceiling: 3000, vis: 10)
        let c = obs("KMIX", minutesAgo: 60,  ceiling: 2400, vis: 10)
        let t = MetarTrend.analyze(ident: "KMIX", observations: [a, b, c])!
        XCTAssertLessThan(t.ceilingRateFtPerHr ?? 0, 0, "newest-first input must not invert the trend")
    }

    // MARK: category thresholds

    func testFlightCategoryThresholds() {
        XCTAssertEqual(MetarTrend.category(ceilingFt: 400, visSm: 10), .lifr)
        XCTAssertEqual(MetarTrend.category(ceilingFt: 5000, visSm: 0.5), .lifr)
        XCTAssertEqual(MetarTrend.category(ceilingFt: 800, visSm: 10), .ifr)
        XCTAssertEqual(MetarTrend.category(ceilingFt: 5000, visSm: 2), .ifr)
        XCTAssertEqual(MetarTrend.category(ceilingFt: 2000, visSm: 10), .mvfr)
        XCTAssertEqual(MetarTrend.category(ceilingFt: 5000, visSm: 4), .mvfr)
        XCTAssertEqual(MetarTrend.category(ceilingFt: 5000, visSm: 10), .vfr)
    }

    func testSummaryReadsLikeSomethingAPilotWouldSay() {
        let series = [obs("KSUM", minutesAgo: 120, ceiling: 4600, vis: 10),
                      obs("KSUM", minutesAgo: 60,  ceiling: 4000, vis: 10),
                      obs("KSUM", minutesAgo: 0,   ceiling: 3400, vis: 10)]
        let s = MetarTrend.analyze(ident: "KSUM", observations: series)!.summary
        XCTAssertTrue(s.contains("Ceiling ↓"), "got: \(s)")
        XCTAssertTrue(s.contains("ft/hr"), "got: \(s)")
    }
}
