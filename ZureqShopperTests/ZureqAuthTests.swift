import XCTest
@testable import ZureqShopper

final class ZureqAuthTests: XCTestCase {
    private var keychain: KeychainStore!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        suite = "zureq-auth-tests-\(UUID().uuidString)"
        keychain = KeychainStore(service: suite)
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        keychain.delete("zureqOAuth")
        keychain.delete("zureqApiKey")
        defaults.removePersistentDomain(forName: suite)
    }

    private func auth(_ stub: StubTransport, now: @escaping @Sendable () -> Date = Date.init) -> ZureqAuth {
        ZureqAuth(keychain: keychain, defaults: defaults, transport: stub, now: now)
    }

    private func form(_ request: URLRequest) -> [String: String] {
        let text = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        return Dictionary(uniqueKeysWithValues: text.split(separator: "&").map { pair in
            let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
            return (parts[0], parts.count > 1 ? parts[1] : "")
        })
    }

    private static let registered = #"{"client_id":"dyn_test"}"#
    private static func tokens(_ access: String, _ refresh: String) -> String {
        #"{"access_token":"\#(access)","token_type":"Bearer","expires_in":3600,"refresh_token":"\#(refresh)","scope":"mcp"}"#
    }

    private func signIn(_ auth: ZureqAuth) async throws {
        let request = try await auth.startRequest()
        let callback = URL(string: "\(ZureqAuth.redirectURI)?code=zac_1&state=\(request.state)")!
        try await auth.complete(request, callback: callback)
    }

    func testPKCEChallengeMatchesRFC7636() {
        XCTAssertEqual(ZureqAuth.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
                       "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testRegistersOnceWithLoopbackRedirectAndBuildsAuthorizeURL() async throws {
        let stub = StubTransport([(201, Self.registered)])
        let auth = auth(stub)
        let first = try await auth.startRequest()
        let second = try await auth.startRequest()

        XCTAssertEqual(stub.requests.count, 1)
        XCTAssertEqual(stub.requests[0].url?.absoluteString, "https://chat.zureq.io/api/oauth/register")
        XCTAssertEqual(stub.body(0)["redirect_uris"] as? [String], ["http://localhost:47823/callback"])
        XCTAssertEqual(stub.body(0)["token_endpoint_auth_method"] as? String, "none")
        XCTAssertNotEqual(first.state, second.state)

        let items = URLComponents(url: first.url, resolvingAgainstBaseURL: false)!.queryItems!
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(first.url.host, "chat.zureq.io")
        XCTAssertEqual(first.url.path, "/oauth/authorize")
        XCTAssertEqual(query["client_id"], "dyn_test")
        XCTAssertEqual(query["redirect_uri"], "http://localhost:47823/callback")
        XCTAssertEqual(query["code_challenge"], ZureqAuth.challenge(for: first.verifier))
        XCTAssertEqual(query["code_challenge_method"], "S256")
        XCTAssertEqual(query["resource"], "https://api.zureq.io/mcp")
        XCTAssertEqual(query["state"], first.state)
    }

    func testCompleteRejectsWrongStateAndDenial() async throws {
        let stub = StubTransport([(201, Self.registered)])
        let auth = auth(stub)
        let request = try await auth.startRequest()

        for (query, code) in [("code=zac_1&state=other", ZureqError.Code.authFailed),
                              ("error=access_denied&state=\(request.state)", .authCancelled),
                              ("error=invalid_request&state=\(request.state)", .authFailed)] {
            do {
                try await auth.complete(request, callback: URL(string: "\(ZureqAuth.redirectURI)?\(query)")!)
                XCTFail("Expected \(code)")
            } catch let error as ZureqError {
                XCTAssertEqual(error.code, code)
            }
        }
        XCTAssertEqual(stub.requests.count, 1)
        XCTAssertFalse(auth.hasSession)
    }

    func testCompleteExchangesCodeAndReusesFreshToken() async throws {
        let stub = StubTransport([(201, Self.registered), (200, Self.tokens("zat_1", "zrt_1"))])
        let auth = auth(stub)
        try await signIn(auth)

        let exchange = form(stub.requests[1])
        XCTAssertEqual(exchange["grant_type"], "authorization_code")
        XCTAssertEqual(exchange["code"], "zac_1")
        XCTAssertEqual(exchange["client_id"], "dyn_test")
        XCTAssertEqual(exchange["redirect_uri"], "http://localhost:47823/callback")
        XCTAssertNotNil(exchange["code_verifier"])
        XCTAssertTrue(auth.hasSession)
        let token = try await auth.accessToken()
        XCTAssertEqual(token, "zat_1")
        XCTAssertEqual(stub.requests.count, 2)
    }

    func testExpiredTokenRefreshesOnceForConcurrentCallers() async throws {
        let clock = Clock()
        let stub = StubTransport([(201, Self.registered), (200, Self.tokens("zat_1", "zrt_1")), (200, Self.tokens("zat_2", "zrt_2"))])
        let auth = auth(stub) { clock.now }
        try await signIn(auth)
        clock.now = clock.now.addingTimeInterval(3600)

        async let a = auth.accessToken()
        async let b = auth.accessToken()
        let tokens = try await [a, b]

        XCTAssertEqual(tokens, ["zat_2", "zat_2"])
        XCTAssertEqual(stub.requests.count, 3)
        XCTAssertEqual(form(stub.requests[2])["grant_type"], "refresh_token")
        XCTAssertEqual(form(stub.requests[2])["refresh_token"], "zrt_1")
    }

    func testInvalidGrantEndsSession() async throws {
        let stub = StubTransport([(201, Self.registered), (200, Self.tokens("zat_1", "zrt_1")), (400, #"{"error":"invalid_grant"}"#)])
        let auth = auth(stub)
        try await signIn(auth)
        do {
            _ = try await auth.refresh(after: "zat_1")
            XCTFail("Expected sign-in to end")
        } catch let error as ZureqError {
            XCTAssertEqual(error, .signInEnded)
        }
        XCTAssertFalse(auth.hasSession)
    }

    func testAppModelSignInReplacesKeyAndSignOutRevokes() async throws {
        let stub = StubTransport([
            (201, Self.registered),
            (200, Self.tokens("zat_1", "zrt_1")),
            (200, #"{"result":{"structuredContent":{"plan":"free","included":100,"used":3,"remaining":97}},"jsonrpc":"2.0","id":1}"#),
            (200, "{}"),
        ])
        keychain.write("zmcp_old", for: "zureqApiKey")
        let model = await AppModel(keychain: keychain, defaults: defaults, transport: stub)

        try await model.signInWithZureq { url in
            let state = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "state" }!.value!
            return URL(string: "\(ZureqAuth.redirectURI)?code=zac_1&state=\(state)")!
        }

        let signedIn = await (model.hasKey, model.usesZureqSignIn, model.usage?.remaining)
        XCTAssertEqual(signedIn.0, true)
        XCTAssertEqual(signedIn.1, true)
        XCTAssertEqual(signedIn.2, 97)
        XCTAssertNil(keychain.read("zureqApiKey"))
        XCTAssertEqual(stub.requests[2].value(forHTTPHeaderField: "Authorization"), "Bearer zat_1")

        await model.removeKey()
        let signedOut = await model.hasKey
        XCTAssertFalse(signedOut)
        XCTAssertNil(keychain.read("zureqOAuth"))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(stub.requests.last?.url?.path, "/api/oauth/revoke")
    }

    func testClientRefreshesOnceAfter401ThenEndsSignIn() async throws {
        let usage = #"{"result":{"structuredContent":{"remaining":5}},"jsonrpc":"2.0","id":1}"#
        let rejected = #"{"jsonrpc":"2.0","id":null,"error":{"code":-32001,"message":"Unknown credential"}}"#
        let provider = RefreshingCredential()

        let stub = StubTransport([(401, rejected), (200, usage)])
        let value: Usage = try await ZureqClient(transport: stub, retryDelay: .zero, provider: provider).call("get_usage")
        XCTAssertEqual(value.remaining, 5)
        XCTAssertEqual(stub.requests.map { $0.value(forHTTPHeaderField: "Authorization") }, ["Bearer zat_old", "Bearer zat_new"])

        let failing = StubTransport([(401, rejected), (401, rejected)])
        do {
            let _: Usage = try await ZureqClient(transport: failing, retryDelay: .zero, provider: provider).call("get_usage")
            XCTFail("Expected sign-in to end")
        } catch let error as ZureqError {
            XCTAssertEqual(error, .signInEnded)
        }
        XCTAssertTrue(provider.invalidated)
    }

    func testLoopbackServerDeliversCallback() async throws {
        XCTAssertEqual(LoopbackServer.requestTarget(in: Data("GET /callback?code=a&state=b HTTP/1.1\r\nHost: x\r\n\r\n".utf8)), "/callback?code=a&state=b")
        XCTAssertNil(LoopbackServer.requestTarget(in: Data("POST /callback HTTP/1.1\r\n\r\n".utf8)))

        let server = try LoopbackServer(port: 47_901)
        defer { server.stop() }
        let received = expectation(description: "callback")
        let box = URLBox()
        try await server.start { url in
            box.url = url
            received.fulfill()
        }
        let (data, response) = try await URLSession.shared.data(from: URL(string: "http://localhost:47901/callback?code=zac_9&state=s")!)
        await fulfillment(of: [received], timeout: 5)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("Signed in"))
        XCTAssertEqual(box.url?.absoluteString, "http://localhost:47901/callback?code=zac_9&state=s")
    }
}

private final class Clock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
}

private final class URLBox: @unchecked Sendable {
    var url: URL?
}

private final class RefreshingCredential: CredentialProvider, @unchecked Sendable {
    var invalidated = false
    func credential() async throws -> String? { "zat_old" }
    func refreshed(after rejected: String) async throws -> String? { "zat_new" }
    func invalidate() async { invalidated = true }
}
