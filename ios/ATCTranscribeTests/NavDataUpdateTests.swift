import XCTest
import SQLite3
@testable import ATCTranscribe

/// Installing a downloaded AIRAC cycle over the bundled one. The whole point of these tests is the
/// refusals: the failure mode is a pilot holding NO procedure data, or worse, data that opens but is
/// wrong, so a candidate has to earn its place.
final class NavDataUpdateTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("navupd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
        NavDataUpdate.revertToBundled(.apt)
        NavDataUpdate.revertToBundled(.cifp)
        // These tests INSTALL a cycle-2699 fixture DB into the shared Application Support path. CIFP's
        // handle is a resolve-once static, so any CIFP read that happened while the override was active
        // bound the shared handle to that tiny fixture — starving every later CIFP-backed test in the
        // process. Reopen against the now-reverted (bundled) path so the leak cannot cross the class
        // boundary. (revert alone is not enough once the handle is already bound.)
        CIFP.reopenForTests()
        AirportData.reopenForTests()
        // Airways reads the airway table out of the SAME cifp.sqlite and now resolves it through
        // NavDataUpdate too, so it has the identical fixture-leak and needs the identical reset.
        Airways.reopenForTests()
    }

    /// A minimal database shaped like the real one, so the invariant checks have something to bite on.
    ///
    /// ⚠️ `effective` must be a date that is BOTH newer than the bundled cycle AND already in force.
    /// These fixtures used "2099-01-01" — comfortably newer, and never effective — which was harmless
    /// until `isNotYetEffective` started refusing cycles that have not begun. A far-future cycle is
    /// exactly what that guard exists to reject, so the fixtures say `Self.iso(daysFromNow: -1)`:
    /// yesterday is newer than the bundle (2026-07-09) and in force, without hardcoding a date that
    /// rots.
    private func makeCIFP(cycle: String, effective: String,
                          legs: Bool = true, marks: Bool = true, orphanProcedure: Bool = false) throws -> URL {
        let url = tmp.appendingPathComponent("\(UUID().uuidString).sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let ddl = """
        CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT);
        CREATE TABLE procedure(id INTEGER PRIMARY KEY, airport TEXT, kind TEXT, ident TEXT,
                               name TEXT, runway TEXT, transition TEXT);
        CREATE TABLE leg(procedure_id INTEGER, seq INTEGER, fix TEXT, wp_desc TEXT);
        INSERT INTO meta VALUES('cycle','\(cycle)');
        INSERT INTO meta VALUES('effective','\(effective)');
        INSERT INTO procedure VALUES(1,'KBOS','IAP','H33LX','RNAV (RNP) X RWY 33L','33L','');
        """
        XCTAssertEqual(sqlite3_exec(db, ddl, nil, nil, nil), SQLITE_OK)
        if legs {
            let f = marks ? "E  F" : "E   ", m = marks ? "GY M" : "GY  "
            sqlite3_exec(db, "INSERT INTO leg VALUES(1,10,'SHUSH','\(f)');"
                           + "INSERT INTO leg VALUES(1,20,'RW33L','\(m)');", nil, nil, nil)
        }
        if orphanProcedure {
            sqlite3_exec(db, "INSERT INTO procedure VALUES(2,'KBOS','SID','LOGAN4','LOGAN4','','');", nil, nil, nil)
        }
        return url
    }

    // MARK: refusals

    func testRefusesAFileThatIsNotADatabase() throws {
        let junk = tmp.appendingPathComponent("truncated.sqlite")
        try Data("not a database".utf8).write(to: junk)
        XCTAssertEqual(NavDataUpdate.verify(junk, as: .cifp), .unopenable)
    }

    func testRefusesADatabaseWithNoProvenance() throws {
        let url = tmp.appendingPathComponent("nometa.sqlite")
        var db: OpaquePointer?
        sqlite3_open(url.path, &db)
        sqlite3_exec(db, "CREATE TABLE procedure(id INTEGER); CREATE TABLE leg(procedure_id INTEGER);", nil, nil, nil)
        sqlite3_close(db)
        XCTAssertEqual(NavDataUpdate.verify(url, as: .cifp), .noMeta)
    }

    /// The regression this whole project is haunted by: a build that dropped the final approach fix
    /// looked fine by row count. A candidate with no F or M markers must not install.
    func testRefusesADatabaseWithNoPublishedSegmentMarkers() throws {
        let url = try makeCIFP(cycle: "2608", effective: "2026-08-06", marks: false)
        XCTAssertEqual(NavDataUpdate.verify(url, as: .cifp), .failsInvariants)
    }

    func testRefusesADatabaseWithALeglessProcedure() throws {
        let url = try makeCIFP(cycle: "2608", effective: "2026-08-06", orphanProcedure: true)
        XCTAssertEqual(NavDataUpdate.verify(url, as: .cifp), .failsInvariants,
                       "a named, selectable procedure with nothing to fly")
    }

    /// A later app release ships a newer bundle; a stale download in Application Support must not
    /// silently undo it.
    func testRefusesADatabaseOlderThanTheBundledOne() throws {
        let url = try makeCIFP(cycle: "2001", effective: "2020-01-02")
        XCTAssertEqual(NavDataUpdate.verify(url, as: .cifp), .olderThanBundle)
    }

    // MARK: the happy path, and the fallback underneath it

    func testInstallsAValidNewerCycleAndServesIt() throws {
        let url = try makeCIFP(cycle: "2699", effective: Self.iso(daysFromNow: -1))
        XCTAssertNil(NavDataUpdate.install(from: url, as: .cifp))
        XCTAssertTrue(NavDataUpdate.isOverridden(.cifp))
        XCTAssertEqual(NavDataUpdate.activeURL(.cifp)?.path, NavDataUpdate.installedURL(.cifp).path)
        XCTAssertEqual(NavDataUpdate.readCycle(NavDataUpdate.installedURL(.cifp)), "2699")
    }

    func testRevertingGoesBackToTheBundledCopyRatherThanNothing() throws {
        let url = try makeCIFP(cycle: "2699", effective: Self.iso(daysFromNow: -1))
        XCTAssertNil(NavDataUpdate.install(from: url, as: .cifp))
        NavDataUpdate.revertToBundled(.cifp)
        XCTAssertFalse(NavDataUpdate.isOverridden(.cifp))
        XCTAssertEqual(NavDataUpdate.activeURL(.cifp)?.path, NavDataUpdate.Dataset.cifp.bundledURL?.path)
    }

    /// A refused candidate must leave the previously-active database exactly as it was.
    func testARefusedCandidateDoesNotDisturbWhatIsInstalled() throws {
        let good = try makeCIFP(cycle: "2699", effective: Self.iso(daysFromNow: -1))
        XCTAssertNil(NavDataUpdate.install(from: good, as: .cifp))
        let bad = try makeCIFP(cycle: "2700", effective: Self.iso(daysFromNow: -1), marks: false)
        XCTAssertEqual(NavDataUpdate.install(from: bad, as: .cifp), .failsInvariants)
        XCTAssertEqual(NavDataUpdate.readCycle(NavDataUpdate.installedURL(.cifp)), "2699",
                       "the good cycle must still be the one installed")
    }

    /// With nothing installed the app reads the bundle — the state every install starts from.
    func testWithNothingInstalledTheBundleIsServed() {
        NavDataUpdate.revertToBundled(.cifp)
        XCTAssertFalse(NavDataUpdate.isOverridden(.cifp))
        XCTAssertNotNil(NavDataUpdate.activeURL(.cifp))
        XCTAssertNotNil(NavDataUpdate.activeURL(.apt))
    }

    // MARK: Not-yet-effective cycles

    /// ⚠️ THE CASE AN AUTOMATED JOB WALKS STRAIGHT INTO. The FAA posts a cycle weeks before it takes
    /// effect — CIFP_261029.zip was downloadable on 2026-10-19, ten days early. A daily job that
    /// fetches "the newest cycle published" therefore fetches one that is not legal to fly, and before
    /// this guard every other check waved it through: it is newer than the bundle, it has a cycle, and
    /// its invariants pass. The app would have shown next cycle's procedures as current.
    func testACycleThatHasNotTakenEffectYetIsRefused() throws {
        let future = Self.iso(daysFromNow: 10)
        let db = try makeCIFP(cycle: "2699", effective: future)
        XCTAssertEqual(NavDataUpdate.verify(db, as: .cifp), .notYetEffective,
                       "a cycle effective in 10 days must not install")
        XCTAssertEqual(NavDataUpdate.install(from: db, as: .cifp), .notYetEffective)
        XCTAssertFalse(NavDataUpdate.isOverridden(.cifp), "the bundle must still be serving")
    }

    /// The boundary is 0901Z on the effective date, which is the FAA's own cutover — not local
    /// midnight, so the answer does not depend on where the aircraft is.
    func testEffectiveTodayBeforeTheCutoverIsStillNotEffective() throws {
        let today = Self.iso(daysFromNow: 0)
        let db = try makeCIFP(cycle: "2699", effective: today)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let midnightZ = cal.startOfDay(for: Date())
        XCTAssertTrue(NavDataUpdate.isNotYetEffective(db, asOf: midnightZ.addingTimeInterval(8 * 3600)),
                      "0800Z on the effective date is before the 0901Z cutover")
        XCTAssertFalse(NavDataUpdate.isNotYetEffective(db, asOf: midnightZ.addingTimeInterval(10 * 3600)),
                       "1000Z on the effective date is after it")
    }

    /// Pre-staging is the point of checking at READ time too: a cycle installed early must not be
    /// served early, but must start being served on its own without another download.
    func testAnAlreadyEffectiveCycleInstallsAndServes() throws {
        let past = Self.iso(daysFromNow: -1)
        let db = try makeCIFP(cycle: "2699", effective: past)
        XCTAssertNil(NavDataUpdate.verify(db, as: .cifp), "yesterday's effective date is in force today")
        XCTAssertNil(NavDataUpdate.install(from: db, as: .cifp))
        XCTAssertTrue(NavDataUpdate.isOverridden(.cifp), "it should now be serving")
    }

    /// An undated database is not guessed at, matching `isOlderThanBundle`'s existing stance.
    func testAnUndatedCandidateIsNotTreatedAsNotYetEffective() throws {
        let db = try makeCIFP(cycle: "2699", effective: "")
        XCTAssertFalse(NavDataUpdate.isNotYetEffective(db), "no effective date means no opinion")
    }

    private static func iso(daysFromNow: Int) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let d = cal.date(byAdding: .day, value: daysFromNow, to: Date())!
        let f = DateFormatter()
        f.calendar = cal; f.timeZone = cal.timeZone
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }
}
