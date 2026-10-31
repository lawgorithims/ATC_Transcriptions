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
        NavDataUpdate.revertToBundled(.procedures)
        // These tests INSTALL a cycle-2699 fixture DB into the shared Application Support path. CIFP's
        // handle is a resolve-once static, so any CIFP read that happened while the override was active
        // bound the shared handle to that tiny fixture — starving every later CIFP-backed test in the
        // process. Reopen against the now-reverted (bundled) path so the leak cannot cross the class
        // boundary. (revert alone is not enough once the handle is already bound.)
        // Staged fixtures must not outlive their test: `activateStagedIfDue` is wired to the first
        // nav read, so a file left in the slot can install itself under an unrelated test.
        for d in NavDataUpdate.Dataset.allCases { NavDataUpdate.removeStaged(d) }
        CIFP.reopenForTests()
        AirportData.reopenForTests()
        // Airways reads the airway table out of the SAME cifp.sqlite and now resolves it through
        // NavDataUpdate too, so it has the identical fixture-leak and needs the identical reset.
        Airways.reopenForTests()
        // procedures.json is an updatable dataset too now, and `Procedures.data` is the same kind of
        // resolve-once static.
        Procedures.reloadForTests()
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
    /// ⚠️ THE EFFECTIVE DATE IS RELATIVE, AND HAS TO BE. These fixtures were dated "2026-08-06",
    /// which was newer than the bundle when they were written. Refreshing the bundled CIFP to cycle
    /// 2610 made them OLDER than it, and `verify` checks `isOlderThanBundle` before the corpus — so
    /// both tests started reporting `.olderThanBundle` and stopped exercising the invariant they
    /// exist for. A fixture that pins a date against a bundle that moves is a test with an expiry
    /// date of its own; `daysFromNow: -1` is newer than any bundle, because `BundledNavDataTests`
    /// forbids shipping one dated in the future.
    func testRefusesADatabaseWithNoPublishedSegmentMarkers() throws {
        let url = try makeCIFP(cycle: "2699", effective: Self.iso(daysFromNow: -1), marks: false)
        XCTAssertEqual(NavDataUpdate.verify(url, as: .cifp), .failsInvariants)
    }

    func testRefusesADatabaseWithALeglessProcedure() throws {
        let url = try makeCIFP(cycle: "2699", effective: Self.iso(daysFromNow: -1), orphanProcedure: true)
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
        let installed = try XCTUnwrap(NavDataUpdate.installedURL(.cifp))
        XCTAssertEqual(NavDataUpdate.activeURL(.cifp)?.path, installed.path)
        XCTAssertEqual(NavDataUpdate.readCycle(installed), "2699")
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
        XCTAssertEqual(NavDataUpdate.readCycle(try XCTUnwrap(NavDataUpdate.installedURL(.cifp))), "2699",
                       "the good cycle must still be the one installed")
    }

    // MARK: Never under a reader

    /// Taking an update, or reverting, while a downloaded cycle is being served must not take the
    /// procedures away for the rest of the session.
    ///
    /// Apple's libsqlite3 INVALIDATES an open connection whose file was replaced or deleted ("vnode
    /// renamed / unlinked while in use"), and `CIFP` reads every failed query as no rows. Installing
    /// over one fixed `cifp.sqlite` therefore emptied every approach the moment the pilot tapped
    /// Update — measured here before the fix: the procedure count fell from 1 to 0 on the install, and
    /// again on the revert. The open cycle must stay readable; the new one is served from next launch.
    func testAnUpdateTakenMidSessionLeavesTheOpenCycleReadable() throws {
        let first = try makeCIFP(cycle: "2698", effective: Self.iso(daysFromNow: -2))
        XCTAssertNil(NavDataUpdate.install(from: first, as: .cifp))
        CIFP.reopenForTests()                                   // this "launch" reads the download
        XCTAssertEqual(CIFP.procedureCount, 1, "precondition: serving the installed fixture")

        let second = try makeCIFP(cycle: "2699", effective: Self.iso(daysFromNow: -1))
        XCTAssertNil(NavDataUpdate.install(from: second, as: .cifp))
        XCTAssertEqual(CIFP.procedureCount, 1, "installing a newer cycle took the open one away")
        XCTAssertEqual(NavDataUpdate.readCycle(try XCTUnwrap(NavDataUpdate.activeURL(.cifp))), "2699",
                       "the next launch serves the new cycle")

        NavDataUpdate.revertToBundled(.cifp)
        XCTAssertEqual(CIFP.procedureCount, 1, "reverting took the open cycle away")
        XCTAssertEqual(NavDataUpdate.activeURL(.cifp)?.path, NavDataUpdate.Dataset.cifp.bundledURL?.path)
    }

    /// The files an install supersedes are removed only at the next launch, before any reader opens —
    /// never by the install itself.
    func testASupersededCopyIsPrunedAtTheNextLaunchNotByTheInstall() throws {
        XCTAssertNil(NavDataUpdate.install(from: try makeCIFP(cycle: "2698", effective: Self.iso(daysFromNow: -2)),
                                           as: .cifp))
        let old = try XCTUnwrap(NavDataUpdate.installedURL(.cifp))
        XCTAssertNil(NavDataUpdate.install(from: try makeCIFP(cycle: "2699", effective: Self.iso(daysFromNow: -1)),
                                           as: .cifp))
        let new = try XCTUnwrap(NavDataUpdate.installedURL(.cifp))
        XCTAssertNotEqual(old, new, "each install gets a file of its own")
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path), "the install deleted the copy in use")

        NavDataUpdate.pruneSuperseded()                         // what the next launch does first
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path), "a superseded copy outlived its launch")
        XCTAssertTrue(FileManager.default.fileExists(atPath: new.path), "pruning removed the cycle being served")
        XCTAssertEqual(NavDataUpdate.installedURL(.cifp), new)

        NavDataUpdate.revertToBundled(.cifp)
        NavDataUpdate.pruneSuperseded()
        XCTAssertFalse(FileManager.default.fileExists(atPath: new.path), "a reverted copy outlived its launch")
        XCTAssertNil(NavDataUpdate.installedURL(.cifp))
    }

    /// A cycle downloaded by a build that installed to the fixed `cifp.sqlite` keeps being served, and
    /// goes away only once an install has superseded it — at the following launch.
    func testALegacyInstallIsStillServedUntilSuperseded() throws {
        let legacy = NavDataUpdate.legacyInstalledURL(.cifp)
        try FileManager.default.createDirectory(at: NavDataUpdate.directory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: NavDataUpdate.pointerURL(.cifp))
        try? FileManager.default.removeItem(at: legacy)
        try FileManager.default.copyItem(at: try makeCIFP(cycle: "2698", effective: Self.iso(daysFromNow: -2)),
                                         to: legacy)
        defer { try? FileManager.default.removeItem(at: legacy) }
        XCTAssertEqual(NavDataUpdate.activeURL(.cifp)?.path, legacy.path, "an older build's download is served")
        NavDataUpdate.pruneSuperseded()
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path), "pruning removed a served legacy copy")

        XCTAssertNil(NavDataUpdate.install(from: try makeCIFP(cycle: "2699", effective: Self.iso(daysFromNow: -1)),
                                           as: .cifp))
        XCTAssertEqual(NavDataUpdate.readCycle(try XCTUnwrap(NavDataUpdate.activeURL(.cifp))), "2699")
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path), "the install deleted the legacy copy")
        NavDataUpdate.pruneSuperseded()
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path), "the superseded legacy copy stayed")
    }

    /// The pointer can only ever name a file of its own dataset inside NavData.
    func testAPointerCannotAimOutsideItsDataset() throws {
        try FileManager.default.createDirectory(at: NavDataUpdate.directory, withIntermediateDirectories: true)
        for bad in ["../../cifp.sqlite", "/etc/hosts", "apt-2699-ABCD.sqlite", "cifp-2699-ABCD.json", ""] {
            try Data((bad + "\n").utf8).write(to: NavDataUpdate.pointerURL(.cifp), options: .atomic)
            XCTAssertNotEqual(NavDataUpdate.activeURL(.cifp)?.lastPathComponent, bad, "served a pointer to \(bad)")
            XCTAssertEqual(NavDataUpdate.activeURL(.cifp)?.path, NavDataUpdate.Dataset.cifp.bundledURL?.path,
                           "a malformed pointer must fall back to the bundle, not to nothing: \(bad)")
        }
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

    // MARK: Pre-downloading the next cycle (the staging slot)

    /// The exemption exists for exactly one caller and must not leak into the live path.
    func testStagingVerifiesEverythingExceptTheEffectiveDate() throws {
        let future = Self.iso(daysFromNow: 9)
        let db = try makeCIFP(cycle: "2699", effective: future)
        XCTAssertEqual(NavDataUpdate.verify(db, as: .cifp), .notYetEffective,
                       "the live path still refuses a cycle that has not started")
        XCTAssertNil(NavDataUpdate.verify(db, as: .cifp, allowNotYetEffective: true),
                     "the staging path accepts it — that is the whole point of pre-downloading")
    }

    /// The exemption must not become a way to smuggle a BROKEN database past the real checks. This is
    /// the test that would fail if someone "simplified" staging to skip verification entirely.
    func testStagingStillRefusesADatabaseThatFailsItsInvariants() throws {
        let future = Self.iso(daysFromNow: 9)
        let gutted = try makeCIFP(cycle: "2699", effective: future, legs: false)
        XCTAssertEqual(NavDataUpdate.verify(gutted, as: .cifp, allowNotYetEffective: true),
                       .failsInvariants,
                       "a procedure with no legs is not flyable whenever it becomes effective")
    }

    /// A staged cycle waits, and is not installed a day early.
    func testStagedCycleIsNotActivatedBeforeItsEffectiveDate() throws {
        let future = Self.iso(daysFromNow: 9)
        let db = try makeCIFP(cycle: "2699", effective: future)
        try stage(db, as: .cifp, cycle: "2699")

        XCTAssertEqual(NavDataUpdate.stagedCycle(.cifp), "2699", "it is waiting")
        XCTAssertEqual(NavDataUpdate.activateStagedIfDue(), [],
                       "nothing is due, so nothing is installed")
        XCTAssertFalse(NavDataUpdate.isOverridden(.cifp), "the bundle must still be serving")
        XCTAssertEqual(NavDataUpdate.stagedCycle(.cifp), "2699", "and it must still be waiting")
    }

    /// …and then activates by itself, with no second download, and is actually SERVED.
    ///
    /// Dated yesterday on purpose, against the real clock. That is the true shape of the event: a
    /// staged file waits until its date has passed, so by the time anything activates it the date is
    /// behind us — and it lets this test assert the end state (`isOverridden`, which has no injectable
    /// clock) instead of only that `install` returned nil.
    func testStagedCycleActivatesAndIsServedOnceItsDateHasPassed() throws {
        let db = try makeCIFP(cycle: "2699", effective: Self.iso(daysFromNow: -1))
        try stage(db, as: .cifp, cycle: "2699")

        XCTAssertEqual(NavDataUpdate.activateStagedIfDue(), [.cifp])
        XCTAssertTrue(NavDataUpdate.isOverridden(.cifp), "it is now the database being served")
        XCTAssertEqual(NavDataUpdate.readCycle(try XCTUnwrap(NavDataUpdate.installedURL(.cifp))), "2699")
        XCTAssertNil(NavDataUpdate.stagedCycle(.cifp),
                     "and the staging slot is cleared, so it cannot be installed twice")
    }

    /// Midnight UTC on the effective date is NOT the cutover — 0901Z is. A staged cycle must sit
    /// through those nine hours rather than going live with the date change.
    func testStagedCycleStillWaitsAtMidnightOnItsEffectiveDate() throws {
        let db = try makeCIFP(cycle: "2699", effective: Self.iso(daysFromNow: 0))
        try stage(db, as: .cifp, cycle: "2699")

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let midnightZ = cal.startOfDay(for: Date())

        XCTAssertEqual(NavDataUpdate.activateStagedIfDue(asOf: midnightZ.addingTimeInterval(8 * 3600)),
                       [], "0800Z is still the previous cycle")
        XCTAssertEqual(NavDataUpdate.stagedCycle(.cifp), "2699", "it waits, it is not discarded")
        XCTAssertEqual(NavDataUpdate.activateStagedIfDue(asOf: midnightZ.addingTimeInterval(10 * 3600)),
                       [.cifp], "1000Z is past the cutover, so now it installs")
    }

    /// A staged file that cannot pass the full install is discarded rather than retried every launch.
    func testAnUnusableStagedFileIsDroppedRatherThanRetriedForever() throws {
        let past = Self.iso(daysFromNow: -1)
        // Due, but gutted: `install`'s own verify must refuse it.
        let bad = try makeCIFP(cycle: "2699", effective: past, legs: false)
        try stage(bad, as: .cifp, cycle: "2699")

        XCTAssertEqual(NavDataUpdate.activateStagedIfDue(), [], "it must not install")
        XCTAssertFalse(NavDataUpdate.isOverridden(.cifp))
        XCTAssertNil(NavDataUpdate.stagedCycle(.cifp),
                     "a staged file that cannot pass is not going to start passing — it is removed")
    }

    /// Activation is called from a `static let` on the read path, so it has to be safe to call twice.
    func testActivationIsIdempotent() throws {
        XCTAssertEqual(NavDataUpdate.activateStagedIfDue(), [])
        XCTAssertEqual(NavDataUpdate.activateStagedIfDue(), [])
    }

    /// Put a file in the staging slot the way `NavDataLibrary.run` does.
    private func stage(_ url: URL, as d: NavDataUpdate.Dataset, cycle: String) throws {
        try FileManager.default.createDirectory(at: NavDataUpdate.stagedDirectory,
                                                withIntermediateDirectories: true)
        let slot = NavDataUpdate.stagedURL(d, cycle: cycle)
        try? FileManager.default.removeItem(at: slot)
        try FileManager.default.copyItem(at: url, to: slot)
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
