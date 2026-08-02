import Foundation
import Combine
import CryptoKit
import MapKit
import SwiftUI

/// Downloads, installs and removes off-field landability packs.
///
/// Mirrors `ChartLibrary`'s SHAPE — warm the catalog once, cache it to disk, expose installed state
/// to the Downloads screen — but deliberately not two of its policies:
///
/// PIN-ONLY. NO LRU, NO INCIDENTAL CACHE.
/// Charts run a 600 MB least-recently-used budget over packs that are small and numerous, and free
/// panning quietly downloads more of them. Neither fits here. A cell is ~88 MB, so seven of them
/// exceed that whole budget and an LRU would spend a flight evicting and re-fetching; and the
/// budget's recency proxy is file modification date, which is really "when it was downloaded", not
/// "when it was last useful". Every pack here is present because the pilot asked for it and leaves
/// only when the pilot removes it. That makes storage predictable, which is worth more than
/// cleverness when the number is measured in hundreds of megabytes.
///
/// NO CYCLE MODEL.
/// There is no AIRAC here, so there is no "your packs are out of date" sweep, no pruning of an old
/// cycle's files, and no pins to drop at rollover. A pack is stale only against its own `built_at`,
/// which is a per-pack question the card answers.
///
/// DOWNLOADS ARE ALWAYS EXPLICIT. Nothing in this class starts a transfer on its own. The route and
/// viewport paths OFFER cells; 88 MB is not something to spend on a pilot's cellular plan because
/// they panned the map.
@MainActor
final class LZPackLibrary: ObservableObject {

    static let shared = LZPackLibrary()

    /// Root of the published dataset. Same `/resolve/main` form the charts use, so the request is a
    /// plain anonymous GET — see `lz/publish.py` for why that constrains how packs are stored.
    static let base = "https://huggingface.co/datasets/SingularityUS/commsight-lz/resolve/main"
    static var indexURL: URL? { URL(string: "\(base)/index.json") }

    @Published private(set) var catalog: LZPackCatalog?
    @Published private(set) var warming = false
    /// Per-cell transfer state, keyed by cell id. Byte-level, unlike the chart rows, which can only
    /// show an indeterminate spinner until an entire pack lands.
    @Published private(set) var states: [String: DownloadState] = [:]
    @Published private(set) var installedIDs: Set<String> = []
    @Published private(set) var installedBytes: Int64 = 0
    /// Why the catalog is unavailable, when it is — so the UI can say something better than "empty".
    @Published private(set) var catalogProblem: String?

    private let directory: URL
    private var tasks: [String: Task<Void, Never>] = [:]
    private var warmTask: Task<Bool, Never>?

    init(directory: URL? = nil) {
        self.directory = directory ?? LZPackStore.defaultDirectory()
        refreshInstalled()
    }

    private var cachedCatalogURL: URL { directory.appendingPathComponent("catalog.json") }

    // MARK: - Catalog

    /// Fetch the catalog once per launch, coalescing concurrent callers.
    @discardableResult
    func warm() async -> Bool {
        if catalog != nil { return true }
        if let t = warmTask { return await t.value }
        let t = Task { () -> Bool in
            warming = true
            defer { warming = false }
            defer { warmTask = nil }
            guard let url = Self.indexURL else { return false }
            do {
                var req = URLRequest(url: url)
                req.cachePolicy = .reloadRevalidatingCacheData
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                    return adoptCached(reason: "catalog server returned an error")
                }
                guard let c = LZPackCatalog.decode(data) else {
                    // A schema this build does not know is a REFUSAL, not a parse failure to shrug
                    // at: offering half a catalog we half-understand is worse than offering none.
                    return adoptCached(reason: "catalog format is newer than this app version")
                }
                catalog = c
                catalogProblem = nil
                try? data.write(to: cachedCatalogURL, options: .atomic)
                return true
            } catch {
                return adoptCached(reason: "offline")
            }
        }
        warmTask = t
        return await t.value
    }

    /// Fall back to the last catalog seen. Without this a cold offline launch has no catalog, and
    /// the Downloads screen cannot even name what the pilot has already installed — the same bug
    /// `ChartLibrary` documents at length after shipping it once.
    @discardableResult
    private func adoptCached(reason: String) -> Bool {
        if let data = try? Data(contentsOf: cachedCatalogURL), let c = LZPackCatalog.decode(data) {
            catalog = c
            catalogProblem = "\(reason) — showing the last catalog downloaded"
            return true
        }
        catalogProblem = reason
        return false
    }

    /// Seed a catalog without a network round-trip. Tests only — the offer selection is pure logic
    /// over a decoded catalog, and proving it should not require a live HuggingFace fetch.
    func adoptForTesting(_ c: LZPackCatalog) {
        catalog = c
        catalogProblem = nil
    }

    /// Force a re-fetch. Keeps the previous catalog if the new one cannot be had: nil-ing it first
    /// leaves the pilot with nothing while offline, for no gain.
    func refreshCatalog() async {
        let previous = catalog
        catalog = nil
        warmTask = nil
        if await warm() == false { catalog = previous }
    }

    // MARK: - Installed state

    func isInstalled(_ id: String) -> Bool { installedIDs.contains(id) }

    func localURL(_ cell: LZPackCatalog.Cell) -> URL {
        directory.appendingPathComponent(cell.localFilename)
    }

    /// Rescan the pack directory. Cheap: a listing plus a size per file, over a handful of packs.
    func refreshInstalled() {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: directory,
                                                includingPropertiesForKeys: [.fileSizeKey])) ?? []
        var ids = Set<String>()
        var total: Int64 = 0
        for url in urls where url.pathExtension.lowercased() == "lzpack" {   // bounded (rule 2)
            if let id = Self.packID(url.lastPathComponent) { ids.insert(id) }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Int64(size)
        }
        installedIDs = ids
        installedBytes = total
    }

    /// A pack's id from its filename. Trivial here BECAUSE there is no cycle in the name — and that
    /// is the point. `ChartLibrary.packID` has to strip an FAA cycle by shape, after a version that
    /// split at the last dash silently mis-identified every pack and deleted a pilot's pinned kit at
    /// rollover. Keep landability filenames identity-only and this stays a `dropLast`.
    /// `nonisolated` because it is pure string arithmetic on a filename — no state, no actor. The
    /// directory scan that uses it is a candidate to move off the main actor as the pack count grows.
    nonisolated static func packID(_ filename: String) -> String? {
        guard filename.hasSuffix(".lzpack") else { return nil }
        let base = String(filename.dropLast(".lzpack".count))
        guard !base.isEmpty, !base.contains("/"), !base.hasPrefix(".") else { return nil }
        return base
    }

    // MARK: - Transfers

    func state(_ id: String) -> DownloadState {
        if let s = states[id] { return s }
        return installedIDs.contains(id) ? .ready : .notDownloaded
    }

    var isDownloading: Bool { states.values.contains { if case .downloading = $0 { return true }; return false } }

    /// Bytes still to fetch for a set of cells the pilot has not installed.
    func remainingBytes(_ cells: [LZPackCatalog.Cell]) -> Int {
        cells.filter { !installedIDs.contains($0.id) }.reduce(0) { $0 + $1.bytes }
    }

    /// Download one cell. Explicit only — never called from a background prefetch.
    func download(_ cell: LZPackCatalog.Cell) {
        guard tasks[cell.id] == nil else { return }
        guard let url = cell.remote(base: Self.base) else {
            states[cell.id] = .failed("this pack has no usable download address")
            return
        }
        states[cell.id] = .downloading(0)
        let dest = localURL(cell)
        let t = Task { [weak self] in
            defer { Task { @MainActor [weak self] in self?.tasks[cell.id] = nil } }
            do {
                try await LiveModelDownloader().downloadFile(from: url, to: dest) { p in
                    Task { @MainActor [weak self] in
                        // Late progress from a cancelled transfer must not resurrect a finished row.
                        guard let self, case .downloading = self.state(cell.id) else { return }
                        self.states[cell.id] = .downloading(min(max(p, 0), 1))
                    }
                }
                try await self?.accept(cell, at: dest)
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: dest)
                await MainActor.run { [weak self] in self?.states[cell.id] = .notDownloaded }
            } catch {
                try? FileManager.default.removeItem(at: dest)
                await MainActor.run { [weak self] in
                    self?.states[cell.id] = .failed(Self.message(error))
                }
            }
        }
        tasks[cell.id] = t
    }

    /// Verify a freshly-downloaded pack before it counts as installed.
    ///
    /// TWO CHECKS, because they catch different things. The sha256 catches a truncated or corrupted
    /// transfer; opening it as a pack catches a file that arrived intact and is still not usable —
    /// an HTML error page saved under a .lzpack name, or a pack whose schema this build refuses. A
    /// pack that fails either is DELETED rather than left on disk looking installed.
    private func accept(_ cell: LZPackCatalog.Cell, at dest: URL) async throws {
        let expected = cell.sha256
        let ok: Bool = await Task.detached(priority: .utility) {
            guard let r = MBTilesReader(path: dest.path), r.hasTiles else { return false }
            guard r.metadata["lz_schema"] == String(LZPack.schema) else { return false }
            guard let expected, !expected.isEmpty else { return true }   // catalog published none
            return Self.sha256(of: dest)?.caseInsensitiveCompare(expected) == .orderedSame
        }.value

        guard ok else {
            try? FileManager.default.removeItem(at: dest)
            states[cell.id] = .failed("the downloaded pack failed its integrity check")
            return
        }
        states[cell.id] = .ready
        refreshInstalled()
        packsChanged.send()
    }

    func cancel(_ id: String) {
        tasks[id]?.cancel()
        tasks[id] = nil
        states[id] = .notDownloaded
    }

    func remove(_ cell: LZPackCatalog.Cell) {
        cancel(cell.id)
        try? FileManager.default.removeItem(at: localURL(cell))
        states[cell.id] = .notDownloaded
        refreshInstalled()
        packsChanged.send()
    }

    /// Fires whenever the installed set changes, so the map can re-mount without a relaunch. A pack
    /// finishing while the map is open and NOT appearing is indistinguishable from a broken layer.
    let packsChanged = PassthroughSubject<Void, Never>()

    // MARK: - Coverage offers

    /// Cells that cover `rects` and are NOT installed — what a coverage offer is made of.
    ///
    /// OFFERS, NEVER AUTOMATIC DOWNLOADS. `ChartLibrary.prefetch` quietly fetches chart packs along
    /// the route and around the aircraft, and that is defensible because those packs are small. A
    /// landability cell is ~88 MB: spending that on a pilot's cellular plan because they filed a
    /// plan or panned the map would be indefensible, so this only ever returns a LIST and something
    /// on screen asks.
    func missingCells(covering rects: [MKMapRect]) -> [LZPackCatalog.Cell] {
        guard let catalog, !rects.isEmpty else { return [] }
        return catalog.cells(intersecting: rects).filter { !installedIDs.contains($0.id) }
    }

    /// Cells the filed route passes over that are not yet installed.
    func missingCells(alongRoute route: [ResolvedLeg]) -> [LZPackCatalog.Cell] {
        missingCells(covering: ChartGeo.routeRects(route))
    }

    /// Cells within `radiusNM` of a position that are not yet installed.
    func missingCells(around here: Coord, radiusNM: Double = 60) -> [LZPackCatalog.Cell] {
        missingCells(covering: [ChartGeo.rect(around: here, radiusNM: radiusNM)])
    }

    // MARK: - Helpers

    private static func message(_ e: Error) -> String {
        let ns = e as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorNotConnectedToInternet: return "no internet connection"
            case NSURLErrorTimedOut: return "the download timed out"
            case NSURLErrorCancelled: return "cancelled"
            default: return "download failed"
            }
        }
        return "could not save the pack — check free space"
    }

    /// Streamed SHA-256, so an 88 MB pack is never held in memory. Runs off the main actor.
    /// `Data(contentsOf:)` would map the whole file to hash it, which is exactly the allocation a
    /// download-time check on a large pack must not make.
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
}
