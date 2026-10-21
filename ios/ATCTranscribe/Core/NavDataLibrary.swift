import Foundation
import Combine
import CryptoKit

/// Fetches updated navigation databases so a pilot's procedures and airports are not frozen at
/// whatever shipped in the app bundle.
///
/// THE GAP THIS FILLS. `NavDataUpdate` is a complete, tested installer — it verifies a candidate
/// against the same invariants the builder enforces, refuses one older than the bundle or not yet in
/// effect, installs atomically, and falls back to the bundle on any doubt. `CIFP.swift` and
/// `AirportData.swift` already read through `NavDataUpdate.activeURL`. But nothing ever CALLED the
/// installer outside its own tests: there was no manifest, no URL and no downloader, so the read half
/// of the contract shipped and the write half did not exist. Procedures and airports could only be
/// refreshed by an App Store release, on a 28-day cycle, and measured on 2026-10-19 both were three
/// cycles stale with the expiry banner showing on first launch.
///
/// The manifest is published by `nav/publish_nav.py`:
///
///     { "schema": 1,
///       "datasets": { "cifp": { cycle, effective, expires, bytes, sha256, path }, "apt": { … } },
///       "next":     { … } }          // optional: a cycle published ahead of its effective date
///
/// `next` exists because the FAA posts a cycle weeks early, and `publish_nav.py --stage-next` writes
/// it under a `next/` prefix so it cannot overwrite the in-force file.
///
/// `next` IS NOW CONSUMED — `precacheNext()`. A staged cycle is downloaded ahead of time, verified in
/// full apart from the one check it cannot pass yet (its own effective date), and parked in
/// `NavDataUpdate.stagedDirectory`. `NavDataUpdate.activateStagedIfDue()` installs it through the
/// ordinary verified path on the morning it becomes legal, so the roll needs no network at all.
/// (Earlier revisions of this comment first claimed the pre-download worked when it did not, then
/// recorded it as unwritten. It is written now, and `NavDataLibraryTests` holds it to that.)
@MainActor
final class NavDataLibrary: ObservableObject {
    static let shared = NavDataLibrary()

    /// Keep this in step with `nav/publish_nav.py`'s HF_NAV_DATASET default.
    static let base = "https://huggingface.co/datasets/SingularityUS/commsight-nav/resolve/main"

    struct Catalog: Decodable {
        let schema: Int
        let datasets: [String: Entry]
        let next: [String: Entry]?

        struct Entry: Decodable {
            let dataset: String
            let cycle: String
            let effective: String
            let expires: String
            let bytes: Int
            let sha256: String
            let path: String
        }
    }

    enum State: Equatable {
        case idle, checking, downloading(Double), verifying, installed(cycle: String), failed(String)
        /// Downloaded and verified, waiting for its effective date. Distinct from `.installed` on
        /// purpose: nothing is being SERVED from it yet, and a row that said "installed" for a cycle
        /// the app is deliberately not reading would be a lie the pilot could act on.
        case staged(cycle: String)
    }

    /// Where a finished download goes.
    private enum Destination: Equatable {
        case install                    // live now: verified and swapped in
        case stage(cycle: String)       // not yet effective: verified and parked
    }

    @Published private(set) var catalog: Catalog?
    @Published private(set) var states: [String: State] = [:]
    /// Progress of the next-cycle pre-download, keyed by dataset. Kept apart from `states` so the
    /// "an update is available" rows and the "next cycle is ready" rows cannot be confused for each
    /// other — they mean opposite things about what the app is currently reading.
    @Published private(set) var staging: [String: State] = [:]
    @Published private(set) var problem: String?

    private var tasks: [String: Task<Void, Never>] = [:]

    private var dir: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("NavStaging", isDirectory: true)
    }

    // MARK: Catalog

    /// Fetch the manifest. Revalidating rather than cached: a stale manifest is how a device decides
    /// it is already current and never asks again — the precise silence this whole pipeline exists to
    /// break.
    @discardableResult
    func refresh() async -> Bool {
        guard let url = URL(string: "\(Self.base)/index.json") else { return false }
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadRevalidatingCacheData
        req.timeoutInterval = 30
        do {
            let (data, resp) = try await NetworkActivity.data(for: req, "Nav data index", .navData)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                problem = "The nav-data server returned an unexpected response."
                return false
            }
            let decoded = try JSONDecoder().decode(Catalog.self, from: data)
            // Refuse a manifest from the future, the way LZPackCatalog does. A schema bump means
            // fields this build does not understand; installing from it would be acting on a
            // contract we cannot read, and the bundled data is a safe place to stay.
            guard decoded.schema == 1 else {
                problem = "This app is too old to read the nav-data catalog (schema "
                    + "\(decoded.schema)). Update the app to get new procedures and airports."
                catalog = nil
                return false
            }
            catalog = decoded
            problem = nil
            return true
        } catch {
            // Offline is the normal case for an EFB, not an error worth shouting about. The bundled
            // data keeps serving; say nothing alarming.
            problem = nil
            return false
        }
    }

    /// Datasets where the published cycle is newer than what is being served, and already in force.
    ///
    /// Compares against `activeURL`, NOT the bundle: once a download is installed, the question is
    /// whether the server has something newer still, and comparing to the bundle would re-offer an
    /// update the pilot already took.
    func available() -> [(dataset: NavDataUpdate.Dataset, entry: Catalog.Entry)] {
        guard let cat = catalog else { return [] }
        let today = Self.todayISO()
        return NavDataUpdate.Dataset.allCases.compactMap { d in
            guard let e = cat.datasets[d.rawValue] else { return nil }
            guard e.effective <= today else { return nil }          // not in force yet — not offered
            let serving = NavDataUpdate.activeURL(d).map { NavDataUpdate.meta($0)["effective"] ?? "" } ?? ""
            guard !serving.isEmpty, e.effective > serving else { return nil }
            return (d, e)
        }
    }

    // MARK: Download + install

    /// Clear a failed state and try again. Nothing else resets `states`, so without this a single
    /// failure was permanent for the life of the process.
    func retry(_ d: NavDataUpdate.Dataset) {
        states[d.rawValue] = nil
        update(d)
    }

    func update(_ d: NavDataUpdate.Dataset, allowMetered: Bool = false) {
        guard tasks[d.rawValue] == nil, let e = catalog?.datasets[d.rawValue] else { return }
        states[d.rawValue] = .checking
        tasks[d.rawValue] = Task { [weak self] in
            defer { Task { @MainActor [weak self] in self?.tasks[d.rawValue] = nil } }
            // ⚠️ THIS PATH HAD NO CONNECTION CHECK AT ALL. Every chart path consulted something;
            // nav data — 22 MB of databases — asked nothing, so a pilot with Wi-Fi-only set and a
            // cockpit hotspot as their only link got exactly the bill the setting exists to prevent.
            if !allowMetered {
                let verdict = await DownloadPolicy.shared.verdict(.userInitiated)
                if !verdict.isAllowed {
                    self?.states[d.rawValue] = .failed(verdict.explanation ?? "Paused.")
                    return
                }
            }
            await self?.run(d, e, .install)
        }
    }

    // MARK: Next-cycle pre-download

    /// Datasets the publisher has staged ahead of their effective date and this device has not.
    func stageable(now: Date = Date()) -> [(dataset: NavDataUpdate.Dataset, entry: Catalog.Entry)] {
        guard let next = catalog?.next else { return [] }
        let today = Self.todayISO(now)
        return NavDataUpdate.Dataset.allCases.compactMap { d in
            guard let e = next[d.rawValue] else { return nil }
            guard e.effective > today else { return nil }           // in force already: the ordinary path
            guard NavDataUpdate.stagedCycle(d) != e.cycle else { return nil }   // already waiting
            return (d, e)
        }
    }

    /// Cycles already downloaded and waiting for their effective date.
    func stagedReady() -> [(dataset: NavDataUpdate.Dataset, cycle: String)] {
        NavDataUpdate.Dataset.allCases.compactMap { d in
            NavDataUpdate.stagedCycle(d).map { (d, $0) }
        }
    }

    /// Download every staged cycle this device is missing, under the pilot's download settings.
    func precacheNext(now: Date = Date()) async {
        guard DownloadPolicy.shared.precacheNextCycle else { return }
        let todo = stageable(now: now)
        guard !todo.isEmpty else { return }
        for (d, e) in todo {
            guard tasks[d.rawValue] == nil else { continue }
            // Re-checked per dataset, not once for the batch: three databases is three chances for the
            // link to change underneath us.
            guard (await DownloadPolicy.shared.verdict(.background)).isAllowed else {
                staging[d.rawValue] = .idle          // not a failure; it will be retried next launch
                return
            }
            staging[d.rawValue] = .checking
            await run(d, e, .stage(cycle: e.cycle))
        }
    }

    private func run(_ d: NavDataUpdate.Dataset, _ e: Catalog.Entry, _ dest: Destination) async {
        // One progress channel per destination — see `staging`.
        func set(_ st: State) {
            if case .stage = dest { staging[d.rawValue] = st } else { states[d.rawValue] = st }
        }
        guard let url = URL(string: "\(Self.base)/\(e.path)") else {
            set(.failed("The download address is not valid.")); return
        }
        // ⚠️ THE DATASET'S OWN EXTENSION, NOT ".sqlite". `NavDataUpdate.meta` decides whether to read
        // provenance as JSON or out of a SQLite `meta` table by looking at `url.pathExtension`
        // (NavDataUpdate.swift), so staging procedures.json as `procedures-2610.sqlite` sent a JSON
        // file down the SQLite path: sqlite3_open succeeds on anything, the schema probe fails, and
        // the download was rejected as `.unopenable`. The plate index — the dataset whose staleness
        // 404'd every approach plate for 74 days — could never have installed.
        let staged = dir.appendingPathComponent("\(d.rawValue)-\(e.cycle).\(d.fileExtension)")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            set(.downloading(0))
            let (tmp, resp) = try await NetworkActivity.download(
                from: url, "\(d.displayName) \(e.cycle)", .navData,
                { if case .stage = dest { return .background } else { return .normal } }())
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                // The caller owns the file `download(from:)` wrote, even on a non-200 — returning
                // without removing it leaks a full-size temp per failed attempt, and a retry loop on
                // a flaky link would fill the caches directory with copies of an error page.
                try? FileManager.default.removeItem(at: tmp)
                set(.failed("The server did not return the database.")); return
            }
            if FileManager.default.fileExists(atPath: staged.path) {
                try FileManager.default.removeItem(at: staged)
            }
            try FileManager.default.moveItem(at: tmp, to: staged)

            // TWO CHECKS, because they catch different things — the same split LZPackLibrary makes.
            // sha256 catches a truncated or corrupted transfer; NavDataUpdate.verify catches a file
            // that arrived intact and is still the wrong thing (empty tables, no provenance, a cycle
            // that has not started). Neither subsumes the other.
            set(.verifying)
            // Off the main actor: this class is @MainActor, and hashing 22 MB plus the install's
            // verify-and-copy on the main thread stutters the UI for the whole of it. Both are
            // nonisolated statics touching only the filesystem, so a detached task is safe.
            let digest = await Task.detached(priority: .utility) { Self.sha256(of: staged) }.value
            guard digest?.caseInsensitiveCompare(e.sha256) == .orderedSame else {
                try? FileManager.default.removeItem(at: staged)
                set(.failed("The download did not match its checksum.")); return
            }

            switch dest {
            case .install:
                let rejection = await Task.detached(priority: .utility) {
                    NavDataUpdate.install(from: staged, as: d)
                }.value
                if let bad = rejection {
                    try? FileManager.default.removeItem(at: staged)
                    set(.failed("Refused — \(bad.reason)."))
                    return
                }
                try? FileManager.default.removeItem(at: staged)
                set(.installed(cycle: e.cycle))

            case .stage(let cycle):
                // EVERY CHECK EXCEPT THE ONE IT CANNOT PASS YET. Verifying at download time is the
                // whole value of pre-downloading: a database that is going to be refused should be
                // refused now, while there is a connection and 28 days to do something about it —
                // not at 0901Z on cycle-roll morning. The effective-date check is re-applied, without
                // the exemption, by `install` when `activateStagedIfDue` promotes this file.
                let rejection = await Task.detached(priority: .utility) {
                    NavDataUpdate.verify(staged, as: d, allowNotYetEffective: true)
                }.value
                if let bad = rejection {
                    try? FileManager.default.removeItem(at: staged)
                    set(.failed("Refused — \(bad.reason)."))
                    return
                }
                do {
                    try FileManager.default.createDirectory(
                        at: NavDataUpdate.stagedDirectory, withIntermediateDirectories: true)
                    // One staged cycle per dataset: an older one waiting here is superseded, and
                    // leaving it would hold 22 MB that can never be activated.
                    NavDataUpdate.removeStaged(d)
                    let slot = NavDataUpdate.stagedURL(d, cycle: cycle)
                    try? FileManager.default.removeItem(at: slot)
                    try FileManager.default.moveItem(at: staged, to: slot)
                    var values = URLResourceValues(); values.isExcludedFromBackup = true
                    var s2 = slot; try? s2.setResourceValues(values)
                    set(.staged(cycle: cycle))
                } catch {
                    try? FileManager.default.removeItem(at: staged)
                    set(.failed("Could not store the pre-downloaded cycle."))
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: staged)
            set(.failed("The download did not finish."))
        }
    }

    /// Streamed SHA-256 so a 21 MB database is never held in memory whole.
    nonisolated static func sha256(of url: URL) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        var hasher = SHA256()
        while true {                                        // bounded by file length (rule 2)
            guard let chunk = try? fh.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// UTC, to match the dates in the manifest and `NavDataUpdate`'s own comparisons.
    nonisolated static func todayISO(_ now: Date = Date()) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        let f = DateFormatter()
        f.calendar = cal; f.timeZone = cal.timeZone
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: now)
    }
}
