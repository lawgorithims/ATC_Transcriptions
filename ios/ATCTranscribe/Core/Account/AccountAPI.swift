import Foundation

// MARK: - Wire types

/// The pilot's identity as the server knows it.
///
/// Field names mirror `website/lib/auth/native.ts` exactly. That file is the contract; changing a
/// name on either side breaks builds already on pilots' iPads, so both are treated as published API.
struct AccountUser: Codable, Equatable, Sendable {
    let id: String
    let email: String
    let name: String?
    let emailVerified: Bool
    let createdAt: Date
}

/// What the account is entitled to, as the **web/Stripe rail** sees it.
///
/// ⚠️ This is NOT the app's entitlement gate. `EntitlementStore` remains the only thing that decides
/// whether a capability is available, and in this build it still grants everything (M1). This type
/// exists so the account screen can tell the pilot the truth about their subscription without the
/// two systems being wired together before the StoreKit rail exists — see the note in
/// `AccountStore` on why joining them now would be premature.
struct AccountEntitlement: Codable, Equatable, Sendable {
    /// Raw name of the server's tier, matching `Tier`'s case names.
    let tier: String
    let active: Bool
    let status: String?
    let trialing: Bool
    let trialDaysLeft: Int?
    let currentPeriodEnd: Date?
    let cancelAtPeriodEnd: Bool
    let source: String?

    /// The server's tier mapped onto the app's ladder. Unknown names decode to `.none` rather than
    /// crashing or guessing upward: an unrecognised tier is the unwritten state, same polarity rule
    /// as `Entitlements`.
    var appTier: Tier {
        switch tier {
        case "flightBag":      return .flightBag
        case "pro":            return .pro
        case "proPerformance": return .proPerformance
        default:               return .none
        }
    }

    /// Customer-facing one-liner for the account screen.
    var planLabel: String {
        guard active else { return "No active subscription" }
        if trialing, let days = trialDaysLeft {
            return days == 1 ? "Free trial · 1 day left" : "Free trial · \(days) days left"
        }
        return appTier == .none ? "Active" : appTier.label
    }
}

/// `GET /api/auth/native/me`
struct AccountSnapshot: Codable, Equatable, Sendable {
    let user: AccountUser
    let entitlement: AccountEntitlement
}

/// Any response that mints a session: signup, login, Apple, OAuth exchange.
struct AccountSession: Codable, Equatable, Sendable {
    let token: String
    let expiresAt: Date
    let user: AccountUser
    let entitlement: AccountEntitlement

    var snapshot: AccountSnapshot { AccountSnapshot(user: user, entitlement: entitlement) }
}

// MARK: - Errors

/// Why an account call failed, split by the ONE distinction that matters to the caller: whether the
/// stored credential is definitively dead.
///
/// This mirrors the fail-open rule the entitlement layer already lives by (invariant 2 in
/// `HANDOFF_MONETIZATION.md`): *a network failure must never downgrade an entitlement.* A dropped
/// connection at 8,000 feet must not sign a pilot out of their own app, so only `.unauthorized` —
/// a definite negative from the server — is allowed to clear the Keychain.
enum AccountError: Error, LocalizedError, Equatable {
    /// No usable connection, or the server could not be reached. Credential is kept.
    case offline
    /// The server said this session is not valid. Credential must be cleared.
    case unauthorized
    /// The server refused with a message meant for a human (wrong password, email taken…).
    case message(String)
    /// The server answered, but not with anything we understand.
    case badResponse
    /// The pilot backed out of a sign-in sheet. Not an error to report.
    case cancelled

    var errorDescription: String? {
        switch self {
        case .offline:
            return "No connection. Your account will sync when you're back online."
        case .unauthorized:
            return "You've been signed out. Please sign in again."
        case .message(let text):
            return text
        case .badResponse:
            return "Unexpected response from the server. Please try again."
        case .cancelled:
            return nil
        }
    }

    /// Does this error mean the saved credential should be thrown away?
    var invalidatesCredential: Bool { self == .unauthorized }
}

// MARK: - Private wire shapes

/// Every refusal route answers `{ "error": "<human message>" }`.
private struct APIFailure: Decodable { let error: String? }

/// Routes whose body we do not read, only the status of.
private struct APIAck: Decodable { let ok: Bool?; let deleted: Bool? }

// MARK: - Client

/// The app's one HTTP client for accounts.
///
/// Everything here talks to the same Next.js app that serves obeliskaerospace.com, under
/// `/api/auth/native/*` — a namespace that exists because the website authenticates with an
/// HttpOnly cookie and a native client cannot. Same `sessions` table, same 30-day sliding expiry;
/// only the transport differs (bearer header instead of cookie), so signing out on the web and
/// signing out here are the same operation.
struct AccountAPI: Sendable {
    static let shared = AccountAPI()

    let baseURL: URL
    private let session: URLSession

    /// Production host. The app ships pointing here; see `resolvedBaseURL` for the debug override.
    static let productionBaseURL = URL(string: "https://obeliskaerospace.com")!

    init(baseURL: URL? = nil) {
        self.baseURL = baseURL ?? Self.resolvedBaseURL()

        let config = URLSessionConfiguration.ephemeral
        // Ephemeral so no cookie or URL cache persists: the Keychain holds the one credential, and
        // a cached 200 on /me would be indistinguishable from a live confirmation.
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        // Fail fast rather than parking the request until a connection appears. The caller's
        // fail-open handling is better than a spinner that never resolves in the cockpit.
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    /// `--account-host https://host` for pointing a debug build at a local `next dev`.
    ///
    /// A launch argument rather than a UserDefault, for the reason `DownloadPolicy` records: a
    /// `-key value` launch argument lands in UserDefaults' ARGUMENT domain, which outranks every
    /// other domain and is read-only. `#if DEBUG` because a release build that could be pointed at
    /// an arbitrary host by a configuration profile is a credential-harvesting primitive.
    private static func resolvedBaseURL() -> URL {
        #if DEBUG
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--account-host"), i + 1 < args.count,
           let url = URL(string: args[i + 1]), url.scheme != nil {
            return url
        }
        #endif
        return productionBaseURL
    }

    // MARK: Endpoints

    func signUp(email: String, password: String, name: String?) async throws -> AccountSession {
        try await post("/api/auth/native/signup",
                       body: ["email": email, "password": password, "name": name ?? ""])
    }

    func signIn(email: String, password: String) async throws -> AccountSession {
        try await post("/api/auth/native/login", body: ["email": email, "password": password])
    }

    /// Exchange an `ASAuthorizationAppleIDCredential` for a session.
    ///
    /// - Parameters:
    ///   - nonce: the exact string set on the Apple request. Apple echoes it verbatim into the
    ///     identity token, and the server compares it, which is what makes a captured token
    ///     un-replayable.
    ///   - fullName: Apple releases this on the FIRST consent only, so it has to be forwarded then
    ///     or it is lost for good.
    func signInWithApple(identityToken: String, nonce: String, fullName: String?) async throws -> AccountSession {
        var body: [String: String] = ["identityToken": identityToken, "nonce": nonce]
        if let fullName, !fullName.isEmpty { body["fullName"] = fullName }
        return try await post("/api/auth/native/apple", body: body)
    }

    /// Trade the one-time code from a web OAuth handoff for a session. See `WebOAuthSignIn`.
    func exchangeOAuth(code: String, verifier: String) async throws -> AccountSession {
        try await post("/api/auth/native/oauth/exchange", body: ["code": code, "verifier": verifier])
    }

    /// Re-read the account. A 401 here is the only signal that may clear the Keychain.
    func refresh(token: String) async throws -> AccountSnapshot {
        try await request("/api/auth/native/me", method: "GET", token: token, body: nil)
    }

    /// Invalidate this device's session. Best-effort: the caller clears local state regardless,
    /// so a failure here must not block signing out.
    func signOut(token: String) async {
        _ = try? await request("/api/auth/native/logout",
                               method: "POST", token: token, body: nil) as APIAck
    }

    /// Delete the account outright. Required in-app by App Store guideline 5.1.1(v).
    func deleteAccount(token: String) async throws {
        _ = try await request("/api/auth/native/account",
                              method: "DELETE", token: token, body: nil) as APIAck
    }

    // MARK: Transport

    private func post<T: Decodable>(_ path: String, body: [String: String]) async throws -> T {
        try await request(path, method: "POST", token: nil, body: body)
    }

    private func request<T: Decodable>(
        _ path: String,
        method: String,
        token: String?,
        body: [String: String]?
    ) async throws -> T {
        guard let url = URL(string: path, relativeTo: baseURL) else { throw AccountError.badResponse }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch let urlError as URLError {
            switch urlError.code {
            case .cancelled: throw AccountError.cancelled
            default: throw AccountError.offline
            }
        } catch {
            throw AccountError.offline
        }

        guard let http = response as? HTTPURLResponse else { throw AccountError.badResponse }

        if http.statusCode == 401 { throw AccountError.unauthorized }

        guard (200..<300).contains(http.statusCode) else {
            // Show the server's own message rather than a status code — see `APIFailure`; these
            // strings are written for the pilot.
            let message = (try? Self.decoder.decode(APIFailure.self, from: data))?.error
            throw AccountError.message(message ?? "Something went wrong (\(http.statusCode)).")
        }

        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            throw AccountError.badResponse
        }
    }

    /// `Date.toISOString()` on the server emits fractional seconds, which `.iso8601` does not parse.
    /// Both forms are accepted so a future server change in either direction cannot break sign-in.
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]

        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = withFraction.date(from: text) ?? plain.date(from: text) { return date }
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unparseable date: \(text)"))
        }
        return decoder
    }()
}
