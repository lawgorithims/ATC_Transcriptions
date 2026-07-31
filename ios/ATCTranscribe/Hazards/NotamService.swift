import Foundation
import Security

/// The FAA NOTAM API credential.
///
/// KEYCHAIN, NOT UserDefaults. Every other setting in this app is UserDefaults-backed and that is right
/// for a preference, but a client secret is a bearer credential: UserDefaults is plaintext inside the
/// container and goes into backups. `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` keeps it readable
/// to a background refresh after the first unlock without letting it travel to another device.
enum NotamCredential {
    private static let service = "com.flycommsight.notamapi"
    private static let idKey = "client_id"
    private static let secretKey = "client_secret"

    struct Pair: Equatable { let clientID: String; let clientSecret: String }

    static var current: Pair? {
        guard let id = read(idKey), let secret = read(secretKey), !id.isEmpty, !secret.isEmpty else {
            return nil
        }
        return Pair(clientID: id, clientSecret: secret)
    }
    static var isConfigured: Bool { current != nil }

    static func save(clientID: String, clientSecret: String) {
        assert(!clientID.isEmpty, "NotamCredential.save: empty client id")
        write(idKey, clientID.trimmingCharacters(in: .whitespacesAndNewlines))
        write(secretKey, clientSecret.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func clear() {
        for key in [idKey, secretKey] {                              // bounded (rule 2)
            SecItemDelete([kSecClass: kSecClassGenericPassword,
                           kSecAttrService: service,
                           kSecAttrAccount: key] as CFDictionary)
        }
    }

    private static func read(_ key: String) -> String? {
        var out: CFTypeRef?
        let status = SecItemCopyMatching([kSecClass: kSecClassGenericPassword,
                                          kSecAttrService: service,
                                          kSecAttrAccount: key,
                                          kSecReturnData: true,
                                          kSecMatchLimit: kSecMatchLimitOne] as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func write(_ key: String, _ value: String) {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword,
                                      kSecAttrService: service,
                                      kSecAttrAccount: key]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData] = Data(value.utf8)
        add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        assert(status == errSecSuccess || status == errSecDuplicateItem,
               "NotamCredential.write: keychain refused the item")
    }
}

/// Network seam, so the store's behaviour is testable without the FAA (a fake in tests).
protocol NotamFetching: Sendable {
    func fetch(icao: String) async throws -> [Notam]
}

enum NotamFetchError: Error, Equatable {
    case noCredential
    case unauthorized
    case transport(String)
}

/// Live fetch from `external-api.faa.gov/notamapi/v1/notams`.
///
/// AUTHENTICATION is a `client_id` / `client_secret` HEADER pair from api.faa.gov — not a query
/// parameter and not an OAuth bearer token, despite how some API-catalogue pages describe it. The
/// endpoint returns 401 to an anonymous request, which is how this feature came to need a credential
/// setting at all.
///
/// NO SERVER-SIDE FILTERING. The API can filter by feature type and classification, and it is tempting:
/// a filter you got slightly wrong silently deletes NOTAMs the app never sees and the pilot cannot
/// audit. Everything for the aerodrome is pulled and the classification happens on device, where the
/// full list can always show all of it.
///
/// ⚠️ The FAA's reference is behind MyAccess, so the exact envelope key names could not be confirmed
/// against the published spec. The decoder is therefore PERMISSIVE per record — one malformed item
/// drops itself rather than failing the page — and accepts the two envelope shapes the API is described
/// as using. Verify against a live key before trusting the field mapping.
struct LiveNotamFetcher: NotamFetching {
    static let endpoint = "https://external-api.faa.gov/notamapi/v1/notams"
    /// Records per page, and the page cap. Beyond this the UI says the list was truncated rather than
    /// pretending it is complete.
    static let pageSize = 1_000
    static let maxPages = 4

    func fetch(icao: String) async throws -> [Notam] {
        guard let cred = NotamCredential.current else { throw NotamFetchError.noCredential }
        assert(!icao.isEmpty, "LiveNotamFetcher: empty ICAO")
        var out: [Notam] = []
        for pageNum in 1...Self.maxPages {                           // bounded (rule 2)
            let batch = try await fetchPage(icao: icao, cred: cred, pageNum: pageNum)
            out.append(contentsOf: batch)
            if batch.count < Self.pageSize { break }
        }
        return out
    }

    private func fetchPage(icao: String, cred: NotamCredential.Pair, pageNum: Int) async throws -> [Notam] {
        var comps = URLComponents(string: Self.endpoint)
        comps?.queryItems = [.init(name: "icaoLocation", value: icao),
                             .init(name: "responseFormat", value: "geoJson"),
                             .init(name: "pageSize", value: "\(Self.pageSize)"),
                             .init(name: "pageNum", value: "\(pageNum)")]
        guard let url = comps?.url else { throw NotamFetchError.transport("bad URL") }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.setValue(cred.clientID, forHTTPHeaderField: "client_id")
        req.setValue(cred.clientSecret, forHTTPHeaderField: "client_secret")
        req.setValue("CommSight/1.0", forHTTPHeaderField: "User-Agent")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 || code == 403 { throw NotamFetchError.unauthorized }
            guard code == 200 else { throw NotamFetchError.transport("HTTP \(code)") }
            return NotamParser.parse(data, icao: icao)
        } catch let e as NotamFetchError {
            throw e
        } catch {
            throw NotamFetchError.transport(error.localizedDescription)
        }
    }
}
