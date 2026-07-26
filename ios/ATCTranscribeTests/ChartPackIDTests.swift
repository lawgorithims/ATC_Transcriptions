import XCTest
@testable import ATCTranscribe

/// `packID` is the only bridge between an on-disk chart file and a catalog pack id, and two things
/// depend on getting it right: restoring the pilot's downloads at a cycle rollover, and recognising a
/// PINNED pack so `pruneOldCycleFiles` does not delete it.
final class ChartPackIDTests: XCTestCase {

    /// The regression. An FAA cycle is an effective date in MM-DD-YYYY form, so it contains TWO dashes;
    /// the old rule took everything before the LAST one and returned "New_York_SEC-05-14" for every real
    /// file. Nothing matched a catalog id, so the rollover could not tell a pinned pack from an
    /// incidental one and wiped the pilot's explicitly-downloaded kit.
    func testTheCycleSuffixIsStrippedEvenThoughItContainsDashes() {
        XCTAssertEqual(ChartLibrary.packID("New_York_SEC-05-14-2026.mbtiles"), "New_York_SEC")
        XCTAssertEqual(ChartLibrary.packID("ENR_L01-05-14-2026.mbtiles"), "ENR_L01")
        XCTAssertEqual(ChartLibrary.packID("Atlanta_SEC-07-09-2026.mbtiles"), "Atlanta_SEC")
    }

    /// A pack id may legitimately contain dashes, so only a cycle-SHAPED tail may be stripped.
    func testAPackIdContainingDashesSurvives() {
        XCTAssertEqual(ChartLibrary.packID("Grand-Canyon_SEC-05-14-2026.mbtiles"), "Grand-Canyon_SEC")
        XCTAssertEqual(ChartLibrary.packID("A-B-C-05-14-2026.mbtiles"), "A-B-C")
    }

    /// The legacy 4-digit cycle still exists on disk from earlier installs, and prune walks those files.
    func testTheLegacyFourDigitCycleIsStillUnderstood() {
        XCTAssertEqual(ChartLibrary.packID("New_York_SEC-2508.mbtiles"), "New_York_SEC")
        XCTAssertEqual(ChartLibrary.packID("vfr-sec-den-2508.mbtiles"), "vfr-sec-den")
    }

    /// A tail that merely looks dash-separated is not a cycle; a name with no cycle is not a pack file.
    func testANonCycleTailIsNotMistakenForOne() {
        XCTAssertNil(ChartLibrary.packID("Pack-AA-BB-CCCC.mbtiles"))
        XCTAssertNil(ChartLibrary.packID("Pack-5-14-202.mbtiles"), "not MM-DD-YYYY and not YYNN")
        XCTAssertNil(ChartLibrary.packID("NoCycleHere.mbtiles"))
    }

    func testNonChartFilesAndJunkAreRejected() {
        XCTAssertNil(ChartLibrary.packID("notes.txt"))
        XCTAssertNil(ChartLibrary.packID(""))
        XCTAssertNil(ChartLibrary.packID("-05-14-2026.mbtiles"), "no id left after the cycle")
    }
}
