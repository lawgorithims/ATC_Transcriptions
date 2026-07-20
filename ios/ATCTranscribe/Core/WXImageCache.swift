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
    static let maxEntries = 200                       // ~a full catalog sweep incl. variants; bounded (rule 2)

    private struct Entry: Codable { let file: String; let fetchedAt: Date; var releasedAt: Date? }
    private var index: [String: Entry] = [:]          // url → entry
    private let dir: URL
    private var indexURL: URL { dir.appendingPathComponent("index.json") }

    init(directory: URL? = nil) {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true)) ?? FileManager.default.temporaryDirectory
        dir = directory ?? base.appendingPathComponent("WXCache")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let d = try? Data(contentsOf: indexURL),
           let i = try? JSONDecoder().decode([String: Entry].self, from: d) { index = i }
        assert(index.count <= Self.maxEntries * 2, "WX cache index unexpectedly large")
    }

    /// Fetch the image (network-first), falling back to the cached copy offline. `forceRefresh` skips
    /// nothing extra today (the URLs are latest-pointers) but names the intent at the call site.
    func load(_ urlString: String, forceRefresh: Bool = false) async -> WXCachedImage? {
        assert(!urlString.isEmpty, "empty WX url")
        if let fresh = await download(urlString) { return fresh }
        return cached(urlString)                       // offline / fetch failed → last downloaded copy
    }

    /// The cached copy only (no network) — lets the UI paint instantly before the refresh lands.
    func cached(_ urlString: String) -> WXCachedImage? {
        guard let e = index[urlString],
              let data = try? Data(contentsOf: dir.appendingPathComponent(e.file)),
              let img = UIImage(data: data) else { return nil }
        return WXCachedImage(image: img, fetchedAt: e.fetchedAt, releasedAt: e.releasedAt, fromCache: true)
    }

    /// The source RELEASE time of a cached product (Last-Modified), without loading the image — lets the
    /// product list show "released HH:MM" after a name once it's been viewed once.
    func releasedAt(_ urlString: String) -> Date? { index[urlString]?.releasedAt }

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
        index[urlString] = Entry(file: file, fetchedAt: Date(), releasedAt: releasedAt)
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

    /// Drop the oldest entries past the cap (bounded loop; index size is itself bounded by the cap + 1).
    private func evictIfNeeded() {
        guard index.count > Self.maxEntries else { return }
        let excess = index.sorted { $0.value.fetchedAt < $1.value.fetchedAt }.prefix(index.count - Self.maxEntries)
        assert(excess.count <= index.count, "eviction overshoot")
        for (url, e) in excess {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(e.file))
            index.removeValue(forKey: url)
        }
        assert(index.count <= Self.maxEntries, "cache still over cap after eviction")
    }

    private func persistIndex() {
        guard let d = try? JSONEncoder().encode(index) else { return }
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
