import Foundation
import SQLite3

/// Where a bundled navigation database is read from, so a new AIRAC cycle can be installed without an
/// App Store build.
///
/// `cifp.sqlite` expires every 28 days and was frozen in the app bundle, which meant a pilot's only
/// route to current procedures was waiting for a release. Charts and plates already download; this
/// gives the coded procedures — the data the approach-activation sheet actually flies — the same path.
///
/// The contract is deliberately conservative, because the failure mode is a pilot holding NO procedure
/// data at all:
///
///   * The bundled copy is never removed. A downloaded database is an OVERRIDE, and any doubt about it
///     falls back to the bundle rather than to nothing.
///   * A download is verified BEFORE it is installed — it must open, carry a meta table with a readable
///     cycle, and satisfy the same corpus invariants the builder enforces. A truncated or corrupt file
///     never becomes the active database.
///   * Installation is atomic (write to a temporary name, then replace), so a crash mid-write cannot
///     leave a half-written database in the active slot.
///   * An installed database that is OLDER than the bundled one is rejected. Shipping a newer bundle in
///     a later app release must not be silently undone by a stale download sitting in Application
///     Support.
enum NavDataUpdate {
    /// Datasets that can be overridden by a download.
    enum Dataset: String, CaseIterable {
        case cifp, apt, procedures

        var displayName: String {
            switch self {
            case .cifp:       return "Procedures"
            case .apt:        return "Airports"
            case .procedures: return "Approach plates"
            }
        }

        /// `procedures` is JSON, the other two are SQLite. It is in here anyway because it is the
        /// dataset whose staleness BROKE A FEATURE OUTRIGHT: `Procedures.plateURL` interpolates the
        /// bundled cycle into https://aeronav.faa.gov/d-tpp/<cycle>/<pdf>, the FAA ages old cycles
        /// off, and so every approach plate in the app 404'd for 74 days with nothing reporting it.
        var fileExtension: String { self == .procedures ? "json" : "sqlite" }

        /// The bundled fallback, always present.
        var bundledURL: URL? {
            Bundle.main.url(forResource: rawValue, withExtension: fileExtension, subdirectory: "nav")
                ?? Bundle.main.url(forResource: rawValue, withExtension: fileExtension)
        }
    }

    /// Application Support/NavData — outside Documents so it is not user-visible, and excluded from
    /// backup because it is reproducible from the network.
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("NavData", isDirectory: true)
    }

    static func installedURL(_ d: Dataset) -> URL {
        directory.appendingPathComponent("\(d.rawValue).\(d.fileExtension)")
    }

    /// The database to actually open: a verified download when one is installed, else the bundle.
    ///
    /// Called once per launch from each reader's lazy `open()`, so a swap takes effect on the next
    /// launch rather than under a query already in flight.
    static func activeURL(_ d: Dataset) -> URL? {
        let installed = installedURL(d)
        if FileManager.default.fileExists(atPath: installed.path),
           !readCycle(installed).isEmpty,
           !isOlderThanBundle(installed, d),
           // Re-checked at READ time, not just at install: a cycle staged ahead of its effective date
           // would otherwise go live the moment it was written. Checking here means a pre-staged cycle
           // simply starts being used on the morning it becomes legal, with no further download.
           !isNotYetEffective(installed) {
            return installed
        }
        return d.bundledURL
    }

    /// Cycle identifier from a database's `meta` table, or "" if it has none.
    static func readCycle(_ url: URL) -> String {
        meta(url)["cycle"] ?? ""
    }

    static func meta(_ url: URL) -> [String: String] {
        // procedures.json keeps its provenance as top-level `cycle`/`from`/`to` rather than a meta
        // table. Normalised to the same keys the SQLite path returns so every caller —
        // `isOlderThanBundle`, `isNotYetEffective`, `activeURL`, the Downloads row — is unchanged.
        if url.pathExtension == "json" {
            guard let d = try? Data(contentsOf: url),
                  let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return [:] }
            var m: [String: String] = [:]
            if let c = o["cycle"] as? String, !c.isEmpty { m["cycle"] = c }
            if let f = o["from"] as? String, !f.isEmpty { m["effective"] = f }
            if let t = o["to"] as? String, !t.isEmpty { m["expires"] = t }
            return m
        }
        var out: [String: String] = [:]
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_close(db) }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT key, value FROM meta", -1, &st, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(st) }
        while sqlite3_step(st) == SQLITE_ROW, out.count < 64 {          // bounded (rule 2)
            guard let k = sqlite3_column_text(st, 0), let v = sqlite3_column_text(st, 1) else { continue }
            out[String(cString: k)] = String(cString: v)
        }
        return out
    }

    /// A downloaded database that predates the bundled one is rejected: a later app release ships a
    /// newer bundle, and a stale download must not silently undo it.
    static func isOlderThanBundle(_ url: URL, _ d: Dataset) -> Bool {
        guard let bundled = d.bundledURL else { return false }
        let a = meta(url)["effective"] ?? "", b = meta(bundled)["effective"] ?? ""
        guard !a.isEmpty, !b.isEmpty else { return false }              // undated: don't guess
        return a < b                                                    // ISO dates compare lexically
    }

    /// Why a candidate database was rejected, for the log and the UI.
    enum Rejection: String {
        case unopenable, noMeta, noCycle, failsInvariants, olderThanBundle, notYetEffective
        var reason: String {
            switch self {
            case .unopenable:      return "the file is not a readable database"
            case .noMeta:          return "it carries no provenance"
            case .noCycle:         return "it carries no cycle identifier"
            case .failsInvariants: return "its contents failed the integrity checks"
            case .olderThanBundle: return "it is older than the data already built in"
            case .notYetEffective: return "its cycle has not taken effect yet"
            }
        }
    }

    /// Is this database's cycle not yet in force?
    ///
    /// ⚠️ THE FAA PUBLISHES A CYCLE WEEKS BEFORE IT TAKES EFFECT. CIFP_261029.zip was downloadable on
    /// 2026-10-19, ten days before 2026-10-29. Everything else in this file — `isOlderThanBundle`,
    /// `activeURL`, and the currency banner — reasons about `expires` and about being too OLD. Nothing
    /// looked at `effective`, so an automated job that simply fetched "the newest cycle the FAA has
    /// posted" would install procedures that are not legal to fly yet, and the app would show them as
    /// current with no warning. Flying next cycle's approach today is a worse error than flying last
    /// cycle's, because the pilot has no reason to suspect it.
    ///
    /// Compared in UTC against the cycle boundary the FAA actually uses (0901Z), not local midnight, so
    /// the swap happens at the real cutover wherever the aircraft is. Undated databases are not guessed
    /// at — `isOlderThanBundle` already takes that position.
    static func isNotYetEffective(_ url: URL, asOf now: Date = Date()) -> Bool {
        guard let eff = meta(url)["effective"], !eff.isEmpty else { return false }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        let f = DateFormatter()
        f.calendar = cal; f.timeZone = cal.timeZone
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: eff) else { return false }           // unparseable: don't guess
        return now < d.addingTimeInterval(9 * 3600 + 60)                // 0901Z on the effective date
    }

    /// Verify a candidate BEFORE it replaces anything. Mirrors the builder's own self-checks, so a file
    /// that was truncated in transit, or built by a broken pipeline, never becomes the active database.
    static func verify(_ url: URL, as d: Dataset) -> Rejection? {
        if d == .procedures { return verifyProcedures(url) }
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return .unopenable }
        defer { sqlite3_close(db) }
        // sqlite3_open defers header validation to the first read, so a truncated download — or any
        // file at all — "opens" successfully. Touch the schema so a junk file is reported as what it is
        // rather than as a database that merely lacks provenance.
        guard count(db, "SELECT COUNT(*) FROM sqlite_master") >= 0 else { return .unopenable }

        let m = meta(url)
        guard !m.isEmpty else { return .noMeta }
        guard !(m["cycle"] ?? "").isEmpty else { return .noCycle }
        if isOlderThanBundle(url, d) { return .olderThanBundle }
        if isNotYetEffective(url) { return .notYetEffective }

        // The same invariants navdb.py verifies, so a database that would have failed the build cannot
        // pass here either. Every one of these was a real defect at some point in this project's life.
        let checks: [(String, Int)]
        switch d {
        case .cifp:
            checks = [("SELECT COUNT(*) FROM procedure", 1),
                      ("SELECT COUNT(*) FROM leg", 1),
                      // one published missed-approach point per approach, and one final approach fix
                      ("SELECT COUNT(*) FROM leg WHERE substr(wp_desc,4,1)='M'", 1),
                      ("SELECT COUNT(*) FROM leg WHERE substr(wp_desc,4,1)='F'", 1)]
        case .apt:
            checks = [("SELECT COUNT(*) FROM airport", 1),
                      ("SELECT COUNT(*) FROM runway_end", 1),
                      ("SELECT COUNT(*) FROM frequency", 1)]
        case .procedures:
            // Unreachable — `verify` hands this case to `verifyProcedures` before opening SQLite.
            // Spelled out rather than covered by a `default:` on purpose: a `default` here would
            // silently absorb the NEXT dataset someone adds, letting it install having had no corpus
            // check at all, which is the one thing this function exists to prevent.
            return verifyProcedures(url)
        }
        for (sql, atLeast) in checks {
            guard count(db, sql) >= atLeast else { return .failsInvariants }
        }
        if d == .cifp {
            // A procedure with no legs is a named, selectable path with nothing to fly.
            guard count(db, "SELECT COUNT(*) FROM procedure p WHERE NOT EXISTS"
                        + "(SELECT 1 FROM leg WHERE procedure_id=p.id)") == 0 else { return .failsInvariants }
        }
        return nil
    }

    /// The JSON sibling of `verify`. Same contract, different shape of corpus check.
    ///
    /// The invariant that matters is NOT "is this valid JSON" — a truncated download usually is not,
    /// and `JSONSerialization` catches that. It is that the file describes a usable plate index:
    /// provenance that can be dated, and enough airports to be the real thing rather than a stub. A
    /// 3,197-airport index silently replaced by one holding four would leave most of the country with
    /// no plates and nothing saying why.
    private static func verifyProcedures(_ url: URL) -> Rejection? {
        guard let data = try? Data(contentsOf: url),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return .unopenable }
        let m = meta(url)
        guard !m.isEmpty else { return .noMeta }
        guard !(m["cycle"] ?? "").isEmpty else { return .noCycle }
        guard let airports = o["airports"] as? [String: Any], airports.count >= 1000 else {
            return .failsInvariants
        }
        if isOlderThanBundle(url, .procedures) { return .olderThanBundle }
        if isNotYetEffective(url) { return .notYetEffective }
        return nil
    }

    /// Install a verified database atomically. Returns the rejection when it was refused.
    @discardableResult
    static func install(from staged: URL, as d: Dataset) -> Rejection? {
        if let bad = verify(staged, as: d) {
            NSLog("CommSight: nav update REFUSED for %@ — %@", d.rawValue, bad.reason)
            return bad
        }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let dest = installedURL(d)
            let tmp = dest.appendingPathExtension("incoming")
            if fm.fileExists(atPath: tmp.path) { try fm.removeItem(at: tmp) }
            try fm.copyItem(at: staged, to: tmp)
            // Replace, never remove-then-copy: a crash between the two would leave no database at all.
            _ = try fm.replaceItemAt(dest, withItemAt: tmp)
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            var d2 = dest; try? d2.setResourceValues(values)
            NSLog("CommSight: nav update INSTALLED %@ cycle %@", d.rawValue, readCycle(dest))
            return nil
        } catch {
            NSLog("CommSight: nav update FAILED to install %@ — %@", d.rawValue, "\(error)")
            return .unopenable
        }
    }

    /// Drop a downloaded override and go back to the bundled data.
    static func revertToBundled(_ d: Dataset) {
        try? FileManager.default.removeItem(at: installedURL(d))
        NSLog("CommSight: nav update reverted %@ to the bundled copy", d.rawValue)
    }

    /// Is this dataset currently being served from a download rather than the bundle?
    static func isOverridden(_ d: Dataset) -> Bool {
        activeURL(d)?.path == installedURL(d).path
    }

    private static func count(_ db: OpaquePointer?, _ sql: String) -> Int {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return -1 }
        defer { sqlite3_finalize(st) }
        return sqlite3_step(st) == SQLITE_ROW ? Int(sqlite3_column_int(st, 0)) : -1
    }
}
