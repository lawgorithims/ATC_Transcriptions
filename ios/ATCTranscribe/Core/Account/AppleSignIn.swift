import AuthenticationServices
import CryptoKit
import Foundation

/// Helpers for Sign in with Apple.
///
/// The button itself is SwiftUI's `SignInWithAppleButton` (see `UI/Account/SignInView.swift`) —
/// Apple's Human Interface Guidelines require their own button, and rolling one is a review
/// rejection. What is left over is the two things the button cannot do for us: minting a nonce, and
/// turning the returned credential into something `AccountAPI` can post.
///
/// # Why Sign in with Apple is not optional here
///
/// App Store guideline 4.8 requires an equivalent privacy-preserving login option wherever an app
/// offers third-party sign-in. This app offers Google (through `WebOAuthSignIn`), so Apple has to
/// be there too — and because the Apple credential is a system one, it is also the fastest path for
/// most pilots, which is why it sits at the top of the sign-in sheet.
enum AppleSignIn {

    /// A fresh random nonce for one sign-in attempt.
    ///
    /// Apple echoes whatever string we set on `ASAuthorizationAppleIDRequest.nonce` **verbatim**
    /// into the identity token's `nonce` claim — it does not hash it for us, which is a common
    /// misreading of the docs. So the value we set is exactly the value the server compares, and
    /// the only requirement is that it is unpredictable and used once.
    static func makeNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status == errSecSuccess {
            return Data(bytes).base64URLEncodedString()
        }
        // SecRandomCopyBytes effectively cannot fail on a running device, but a silent fallback to
        // something guessable would quietly remove the replay protection, so be loud in debug and
        // still return something unique in release.
        assertionFailure("AppleSignIn: SecRandomCopyBytes failed (\(status))")
        return UUID().uuidString + UUID().uuidString
    }

    /// Configure the request the button will run.
    static func configure(_ request: ASAuthorizationAppleIDRequest, nonce: String) {
        request.requestedScopes = [.fullName, .email]
        request.nonce = nonce
    }

    /// What we need out of a successful authorization.
    struct Credential {
        let identityToken: String
        /// Apple releases the name on the FIRST consent only — forward it now or lose it for good.
        let fullName: String?
    }

    /// Pull the identity token and name out of an `ASAuthorization`.
    static func credential(from authorization: ASAuthorization) throws -> Credential {
        guard let appleID = authorization.credential as? ASAuthorizationAppleIDCredential else {
            throw AccountError.badResponse
        }
        guard let tokenData = appleID.identityToken,
              let token = String(data: tokenData, encoding: .utf8) else {
            throw AccountError.badResponse
        }

        let name = [appleID.fullName?.givenName, appleID.fullName?.familyName]
            .compactMap { $0 }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)

        return Credential(identityToken: token, fullName: name.isEmpty ? nil : name)
    }

    /// Map an `ASAuthorizationError` onto our own error type, so the UI treats a cancel as a cancel
    /// rather than showing the pilot a failure they caused on purpose.
    static func mapError(_ error: Error) -> AccountError {
        guard let authError = error as? ASAuthorizationError else { return .badResponse }
        switch authError.code {
        case .canceled:
            return .cancelled
        case .notHandled, .failed, .invalidResponse, .unknown:
            return .message("Apple sign-in didn't complete. Please try again.")
        @unknown default:
            return .badResponse
        }
    }
}

// MARK: - base64url

extension Data {
    /// base64url, no padding — the encoding every JWT-adjacent value in this flow uses.
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

extension SHA256 {
    /// base64url of the digest, matching the server's `s256()` in `lib/auth/native-handoff.ts`.
    static func base64URLDigest(of text: String) -> String {
        Data(SHA256.hash(data: Data(text.utf8))).base64URLEncodedString()
    }
}
