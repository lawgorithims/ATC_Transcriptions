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
/// **One condition on that change, and it is a safety one.** This store's tier must enter the gate
/// as an `EntitlementCurrency`, never as a `Bool` or a bare `Tier`. A refresh that cannot reach the
/// server has to land as `.unverified(lastVerified:)`, which grants exactly what `.verified`
/// grants; only an expiry we can see has passed may become `.lapsed`. Wire it as a boolean and
/// every reason this file fails open is undone one layer up — the pilot keeps a session and loses
/// the charts anyway.
///
/// # Fail open
///
/// Only a definite `401` from the server clears the credential. A timeout, a captive portal or a
/// dead cell site leaves the pilot signed in with the last known snapshot, because the alternative
/// is signing someone out of their own app mid-flight. Same rule as `EntitlementCurrency`.
///
/// # And even a definite 401 waits for the aircraft to stop
///
/// Once a pilot is signed in they stay signed in, as near to permanently as the design allows: the
/// session is a 30-day sliding one (the server pushes expiry back to a full 30 days on any use
/// inside the last 15), the credential lives in the Keychain, and an *involuntary* sign-out is
/// held until the wheels stop — see `discardCredentialWhenStopped()`. The pilot's own sign-out and
/// account deletion are immediate, because they asked.
///
/// The reason is that the refresh carrying that 401 is one nobody requested: it fires at launch and
/// on every `scenePhase == .active`, so an app backgrounded at altitude and reopened is the exact
/// trigger. Today a sign-out costs no capability, so this is mostly a matter of not startling
/// somebody who is flying an aeroplane. At M3 it stops being cosmetic, which is the other half of
/// the condition stated above.
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

    // MARK: An involuntary sign-out waits for the wheels to stop

    /// Whether the aircraft is moving. `nil` — nobody wired it up — reads as "not moving".
    ///
    /// Set once at launch in `ATCTranscribeApp`, the provider pattern already used for
    /// `battery.snapshotProvider` and `flightRecorder.fixProvider`. It exists so this store can ask
    /// the question without holding `AppModel`, which ARCHITECTURE §5 names the god-object and
    /// which publishes several times a second during a live session.
    var isMovingProvider: (() -> Bool)?

    /// The server has definitely repudiated this credential, and the aircraft was moving when it
    /// said so. The pilot stays signed in until the next refresh on the ground.
    ///
    /// Published because the account screen says so out loud: a pilot who will be signed out after
    /// landing should learn it from the app, not from a surprise at the next preflight.
    @Published private(set) var sessionEndedPendingLanding = false

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
        // A sign-out the server already demanded while the aircraft was moving. Applied here, at
        // the top, so it lands on the first refresh after the wheels stop even if that refresh then
        // fails for want of a connection — the verdict does not need the network a second time.
        if sessionEndedPendingLanding, !isMoving {
            clearLocalCredential()
            return
        }

        guard let token else { return }
        do {
            let snapshot = try await api.refresh(token: token)
            cache(snapshot)
            state = .signedIn(snapshot)
            // The server honoured the token after all, so withdraw any pending verdict against it.
            sessionEndedPendingLanding = false
        } catch let error as AccountError where error.invalidatesCredential {
            // A definite negative: signed out on another device, or the session aged out.
            discardCredentialWhenStopped()
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
        sessionEndedPendingLanding = false
    }

    private func cache(_ snapshot: AccountSnapshot) {
        if let data = try? Self.cacheEncoder.encode(snapshot) {
            keychain.set(Self.snapshotAccount, data)
        }
    }

    /// Whether the aircraft is moving, with an uninstrumented store reading as stopped.
    ///
    /// That polarity is the opposite of the one `Entitlements` uses for a missing record, and
    /// deliberately so. There, an absent entitlement must not be read as "paid". Here, an absent
    /// *motion* reading means no flying surface ever told us anything — a simulator, a unit test, a
    /// desk — and treating that as "airborne" would make a revoked session un-revokable in every
    /// build that forgot to wire the provider. The real app wires it one line below the battery
    /// provider it copies.
    ///
    /// Internal rather than private so `AccountSignOutTests` can drive this path directly. The API
    /// struct behind this store is concrete, so there is no fake to stand a 401 up with; the policy
    /// is still worth a test, and `@testable import` reaches internal but not private.
    var isMoving: Bool { isMovingProvider?() == true }

    /// Honour a definite 401 — but not with the aircraft in motion.
    ///
    /// # Why a definite negative still waits
    ///
    /// `EntitlementCurrency.grants` already argues the general case: a verification *failure* must
    /// never downgrade a pilot, because *"a paying pilot at FL080 with no signal loses the
    /// sectional under the aircraft for a billing reason."* A 401 is not that case — it is the
    /// server saying no, and the fail-open rule does not cover it.
    ///
    /// It still waits, for a narrower reason. The 401 arrives on a refresh the pilot did not ask
    /// for (launch, and every `scenePhase == .active`), so the trigger is backgrounding the app at
    /// altitude and coming back — and the credential is discarded at the one moment the pilot is
    /// least able to do anything about it. Deferring costs nothing: the token is already dead
    /// server-side, so nothing is being kept *usable*, only on screen. What it buys is that no
    /// pilot watches their account evaporate in the air, and — once M3 makes the account feed the
    /// gate — that the cached entitlement riding on it stays put until the aircraft is stopped.
    ///
    /// Explicit sign-out and account deletion do NOT come through here. The pilot asked for those,
    /// so they take effect immediately, moving or not.
    func discardCredentialWhenStopped() {
        guard !isMoving else {
            sessionEndedPendingLanding = true
            return
        }
        clearLocalCredential()
    }

    /// Forget the credential on this device. Deliberately a bounded, named list — `KeychainBox`
    /// has no wildcard delete, for the reason its own comment gives.
    ///
    /// Internal for the same reason as `isMoving` above: `AccountSignOutTests` calls it in `setUp`
    /// so each test starts from a known credential-free state without making a network call.
    func clearLocalCredential() {
        keychain.remove(accounts: [Self.tokenAccount, Self.snapshotAccount])
        state = .signedOut
        sessionEndedPendingLanding = false
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
