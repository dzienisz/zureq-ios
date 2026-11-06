import CryptoKit
import Foundation

/// Sign in with ZUREQ: OAuth 2.1 authorization code + PKCE against chat.zureq.io
/// (docs.zureq.io/account/sign-in-with-zureq). Tokens live in the Keychain.
actor ZureqAuth {
    static let issuer = URL(string: "https://chat.zureq.io")!
    static let resource = "https://api.zureq.io/mcp"
    static let callbackPort: UInt16 = 47823
    /// chat.zureq.io rewrites 127.0.0.1 to localhost when it sends the user through login, so register localhost.
    static let redirectURI = "http://localhost:\(callbackPort)/callback"
    /// A pre-registered client_id from hello@zureq.io; until there is one the app registers itself (RFC 7591).
    static let fixedClientId: String? = nil
    static let clientName = "ZUREQ Shopper for iOS"

    private static let tokensAccount = "zureqOAuth"
    private static let clientKey = "zureqOAuthClient"

    struct Tokens: Codable, Equatable, Sendable {
        var access: String
        var refresh: String
        var expiresAt: Date
        var clientId: String
    }

    struct Request: Sendable {
        var url: URL
        var state: String
        var verifier: String
        var clientId: String
    }

    private let keychain: KeychainStore
    private let defaults: UserDefaults
    private let transport: HTTPTransport
    private let now: @Sendable () -> Date
    private var refreshTask: Task<String, Error>?

    init(keychain: KeychainStore, defaults: UserDefaults, transport: HTTPTransport, now: @escaping @Sendable () -> Date = Date.init) {
        self.keychain = keychain
        self.defaults = defaults
        self.transport = transport
        self.now = now
    }

    nonisolated var hasSession: Bool { storedTokens() != nil }

    func clientId() async throws -> String {
        if let fixed = Self.fixedClientId { return fixed }
        if let cached = defaults.dictionary(forKey: Self.clientKey),
           cached["redirectUri"] as? String == Self.redirectURI,
           let id = cached["clientId"] as? String, !id.isEmpty {
            return id
        }
        let body: [String: Any] = [
            "client_name": Self.clientName,
            "redirect_uris": [Self.redirectURI],
            "token_endpoint_auth_method": "none",
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "scope": "mcp",
        ]
        var request = URLRequest(url: Self.issuer.appending(path: "api/oauth/register"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (status, json) = try await send(request)
        guard (200..<300).contains(status), let id = json?["client_id"] as? String, !id.isEmpty else { throw ZureqError.signInFailed }
        defaults.set(["redirectUri": Self.redirectURI, "clientId": id], forKey: Self.clientKey)
        return id
    }

    func startRequest() async throws -> Request {
        let clientId = try await clientId()
        let verifier = Self.randomValue(32)
        let state = Self.randomValue(16)
        var components = URLComponents(url: Self.issuer.appending(path: "oauth/authorize"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "code_challenge", value: Self.challenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "scope", value: "mcp"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "resource", value: Self.resource),
        ]
        return Request(url: components.url!, state: state, verifier: verifier, clientId: clientId)
    }

    /// Checks the redirect the browser came back with and exchanges its code for tokens.
    func complete(_ request: Request, callback: URL) async throws {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard value("state") == request.state else {
            throw ZureqError(code: .authFailed, message: "ZUREQ sign-in could not be verified. Please try again.")
        }
        if value("error") == "access_denied" { throw ZureqError.signInCancelled }
        guard value("error") == nil, let code = value("code"), !code.isEmpty else { throw ZureqError.signInFailed }

        let (status, json) = try await postToken([
            "grant_type": "authorization_code",
            "code": code,
            "client_id": request.clientId,
            "redirect_uri": Self.redirectURI,
            "code_verifier": request.verifier,
            "resource": Self.resource,
        ])
        guard (200..<300).contains(status), let tokens = tokens(from: json, clientId: request.clientId) else { throw ZureqError.signInFailed }
        guard store(tokens) else {
            throw ZureqError(code: .authFailed, message: "Could not save the sign-in to the Keychain.")
        }
    }

    func accessToken() async throws -> String {
        guard let tokens = storedTokens() else { throw ZureqError.signInEnded }
        if tokens.expiresAt > now().addingTimeInterval(60) { return tokens.access }
        return try await refresh(after: tokens.access)
    }

    /// Refresh tokens are single-use, so concurrent callers share one refresh.
    func refresh(after stale: String?) async throws -> String {
        if let refreshTask { return try await refreshTask.value }
        let task = Task { try await performRefresh(after: stale) }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    /// Drops the local session straight away and returns it so the caller can revoke it.
    @discardableResult
    nonisolated func forget() -> Tokens? {
        let tokens = storedTokens()
        keychain.delete(Self.tokensAccount)
        return tokens
    }

    func revoke(_ tokens: Tokens) async {
        var request = URLRequest(url: Self.issuer.appending(path: "api/oauth/revoke"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formBody(["token": tokens.refresh, "client_id": tokens.clientId])
        _ = try? await transport.send(request)
    }

    // MARK: - Helpers

    private func performRefresh(after stale: String?) async throws -> String {
        guard let tokens = storedTokens() else { throw ZureqError.signInEnded }
        if tokens.access != stale, tokens.expiresAt > now().addingTimeInterval(60) { return tokens.access }
        let (status, json) = try await postToken([
            "grant_type": "refresh_token",
            "refresh_token": tokens.refresh,
            "client_id": tokens.clientId,
        ])
        if json?["error"] as? String == "invalid_grant" {
            forget()
            throw ZureqError.signInEnded
        }
        guard (200..<300).contains(status), let fresh = self.tokens(from: json, clientId: tokens.clientId), store(fresh) else {
            throw ZureqError(code: .authFailed, message: "Could not refresh your ZUREQ sign-in. Please try again.")
        }
        return fresh.access
    }

    private func postToken(_ fields: [String: String]) async throws -> (Int, [String: Any]?) {
        var request = URLRequest(url: Self.issuer.appending(path: "api/oauth/token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formBody(fields)
        return try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> (Int, [String: Any]?) {
        do {
            let (data, response) = try await transport.send(request)
            return (response.statusCode, (try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
        } catch {
            throw ZureqError(code: .networkError, message: "Could not reach ZUREQ. Check your connection.")
        }
    }

    private func tokens(from json: [String: Any]?, clientId: String) -> Tokens? {
        guard let access = json?["access_token"] as? String, let refresh = json?["refresh_token"] as? String,
              let expiresIn = (json?["expires_in"] as? NSNumber)?.doubleValue else { return nil }
        return Tokens(access: access, refresh: refresh, expiresAt: now().addingTimeInterval(expiresIn), clientId: clientId)
    }

    private func store(_ tokens: Tokens) -> Bool {
        guard let data = try? JSONEncoder().encode(tokens), let text = String(data: data, encoding: .utf8) else { return false }
        return keychain.write(text, for: Self.tokensAccount)
    }

    private nonisolated func storedTokens() -> Tokens? {
        guard let text = keychain.read(Self.tokensAccount) else { return nil }
        return try? JSONDecoder().decode(Tokens.self, from: Data(text.utf8))
    }

    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func randomValue(_ count: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        return base64URL(Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func formBody(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let pairs = fields.sorted { $0.key < $1.key }.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }
        return Data(pairs.joined(separator: "&").utf8)
    }
}
