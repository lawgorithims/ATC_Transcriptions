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
/// `next` exists because the FAA posts a cycle weeks early. Staging it lets a pilot download on the
/// ground before it is in force; `NavDataUpdate.activeURL` re-checks the effective date at read time,
/// so a staged cycle simply starts being served on the morning it becomes legal.
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
            catalog = try JSONDecoder().decode(Catalog.self, from: data)
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
        let staged = dir.appendingPathComponent("\(d.rawValue)-\(e.cycle).sqlite")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            states[d.rawValue] = .downloading(0)
            let (tmp, resp) = try await URLSession.shared.download(from: url)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
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
            let digest = Self.sha256(of: staged)
            guard digest?.caseInsensitiveCompare(e.sha256) == .orderedSame else {
                try? FileManager.default.removeItem(at: staged)
                states[d.rawValue] = .failed("The download did not match its checksum."); return
            }
            if let bad = NavDataUpdate.install(from: staged, as: d) {
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
