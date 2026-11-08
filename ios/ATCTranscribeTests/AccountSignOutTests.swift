import XCTest
@testable import ATCTranscribe

/// What it takes to sign a pilot out, and what it does not.
///
/// The rule these assert is a safety rule, not a commercial one: once signed in, a pilot stays
/// signed in until they say otherwise or the aircraft is stopped. The 401 that would end a session
/// arrives on a refresh nobody asked for — launch, and every `scenePhase == .active` — so without
/// the deferral the trigger is backgrounding the app at altitude and coming back to find the
/// account gone. `AccountStore`'s header has the longer argument.
///
/// These drive `discardCredentialWhenStopped()` directly rather than through a stubbed server.
/// `AccountAPI` is a concrete struct with no protocol in front of it, so there is no fake to raise
/// a real 401 with; the policy is the part worth pinning down, and it is reachable.
@MainActor
final class AccountSignOutTests: XCTestCase {

    /// Start every test credential-free.
    ///
    /// `AccountStore.init` restores from the Keychain, and the simulator's Keychain persists
    /// between runs — a store built in a test could otherwise come up signed in from whenever
    /// somebody last used the app on this simulator, and `refresh()` would then make a real network
    /// call to the live site. Purging locally is offline and costs nothing but a sign-out on that
    /// simulator.
    override func setUp() {
        super.setUp()
        AccountStore().clearLocalCredential()
    }

    /// A store with no stored credential. Every assertion below is about the published state and
    /// the pending flag, neither of which needs a session to exist.
    private func store(moving: Bool?) -> AccountStore {
        let store = AccountStore()
        if let moving { store.isMovingProvider = { moving } }
        return store
    }

    // MARK: The aircraft is moving

    func testAServerRefusalWhileMovingDoesNotSignThePilotOut() {
        let store = self.store(moving: true)
        store.discardCredentialWhenStopped()

        XCTAssertTrue(store.sessionEndedPendingLanding,
                      "the server's verdict has to be remembered, or landing forgets it")
    }

    func testTheVerdictSurvivesRepeatedRefusalsInTheAir() {
        let store = self.store(moving: true)
        store.discardCredentialWhenStopped()
        store.discardCredentialWhenStopped()
        store.discardCredentialWhenStopped()

        XCTAssertTrue(store.sessionEndedPendingLanding,
                      "every foreground transition refuses again; none of them may clear early")
    }

    // MARK: The aircraft is stopped

    func testAServerRefusalOnTheGroundSignsThePilotOutAtOnce() {
        let store = self.store(moving: false)
        store.discardCredentialWhenStopped()

        XCTAssertFalse(store.sessionEndedPendingLanding,
                       "nothing is pending once it has been applied")
        XCTAssertFalse(store.isSignedIn)
    }

    /// The deferred sign-out must land without the network. A pilot who lands somewhere with no
    /// signal still gets the verdict applied — it was reached in the air and needs no second ask.
    func testThePendingSignOutIsAppliedOnTheNextRefreshAfterStopping() async {
        let store = AccountStore()
        var moving = true
        store.isMovingProvider = { moving }

        store.discardCredentialWhenStopped()
        XCTAssertTrue(store.sessionEndedPendingLanding)

        moving = false
        await store.refresh()

        XCTAssertFalse(store.sessionEndedPendingLanding,
                       "the first refresh after the wheels stop applies what the server said")
    }

    func testARefreshStillInTheAirLeavesThePendingVerdictPending() async {
        let store = self.store(moving: true)
        store.discardCredentialWhenStopped()
        await store.refresh()

        XCTAssertTrue(store.sessionEndedPendingLanding,
                      "a refresh while moving must not be the thing that applies it")
    }

    // MARK: Polarity of an uninstrumented store

    /// Deliberately the opposite polarity to a missing *entitlement*, which is never read as paid.
    /// A missing motion reading means no flying surface ever reported anything — a desk, a
    /// simulator, this test — and reading that as "airborne" would make a revoked session
    /// un-revokable in any build that forgot to wire the provider up.
    func testAStoreWithNoMotionProviderTreatsItselfAsStopped() {
        let store = self.store(moving: nil)
        XCTAssertFalse(store.isMoving)

        store.discardCredentialWhenStopped()
        XCTAssertFalse(store.sessionEndedPendingLanding,
                       "with nothing reporting motion, the refusal applies immediately")
    }

    // MARK: The pilot's own choices are never deferred

    /// Sign-out and deletion do not go through `discardCredentialWhenStopped()` at all. This test
    /// is here so that stays true: route either of them through the deferral and a pilot who taps
    /// "Sign out" while taxiing would appear to stay signed in.
    func testAnExplicitSignOutClearsEvenWhileMoving() async {
        let store = self.store(moving: true)
        await store.signOut()

        XCTAssertFalse(store.isSignedIn)
        XCTAssertFalse(store.sessionEndedPendingLanding,
                       "the pilot asked; there is nothing left to defer")
    }
}
