import XCTest
@testable import ATCTranscribe

/// The cycle-roll fallback: which pack file the map opens when the catalog has moved to a new cycle
/// but the pilot's downloads are still the previous one's.
///
/// WHY THIS EXISTS. `pruneOldCycleFiles` deliberately keeps pinned packs across a rollover, and its
/// comment promised they survive "as a labeled-expired fallback" — but nothing implemented the
/// fallback. `localURL` returns only `<id>-<currentCycle>.mbtiles`, so the moment a newly published
/// index.json was adopted every downloaded pack went invisible: the files were on disk and the reader
/// asked for a name that did not exist. That is a blank chart, offline, with a multi-gigabyte
/// re-download as the only cure — and it would fire the instant an automated publish landed.
///
/// These are pure tests on purpose. `ChartLibrary` is a singleton with a private `dir`, so the choice
/// is factored out as `chooseOlderCyclePack` and tested without a filesystem, the same split
/// `ChartPackIDTests` uses for `packID`.
final class ChartCycleRollTests: XCTestCase {

    private func c(_ name: String, _ daysAgo: Double) -> (name: String, modified: Date) {
        (name, Date(timeIntervalSince1970: 1_700_000_000 - daysAgo * 86_400))
    }

    func testFallsBackToThePreviousCycleWhenThisCycleIsNotOnDisk() {
        let picked = ChartLibrary.chooseOlderCyclePack(
            id: "New_York_SEC", currentCycle: "10-29-2026",
            candidates: [c("New_York_SEC-09-03-2026.mbtiles", 1)])
        XCTAssertEqual(picked, "New_York_SEC-09-03-2026.mbtiles",
                       "a downloaded pack from last cycle must still be readable, not invisible")
    }

    func testPicksTheNewestWhenSeveralOldCyclesLinger() {
        let picked = ChartLibrary.chooseOlderCyclePack(
            id: "Denver_SEC", currentCycle: "10-29-2026",
            candidates: [c("Denver_SEC-05-14-2026.mbtiles", 90),
                         c("Denver_SEC-09-03-2026.mbtiles", 5),
                         c("Denver_SEC-07-09-2026.mbtiles", 40)])
        XCTAssertEqual(picked, "Denver_SEC-09-03-2026.mbtiles", "the most recently downloaded one wins")
    }

    /// The reason the ordering is by DATE and not by the cycle string.
    func testOrdersByDownloadDateNotByCycleStringWhichDoesNotSortChronologically() {
        // "05-14-2027" sorts BEFORE "09-03-2026" as text, but is a year newer.
        //
        // `asOf` is explicit here, and has to be: the fallback now excludes cycles that have not
        // started, and 05-14-2027 is in the future against the real clock — so with a default `asOf`
        // this test would pass for the WRONG reason (the candidate excluded rather than out-ordered),
        // and would then start failing on 2027-05-14 for a third reason. Pinning the clock keeps the
        // test about the one thing it is for: ordering by download date, not by cycle string.
        let picked = ChartLibrary.chooseOlderCyclePack(
            id: "Miami_SEC", currentCycle: "12-24-2027",
            candidates: [c("Miami_SEC-09-03-2026.mbtiles", 400),
                         c("Miami_SEC-05-14-2027.mbtiles", 20)],
            asOf: ChartCatalog.cycleDate("12-01-2027")!)
        XCTAssertEqual(picked, "Miami_SEC-05-14-2027.mbtiles",
                       "lexical cycle order is not chronological order — mtime is the only sound key")
    }

    /// The legacy 4-digit cycle shape still on some devices must not sort against the date shape.
    func testLegacyFourDigitCycleIsStillAUsableFallback() {
        let picked = ChartLibrary.chooseOlderCyclePack(
            id: "Chicago_SEC", currentCycle: "10-29-2026",
            candidates: [c("Chicago_SEC-2607.mbtiles", 30)])
        XCTAssertEqual(picked, "Chicago_SEC-2607.mbtiles")
    }

    func testNeverReturnsTheCurrentCycleFile() {
        // Reached only when the current file is missing; a half-written one must not win on recency.
        let picked = ChartLibrary.chooseOlderCyclePack(
            id: "Boston_SEC", currentCycle: "10-29-2026",
            candidates: [c("Boston_SEC-10-29-2026.mbtiles", 0),
                         c("Boston_SEC-09-03-2026.mbtiles", 10)])
        XCTAssertEqual(picked, "Boston_SEC-09-03-2026.mbtiles",
                       "the current-cycle name is excluded — the caller already found it absent")
    }

    func testDoesNotMatchADifferentPack() {
        let picked = ChartLibrary.chooseOlderCyclePack(
            id: "Albuquerque_SEC", currentCycle: "10-29-2026",
            candidates: [c("Atlanta_SEC-09-03-2026.mbtiles", 1),
                         c("Albuquerque_SEC_EXTRA-09-03-2026.mbtiles", 1)])
        XCTAssertNil(picked, "only the same pack id may stand in for itself")
    }

    /// Pack ids legitimately contain dashes, which is what broke the original cycle parser.
    func testHandlesAPackIDContainingDashes() {
        let picked = ChartLibrary.chooseOlderCyclePack(
            id: "Dallas-Ft_Worth_SEC", currentCycle: "10-29-2026",
            candidates: [c("Dallas-Ft_Worth_SEC-09-03-2026.mbtiles", 3)])
        XCTAssertEqual(picked, "Dallas-Ft_Worth_SEC-09-03-2026.mbtiles")
    }

    func testNoCopyAtAllReportsNil() {
        XCTAssertNil(ChartLibrary.chooseOlderCyclePack(
            id: "Seattle_SEC", currentCycle: "10-29-2026", candidates: []),
            "nil keeps the caller's existing not-cached path")
        XCTAssertNil(ChartLibrary.chooseOlderCyclePack(
            id: "Seattle_SEC", currentCycle: "10-29-2026",
            candidates: [c("notes.txt", 1), c("Seattle_SEC.mbtiles", 1)]),
            "a file with no recognisable cycle is not a pack")
    }

    // MARK: The pre-cache hazard — a fallback must never be a chart that is not in force

    /// ⚠️ THE DEFECT PRE-CACHING WOULD HAVE INTRODUCED.
    ///
    /// Pre-caching writes NEXT cycle's pack to disk days early, under next cycle's filename. It is
    /// therefore the newest file for that id from a cycle other than the current one — which is
    /// exactly what this function selects, and it wins on recency every time. A pilot whose current
    /// pack was missing (evicted, or an interrupted download) would have been served a chart that is
    /// not legal yet, reported by `isServedStale` as an OLDER cycle, under a currency banner showing
    /// the current cycle's dates. Three layers agreeing on a wrong answer.
    func testNeverServesANotYetEffectivePackAsAFallback() {
        let asOf = ChartCatalog.cycleDate("10-20-2026")!
        let picked = ChartLibrary.chooseOlderCyclePack(
            id: "Denver_SEC", currentCycle: "09-03-2026",
            candidates: [c("Denver_SEC-10-29-2026.mbtiles", 0),     // pre-cached, newest on disk
                         c("Denver_SEC-07-09-2026.mbtiles", 60)],   // genuinely old
            asOf: asOf)
        XCTAssertEqual(picked, "Denver_SEC-07-09-2026.mbtiles",
                       "an expired chart is a safe fallback; a chart from the future is not")
    }

    /// With nothing but a staged pack on disk, the honest answer is nil — a blank chart that says so,
    /// not a chart that is quietly out of its validity window.
    func testAStagedPackAloneIsNotAFallback() {
        XCTAssertNil(ChartLibrary.chooseOlderCyclePack(
            id: "Omaha_SEC", currentCycle: "09-03-2026",
            candidates: [c("Omaha_SEC-10-29-2026.mbtiles", 0)],
            asOf: ChartCatalog.cycleDate("10-20-2026")!),
            "nil routes the caller to its not-cached path, which tells the truth")
    }

    /// And the same file becomes usable the moment its cycle starts — no re-download, which is the
    /// entire value of pre-caching.
    func testTheStagedPackBecomesUsableOnceItsCycleStarts() {
        let afterRoll = ChartCatalog.cycleDate("10-29-2026")!.addingTimeInterval(10 * 3600)
        let picked = ChartLibrary.chooseOlderCyclePack(
            id: "Omaha_SEC", currentCycle: "12-24-2026",
            candidates: [c("Omaha_SEC-10-29-2026.mbtiles", 1)],
            asOf: afterRoll)
        XCTAssertEqual(picked, "Omaha_SEC-10-29-2026.mbtiles")
    }

    /// The 0901Z boundary, tested on both sides of the minute rather than "some time that day".
    func testTheCutoverIsAtZeroNineZeroOneZulu() {
        let eff = ChartCatalog.cycleDate("10-29-2026")!
        XCTAssertTrue(ChartLibrary.isFuturePack("X_SEC-10-29-2026.mbtiles",
                                                asOf: eff.addingTimeInterval(9 * 3600)),
                      "0900Z on the effective date is still before the cutover")
        XCTAssertFalse(ChartLibrary.isFuturePack("X_SEC-10-29-2026.mbtiles",
                                                 asOf: eff.addingTimeInterval(9 * 3600 + 61)),
                       "0901Z is the cutover, and one second past it is in force")
    }

    /// "Cannot tell" must not be treated as "from the future": that would exclude a real old pack
    /// from the fallback and blank the map — the opposite failure, and a worse one.
    func testAnUndatableNameIsNotTreatedAsFuture() {
        let future = ChartCatalog.cycleDate("01-01-2030")!
        XCTAssertFalse(ChartLibrary.isFuturePack("Chicago_SEC-2607.mbtiles", asOf: future),
                       "the legacy 4-digit shape carries no date and predates the rename")
        XCTAssertFalse(ChartLibrary.isFuturePack("notes.txt", asOf: future))
        XCTAssertFalse(ChartLibrary.isFuturePack("Seattle_SEC.mbtiles", asOf: future))
    }

    func testPackCycleParsesBothShapesAndIDsWithDashes() {
        XCTAssertEqual(ChartLibrary.packCycle("New_York_SEC-10-29-2026.mbtiles"), "10-29-2026")
        XCTAssertEqual(ChartLibrary.packCycle("Dallas-Ft_Worth_SEC-09-03-2026.mbtiles"), "09-03-2026")
        XCTAssertEqual(ChartLibrary.packCycle("Chicago_SEC-2607.mbtiles"), "2607")
        XCTAssertNil(ChartLibrary.packCycle("Seattle_SEC.mbtiles"))
        XCTAssertNil(ChartLibrary.packCycle("catalog.json"))
    }
}
