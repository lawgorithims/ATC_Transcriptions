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
/// ⚠️ THIS CLIENT DOES NOT CONSUME IT YET. `available()` and `update()` read only `datasets`, so a
/// staged cycle is published and ignored until it becomes effective — at which point the publisher
/// promotes it to `datasets` and the ordinary path picks it up. That is a working outcome, just not
/// the pre-download one. The field is decoded rather than dropped so the schema stays stable while
/// the pre-download path is written; the earlier version of this comment claimed the pre-download
/// already worked, which it never did.
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
    }

    @Published private(set) var catalog: Catalog?
    @Published private(set) var states: [String: State] = [:]
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
            let (data, resp) = try await URLSession.shared.data(for: req)
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

    func update(_ d: NavDataUpdate.Dataset) {
        guard tasks[d.rawValue] == nil, let e = catalog?.datasets[d.rawValue] else { return }
        states[d.rawValue] = .checking
        tasks[d.rawValue] = Task { [weak self] in
            defer { Task { @MainActor [weak self] in self?.tasks[d.rawValue] = nil } }
            await self?.run(d, e)
        }
    }

    private func run(_ d: NavDataUpdate.Dataset, _ e: Catalog.Entry) async {
        guard let url = URL(string: "\(Self.base)/\(e.path)") else {
            states[d.rawValue] = .failed("The download address is not valid."); return
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
            states[d.rawValue] = .downloading(0)
            let (tmp, resp) = try await URLSession.shared.download(from: url)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                // The caller owns the file `download(from:)` wrote, even on a non-200 — returning
                // without removing it leaks a full-size temp per failed attempt, and a retry loop on
                // a flaky link would fill the caches directory with copies of an error page.
                try? FileManager.default.removeItem(at: tmp)
                states[d.rawValue] = .failed("The server did not return the database."); return
            }
            if FileManager.default.fileExists(atPath: staged.path) {
                try FileManager.default.removeItem(at: staged)
            }
            try FileManager.default.moveItem(at: tmp, to: staged)

            // TWO CHECKS, because they catch different things — the same split LZPackLibrary makes.
            // sha256 catches a truncated or corrupted transfer; NavDataUpdate.verify catches a file
            // that arrived intact and is still the wrong thing (empty tables, no provenance, a cycle
            // that has not started). Neither subsumes the other.
            states[d.rawValue] = .verifying
            // Off the main actor: this class is @MainActor, and hashing 22 MB plus the install's
            // verify-and-copy on the main thread stutters the UI for the whole of it. Both are
            // nonisolated statics touching only the filesystem, so a detached task is safe.
            let digest = await Task.detached(priority: .utility) { Self.sha256(of: staged) }.value
            guard digest?.caseInsensitiveCompare(e.sha256) == .orderedSame else {
                try? FileManager.default.removeItem(at: staged)
                states[d.rawValue] = .failed("The download did not match its checksum."); return
            }
            let rejection = await Task.detached(priority: .utility) {
                NavDataUpdate.install(from: staged, as: d)
            }.value
            if let bad = rejection {
                try? FileManager.default.removeItem(at: staged)
                states[d.rawValue] = .failed("Refused — \(bad.reason).")
                return
            }
            try? FileManager.default.removeItem(at: staged)
            states[d.rawValue] = .installed(cycle: e.cycle)
        } catch {
            try? FileManager.default.removeItem(at: staged)
            states[d.rawValue] = .failed("The download did not finish.")
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
