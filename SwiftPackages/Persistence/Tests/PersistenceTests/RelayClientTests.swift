import XCTest
@testable import UPasswordsCore
@testable import UPasswordsPersistence

/// RelayClient(/v2 行协议)的传输与错误映射 + RowSync 引擎端到端(脚本化
/// mock 服务端)测试。
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
            {"token":"\(token)","expiresAt":1900000000000,"userId":"u1"}
            """
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(body.utf8))
        }
        let session = try await makeClient().verify(email: "a@b.c", code: "123456",
                                                    deviceName: "test", platform: .macos)
        XCTAssertEqual(session.token, token)
        XCTAssertEqual(session.userId, "u1")
        XCTAssertEqual(session.expiresAt.timeIntervalSince1970, 1_900_000_000, accuracy: 0.001)
    }

    func testListSessionsParsesCurrentFlagAndSelfRevoke() async throws {
        MockURLProtocol.handler = { request in
            if request.url?.path == "/v1/auth/session", request.httpMethod == "DELETE" {
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Data(#"{"ok":true}"#.utf8))
            }
            XCTAssertEqual(request.url?.path, "/v1/auth/sessions")
            let body = """
            {"sessions":[
              {"id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","deviceName":"iPhone 18 Pro · iPhone","platform":"ios","current":true,"lastSeenAt":1000.0},
              {"id":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","deviceName":"Mac","platform":"macos","lastSeenAt":900.0}]}
            """
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(body.utf8))
        }
        let client = makeClient()
        let sessions = try await client.listSessions(token: "t")
        XCTAssertEqual(sessions.count, 2)
        XCTAssertTrue(sessions[0].isCurrent)
        XCTAssertEqual(sessions[0].platform, "ios")
        XCTAssertEqual(sessions[0].lastSeenAt?.timeIntervalSince1970 ?? 0, 1, accuracy: 0.001)
        XCTAssertFalse(sessions[1].isCurrent)
        // 自撤销:DELETE /v1/auth/session(鉴权即身份,不带会话号)
        try await client.revokeOwnSession(token: "t")
    }

    func testGetVaultParsesEnvelopeAndSeq() async throws {
        let envelope = Data([0x55, 0x50, 0x57, 0x4b, 0x45, 0x59, 0x31, 0x00] + Array(repeating: 7, count: 112))
        let b64 = envelope.base64EncodedString()
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/vaults/abc123")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer t1")
            let body = """
            {"vaultId":"abc123","name":"Main","passwordVersion":3,"passwordChangedAt":100.0,
             "envelopeChangedAt":200.0,"hasEnvelope":true,"envelope":"\(b64)","headSeq":42,"itemCount":7}
            """
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(body.utf8))
        }
        let record = try await makeClient().getVault(token: "t1", vaultId: "abc123")
        XCTAssertEqual(record.passwordVersion, 3)
        XCTAssertEqual(record.envelope, envelope)
        XCTAssertEqual(record.headSeq, 42)
        XCTAssertEqual(record.itemCount, 7)
        XCTAssertTrue(record.hasEnvelope)
    }

    func testVaultSeq() async throws {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/vaults/vv/seq")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"headSeq":99,"passwordVersion":1}"#.utf8))
        }
        let seq = try await makeClient().vaultSeq(token: "t", vaultId: "vv")
        XCTAssertEqual(seq.headSeq, 99)
        XCTAssertEqual(seq.passwordVersion, 1)
    }

    func testPostItemsAndChangesParse() async throws {
        let uuid = UUID()
        MockURLProtocol.handler = { request in
            if request.url?.path == "/v1/vaults/vv/items", request.httpMethod == "POST" {
                let body = """
                {"results":[{"uuid":"\(uuid.uuidString)","status":"ok","revision":1}]}
                """
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Data(body.utf8))
            }
            XCTAssertEqual(request.url?.path, "/v1/vaults/vv/changes")
            let body = """
            {"headSeq":5,"changes":[{"seq":5,"uuid":"\(uuid.uuidString)","op":"upsert","revision":1,
             "bodyB64":"AAAA","kind":1,"modifiedMs":123.0}]}
            """
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(body.utf8))
        }
        let client = makeClient()
        let results = try await client.postItems(token: "t", vaultId: "vv", items: [
            .init(uuid: uuid, kind: 1, isDelete: false, baseRevision: 0,
                  bodyB64: "AAAA", sha256: nil, modifiedMs: 123),
        ])
        XCTAssertEqual(results[uuid], .ok(revision: 1))
        let (headSeq, changes) = try await client.getChanges(token: "t", vaultId: "vv", since: 0)
        XCTAssertEqual(headSeq, 5)
        XCTAssertEqual(changes.first?.uuid, uuid)
        XCTAssertEqual(changes.first?.kind, 1)
    }

    func testRateLimitedMapsRetryAfter() async {
        MockURLProtocol.handler = { _ in
            let response = HTTPURLResponse(url: URL(string: "https://api.test")!,
                                           statusCode: 429, httpVersion: nil,
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
            (410, "cursor_expired", .cursorExpired),
            (409, "rekey_in_progress", .rekeyInProgress),
            (413, "item_too_large", .itemTooLarge),
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

/// RowSync 引擎:上行 CAS、下行应用、删除胜、缺席即删除、对端改密信号。
final class RowSyncTests: XCTestCase {

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

    private let key = RowSyncKey(raw: Data((0..<32).map { UInt8($0 & 0xff) }))

    private func makeClient() -> RelayClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return RelayClient(baseURL: URL(string: "https://api.test")!,
                           session: URLSession(configuration: config))
    }

    private func respond(_ body: String, request: URLRequest) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
         Data(body.utf8))
    }

    private func sealedBody(_ item: DatabaseItem) throws -> String {
        try RowSyncCipher.encrypt(DatabaseItemCodec.xmlData(item), key: key, uuid: item.uuid)
            .base64EncodedString()
    }

    private func sampleDatabase() -> (PasswordDatabase, Card, CardLabel) {
        var db = PasswordDatabase()
        var card = Card()
        card.title = "GitHub"
        card.modified = 1000
        let label = CardLabel(name: "Work", timeStamp: 900)
        db.cards = [card]
        db.labels = [label]
        return (db, card, label)
    }

    func testPushUploadsDirtyAndClearsOnOk() async throws {
        var (db, card, label) = sampleDatabase()
        var state = RowSyncState()
        state.markDirty(uuid: card.id, modifiedMs: 1000)
        state.markDirty(uuid: label.id, modifiedMs: 900)

        MockURLProtocol.handler = { [card, label] request in
            XCTAssertEqual(request.url?.path, "/v1/vaults/v1/items")
            let body = """
            {"results":[{"uuid":"\(card.id.uuidString)","status":"ok","revision":1},
                         {"uuid":"\(label.id.uuidString)","status":"ok","revision":1}]}
            """
            return self.respond(body, request: request)
        }
        let outcome = try await RowSync.push(client: makeClient(), token: "t", vaultId: "v1",
                                             key: key, database: &db, state: &state)
        XCTAssertEqual(outcome.pushedItems, 2)
        XCTAssertFalse(state.hasPendingWork)
        XCTAssertEqual(state.revisions[card.id], 1)
        XCTAssertEqual(state.revisions[label.id], 1)
    }

    func testPullAppliesUpsertsAndAdvancesCursor() async throws {
        var db = PasswordDatabase()
        var state = RowSyncState()
        var remote = Card()
        remote.title = "From Peer"
        remote.modified = 5000
        let sealed = try sealedBody(.card(remote))

        MockURLProtocol.handler = { [remote, sealed] request in
            XCTAssertEqual(request.url?.path, "/v1/vaults/v1/changes")
            let body = """
            {"headSeq":7,"changes":[{"seq":7,"uuid":"\(remote.id.uuidString)","op":"upsert","revision":1,
             "bodyB64":"\(sealed)","kind":1,"modifiedMs":5000.0}]}
            """
            return self.respond(body, request: request)
        }
        let outcome = try await RowSync.pull(client: makeClient(), token: "t", vaultId: "v1",
                                             key: key, database: &db, state: &state)
        XCTAssertEqual(outcome.pulledItems, 1)
        XCTAssertEqual(state.cursor, 7)
        XCTAssertEqual(db.card(id: remote.id)?.title, "From Peer")
        XCTAssertEqual(state.revisions[remote.id], 1)
    }

    /// 自己上一轮上传的回声(revision 未超过本地已知)是空操作:
    /// 游标前进但不计入"拉取 N 条"——否则用户删一条会看到"拉取 1 上传 1"。
    func testPullEchoOfOwnPushIsNotCounted() async throws {
        var (db, card, _) = sampleDatabase()
        var state = RowSyncState()
        state.revisions[card.id] = 3 // 本端已知 rev 3(自己刚推上去的)
        let sealed = try sealedBody(.card(card))

        MockURLProtocol.handler = { [card, sealed] request in
            let body = """
            {"headSeq":9,"changes":[{"seq":9,"uuid":"\(card.id.uuidString)","op":"upsert","revision":3,
             "bodyB64":"\(sealed)","kind":1,"modifiedMs":1000.0}]}
            """
            return self.respond(body, request: request)
        }
        let outcome = try await RowSync.pull(client: makeClient(), token: "t", vaultId: "v1",
                                             key: key, database: &db, state: &state)
        XCTAssertEqual(outcome.pulledItems, 0, "回声空操作不计入拉取计数")
        XCTAssertEqual(state.cursor, 9, "游标照常前进")
    }

    func testPullPurgeRemovesLocally() async throws {
        var (db, card, _) = sampleDatabase()
        var state = RowSyncState()
        state.revisions[card.id] = 1
        state.dirtyUpserts[card.id] = 2000 // 本地未上行的编辑也要一并丢弃(删除胜)

        MockURLProtocol.handler = { [card] request in
            let body = """
            {"headSeq":9,"changes":[{"seq":9,"uuid":"\(card.id.uuidString)","op":"purge","revision":2,"deleted":true}]}
            """
            return self.respond(body, request: request)
        }
        _ = try await RowSync.pull(client: makeClient(), token: "t", vaultId: "v1",
                                   key: key, database: &db, state: &state)
        XCTAssertNil(db.card(id: card.id))
        XCTAssertNil(state.dirtyUpserts[card.id], "删除胜:本地未上行修改一并丢弃")
        XCTAssertNil(state.revisions[card.id])
    }

    func testPullRekeySignal() async throws {
        var db = PasswordDatabase()
        var state = RowSyncState()
        MockURLProtocol.handler = { request in
            let body = """
            {"headSeq":11,"changes":[{"seq":11,"uuid":"","op":"rekey","revision":2}]}
            """
            return self.respond(body, request: request)
        }
        do {
            _ = try await RowSync.pull(client: makeClient(), token: "t", vaultId: "v1",
                                       key: key, database: &db, state: &state)
            XCTFail("must throw rekey signal")
        } catch let signal as RowSyncRekeySignal {
            XCTAssertEqual(signal.passwordVersion, 2)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testPushNotFoundDropsLocalItem() async throws {
        var (db, card, _) = sampleDatabase()
        var state = RowSyncState()
        state.markDirty(uuid: card.id, modifiedMs: 1000)

        MockURLProtocol.handler = { [card] request in
            let body = """
            {"results":[{"uuid":"\(card.id.uuidString)","status":"not_found","deletedAt":123.0}]}
            """
            return self.respond(body, request: request)
        }
        _ = try await RowSync.push(client: makeClient(), token: "t", vaultId: "v1",
                                   key: key, database: &db, state: &state)
        XCTAssertNil(db.card(id: card.id), "缺席即删除:本地丢弃,绝不重插")
        XCTAssertFalse(state.hasPendingWork)
    }

    func testPushConflictAdoptsNewerRemote() async throws {
        var (db, card, _) = sampleDatabase()
        var state = RowSyncState()
        state.markDirty(uuid: card.id, modifiedMs: 1000) // 本地 modified=1000

        var remote = card
        remote.title = "Peer Wins"
        remote.modified = 9000 // 对端更新 → 采纳
        let sealed = try sealedBody(.card(remote))

        MockURLProtocol.handler = { [card, sealed] request in
            let body = """
            {"results":[{"uuid":"\(card.id.uuidString)","status":"conflict",
             "current":{"revision":4,"bodyB64":"\(sealed)"}}]}
            """
            return self.respond(body, request: request)
        }
        _ = try await RowSync.push(client: makeClient(), token: "t", vaultId: "v1",
                                   key: key, database: &db, state: &state)
        XCTAssertEqual(db.card(id: card.id)?.title, "Peer Wins")
        XCTAssertNil(state.dirtyUpserts[card.id], "对端新 → 清脏收敛")
        XCTAssertEqual(state.revisions[card.id], 4)
    }

    /// 条目体加密的 AAD 绑定:同一密文搬到别的 uuid 下解不开(行搬运防护)。
    func testCipherAadBindsUuid() throws {
        var card = Card()
        card.title = "AAD"
        let plaintext = DatabaseItemCodec.xmlData(.card(card))
        let sealed = try RowSyncCipher.encrypt(plaintext, key: key, uuid: card.id)
        XCTAssertNotNil(RowSyncCipher.decrypt(sealed, key: key, uuid: card.id))
        XCTAssertNil(RowSyncCipher.decrypt(sealed, key: key, uuid: UUID()), "uuid 不匹配必须解密失败")
    }
}
