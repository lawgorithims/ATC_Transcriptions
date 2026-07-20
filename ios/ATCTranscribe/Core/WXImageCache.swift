import UIKit
import CryptoKit

/// A weather image resolved by the cache: the bitmap, when it was DOWNLOADED (the "date stamp"), when NOAA
/// RELEASED it (the image's HTTP Last-Modified — the issuance/render time the pilot cares about; most NOAA
/// charts also burn their valid time into the image itself), and whether it came from disk (offline).
struct WXCachedImage {
    let image: UIImage
    let fetchedAt: Date
    let releasedAt: Date?      // source Last-Modified (issuance time), shown in the iPad's local time
    let fromCache: Bool
}

/// Downloads NOAA weather imagery and caches every image on disk so it can be viewed OFFLINE later.
/// Network-first (these are "latest" URLs whose content rolls over), falling back to the cached copy when
/// the fetch fails (airborne, no signal). Bounded: oldest entries evicted past the cap. Files live under
/// Application Support/WXCache with a JSON index carrying each URL's fetch timestamp.
@MainActor final class WXImageCache: ObservableObject {
    // Images are ~100-300 KB, so a generous cap is cheap (~120 MB worst case) and keeps a whole route's
    // WX staged for offline use (one turbulence grid alone is ~90 variant URLs). Bounded (rule 2).
    static let maxEntries = 400

    // `lastAccess` (NOT fetchedAt) drives eviction so a chart the pilot re-opens offline survives; fetchedAt
    // still drives the "Downloaded X ago" label. Optional in the struct so an older index.json still decodes.
    private struct Entry: Codable { let file: String; let fetchedAt: Date; var releasedAt: Date?; var lastAccess: Date? }
    private var index: [String: Entry] = [:]          // url → entry
    /// URLs the pilot FAVORITED — never evicted (they staged these for a critical moment). Set by the view.
    var protectedURLs: Set<String> = []
    private let dir: URL
    private var indexURL: URL { dir.appendingPathComponent("index.json") }

    init(directory: URL? = nil) {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true)) ?? FileManager.default.temporaryDirectory
        dir = directory ?? base.appendingPathComponent("WXCache")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Load the index, falling back to the last-good .bak if the primary won't decode — so a single
        // corrupt write never orphans every cached chart the pilot staged for offline use (SHA-256 filenames
        // are irreversible, so a lost index = unreachable files).
        index = Self.decodeIndex(dir.appendingPathComponent("index.json"))
             ?? Self.decodeIndex(dir.appendingPathComponent("index.bak")) ?? [:]
    }

    private static func decodeIndex(_ url: URL) -> [String: Entry]? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([String: Entry].self, from: d)
    }

    /// Fetch the image (network-first), falling back to the cached copy offline. `forceRefresh` skips
    /// nothing extra today (the URLs are latest-pointers) but names the intent at the call site.
    func load(_ urlString: String, forceRefresh: Bool = false) async -> WXCachedImage? {
        assert(!urlString.isEmpty, "empty WX url")
        if let fresh = await download(urlString) { return fresh }
        return cached(urlString)                       // offline / fetch failed → last downloaded copy
    }

    /// The cached copy only (no network) — lets the UI paint instantly before the refresh lands. Bumps the
    /// access time so a re-opened chart survives eviction (LRU-by-access).
    func cached(_ urlString: String) -> WXCachedImage? {
        guard let e = index[urlString],
              let data = try? Data(contentsOf: dir.appendingPathComponent(e.file)),
              let img = UIImage(data: data) else { return nil }
        touch(urlString)
        return WXCachedImage(image: img, fetchedAt: e.fetchedAt, releasedAt: e.releasedAt, fromCache: true)
    }

    /// Whether a URL is cached on disk — index + file existence, NO image decode. Cheap enough to call per
    /// visible row (the offline badge); `cached()` decodes multi-MB imagery and must never run in a row body.
    func isCached(_ urlString: String) -> Bool {
        guard let e = index[urlString] else { return false }
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent(e.file).path)
    }

    /// The source RELEASE time of a cached product (Last-Modified), without loading the image — lets the
    /// product list show "released HH:MM" after a name once it's been viewed once.
    func releasedAt(_ urlString: String) -> Date? { index[urlString]?.releasedAt }

    /// When this product was last DOWNLOADED — drives the update button's freshness (age vs category cadence).
    func fetchedAt(_ urlString: String) -> Date? { index[urlString]?.fetchedAt }

    /// Every cached url with its download time — an in-memory index scan (no disk stat). Drives the WX
    /// freshness dot + the manual update over the pilot's ACTUAL cached variants, not just default axes.
    func cachedEntries() -> [(url: String, fetchedAt: Date)] {
        index.map { ($0.key, $0.value.fetchedAt) }
    }

    private func touch(_ urlString: String) {
        guard var e = index[urlString] else { return }
        e.lastAccess = Date(); index[urlString] = e            // persisted opportunistically on the next store
    }

    private func download(_ urlString: String) async -> WXCachedImage? {
        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url); req.timeoutInterval = 20
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              data.count > 500,                        // reject error stubs
              let img = UIImage(data: data) else { return nil }
        let released = Self.parseLastModified(http.value(forHTTPHeaderField: "Last-Modified"))
        store(urlString, data: data, releasedAt: released)
        return WXCachedImage(image: img, fetchedAt: Date(), releasedAt: released, fromCache: false)
    }

    private func store(_ urlString: String, data: Data, releasedAt: Date?) {
        let file = Self.fileName(for: urlString)
        guard (try? data.write(to: dir.appendingPathComponent(file), options: .atomic)) != nil else { return }
        let now = Date()
        index[urlString] = Entry(file: file, fetchedAt: now, releasedAt: releasedAt, lastAccess: now)
        evictIfNeeded()
        persistIndex()
    }

    /// Parse an HTTP Last-Modified header ("Sun, 19 Jul 2026 23:45:59 GMT") → Date. nil when absent/unparseable.
    nonisolated static func parseLastModified(_ header: String?) -> Date? {
        guard let header, !header.isEmpty else { return nil }
        return lastModifiedFormatter.date(from: header)
    }
    private static let lastModifiedFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f
    }()

    /// Drop the LEAST-RECENTLY-ACCESSED entries past the cap, but NEVER a favorited (protected) URL — the
    /// pilot staged those for offline use and they must not age out. Bounded (index is bounded by cap + 1).
    private func evictIfNeeded() {
        guard index.count > Self.maxEntries else { return }
        let evictable = index.filter { !protectedURLs.contains($0.key) }
            .sorted { ($0.value.lastAccess ?? $0.value.fetchedAt) < ($1.value.lastAccess ?? $1.value.fetchedAt) }
        let overBy = index.count - Self.maxEntries
        for (url, e) in evictable.prefix(overBy) {                 // bounded by overBy (rule 2)
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(e.file))
            index.removeValue(forKey: url)
        }
        // If protected favorites alone exceed the cap we intentionally keep them all (offline safety wins
        // over the byte bound) — the assert allows that case.
        assert(index.count <= Self.maxEntries || index.count == protectedURLs.count, "cache eviction overshoot")
    }

    private func persistIndex() {
        guard let d = try? JSONEncoder().encode(index) else { return }
        // Roll the current good index to .bak before overwriting, so a corrupt write is always recoverable.
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("index.bak"))
        try? FileManager.default.copyItem(at: indexURL, to: dir.appendingPathComponent("index.bak"))
        try? d.write(to: indexURL, options: .atomic)
    }

    /// Stable on-disk name: SHA-256 of the URL (hashValue is NOT stable across launches) + kept extension.
    nonisolated static func fileName(for urlString: String) -> String {
        let digest = SHA256.hash(data: Data(urlString.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined().prefix(24)
        let ext = (urlString as NSString).pathExtension.lowercased()
        return ext.isEmpty ? String(hex) : "\(hex).\(ext)"
    }
}
