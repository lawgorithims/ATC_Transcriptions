import Combine
import Foundation

/// The pilot's account, as the app holds it.
///
/// # An account is OPTIONAL, and that is a requirement rather than a preference
///
/// Everything this app is for — charts, plates, procedures, planning, the glide page — works with
/// no account and no connection, and it must keep doing so. App Store guideline 5.1.1(i) is
/// explicit that an app may not force registration for features that do not depend on it, and
/// beyond the rule it would be the wrong product: an EFB that wants a login before it will show you
/// a sectional is useless on a ramp with no signal. So there is no launch gate, no modal wall, and
/// nothing in the flying surface that asks who you are. Signing in is a row in Settings.
///
/// # Why this is NOT wired into `EntitlementStore`
///
/// It would be one line, and it would be wrong today. `EntitlementStore.resolve()` deliberately
/// grants everything in this build (M1) so the gate's plumbing can be proven under real use before
/// money is involved, and the StoreKit rail that is supposed to be the primary signal does not
/// exist yet. Joining them now would mean a pilot's charts could go dark because a Stripe webhook
/// was slow — exactly the failure the fail-open rule exists to prevent.
///
/// So this store reports what the **web/Stripe rail** says, for the account screen to display, and
/// `EntitlementStore` stays the only thing that gates a capability. When M3 lands,
/// `EntitlementStore.resolve()` takes the *higher* of StoreKit and this, and this comment goes away.
///
/// # Fail open
///
/// Only a definite `401` from the server clears the credential. A timeout, a captive portal or a
/// dead cell site leaves the pilot signed in with the last known snapshot, because the alternative
/// is signing someone out of their own app mid-flight. Same rule as `EntitlementCurrency`.
@MainActor
final class AccountStore: ObservableObject {

    enum State: Equatable {
        case signedOut
        case signedIn(AccountSnapshot)

        var snapshot: AccountSnapshot? {
            if case .signedIn(let snapshot) = self { return snapshot }
            return nil
        }
    }

    @Published private(set) var state: State = .signedOut

    /// A call is in flight. Drives the sign-in button's spinner and disables the form.
    @Published private(set) var isWorking = false

    /// The last thing that went wrong, ready to show. Settable so a view can clear it when the
    /// pilot edits a field — a stale "incorrect password" under a corrected one is its own bug.
    @Published var errorMessage: String?

    var isSignedIn: Bool { state.snapshot != nil }
    var user: AccountUser? { state.snapshot?.user }
    var entitlement: AccountEntitlement? { state.snapshot?.entitlement }

    // MARK: Storage

    /// A credential and a cached account record, in the Keychain — never UserDefaults.
    ///
    /// `KeychainBox`'s own note covers why, and it anticipated this exact caller: *"a client secret
    /// is a bearer credential: UserDefaults is plaintext inside the container and goes into
    /// backups."* The cached snapshot rides along in the same store rather than in UserDefaults for
    /// the second reason named there — `...ThisDeviceOnly` stops a backup restore from carrying a
    /// paid-looking record onto a second iPad.
    private let keychain = KeychainBox(service: "com.flycommsight.atctranscribe.account")
    private static let tokenAccount = "session-token"
    private static let snapshotAccount = "account-snapshot"

    private let api: AccountAPI

    private var token: String? { keychain.string(Self.tokenAccount) }

    init(api: AccountAPI = .shared) {
        self.api = api

        // Restore from the Keychain so a signed-in pilot sees their account immediately — offline,
        // and before any network call resolves. Both halves have to be there: the token proves the
        // session, the cached snapshot is what the account screen draws.
        //
        // A token whose snapshot is missing or unreadable stays `.signedOut` here, and the launch
        // `refresh()` repairs it the moment there is a connection. That is a deliberate choice
        // rather than inventing a half-signed-in state for a case that needs a Keychain write to
        // have half-failed: the credential is NOT discarded, so nothing is lost, and the screen
        // simply offers sign-in until the refresh lands.
        if keychain.string(Self.tokenAccount) != nil,
           let data = keychain.data(Self.snapshotAccount),
           let cached = try? Self.cacheDecoder.decode(AccountSnapshot.self, from: data) {
            state = .signedIn(cached)
        }
    }

    // MARK: Sign in

    func signIn(email: String, password: String) async {
        await perform { try await self.api.signIn(email: email, password: password) }
    }

    func signUp(email: String, password: String, name: String?) async {
        await perform { try await self.api.signUp(email: email, password: password, name: name) }
    }

    func signInWithApple(identityToken: String, nonce: String, fullName: String?) async {
        await perform {
            try await self.api.signInWithApple(identityToken: identityToken,
                                               nonce: nonce,
                                               fullName: fullName)
        }
    }

    func signInWithGoogle() async {
        let flow = WebOAuthSignIn()
        await perform { try await flow.signIn(provider: "google", api: self.api) }
    }

    /// Report a failure raised outside a `perform` block — the Apple button's own error path.
    func report(_ error: Error) {
        let accountError = (error as? AccountError) ?? .badResponse
        if accountError == .cancelled { return }
        errorMessage = accountError.errorDescription
    }

    // MARK: Refresh

    /// Re-read the account. Called on launch and on foreground.
    ///
    /// Silent by design: this runs without the pilot asking, so it must never raise a dialog or
    /// surface an error. The only visible outcome is an updated (or unchanged) account screen.
    func refresh() async {
        guard let token else { return }
        do {
            let snapshot = try await api.refresh(token: token)
            cache(snapshot)
            state = .signedIn(snapshot)
        } catch let error as AccountError where error.invalidatesCredential {
            // A definite negative: signed out on another device, or the session aged out.
            clearLocalCredential()
        } catch {
            // Anything else — offline, a 500, a captive portal — leaves the last snapshot alone.
        }
    }

    // MARK: Sign out / delete

    func signOut() async {
        isWorking = true
        if let token { await api.signOut(token: token) }
        clearLocalCredential()
        isWorking = false
    }

    /// Delete the account for good.
    ///
    /// In-app account deletion is an App Store requirement, not a courtesy (guideline 5.1.1(v)):
    /// an app that can create an account must be able to delete it without sending the pilot to a
    /// web form. The server cancels billing first and then cascades the record away — see
    /// `app/api/auth/native/account/route.ts`.
    ///
    /// - Returns: whether the account is gone. `false` leaves the pilot signed in and
    ///   `errorMessage` set, which matters here: a half-deleted account that *looks* deleted would
    ///   keep billing silently.
    func deleteAccount() async -> Bool {
        guard let token else { return false }
        isWorking = true
        defer { isWorking = false }

        do {
            try await api.deleteAccount(token: token)
            clearLocalCredential()
            return true
        } catch let error as AccountError {
            if error.invalidatesCredential {
                // Already gone server-side. Nothing left to delete; treat it as done.
                clearLocalCredential()
                return true
            }
            errorMessage = error.errorDescription
            return false
        } catch {
            errorMessage = AccountError.badResponse.errorDescription
            return false
        }
    }

    // MARK: Plumbing

    /// Run a sign-in call, adopt its session, and funnel failures into `errorMessage`.
    private func perform(_ work: @escaping () async throws -> AccountSession) async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }

        do {
            adopt(try await work())
        } catch let error as AccountError {
            if error == .cancelled { return }
            errorMessage = error.errorDescription
        } catch {
            errorMessage = AccountError.badResponse.errorDescription
        }
    }

    private func adopt(_ session: AccountSession) {
        keychain.set(Self.tokenAccount, string: session.token)
        cache(session.snapshot)
        state = .signedIn(session.snapshot)
        errorMessage = nil
    }

    private func cache(_ snapshot: AccountSnapshot) {
        if let data = try? Self.cacheEncoder.encode(snapshot) {
            keychain.set(Self.snapshotAccount, data)
        }
    }

    /// Forget the credential on this device. Deliberately a bounded, named list — `KeychainBox`
    /// has no wildcard delete, for the reason its own comment gives.
    private func clearLocalCredential() {
        keychain.remove(accounts: [Self.tokenAccount, Self.snapshotAccount])
        state = .signedOut
    }

    // The cache is our own format on both ends, so plain `.iso8601` is enough — unlike
    // `AccountAPI`, which has to cope with the fractional seconds `Date.toISOString()` emits.
    private static let cacheEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let cacheDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
