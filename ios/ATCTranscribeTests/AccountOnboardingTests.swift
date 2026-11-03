import XCTest
@testable import ATCTranscribe

/// What a pilot who has never had an Obelisk account runs into on the way to getting one.
///
/// These cover the three client-side faults found by walking the flow on 2026-11-02: a first-time
/// pilot landing on the wrong half of the screen, and an email rule looser than the one the server
/// will actually judge by. The fourth fault — a password reset that silently sends nothing — is on
/// the website and is guarded there.
@MainActor
final class AccountOnboardingTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // The flag lives in UserDefaults and outlives any one store, so a test that does not reset
        // it leaks into the next one — and into whatever else in this host reads it.
        AccountStore.resetHasEverSignedInForTests()
    }

    override func tearDown() {
        AccountStore.resetHasEverSignedInForTests()
        super.tearDown()
    }

    // MARK: Which half of the screen opens first

    func testAFreshDeviceHasNeverSignedIn() {
        XCTAssertFalse(AccountStore.hasEverSignedIn,
                       "nothing has signed in here, so the screen should offer to create an account")
    }

    /// ⚠️ SIGNING OUT MUST NOT MAKE THE DEVICE LOOK NEW AGAIN. If it did, a pilot who signed out
    /// deliberately would be sent to "Create account" on their way back in, and told their own
    /// address is already taken.
    func testSigningOutDoesNotForgetThatThisDeviceHasSignedIn() {
        UserDefaults.standard.set(true, forKey: "atc.account.hasEverSignedIn")
        XCTAssertTrue(AccountStore.hasEverSignedIn)

        AccountStore().clearLocalCredential()

        XCTAssertTrue(AccountStore.hasEverSignedIn,
                      "the credential is gone, but this device has still seen an account before")
    }

    // MARK: The email rule

    /// ⚠️ THE EXACT CASE THAT COST A ROUND TRIP. The check was `email.contains("@")`, so a missing
    /// top-level domain lit the button up; production answers that with a 400 and "Enter a valid
    /// email address." Verified live against obeliskaerospace.com on 2026-11-02.
    func testAnAddressWithNoTopLevelDomainIsRejectedBeforeTheNetwork() {
        XCTAssertFalse(SignInView.looksLikeEmail("probe@example"))
        XCTAssertFalse(SignInView.looksLikeEmail("me@gmail"))
        XCTAssertFalse(SignInView.looksLikeEmail("me@localhost"))
    }

    func testOrdinaryAddressesAreAccepted() {
        for address in ["you@example.com", "first.last@sub.domain.co.uk", "n8925t+efb@gmail.com",
                        "a@b.co", "UPPER@EXAMPLE.COM"] {
            XCTAssertTrue(SignInView.looksLikeEmail(address), "\(address) should be accepted")
        }
    }

    func testObviousNonAddressesAreRejected() {
        for address in ["", "no-at-sign", "@example.com", "you@", "two@at@example.com",
                        "has space@example.com", "you@exam ple.com"] {
            XCTAssertFalse(SignInView.looksLikeEmail(address), "\(address) should be rejected")
        }
    }

    /// The server caps the address at 254 characters; anything this accepts and it rejects is the
    /// late-rejection bug all over again.
    func testTheLengthCapMatchesTheServers() {
        let local = String(repeating: "a", count: 240)
        XCTAssertTrue(SignInView.looksLikeEmail("\(local)@ex.com"), "250 chars is inside the cap")
        XCTAssertFalse(SignInView.looksLikeEmail("\(String(repeating: "a", count: 250))@ex.com"),
                       "over 254 characters is a 400 from the server")
    }

    /// ⚠️ NOT STRICTER THAN THE SERVER EITHER. An address the server would happily take but this
    /// refuses is a button that never lights up for a perfectly good address, which the pilot
    /// cannot diagnose at all — strictly worse than the round trip this replaced.
    func testTheRuleIsNoStricterThanTheServers() {
        // The server's regex is /^[^\s@]+@[^\s@]+\.[^\s@]+$/ — it permits plenty that stricter
        // parsers reject, and this must permit the same.
        for address in ["weird!#$%@example.com", "x@y.z", "a..b@example.com", "-@-.-"] {
            XCTAssertTrue(SignInView.looksLikeEmail(address),
                          "\(address) passes the server's rule, so the button must light up")
        }
    }
}
