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
        NavDataUpdate.revertToBundled(.cifp)
    }

    /// A minimal database shaped like the real one, so the invariant checks have something to bite on.
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
        let url = try makeCIFP(cycle: "2699", effective: "2099-01-01")
        XCTAssertNil(NavDataUpdate.install(from: url, as: .cifp))
        XCTAssertTrue(NavDataUpdate.isOverridden(.cifp))
        XCTAssertEqual(NavDataUpdate.activeURL(.cifp)?.path, NavDataUpdate.installedURL(.cifp).path)
        XCTAssertEqual(NavDataUpdate.readCycle(NavDataUpdate.installedURL(.cifp)), "2699")
    }

    func testRevertingGoesBackToTheBundledCopyRatherThanNothing() throws {
        let url = try makeCIFP(cycle: "2699", effective: "2099-01-01")
        XCTAssertNil(NavDataUpdate.install(from: url, as: .cifp))
        NavDataUpdate.revertToBundled(.cifp)
        XCTAssertFalse(NavDataUpdate.isOverridden(.cifp))
        XCTAssertEqual(NavDataUpdate.activeURL(.cifp)?.path, NavDataUpdate.Dataset.cifp.bundledURL?.path)
    }

    /// A refused candidate must leave the previously-active database exactly as it was.
    func testARefusedCandidateDoesNotDisturbWhatIsInstalled() throws {
        let good = try makeCIFP(cycle: "2699", effective: "2099-01-01")
        XCTAssertNil(NavDataUpdate.install(from: good, as: .cifp))
        let bad = try makeCIFP(cycle: "2700", effective: "2099-02-01", marks: false)
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
}
