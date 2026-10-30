import Foundation
import Security

/// A service-scoped Keychain accessor for the app's bearer credentials.
///
/// # Why this exists as its own type
///
/// `Hazards/NotamService.swift` grew the first and, for a long time, only Keychain code in this app:
/// a `kSecClassGenericPassword` read/write pair hardcoded to the NOTAM service name. Its reasoning
/// is worth restating here because it applies verbatim to an auth token and to a cached entitlement:
///
/// > KEYCHAIN, NOT UserDefaults. Every other setting in this app is UserDefaults-backed and that is
/// > right for a preference, but a client secret is a bearer credential: UserDefaults is plaintext
/// > inside the container and goes into backups.
///
/// Monetization adds three more secrets (a session token, a rotating refresh token, and the signed
/// entitlement record), so the primitives move here and `NotamCredential` becomes a second caller
/// rather than the only one. Its public surface is unchanged.
///
/// # Why `...ThisDeviceOnly`
///
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` keeps an item readable to a background refresh
/// after the first unlock without letting it travel to another device. For an entitlement that is
/// doubly load-bearing: it stops an iCloud-backup restore from carrying a paid entitlement *and* its
/// device binding onto a second iPad. A backup-restorable entitlement is a one-tap site licence.
struct KeychainBox {
    let service: String

    init(service: String) {
        assert(!service.isEmpty, "KeychainBox: empty service name")
        self.service = service
    }

    // MARK: Read

    func data(_ account: String) -> Data? {
        var out: CFTypeRef?
        let status = SecItemCopyMatching([kSecClass: kSecClassGenericPassword,
                                         kSecAttrService: service,
                                         kSecAttrAccount: account,
                                         kSecReturnData: true,
                                         kSecMatchLimit: kSecMatchLimitOne] as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data else { return nil }
        return data
    }

    func string(_ account: String) -> String? {
        guard let data = data(account) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: Write

    /// Replace-then-add, because `SecItemUpdate` fails on an absent item and we never care which
    /// case we are in. Returns whether the item landed, so a caller that must not silently lose a
    /// credential can react; the `assert` catches it in debug either way.
    @discardableResult
    func set(_ account: String, _ data: Data) -> Bool {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword,
                                      kSecAttrService: service,
                                      kSecAttrAccount: account]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData] = data
        add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        assert(status == errSecSuccess || status == errSecDuplicateItem,
               "KeychainBox.set(\(service)/\(account)): keychain refused the item (\(status))")
        return status == errSecSuccess || status == errSecDuplicateItem
    }

    @discardableResult
    func set(_ account: String, string value: String) -> Bool {
        set(account, Data(value.utf8))
    }

    // MARK: Delete

    func remove(_ account: String) {
        SecItemDelete([kSecClass: kSecClassGenericPassword,
                       kSecAttrService: service,
                       kSecAttrAccount: account] as CFDictionary)
    }

    /// Delete a known, bounded set of accounts. Bounded by the caller's literal list (rule 2) —
    /// there is deliberately no "delete everything under this service" sweep, because a wildcard
    /// delete in the wrong service name is unrecoverable.
    func remove(accounts: [String]) {
        for account in accounts { remove(account) }
    }
}
