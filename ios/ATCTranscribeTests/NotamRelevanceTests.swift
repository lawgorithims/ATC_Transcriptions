import XCTest
@testable import ATCTranscribe

/// The NOTAM classifier, and the one-way bias it is built around.
///
/// A NOTAM promoted in error is a nuisance the pilot reads and dismisses. One quietly demoted is a
/// hazard they never see. Most of these tests assert the *conservative* direction — that something the
/// classifier could not understand is still shown, that a NOTAM naming no runway applies to all of
/// them, that an unparseable window counts as in force — because those are the properties that make it
/// safe to promote anything at all.
final class NotamRelevanceTests: XCTestCase {

    private func notam(_ text: String, id: String = "04/123", icao: String = "KBOS",
                       start: Date? = nil, end: Date? = nil) -> Notam {
        Notam(id: id, icao: icao, text: text, plainText: nil, classification: nil,
              effectiveStart: start, effectiveEnd: end, issued: nil,
              lat: nil, lon: nil, radiusNm: nil)
    }

    // MARK: what it recognises

    func testRunwayClosure() {
        let c = NotamRelevance.classify(notam("RWY 04R CLSD"))
        XCTAssertEqual(c.kind, .runwayClosed)
        XCTAssertEqual(c.runways, ["04R"])
        XCTAssertFalse(c.unclassified)
    }

    func testNavaidOutOfService() {
        XCTAssertEqual(NotamRelevance.classify(notam("ILS RWY 04R GS OTS")).kind, .navaidOut)
        XCTAssertEqual(NotamRelevance.classify(notam("VOR UNUSABLE")).kind, .navaidOut)
    }

    func testLightingOutOfService() {
        XCTAssertEqual(NotamRelevance.classify(notam("MALSR RWY 22L OUT OF SERVICE")).kind, .lightingOut)
        XCTAssertEqual(NotamRelevance.classify(notam("PAPI RWY 33L U/S")).kind, .lightingOut)
    }

    func testApproachNotAuthorised() {
        XCTAssertEqual(NotamRelevance.classify(notam("ILS OR LOC RWY 4R PROCEDURE NA")).kind, .approachNA)
        XCTAssertEqual(NotamRelevance.classify(notam("RNAV RWY 15R LNAV/VNAV NA")).kind, .approachNA)
    }

    func testRVROutRanksAheadOfLighting() {
        // "RVR OTS" mentions no lighting, but the two vocabularies overlap in real NOTAMs and RVR is
        // the more specific answer.
        XCTAssertEqual(NotamRelevance.classify(notam("RWY 04R RVR OTS")).kind, .rvrOut)
    }

    /// Both ends of a paired designator are captured — a NOTAM written against 22L is about the same
    /// strip of concrete as one written against 04R.
    func testPairedRunwayDesignatorsAreBothCaptured() {
        let c = NotamRelevance.classify(notam("RWY 04R/22L CLSD"))
        XCTAssertEqual(Set(c.runways), ["04R", "22L"])
    }

    /// `4R` and `04R` are the same runway; the CIFP writes one form and NOTAMs write either.
    func testRunwayFormsAreNormalised() {
        XCTAssertEqual(NotamRelevance.normalise("4R"), "04R")
        XCTAssertEqual(NotamRelevance.normalise("04R"), "04R")
        XCTAssertEqual(NotamRelevance.normalise("22"), "22")
        let c = NotamRelevance.classify(notam("RWY 4R CLSD"))
        XCTAssertTrue(NotamRelevance.bearsOnApproach(c, airport: "KBOS", runway: "04R"))
    }

    // MARK: the conservative direction

    /// A subject and its condition must be in the SAME clause. Otherwise `TWY B CLSD. RWY 04R AVBL`
    /// reads as a runway closure and the pilot is told the runway is shut when it is open.
    func testAClosureOnAnotherSurfaceIsNotARunwayClosure() {
        let c = NotamRelevance.classify(notam("TWY B CLSD. RWY 04R AVBL"))
        XCTAssertNotEqual(c.kind, .runwayClosed, "a taxiway closure is not a runway closure")
    }

    /// Something the classifier cannot read is PINNED, not dropped. This is the single most important
    /// property here: the classifier's job is to promote what it understands, never to demote what it
    /// does not.
    func testSomethingUnrecognisedIsStillShown() {
        let c = NotamRelevance.classify(notam("SFC COND RPT NOT AVBL DUE TO WIP CTC ARPT MGR"))
        XCTAssertTrue(c.unclassified || c.kind != .other,
                      "an unreadable NOTAM must be marked, not silently filed away")
        if c.unclassified {
            XCTAssertTrue(NotamRelevance.bearsOnApproach(c, airport: "KBOS", runway: "04R"),
                          "unclassified must be pinned for the pilot to read")
        }
    }

    /// A NOTAM naming no runway applies to ALL of them. An airport-wide navaid or lighting outage names
    /// none, and demanding a match would hide exactly the outages that matter most.
    func testANotamNamingNoRunwayAppliesToEveryRunway() {
        let c = NotamRelevance.classify(notam("ASOS OTS"))
        XCTAssertTrue(c.runways.isEmpty)
        XCTAssertTrue(NotamRelevance.bearsOnApproach(c, airport: "KBOS", runway: "04R"))
        XCTAssertTrue(NotamRelevance.bearsOnApproach(c, airport: "KBOS", runway: "33L"))
    }

    /// A NOTAM for a DIFFERENT runway does not bear on this approach — the classifier is allowed to be
    /// specific when the text is specific.
    func testANotamForAnotherRunwayIsNotPinned() {
        let c = NotamRelevance.classify(notam("RWY 15R CLSD"))
        XCTAssertFalse(NotamRelevance.bearsOnApproach(c, airport: "KBOS", runway: "04R"))
    }

    /// A missing end date is open-ended, never expired. The failure that matters is hiding a NOTAM that
    /// is still in force.
    func testAMissingEndDateMeansStillInForce() {
        let n = notam("RWY 04R CLSD", start: Date(timeIntervalSinceNow: -3_600), end: nil)
        XCTAssertTrue(n.isActive())
    }

    func testAnExpiredNotamIsNotActive() {
        let n = notam("RWY 04R CLSD", start: Date(timeIntervalSinceNow: -7_200),
                      end: Date(timeIntervalSinceNow: -3_600))
        XCTAssertFalse(n.isActive())
    }

    /// A circling or point-in-space approach codes an empty runway; everything at the field bears on it.
    func testAnApproachWithNoRunwayTakesEverything() {
        let c = NotamRelevance.classify(notam("RWY 15R CLSD"))
        XCTAssertTrue(NotamRelevance.bearsOnApproach(c, airport: "KBOS", runway: ""))
    }

    // MARK: the partition

    /// Pinned plus the rest is ALWAYS the whole fetched set. A filter that silently loses records is
    /// the failure this whole design exists to prevent, so it is asserted rather than assumed.
    func testThePartitionNeverLosesARecord() {
        let all = [notam("RWY 04R CLSD", id: "1"),
                   notam("RWY 15R CLSD", id: "2"),
                   notam("MALSR RWY 04R OTS", id: "3"),
                   notam("CRANE 1.2NM SW OF ARPT 240FT AGL", id: "4"),
                   notam("SOMETHING THE PARSER HAS NEVER SEEN", id: "5"),
                   notam("ASOS OTS", id: "6")]
        let (pinned, others) = NotamRelevance.partition(all, airport: "KBOS", runway: "04R")
        XCTAssertEqual(pinned.count + others.count, all.count)
        let ids = Set(pinned.map(\.id)).union(others.map(\.id))
        XCTAssertEqual(ids, Set(all.map(\.id)), "every fetched NOTAM must survive the partition")
        XCTAssertTrue(pinned.contains { $0.id == "1" }, "this runway's closure must be pinned")
        XCTAssertTrue(pinned.contains { $0.id == "3" }, "this runway's lighting outage must be pinned")
        XCTAssertFalse(pinned.contains { $0.id == "2" }, "another runway's closure need not be pinned")
    }

    /// Unclassified sorts FIRST inside the pinned group: they are the ones the app could not read and
    /// the pilot must.
    func testUnclassifiedNotamsSortToTheTop() {
        let all = [notam("RWY 04R CLSD", id: "known"),
                   notam("ZZZZ QQQQ WWWW", id: "unknown")]
        let (pinned, _) = NotamRelevance.partition(all, airport: "KBOS", runway: "04R")
        XCTAssertEqual(pinned.first?.id, "unknown")
    }

    // MARK: the feed state

    /// "No NOTAMs", "no API key" and "the fetch failed" look identical as an empty list, and only one
    /// of them means the pilot has nothing to read.
    func testOnlyASuccessfulFetchMayReportNone() {
        XCTAssertTrue(NotamFeedState.ok(fetchedAt: Date()).mayReportEmpty)
        XCTAssertFalse(NotamFeedState.noCredential.mayReportEmpty)
        XCTAssertFalse(NotamFeedState.loading.mayReportEmpty)
        XCTAssertFalse(NotamFeedState.failed("timeout").mayReportEmpty)
    }
}
