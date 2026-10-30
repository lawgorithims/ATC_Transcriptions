import Foundation
import Combine

/// Downloads the national "where not to go" map: ONE file for the contiguous US, offered, never
/// auto-fetched (it is a few hundred MB and that is the pilot's decision), and verified twice before
/// it is served — sha256 for a damaged transfer, and opening it as an avoid map for a file that
/// arrived intact but is the wrong thing (an HTML error page, a schema this build cannot read).
@MainActor
final class AvoidMapLibrary: ObservableObject {
    static let shared = AvoidMapLibrary()

    /// The hosted dataset. Kept in step with `lz/avoid/publish.py`.
    static let base = "https://huggingface.co/datasets/SingularityUS/commsight-avoid/resolve/main"

    struct Catalog: Decodable, Equatable {
        let schema: Int
        let map: Entry
        struct Entry: Decodable, Equatable {
            let path: String
            let bytes: Int
            let sha256: String
            let built_at: String
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
    }

    /// Is the hosted map newer than the installed one?
    var updateAvailable: Bool {
        guard let c = catalog, let i = store.info else { return false }
        return c.map.built_at > i.builtAt
    }

    func refresh() async {
        guard let url = URL(string: "\(Self.base)/index.json") else { return }
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadRevalidatingCacheData
        req.timeoutInterval = 30
        guard let (data, resp) = try? await NetworkActivity.data(for: req, "Where-not-to-go catalog", .landability),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let c = try? JSONDecoder().decode(Catalog.self, from: data), c.schema == 1 else { return }
        catalog = c
    }

    func download(allowMetered: Bool = false) {
        guard task == nil, let entry = catalog?.map, let url = URL(string: "\(Self.base)/\(entry.path)") else { return }
        state = .downloading(0)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("avoid-\(UUID().uuidString).mbtiles")
        task = Task { [weak self] in
            defer { Task { @MainActor [weak self] in self?.task = nil } }
            do {
                if !allowMetered {
                    let verdict = await DownloadPolicy.shared.verdict(.userInitiated)
                    guard verdict.isAllowed else {
                        self?.state = .failed(verdict.explanation ?? "Paused.")
                        return
                    }
                }
                try await NetworkActivity.shared.run("Where-not-to-go map (contiguous US)", category: .landability) {
                    // Captured HERE, not inside the progress callback: that runs concurrently, and
                    // reaching the outer task's `self` from it is a data race.
                    try await LiveModelDownloader().downloadFile(from: url, to: tmp) { [weak self] p in
                        Task { @MainActor [weak self] in
                            guard let self, case .downloading = self.state else { return }
                            self.state = .downloading(min(max(p, 0), 1))
                        }
                    }
                }
                await self?.accept(tmp, sha256: entry.sha256)
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: tmp)
                await MainActor.run { [weak self] in self?.state = self?.store.isInstalled == true ? .installed : .idle }
            } catch {
                try? FileManager.default.removeItem(at: tmp)
                await MainActor.run { [weak self] in self?.state = .failed("The download did not finish.") }
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    func remove() {
        store.uninstallKeepingFilesUntilRelaunch()
        state = .idle
        objectWillChange.send()
    }

    private func accept(_ tmp: URL, sha256 expected: String) async {
        state = .verifying
        let ok: Bool = await Task.detached(priority: .utility) {
            guard AvoidMapStore.open(tmp) != nil else { return false }
            return LZPackLibrary.sha256(of: tmp)?.caseInsensitiveCompare(expected) == .orderedSame
        }.value
        guard ok else {
            try? FileManager.default.removeItem(at: tmp)
            state = .failed("The downloaded map failed its integrity check.")
            return
        }
        do {
            try store.install(tmp)
            state = .installed
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            state = .failed("The map could not be installed.")
        }
    }
}
