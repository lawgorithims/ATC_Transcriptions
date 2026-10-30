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
///
/// # A refusal is an answer, not a crash
///
/// The Keychain refusing an operation is a fact about the environment, not a bug in the caller, so
/// nothing here asserts on a status. A device not unlocked since boot answers
/// `errSecInteractionNotAllowed` (-25308) for anything `...AfterFirstUnlock`; a simulator build made
/// with `CODE_SIGNING_ALLOWED=NO` carries no entitlements, so no keychain access group, and answers
/// `errSecMissingEntitlement` (-34018) to everything. `set` used to `assert` on its status, which
/// crashed the unit suite of every unsigned build (two `InstallIdentityTests`, 2026-10-29). Now a
/// write reports whether it landed and logs a refusal, and `lookup` tells "nothing is stored" apart
/// from "the Keychain did not answer".
struct KeychainBox {
    let service: String

    init(service: String) {
        assert(!service.isEmpty, "KeychainBox: empty service name")
        self.service = service
    }

    // MARK: Read

    /// What a read found.
    ///
    /// `data(_:)` folds `.absent` and `.unavailable` into one `nil`, which suits a credential the
    /// pilot can simply enter again. A caller whose answer to "nothing is stored" is to MINT a
    /// replacement must not make that fold: a Keychain that would not look is not evidence that
    /// nothing is there.
    enum Lookup: Equatable {
        case found(Data)
        /// The Keychain looked, and there is no such item (`errSecItemNotFound`).
        case absent
        /// The Keychain did not look; the status says why. The item may exist all the same.
        case unavailable(OSStatus)
    }

    func lookup(_ account: String) -> Lookup {
        assert(!account.isEmpty, "KeychainBox.lookup(\(service)): empty account")
        var out: CFTypeRef?
        let status = SecItemCopyMatching([kSecClass: kSecClassGenericPassword,
                                         kSecAttrService: service,
                                         kSecAttrAccount: account,
                                         kSecReturnData: true,
                                         kSecMatchLimit: kSecMatchLimitOne] as CFDictionary, &out)
        if status == errSecItemNotFound { return .absent }
        guard status == errSecSuccess else { return .unavailable(status) }
        // Success without data is not an answer this query can give; report it rather than trust it.
        guard let data = out as? Data else { return .unavailable(errSecDecode) }
        return .found(data)
    }

    func data(_ account: String) -> Data? {
        guard case .found(let data) = lookup(account) else { return nil }
        return data
    }

    func string(_ account: String) -> String? {
        guard let data = data(account) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: Write

    /// Replace-then-add, because `SecItemUpdate` fails on an absent item and we never care which
    /// case we are in. Returns whether the item landed, so a caller that must not silently lose a
    /// credential can react. A refusal is logged with its status, never asserted (see the type).
    @discardableResult
    func set(_ account: String, _ data: Data) -> Bool {
        assert(!account.isEmpty, "KeychainBox.set(\(service)): empty account")
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword,
                                      kSecAttrService: service,
                                      kSecAttrAccount: account]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData] = data
        add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            NSLog("CommSight: the Keychain refused %@/%@ — %@. Nothing was stored.",
                  service, account, Self.describe(status))
            return false
        }
        return true
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

    // MARK: Status

    /// A refusal for the log: the number to search for, the words to read, and for -34018 the usual
    /// cause, because it reads like a bug and is a build setting.
    static func describe(_ status: OSStatus) -> String {
        assert(status != errSecSuccess, "KeychainBox.describe: success is not a refusal")
        let words = SecCopyErrorMessageString(status, nil) as String? ?? "no description"
        guard status == errSecMissingEntitlement else { return "\(status) (\(words))" }
        return "\(status) (\(words)) — no keychain access group, which is what a simulator build "
             + "made with CODE_SIGNING_ALLOWED=NO has"
    }
}

/// The Keychain calls `InstallIdentity` makes, as a seam. Its fallback runs only when the Keychain
/// refuses, which never happens in the signed build the release gate tests, so without a fake
/// Keychain that path would ship without ever having run.
protocol KeychainStoring {
    func lookup(_ account: String) -> KeychainBox.Lookup
    func set(_ account: String, string value: String) -> Bool
}

extension KeychainBox: KeychainStoring {}
