import XCTest
@testable import UPasswordsCore
@testable import UPasswordsPersistence

/// RelayClient(api.upasswords.com 协调服务客户端)的传输与错误映射测试。
final class RelayClientTests: XCTestCase {

    final class MockURLProtocol: URLProtocol {
        nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let handler = Self.handler else {
                client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
                return
            }
            do {
                let (response, data) = try handler(request)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }

        override func stopLoading() {}
    }

    private func makeClient() -> RelayClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return RelayClient(baseURL: URL(string: "https://api.test")!,
                           session: URLSession(configuration: config))
    }

    private func ok(_ body: String, status: Int = 200,
                    headers: [String: String] = [:]) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(url: URL(string: "https://api.test")!,
                                       statusCode: status, httpVersion: nil,
                                       headerFields: headers)!
        return (response, Data(body.utf8))
    }

    func testVerifyParsesSession() async throws {
        let token = String(repeating: "a", count: 64)
        MockURLProtocol.handler = { [token] request in
            XCTAssertEqual(request.url?.path, "/v1/auth/verify")
            XCTAssertEqual(request.httpMethod, "POST")
            let body = """
            {"token":"\(token)","expiresAt":1900000000,"userId":"u1"}
            """
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(body.utf8))
        }
        let session = try await makeClient().verify(email: "a@b.c", code: "123456", deviceName: "test")
        XCTAssertEqual(session.token, token)
        XCTAssertEqual(session.userId, "u1")
        XCTAssertEqual(session.expiresAt.timeIntervalSince1970, 1_900_000_000)
    }

    func testGetVaultParsesEnvelope() async throws {
        let envelope = Data([0x55, 0x50, 0x57, 0x4b, 0x45, 0x59, 0x31, 0x00] + Array(repeating: 7, count: 112))
        let b64 = envelope.base64EncodedString()
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/vaults/abc123")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer t1")
            let body = """
            {"vaultId":"abc123","name":"Main","passwordVersion":3,"passwordChangedAt":100.0,
             "envelopeChangedAt":200.0,"hasEnvelope":true,"envelope":"\(b64)",
             "cipherSha256":"\(String(repeating: "c", count: 64))",
             "xmlSha256":"\(String(repeating: "x", count: 64))"}
            """
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(body.utf8))
        }
        let record = try await makeClient().getVault(token: "t1", vaultId: "abc123")
        XCTAssertEqual(record.passwordVersion, 3)
        XCTAssertEqual(record.envelope, envelope)
        XCTAssertEqual(record.envelopeChangedAt, Date(timeIntervalSince1970: 200))
        XCTAssertTrue(record.hasEnvelope)
    }

    func testPutEnvelopeStaleOutcome() async throws {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "PUT")
            let body = """
            {"stale":true,"changedAt":300.0}
            """
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(body.utf8))
        }
        let outcome = try await makeClient().putEnvelope(
            token: "t", vaultId: "v", envelope: Data(repeating: 1, count: 120),
            changedAt: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(outcome, .stale(changedAt: Date(timeIntervalSince1970: 300)))
    }

    /// URLProtocol 层 httpBody 可能为空,须经 bodyStream 读取。
    private static func bodyData(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    func testListSessionsAndRename() async throws {
        MockURLProtocol.handler = { request in
            if request.url?.path == "/v1/auth/sessions" {
                let body = """
                {"sessions":[{"id":"\(String(repeating: "b", count: 32))","deviceName":"iPhone"},
                             {"id":"\(String(repeating: "c", count: 32))","deviceName":""}]}
                """
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Data(body.utf8))
            }
            XCTAssertEqual(request.url?.path, "/v1/vaults/v9")
            XCTAssertEqual(request.httpMethod, "PATCH")
            let body = String(data: Self.bodyData(of: request), encoding: .utf8) ?? ""
            XCTAssertTrue(body.contains(#""name":"NewName""#), "rename body must carry new name")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"ok":true}"#.utf8))
        }
        let client = makeClient()
        let sessions = try await client.listSessions(token: "t")
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions.first?.deviceName, "iPhone")
        try await client.renameVault(token: "t", vaultId: "v9", name: "NewName")
    }

    func testRateLimitedMapsRetryAfter() async {
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil,
                                           headerFields: ["retry-after": "77"])!
            return (response, Data(#"{"error":"rate_limited"}"#.utf8))
        }
        do {
            try await makeClient().requestCode(email: "a@b.c")
            XCTFail("must throw")
        } catch let error as RelayClient.RelayError {
            XCTAssertEqual(error, .rateLimited(retryAfter: 77))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testErrorCodesMap() async {
        let cases: [(Int, String, RelayClient.RelayError)] = [
            (401, "unauthorized", .unauthorized),
            (400, "invalid_code", .invalidCode),
            (409, "name_exists", .nameExists),
            (413, "quota_exceeded", .quotaExceeded),
            (404, "not_found", .notFound),
        ]
        for (status, code, expected) in cases {
            MockURLProtocol.handler = { request in
                let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                               httpVersion: nil, headerFields: nil)!
                return (response, Data(#"{"error":"\#(code)"}"#.utf8))
            }
            do {
                _ = try await self.makeClient().listVaults(token: "t")
                XCTFail("must throw for \(code)")
            } catch let error as RelayClient.RelayError {
                XCTAssertEqual(error, expected)
            } catch {
                XCTFail("unexpected error \(error) for \(code)")
            }
        }
    }
}

/// RelayStore:绑定、版本高水位与令牌存取(注入 defaults + 内存令牌存储)。
final class RelayStoreTests: XCTestCase {

    final class MemoryTokens: RelayTokenStoring {
        var map: [String: String] = [:]
        func saveToken(_ token: String, for email: String) { map[email] = token }
        func token(for email: String) -> String? { map[email] }
        func deleteToken(for email: String) { map.removeValue(forKey: email) }
    }

    private func makeStore() -> (RelayStore, UserDefaults, MemoryTokens) {
        let defaults = UserDefaults(suiteName: "relay.tests.\(UUID().uuidString)")!
        let tokens = MemoryTokens()
        return (RelayStore(defaults: defaults, tokens: tokens), defaults, tokens)
    }

    func testBindingRoundTripAndClear() {
        let (store, defaults, _) = makeStore()
        XCTAssertNil(store.binding(database: "Main"))
        store.setBinding(RelayBinding(email: "a@b.c", vaultId: "v1", vaultName: "Main"), database: "Main")
        XCTAssertEqual(store.binding(database: "Main"),
                       RelayBinding(email: "a@b.c", vaultId: "v1", vaultName: "Main"))
        store.setBinding(nil, database: "Main")
        XCTAssertNil(store.binding(database: "Main"))
    }

    func testVersionHighWaterOnlyAdvances() {
        let (store, _, _) = makeStore()
        XCTAssertNil(store.knownPasswordVersion(database: "Main"))
        store.recordPasswordVersion(3, database: "Main")
        XCTAssertEqual(store.knownPasswordVersion(database: "Main"), 3)
        store.recordPasswordVersion(2, database: "Main")
        XCTAssertEqual(store.knownPasswordVersion(database: "Main"), 3, "version must never regress")
    }

    final class CountingTokens: RelayTokenStoring {
        var map: [String: String] = [:]
        private(set) var reads = 0
        func saveToken(_ token: String, for email: String) { map[email] = token }
        func token(for email: String) -> String? {
            reads += 1
            return map[email]
        }
        func deleteToken(for email: String) { map.removeValue(forKey: email) }
    }

    func testTokenFollowsBindingAndLogoutClears() {
        let (store, _, tokens) = makeStore()
        XCTAssertNil(store.token(database: "Main"))
        store.storeSession(token: "tok1", email: "a@b.c")
        store.setBinding(RelayBinding(email: "a@b.c", vaultId: "v1", vaultName: "Main"), database: "Main")
        XCTAssertEqual(store.token(database: "Main"), "tok1")
        store.logout(database: "Main")
        XCTAssertNil(store.token(database: "Main"))
        XCTAssertNil(tokens.map["a@b.c"])
        XCTAssertNil(store.binding(database: "Main"))
    }

    /// 令牌进程内缓存:自动同步每轮取令牌不再周期性触发钥匙串访问——
    /// 热缓存(本进程登录过)零落盘;冷缓存(进程重启)只读底层一次。
    func testTokenCachedAcrossReads() {
        let defaults = UserDefaults(suiteName: "relay.tests.\(UUID().uuidString)")!
        let tokens = CountingTokens()
        let store = RelayStore(defaults: defaults, tokens: tokens)
        store.storeSession(token: "tok1", email: "a@b.c")
        store.setBinding(RelayBinding(email: "a@b.c", vaultId: "v1", vaultName: "Main"), database: "Main")
        XCTAssertEqual(store.token(database: "Main"), "tok1")
        XCTAssertEqual(store.token(database: "Main"), "tok1")
        XCTAssertEqual(tokens.reads, 0, "warm cache must not touch storage")

        // 冷缓存路径(重启后缓存为空,底层已有令牌)
        let restarted = RelayStore(defaults: defaults, tokens: tokens)
        XCTAssertEqual(restarted.token(database: "Main"), "tok1")
        XCTAssertEqual(restarted.token(database: "Main"), "tok1")
        XCTAssertEqual(tokens.reads, 1, "cold cache must read storage exactly once")

        store.logout(database: "Main")
        XCTAssertNil(store.token(database: "Main"))
    }

    /// 引导门槛状态:登录记住账户(必经门槛解除);首次绑定登记 everBound,
    /// 解绑后不自动回绑。
    func testOnboardingStateAndEverBound() {
        let (store, _, _) = makeStore()
        XCTAssertNil(store.lastAccountEmail)

        store.storeSession(token: "t", email: "a@b.c")
        XCTAssertEqual(store.lastAccountEmail, "a@b.c")

        XCTAssertFalse(store.everBound(database: "Main"))
        store.setBinding(RelayBinding(email: "a@b.c", vaultId: "v1", vaultName: "Main"), database: "Main")
        XCTAssertTrue(store.everBound(database: "Main"))
        store.setBinding(nil, database: "Main")
        XCTAssertTrue(store.everBound(database: "Main"), "unbind must keep ever-bound (no silent rebind)")
    }
}
