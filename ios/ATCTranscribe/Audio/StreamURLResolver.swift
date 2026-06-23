import Foundation

enum StreamURLError: Error { case noURL, invalid(String), noMount(String) }

/// Resolves a playable stream URL from a direct URL, a bundled feed config, or a
/// LiveATC listen-page link, and expands LiveATC mounts across edge servers. Swift
/// port of `atc_stream.resolve_stream_url` / `_normalize_stream_url` /
/// `_extract_liveatc_mount` / `candidate_stream_urls`.
enum StreamURLResolver {
    /// Edge servers a LiveATC mount can be served from (atc_stream.LIVEATC_SERVERS).
    static let liveATCServers = [
        "d.liveatc.net", "s1-dfw.liveatc.net", "s2-dfw.liveatc.net",
        "s1-bos.liveatc.net", "s2-bos.liveatc.net", "s1-fpl.liveatc.net",
        "s1-nyc.liveatc.net", "s1-lax.liveatc.net",
    ]

    /// Priority: explicit `streamURL` > `config.streams[feedKey]` > `liveatcPage`.
    static func resolve(streamURL: String? = nil,
                        config: AirportConfig? = nil,
                        feedKey: String? = nil,
                        liveatcPage: String? = nil) throws -> String {
        if let s = streamURL?.trimmingCharacters(in: .whitespaces), !s.isEmpty {
            return try normalize(s)
        }
        if let config, let feedKey, let entry = config.streams?[feedKey] {
            if let url = (entry.url ?? entry.streamUrl)?.trimmingCharacters(in: .whitespaces), !url.isEmpty {
                return try normalize(url)
            }
            if let page = entry.liveatcPage { return try resolveLiveATCPage(page) }
        }
        if let page = liveatcPage { return try resolveLiveATCPage(page) }
        throw StreamURLError.noURL
    }

    /// Port of `_normalize_stream_url` (URL forms only; file paths are handled by
    /// `FileReplaySource`).
    static func normalize(_ url: String) throws -> String {
        let u = url.trimmingCharacters(in: .whitespaces)
        if u.contains("liveatc.net/hlisten") || (u.contains("liveatc.net") && u.contains("mount=")) {
            return try resolveLiveATCPage(u)
        }
        if u.hasPrefix("http://") || u.hasPrefix("https://") || u.hasPrefix("file:") { return u }
        throw StreamURLError.invalid(url)
    }

    static func resolveLiveATCPage(_ page: String) throws -> String {
        guard let mount = extractMount(page) else { throw StreamURLError.noMount(page) }
        return "https://\(liveATCServers[0])/\(mount)"
    }

    /// Port of `_extract_liveatc_mount`: the `mount`/`m` query param, else a regex.
    static func extractMount(_ url: String) -> String? {
        if let items = URLComponents(string: url)?.queryItems {
            for key in ["mount", "m"] {
                if let v = items.first(where: { $0.name == key })?.value, !v.isEmpty { return v }
            }
        }
        if let r = url.range(of: "mount=([a-z0-9_]+)", options: [.regularExpression, .caseInsensitive]) {
            return String(url[r]).replacingOccurrences(of: "mount=", with: "", options: .caseInsensitive)
        }
        return nil
    }

    /// URLs to try, expanding a LiveATC mount across edge servers. Port of
    /// `candidate_stream_urls`.
    static func candidateURLs(_ url: String) -> [String] {
        if url.hasPrefix("file:") { return [url] }
        if let comps = URLComponents(string: url), let host = comps.host, host.hasSuffix("liveatc.net") {
            let mount = comps.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !mount.isEmpty { return liveATCServers.map { "https://\($0)/\(mount)" } }
        }
        if url.contains("liveatc.net"), let mount = extractMount(url) {
            return liveATCServers.map { "https://\($0)/\(mount)" }
        }
        return [url]
    }
}
