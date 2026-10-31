import Foundation
import Combine

/// Downloads the national "where not to go" map, band by band: offered, never auto-fetched (about a
/// gigabyte in all, so that is the pilot's decision), and each band verified twice before it is served
/// — sha256 for a damaged transfer, and opening it as an avoid map for a file that arrived intact but
/// is the wrong thing (an HTML error page, a schema this build cannot read).
///
/// BANDS, NOT ONE FILE: the downloader cannot resume, and the largest thing this app downloaded before
/// was a 73 MB chart pack. A dropped connection now costs one band (≤ ~100 MB), every band already
/// installed keeps working, and Download again fetches only what is missing.
@MainActor
final class AvoidMapLibrary: ObservableObject {
    static let shared = AvoidMapLibrary()

    /// The hosted dataset. Kept in step with `lz/avoid/publish.py`.
    static let base = "https://huggingface.co/datasets/SingularityUS/commsight-avoid/resolve/main"
    static let catalogSchema = 2

    struct Catalog: Decodable, Equatable {
        let schema: Int
        let built_at: String
        let shards: [Shard]
        struct Shard: Decodable, Equatable {
            let id: String
            let path: String
            let bytes: Int
            let sha256: String
        }
    }

    enum State: Equatable {
        case idle, downloading(Double), verifying, installed, failed(String)
    }

    @Published private(set) var catalog: Catalog?
    @Published private(set) var state: State = .idle
    private var task: Task<Void, Never>?
    let store: AvoidMapStore

    init(store: AvoidMapStore = .shared) {
        self.store = store
        if store.isInstalled { state = .installed }
        // The last catalog seen, so an offline pilot is still told when only some bands are installed.
        if let data = try? Data(contentsOf: catalogFile), let c = Self.decode(data) { catalog = c }
    }

    private var catalogFile: URL { store.directory.appendingPathComponent("catalog.json") }

    static func decode(_ data: Data) -> Catalog? {
        guard let c = try? JSONDecoder().decode(Catalog.self, from: data), c.schema == catalogSchema,
              !c.shards.isEmpty, c.shards.count <= 64 else { return nil }
        return c
    }

    /// Take a catalog (from the network, or a test) and keep it for the next offline launch.
    @discardableResult
    func adopt(catalogData data: Data) -> Bool {
        guard let c = Self.decode(data) else { return false }
        catalog = c
        try? FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try? data.write(to: catalogFile, options: .atomic)
        return true
    }

    /// Bands in the catalog that are not installed, or installed from an older build.
    var missing: [Catalog.Shard] {
        guard let c = catalog else { return [] }
        let have = Dictionary(store.installed.map { ($0.shardID, $0.builtAt) }, uniquingKeysWith: max)
        return c.shards.filter { (have[$0.id] ?? "") < c.built_at }
    }

    var bytesToDownload: Int { missing.reduce(0) { $0 + $1.bytes } }

    /// Something to fetch while some of the map is already installed: an update, or the rest of a
    /// download that stopped part-way.
    var updateAvailable: Bool { store.isInstalled && !missing.isEmpty }

    /// Installed bands out of the catalog's, for "12 of 14 areas".
    var installedOfTotal: (Int, Int)? {
        guard let c = catalog else { return nil }
        let ids = Set(store.installed.map(\.shardID))
        return (c.shards.filter { ids.contains($0.id) }.count, c.shards.count)
    }

    func refresh() async {
        guard let url = URL(string: "\(Self.base)/index.json") else { return }
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadRevalidatingCacheData
        req.timeoutInterval = 30
        guard let (data, resp) = try? await NetworkActivity.data(for: req, "Where-not-to-go catalog", .landability),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return }
        adopt(catalogData: data)
    }

    func download(allowMetered: Bool = false) {
        let todo = missing
        guard task == nil, !todo.isEmpty else { return }
        let total = Double(max(1, todo.reduce(0) { $0 + $1.bytes }))
        state = .downloading(0)
        task = Task { [weak self] in
            defer { Task { @MainActor [weak self] in self?.task = nil } }
            if !allowMetered {
                let verdict = await DownloadPolicy.shared.verdict(.userInitiated)
                guard verdict.isAllowed else {
                    self?.state = .failed(verdict.explanation ?? "Paused.")
                    return
                }
            }
            var done = 0.0
            for shard in todo {                                         // bounded: the catalog's bands (≤ 64)
                guard let self, !Task.isCancelled else { break }
                guard await self.fetch(shard, done: done, total: total) else { return }
                done += Double(shard.bytes)
            }
            guard let self else { return }
            self.state = Task.isCancelled ? (self.store.isInstalled ? .installed : .idle)
                : (self.missing.isEmpty ? .installed : .failed("Some of the map did not download. Tap Download for the rest."))
        }
    }

    /// One band: download, verify, install. False stops the run (the state says why).
    private func fetch(_ shard: Catalog.Shard, done: Double, total: Double) async -> Bool {
        guard let url = URL(string: "\(Self.base)/\(shard.path)") else { return false }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("avoid-\(UUID().uuidString).mbtiles")
        let share = Double(shard.bytes) / total
        do {
            try await NetworkActivity.shared.run("Where-not-to-go map (\(shard.id))", category: .landability) {
                // Captured HERE, not inside the progress callback: that runs concurrently, and
                // reaching the outer task's `self` from it is a data race.
                try await LiveModelDownloader().downloadFile(from: url, to: tmp) { [weak self] p in
                    Task { @MainActor [weak self] in
                        guard let self, case .downloading = self.state else { return }
                        self.state = .downloading(min(1, (done / total) + share * min(max(p, 0), 1)))
                    }
                }
            }
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: tmp)
            state = store.isInstalled ? .installed : .idle
            return false
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            state = .failed("The download did not finish. Areas already downloaded still work; tap Download for the rest.")
            return false
        }
        state = .verifying
        let expected = shard.sha256
        let ok: Bool = await Task.detached(priority: .utility) {
            guard let opened = AvoidMapStore.open(tmp) else { return false }
            guard opened.1.shardID == shard.id else { return false }       // the file is the band it claims
            return LZPackLibrary.sha256(of: tmp)?.caseInsensitiveCompare(expected) == .orderedSame
        }.value
        guard ok else {
            try? FileManager.default.removeItem(at: tmp)
            state = .failed("A downloaded part of the map failed its integrity check.")
            return false
        }
        do {
            try store.install(tmp)
            objectWillChange.send()
            state = .downloading(min(1, (done + Double(shard.bytes)) / total))
            return true
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            state = .failed("The map could not be installed.")
            return false
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        state = store.isInstalled ? .installed : .idle
    }

    func remove() {
        cancel()
        store.uninstallKeepingFilesUntilRelaunch()
        state = .idle
        objectWillChange.send()
    }
}
