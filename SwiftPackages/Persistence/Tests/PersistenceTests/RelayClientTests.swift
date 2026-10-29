import XCTest
@testable import UPasswordsCore
@testable import UPasswordsPersistence

/// RelayClient(/v1, sync protocol 5)的传输与错误映射 + RowSync 引擎端到端(脚本化
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

    private func respond(_ body: String, request: URLRequest) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
         Data(body.utf8))
    }

    private func bodyData(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { buffer.deallocate() }
        var data = Data()
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: 4096)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data.isEmpty ? nil : data
    }

    func testVerifyParsesSession() async throws {
        let token = String(repeating: "a", count: 64)
        MockURLProtocol.handler = { [token] request in
            XCTAssertEqual(request.url?.path, "/v1/auth/verify")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-UPW-Sync-Protocol"), "5")
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

    func testBackupSnapshotInventoryCollectsRowAttachmentAndConflictState() async throws {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer backup-token")
            switch request.url?.path {
            case "/v1/vaults/vv":
                return self.respond(
                    #"{"vaultId":"vv","name":"Main","passwordVersion":1,"hasEnvelope":false,"headSeq":42,"itemCount":3}"#,
                    request: request)
            case "/v1/vaults/vv/attachment-versions":
                return self.respond(
                    #"{"versions":[],"nextOffset":0,"hasMore":false}"#,
                    request: request)
            case "/v1/vaults/vv/conflicts":
                return self.respond(#"{"conflicts":[]}"#, request: request)
            case "/v1/vaults/vv/conflict-history":
                return self.respond(
                    #"{"snapshotMs":2000000,"totalCandidates":0,"candidates":[],"nextCursor":null}"#,
                    request: request)
            default:
                XCTFail("Unexpected backup inventory endpoint \(request.url?.path ?? "")")
                return self.respond("{}", request: request)
            }
        }

        let inventory = try await makeClient().getBackupSnapshotInventory(
            token: "backup-token",
            vaultId: "vv")

        XCTAssertEqual(inventory.headSequence, 42)
        XCTAssertEqual(inventory.attachmentVersionCount, 0)
        XCTAssertEqual(inventory.conflictCount, 0)
        XCTAssertEqual(inventory.conflictCandidateCount, 0)
        XCTAssertTrue(inventory.retainedHistoryAvailable)
        XCTAssertEqual(inventory.retainedConflictCount, 0)
        XCTAssertEqual(inventory.retainedConflictCandidateCount, 0)
    }

    func testBackupSnapshotInventoryCollectsRetainedConflictsAcrossPages() async throws {
        let conflictID = String(repeating: "a", count: 32)
        let firstCandidateID = String(repeating: "b", count: 32)
        let secondCandidateID = String(repeating: "c", count: 32)
        let itemUUID = UUID()
        let firstCipher = Data("retained candidate one".utf8)
        let secondCipher = Data("retained candidate two".utf8)
        let firstDigest = SyncConflict.sha256Hex(firstCipher)
        let secondDigest = SyncConflict.sha256Hex(secondCipher)

        MockURLProtocol.handler = { request in
            switch request.url?.path {
            case "/v1/vaults/vv":
                return self.respond(
                    #"{"vaultId":"vv","name":"Main","passwordVersion":1,"hasEnvelope":false,"headSeq":42,"itemCount":3}"#,
                    request: request)
            case "/v1/vaults/vv/attachment-versions":
                return self.respond(#"{"versions":[],"nextOffset":0,"hasMore":false}"#, request: request)
            case "/v1/vaults/vv/conflicts":
                return self.respond(#"{"conflicts":[]}"#, request: request)
            case "/v1/vaults/vv/conflict-history":
                let page = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "cursor" })?.value
                if page == nil {
                    return self.respond(
                        """
                        {"snapshotMs":3000000,"totalCandidates":2,"nextCursor":"page_2","candidates":[
                          {"conflictId":"\(conflictID)","itemUuid":"\(itemUUID.uuidString)","baseRevision":1,"currentRevision":2,"currentDeletedSeq":0,"generation":1,"createdMs":1000,"updatedMs":2000,"resolvedMs":2500000,"expiresMs":4000000,"selectedCandidateId":"\(firstCandidateID)","candidate":{"candidateId":"\(firstCandidateID)","kind":1,"op":"upsert","revision":1,"modifiedMs":1000,"committedMs":1100,"deviceName":"Mac","platform":"macos","bodyB64":"\(firstCipher.base64EncodedString())","sha256":"\(firstDigest)"}}
                        ]}
                        """,
                        request: request)
                }
                XCTAssertEqual(page, "page_2")
                return self.respond(
                    """
                    {"snapshotMs":3000000,"totalCandidates":2,"nextCursor":null,"candidates":[
                      {"conflictId":"\(conflictID)","itemUuid":"\(itemUUID.uuidString)","baseRevision":1,"currentRevision":2,"currentDeletedSeq":0,"generation":1,"createdMs":1000,"updatedMs":2000,"resolvedMs":2500000,"expiresMs":4000000,"selectedCandidateId":"\(firstCandidateID)","candidate":{"candidateId":"\(secondCandidateID)","kind":1,"op":"upsert","revision":2,"modifiedMs":1200,"committedMs":1300,"deviceName":"iPhone","platform":"ios","bodyB64":"\(secondCipher.base64EncodedString())","sha256":"\(secondDigest)"}}
                    ]}
                    """,
                    request: request)
            default:
                XCTFail("Unexpected backup inventory endpoint \(request.url?.path ?? "")")
                return self.respond("{}", request: request)
            }
        }

        let inventory = try await makeClient().getBackupSnapshotInventory(
            token: "backup-token",
            vaultId: "vv")

        XCTAssertTrue(inventory.retainedHistoryAvailable)
        XCTAssertEqual(inventory.retainedConflictCount, 1)
        XCTAssertEqual(inventory.retainedConflictCandidateCount, 2)
        XCTAssertEqual(inventory.retainedConflicts.first?.conflictID, conflictID)
        XCTAssertEqual(
            inventory.retainedConflicts.first?.candidates.map(\.candidateID),
            [firstCandidateID, secondCandidateID])
    }

    func testBackupSnapshotInventoryKeepsOtherInventoryWhenRetainedHistoryIsUnavailable() async throws {
        MockURLProtocol.handler = { request in
            switch request.url?.path {
            case "/v1/vaults/vv":
                return self.respond(
                    #"{"vaultId":"vv","name":"Main","passwordVersion":1,"hasEnvelope":false,"headSeq":42,"itemCount":3}"#,
                    request: request)
            case "/v1/vaults/vv/attachment-versions":
                return self.respond(#"{"versions":[],"nextOffset":0,"hasMore":false}"#, request: request)
            case "/v1/vaults/vv/conflicts":
                return self.respond(#"{"conflicts":[]}"#, request: request)
            case "/v1/vaults/vv/conflict-history":
                return self.ok(#"{"error":"not_found"}"#, status: 404)
            default:
                XCTFail("Unexpected backup inventory endpoint \(request.url?.path ?? "")")
                return self.respond("{}", request: request)
            }
        }

        let inventory = try await makeClient().getBackupSnapshotInventory(
            token: "backup-token",
            vaultId: "vv")

        XCTAssertEqual(inventory.headSequence, 42)
        XCTAssertFalse(inventory.retainedHistoryAvailable)
        XCTAssertEqual(inventory.conflictCount, 0)
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

    func testGetAttachmentVerifiesResponseLengthAndDigest() async throws {
        let attachmentID = UUID()
        let cipher = Data("authenticated encrypted attachment".utf8)
        let hash = SyncConflict.sha256Hex(cipher)
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/vaults/vv/attachments/\(attachmentID.uuidString)")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-UPW-Sync-Protocol"), "5")
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: [
                    "X-Sha256": hash,
                    "X-Bytes": String(cipher.count),
                    "Content-Length": String(cipher.count),
                ])!
            return (response, cipher)
        }

        let result = try await makeClient().getAttachment(
            token: "t", vaultId: "vv", attachUuid: attachmentID)
        XCTAssertEqual(result, cipher)
    }

    func testGetAttachmentRejectsDigestMismatch() async throws {
        let attachmentID = UUID()
        let cipher = Data("encrypted attachment".utf8)
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: [
                    "X-Sha256": String(repeating: "0", count: 64),
                    "X-Bytes": String(cipher.count),
                    "Content-Length": String(cipher.count),
                ])!
            return (response, cipher)
        }

        do {
            _ = try await makeClient().getAttachment(
                token: "t", vaultId: "vv", attachUuid: attachmentID)
            XCTFail("A ciphertext digest mismatch must be rejected")
        } catch let error as RelayClient.RelayError {
            XCTAssertEqual(error, .attachmentIntegrityFailure)
        }
    }

    func testGetAttachmentVersionsListsAllRetainedVersionsAcrossPages() async throws {
        let attachmentID = UUID()
        let cardID = UUID()
        let firstVersion = UUID()
        let secondVersion = UUID()
        let wrapper = Data(repeating: 7, count: 40).base64EncodedString()
        var page = 0
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/vaults/v1/attachment-versions")
            XCTAssertNil(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "cardUuid" }))
            defer { page += 1 }
            if page == 0 {
                return self.respond("""
                {"versions":[{"attachmentId":"\(attachmentID)","cardUuid":"\(cardID)",
                "contentVersion":"\(firstVersion)","dekWrapped":"\(wrapper)",
                "sha256":"\(String(repeating: "a", count: 64))","bytes":12,"isCurrent":false}],
                "nextOffset":1,"hasMore":true}
                """, request: request)
            }
            return self.respond("""
            {"versions":[{"attachmentId":"\(attachmentID)","cardUuid":"\(cardID)",
            "contentVersion":"\(secondVersion)","dekWrapped":"\(wrapper)",
            "sha256":"\(String(repeating: "b", count: 64))","bytes":13,"isCurrent":true}],
            "nextOffset":2,"hasMore":false}
            """, request: request)
        }

        let versions = try await makeClient().getAttachmentVersions(token: "t", vaultId: "v1")

        XCTAssertEqual(versions.count, 2)
        XCTAssertEqual(versions.map(\.cardID), [cardID, cardID])
        XCTAssertEqual(versions.map(\.contentVersion), [firstVersion, secondVersion])
        XCTAssertEqual(versions.map(\.isCurrent), [false, true])
    }

    func testGetAttachmentVersionsRejectsDuplicateIdentityAcrossPages() async {
        let attachmentID = UUID()
        let cardID = UUID()
        let contentVersion = UUID()
        let wrapper = Data(repeating: 7, count: 40).base64EncodedString()
        let entry = """
        {"attachmentId":"\(attachmentID)","cardUuid":"\(cardID)",
        "contentVersion":"\(contentVersion)","dekWrapped":"\(wrapper)",
        "sha256":"\(String(repeating: "a", count: 64))","bytes":12,"isCurrent":false}
        """
        var requestCount = 0
        MockURLProtocol.handler = { request in
            defer { requestCount += 1 }
            let hasMore = requestCount == 0
            let nextOffset = requestCount + 1
            return self.respond(
                """
                {"versions":[\(entry)],"nextOffset":\(nextOffset),"hasMore":\(hasMore)}
                """,
                request: request)
        }

        do {
            _ = try await makeClient().getAttachmentVersions(token: "t", vaultId: "v1")
            XCTFail("Duplicate versions across pages must be rejected")
        } catch let error as RowSyncSafetyError {
            XCTAssertEqual(error, .invalidResponse)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(requestCount, 2)
    }

    func testGetAttachmentVersionsRejectsOversizedPage() async {
        let cardID = UUID()
        let wrapper = Data(repeating: 7, count: 40).base64EncodedString()
        let entries = (0...200).map { _ in
            """
            {"attachmentId":"\(UUID())","cardUuid":"\(cardID)",
            "contentVersion":"\(UUID())","dekWrapped":"\(wrapper)",
            "sha256":"\(String(repeating: "a", count: 64))","bytes":12,"isCurrent":false}
            """
        }.joined(separator: ",")
        MockURLProtocol.handler = { request in
            self.respond(
                """
                {"versions":[\(entries)],"nextOffset":201,"hasMore":false}
                """,
                request: request)
        }

        do {
            _ = try await makeClient().getAttachmentVersions(token: "t", vaultId: "v1")
            XCTFail("A page larger than the requested limit must be rejected")
        } catch let error as RowSyncSafetyError {
            XCTAssertEqual(error, .invalidResponse)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testGetAttachmentVersionsStopsReadingOversizedResponseBody() async {
        let padding = String(repeating: "x", count: 2 * 1024 * 1024 + 1)
        MockURLProtocol.handler = { request in
            self.respond(
                """
                {"versions":[],"nextOffset":0,"hasMore":false,"padding":"\(padding)"}
                """,
                request: request)
        }

        do {
            _ = try await makeClient().getAttachmentVersions(token: "t", vaultId: "v1")
            XCTFail("A response exceeding the streaming byte limit must be rejected")
        } catch let error as RowSyncSafetyError {
            XCTAssertEqual(error, .invalidResponse)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testGetAttachmentRejectsLengthMismatch() async throws {
        let attachmentID = UUID()
        let cipher = Data("encrypted attachment".utf8)
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: [
                    "X-Sha256": SyncConflict.sha256Hex(cipher),
                    "X-Bytes": String(cipher.count + 1),
                    "Content-Length": String(cipher.count + 1),
                ])!
            return (response, cipher)
        }

        do {
            _ = try await makeClient().getAttachment(
                token: "t", vaultId: "vv", attachUuid: attachmentID)
            XCTFail("A ciphertext length mismatch must be rejected")
        } catch let error as RelayClient.RelayError {
            XCTAssertEqual(error, .attachmentIntegrityFailure)
        }
    }

    func testGetAttachmentRejectsMissingIntegrityHeaders() async throws {
        let attachmentID = UUID()
        let cipher = Data("encrypted attachment".utf8)
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, cipher)
        }

        do {
            _ = try await makeClient().getAttachment(
                token: "t", vaultId: "vv", attachUuid: attachmentID)
            XCTFail("A response without integrity metadata must be rejected")
        } catch let error as RelayClient.RelayError {
            XCTAssertEqual(error, .attachmentIntegrityFailure)
        }
    }

    func testPostItemsAndChangesParse() async throws {
        let uuid = UUID()
        let attachmentID = UUID()
        let contentVersion = UUID()
        MockURLProtocol.handler = { request in
            if request.url?.path == "/v1/vaults/vv/items", request.httpMethod == "POST" {
                let payloadData = try XCTUnwrap(self.bodyData(request))
                let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: payloadData) as? [String: Any])
                let rows = try XCTUnwrap(payload["items"] as? [[String: Any]])
                let references = try XCTUnwrap(rows.first?["attachmentRefs"] as? [[String: Any]])
                XCTAssertEqual(references.count, 1)
                XCTAssertEqual(references[0]["attachmentId"] as? String, attachmentID.uuidString)
                XCTAssertEqual(references[0]["contentVersion"] as? String, contentVersion.uuidString)
                XCTAssertEqual(references[0]["restoreDeleted"] as? Bool, false)
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
                  bodyB64: "AAAA", sha256: nil, modifiedMs: 123,
                  attachmentRefs: [.init(attachmentID: attachmentID, contentVersion: contentVersion)]),
        ])
        XCTAssertEqual(results[uuid], .ok(revision: 1))
        let (headSeq, changes) = try await client.getChanges(token: "t", vaultId: "vv", since: 0)
        XCTAssertEqual(headSeq, 5)
        XCTAssertEqual(changes.first?.uuid, uuid)
        XCTAssertEqual(changes.first?.kind, 1)
    }

    func testPostItemsRejectsCardUpsertWithoutAttachmentReferences() async throws {
        MockURLProtocol.handler = { _ in
            XCTFail("request must be rejected before network access")
            return self.ok("{}")
        }

        do {
            _ = try await makeClient().postItems(token: "t", vaultId: "vv", items: [
                .init(uuid: UUID(), kind: 1, isDelete: false, baseRevision: 0,
                      bodyB64: "AAAA", sha256: nil, modifiedMs: 123),
            ])
            XCTFail("card write without attachment references must fail")
        } catch let error as RowSyncSafetyError {
            XCTAssertEqual(error, .attachmentReferencesUnavailable)
        }
    }

    func testGetChangesParsesAtomicConflictResolution() async throws {
        let itemUUID = UUID()
        let restoredUUID = UUID()
        let conflictID = String(repeating: "a", count: 32)
        MockURLProtocol.handler = { request in
            let body = """
            {"headSeq":8,"changes":[{"seq":8,"uuid":"\(itemUUID.uuidString)","op":"resolve",
             "revision":3,"conflictId":"\(conflictID)","resolvedItemUuid":"\(restoredUUID.uuidString)",
             "resolvedRevision":1,"baseRevision":1,"winnerCandidateId":"\(String(repeating: "c", count: 32))",
             "winnerKind":1,"winnerOp":"upsert","resolutionType":"candidate",
             "bodyB64":"AAAA","kind":1,"modifiedMs":123.0}]}
            """
            return self.ok(body)
        }

        let (_, changes) = try await makeClient().getChanges(
            token: "t", vaultId: "vv", since: 7)

        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes[0].op, "resolve")
        XCTAssertEqual(changes[0].uuid, itemUUID)
        XCTAssertEqual(changes[0].resolvedItemUUID, restoredUUID)
        XCTAssertEqual(changes[0].conflictID, conflictID)
        XCTAssertEqual(changes[0].revision, 3)
        XCTAssertEqual(changes[0].resolvedRevision, 1)
        XCTAssertEqual(changes[0].conflictBaseRevision, 1)
        XCTAssertEqual(changes[0].winnerCandidateID, String(repeating: "c", count: 32))
        XCTAssertEqual(changes[0].winnerKind, 1)
        XCTAssertEqual(changes[0].winnerIsDelete, false)
        XCTAssertEqual(changes[0].resolutionType, .candidate)
        XCTAssertFalse(changes[0].deleted)
    }

    func testGetChangesParsesConflictResolutionDeletion() async throws {
        let itemUUID = UUID()
        MockURLProtocol.handler = { request in
            self.ok("""
            {"headSeq":8,"changes":[{"seq":8,"uuid":"\(itemUUID.uuidString)","op":"resolve",
             "revision":3,"conflictId":"\(String(repeating: "b", count: 32))","deleted":true,
             "baseRevision":1,"winnerCandidateId":"\(String(repeating: "d", count: 32))",
             "winnerKind":1,"winnerOp":"delete","resolutionType":"candidate"}]}
            """)
        }

        let (_, changes) = try await makeClient().getChanges(
            token: "t", vaultId: "vv", since: 7)

        XCTAssertNil(changes[0].resolvedItemUUID)
        XCTAssertTrue(changes[0].deleted)
        XCTAssertNil(changes[0].bodyB64)
        XCTAssertEqual(changes[0].winnerIsDelete, true)
        XCTAssertEqual(changes[0].resolutionType, .candidate)
    }

    func testGetChangesRejectsIncompleteConflictResolution() async {
        let itemUUID = UUID()
        MockURLProtocol.handler = { request in
            self.ok("""
            {"headSeq":8,"changes":[{"seq":8,"uuid":"\(itemUUID.uuidString)","op":"resolve",
             "revision":3,"conflictId":"\(String(repeating: "c", count: 32))",
             "resolvedItemUuid":"\(UUID().uuidString)","bodyB64":"AAAA","kind":1,"modifiedMs":123.0,
             "baseRevision":1,"winnerCandidateId":"\(String(repeating: "e", count: 32))",
             "winnerKind":1,"winnerOp":"upsert","resolutionType":"candidate"}]}
            """)
        }

        do {
            _ = try await makeClient().getChanges(token: "t", vaultId: "vv", since: 7)
            XCTFail("A resolved row without its revision must be rejected")
        } catch let error as RowSyncSafetyError {
            XCTAssertEqual(error, .invalidResponse)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
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
            (409, "conflict_candidates_retained", .conflictCandidatesRetained),
            (409, "conflict_stale", .conflictStale),
            (409, "conflict_candidates_changed", .conflictCandidatesChanged),
            (409, "conflict_resolved", .conflictResolved),
            (409, "conflict_attachments_pending", .conflictAttachmentsPending),
            (426, "client_upgrade_required", .clientUpgradeRequired),
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

/// RowSync 引擎：CAS、原子拉取、分歧保护、删除与改密信号。
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

    private func bodyData(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { buffer.deallocate() }
        var data = Data()
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: 4096)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data.isEmpty ? nil : data
    }

    private func emptyChanges(headSeq: Int, request: URLRequest) -> (HTTPURLResponse, Data) {
        respond("{\"headSeq\":\(headSeq),\"changes\":[]}", request: request)
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

    private func markSynced(_ item: DatabaseItem, revision: UInt64,
                           state: inout RowSyncState) throws {
        state.revisions[item.uuid] = revision
        state.syncedMtimes[item.uuid] = item.modifiedMs
        state.encryptedItemBaselines[item.uuid] = try RowSyncCipher.encryptBaseline(item, key: key)
    }

    func testRekeyRewrapsEveryRetainedAttachmentVersionBeforeCommit() async throws {
        let oldKey = key
        let newKey = RowSyncKey(raw: Data(repeating: 92, count: 32))
        let attachmentID = UUID()
        let cardID = UUID()
        let versions = [UUID(), UUID()]
        let plaintexts = [Data("older retained bytes".utf8), Data("current bytes".utf8)]
        let encrypted = try zip(versions, plaintexts).map { version, plaintext in
            try AttachmentSyncCipher.encrypt(
                data: plaintext, key: oldKey,
                attachmentID: attachmentID, contentVersion: version)
        }
        var seenVersions = Set<UUID>()
        MockURLProtocol.handler = { request in
            switch request.url?.path {
            case "/v1/vaults/v1/attachment-versions":
                let entries = zip(versions, encrypted).map { version, item in
                    """
                    {"attachmentId":"\(attachmentID)","cardUuid":"\(cardID)",
                    "contentVersion":"\(version)","dekWrapped":"\(item.dekWrapped.base64EncodedString())",
                    "sha256":"\(SyncConflict.sha256Hex(item.cipher))",
                    "bytes":\(item.cipher.count),"isCurrent":\(version == versions[1])}
                    """
                }.joined(separator: ",")
                return self.respond(
                    "{\"versions\":[\(entries)],\"nextOffset\":2,\"hasMore\":false}",
                    request: request)
            case "/v1/vaults/v1/rekey/begin":
                let payload = try XCTUnwrap(JSONSerialization.jsonObject(
                    with: try XCTUnwrap(self.bodyData(request))) as? [String: Any])
                XCTAssertEqual(payload["dekCount"] as? Int, versions.count)
                return self.respond(#"{"rekeyId":"0123456789abcdef0123456789abcdef","passwordVersion":2,"conflictCount":0}"#, request: request)
            case "/v1/vaults/v1/rekey/0123456789abcdef0123456789abcdef/chunk":
                let payload = try XCTUnwrap(JSONSerialization.jsonObject(
                    with: try XCTUnwrap(self.bodyData(request))) as? [String: Any])
                let dekWraps = try XCTUnwrap(payload["dekWraps"] as? [[String: String]])
                for dekWrap in dekWraps {
                    let versionText = try XCTUnwrap(dekWrap["contentVersion"])
                    let version = try XCTUnwrap(UUID(uuidString: versionText))
                    let index = try XCTUnwrap(versions.firstIndex(of: version))
                    XCTAssertEqual(dekWrap["uuid"]?.lowercased(), attachmentID.uuidString.lowercased())
                    let encodedWrapper = try XCTUnwrap(dekWrap["dekB64"])
                    let rewrapped = try XCTUnwrap(Data(base64Encoded: encodedWrapper))
                    XCTAssertEqual(try AttachmentSyncCipher.decrypt(
                        cipher: encrypted[index].cipher, dekWrapped: rewrapped, key: newKey,
                        attachmentID: attachmentID, contentVersion: version), plaintexts[index])
                    XCTAssertThrowsError(try AttachmentSyncCipher.decrypt(
                        cipher: encrypted[index].cipher, dekWrapped: rewrapped, key: oldKey,
                        attachmentID: attachmentID, contentVersion: version))
                    seenVersions.insert(version)
                }
                return self.respond("{}", request: request)
            case "/v1/vaults/v1/rekey/0123456789abcdef0123456789abcdef/commit":
                XCTAssertEqual(seenVersions, Set(versions))
                return self.respond("{}", request: request)
            default:
                XCTFail("Unexpected rekey endpoint \(request.url?.path ?? "")")
                return self.respond("{}", request: request)
            }
        }
        let (database, _, _) = sampleDatabase()
        var state = RowSyncState()

        try await RowSync.rekey(
            client: makeClient(), token: "t", vaultId: "v1", database: database,
            oldKey: oldKey, newKey: newKey,
            newEnvelope: Data("envelope".utf8), state: &state)

        XCTAssertEqual(seenVersions, Set(versions))
    }

    func testRekeyReencryptsAndRemapsConflictCandidateIdentity() async throws {
        let oldKey = key
        let newKey = RowSyncKey(raw: Data(repeating: 73, count: 32))
        let (database, card, _) = sampleDatabase()
        let conflictID = String(repeating: "a", count: 32)
        let deletedUUID = UUID()
        let deleteConflictID = String(repeating: "b", count: 32)
        let plaintext = Data("retained conflict candidate".utf8)
        let oldCiphertext = try RowSyncCipher.encrypt(plaintext, key: oldKey, uuid: card.id)
        let oldIdentity = RowSyncCipher.conflictCandidateIdentity(
            plaintext: plaintext, key: oldKey, uuid: card.id,
            baseRevision: 3, kind: 1, isDelete: false)
        let newIdentity = RowSyncCipher.conflictCandidateIdentity(
            plaintext: plaintext, key: newKey, uuid: card.id,
            baseRevision: 3, kind: 1, isDelete: false)
        let oldDeleteIdentity = RowSyncCipher.conflictCandidateIdentity(
            plaintext: Data(), key: oldKey, uuid: deletedUUID,
            baseRevision: 4, kind: 1, isDelete: true)
        let newDeleteIdentity = RowSyncCipher.conflictCandidateIdentity(
            plaintext: Data(), key: newKey, uuid: deletedUUID,
            baseRevision: 4, kind: 1, isDelete: true)
        let deletedAt: TimeInterval = 1234
        var stagedCandidate = false
        MockURLProtocol.handler = { request in
            switch request.url?.path {
            case "/v1/vaults/v1/attachment-versions":
                return self.respond(
                    #"{"versions":[],"nextOffset":0,"hasMore":false}"#,
                    request: request)
            case "/v1/vaults/v1/rekey/begin":
                return self.respond(
                    #"{"rekeyId":"0123456789abcdef0123456789abcdef","passwordVersion":2,"conflictCount":2}"#,
                    request: request)
            case "/v1/vaults/v1/rekey/0123456789abcdef0123456789abcdef/chunk":
                return self.respond("{}", request: request)
            case "/v1/vaults/v1/rekey/0123456789abcdef0123456789abcdef/conflicts":
                if request.httpMethod == "GET" {
                    let candidate = """
                    {"conflictId":"\(conflictID)","itemUuid":"\(card.id.uuidString)",
                    "candidateId":"\(oldIdentity.candidateID)","kind":1,"op":"upsert",
                    "revision":3,"bodyB64":"\(oldCiphertext.base64EncodedString())",
                    "sha256":"\(SyncConflict.sha256Hex(oldCiphertext))"}
                    """
                    let deleteCandidate = """
                    {"conflictId":"\(deleteConflictID)","itemUuid":"\(deletedUUID.uuidString)",
                    "candidateId":"\(oldDeleteIdentity.candidateID)","kind":1,"op":"delete",
                    "revision":4}
                    """
                    return self.respond(
                        "{\"totalCandidates\":2,\"offset\":0,\"candidates\":[\(candidate),\(deleteCandidate)]}",
                        request: request)
                }
                let payload = try XCTUnwrap(JSONSerialization.jsonObject(
                    with: try XCTUnwrap(self.bodyData(request))) as? [String: Any])
                let candidates = try XCTUnwrap(payload["candidates"] as? [[String: String]])
                let candidate = try XCTUnwrap(candidates.first {
                    $0["conflictId"] == conflictID
                })
                XCTAssertEqual(candidate["conflictId"], conflictID)
                XCTAssertEqual(candidate["oldCandidateId"], oldIdentity.candidateID)
                XCTAssertEqual(candidate["candidateId"], newIdentity.candidateID)
                XCTAssertEqual(candidate["fingerprint"], newIdentity.fingerprint)
                let newCiphertext = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(candidate["bodyB64"])))
                XCTAssertEqual(
                    RowSyncCipher.decrypt(newCiphertext, key: newKey, uuid: card.id), plaintext)
                XCTAssertNil(RowSyncCipher.decrypt(newCiphertext, key: oldKey, uuid: card.id))
                XCTAssertEqual(candidate["sha256"], SyncConflict.sha256Hex(newCiphertext))
                let deleteCandidate = try XCTUnwrap(candidates.first {
                    $0["conflictId"] == deleteConflictID
                })
                XCTAssertEqual(deleteCandidate["oldCandidateId"], oldDeleteIdentity.candidateID)
                XCTAssertEqual(deleteCandidate["candidateId"], newDeleteIdentity.candidateID)
                XCTAssertEqual(deleteCandidate["fingerprint"], newDeleteIdentity.fingerprint)
                XCTAssertNil(deleteCandidate["bodyB64"])
                XCTAssertNil(deleteCandidate["sha256"])
                stagedCandidate = true
                return self.respond(#"{"candidateStaged":1}"#, request: request)
            case "/v1/vaults/v1/rekey/0123456789abcdef0123456789abcdef/commit":
                XCTAssertTrue(stagedCandidate)
                return self.respond("{}", request: request)
            default:
                XCTFail("Unexpected rekey endpoint \(request.url?.path ?? "")")
                return self.respond("{}", request: request)
            }
        }
        var state = RowSyncState()
        state.pendingConflicts[card.id] = RowSyncPendingConflict(
            conflictID: conflictID,
            candidateID: oldIdentity.candidateID,
            fingerprint: oldIdentity.fingerprint,
            baseRevision: 3,
            kind: 1,
            isDelete: false)
        state.pendingConflicts[deletedUUID] = RowSyncPendingConflict(
            conflictID: deleteConflictID,
            candidateID: oldDeleteIdentity.candidateID,
            fingerprint: oldDeleteIdentity.fingerprint,
            baseRevision: 4,
            kind: 1,
            isDelete: true)
        state.markDeleted(uuid: deletedUUID, at: deletedAt)

        try await RowSync.rekey(
            client: makeClient(), token: "t", vaultId: "v1", database: database,
            oldKey: oldKey, newKey: newKey,
            newEnvelope: Data("envelope".utf8), state: &state)

        XCTAssertTrue(stagedCandidate)
        XCTAssertEqual(state.pendingConflicts[card.id]?.candidateID, newIdentity.candidateID)
        XCTAssertEqual(state.pendingConflicts[card.id]?.fingerprint, newIdentity.fingerprint)
        XCTAssertEqual(state.pendingConflicts[deletedUUID]?.candidateID, newDeleteIdentity.candidateID)
        XCTAssertEqual(state.pendingConflicts[deletedUUID]?.fingerprint, newDeleteIdentity.fingerprint)
        XCTAssertEqual(state.dirtyDeletes[deletedUUID], deletedAt)
    }

    func testAdoptRemoteRekeyRetainsOpenDeleteCandidate() async throws {
        let oldKey = key
        let newKey = RowSyncKey(raw: Data(repeating: 74, count: 32))
        let itemID = UUID()
        let conflictID = String(repeating: "c", count: 32)
        let oldIdentity = RowSyncCipher.conflictCandidateIdentity(
            plaintext: Data(), key: oldKey, uuid: itemID,
            baseRevision: 1, kind: 1, isDelete: true)
        let newIdentity = RowSyncCipher.conflictCandidateIdentity(
            plaintext: Data(), key: newKey, uuid: itemID,
            baseRevision: 1, kind: 1, isDelete: true)
        let deletedAt: TimeInterval = 2345
        let remoteCard = Card(id: itemID, title: "Remote version")
        let remoteCipher = try RowSyncCipher.encrypt(
            DatabaseItemCodec.xmlData(.card(remoteCard)), key: newKey, uuid: itemID)
        let competingCipher = try RowSyncCipher.encrypt(
            Data("competing candidate".utf8), key: newKey, uuid: itemID)

        MockURLProtocol.handler = { request in
            switch request.url?.path {
            case "/v1/vaults/v1/seq":
                return self.respond(#"{"headSeq":10,"passwordVersion":2}"#, request: request)
            case "/v1/vaults/v1/items":
                return self.respond("""
                {"headSeq":10,"items":[{"uuid":"\(itemID.uuidString)","kind":1,
                "revision":2,"bodyB64":"\(remoteCipher.base64EncodedString())",
                "modifiedMs":1000}],"nextCursor":null}
                """, request: request)
            case "/v1/vaults/v1/changes":
                return self.respond(#"{"headSeq":10,"changes":[]}"#, request: request)
            case "/v1/vaults/v1/conflicts":
                return self.respond("""
                {"conflicts":[{"conflictId":"\(conflictID)",
                "itemUuid":"\(itemID.uuidString)","baseRevision":1,"currentRevision":2,
                "currentDeletedSeq":0,"generation":1,"createdMs":1000,"updatedMs":2000,
                "candidates":[
                  {"candidateId":"\(newIdentity.candidateID)","kind":1,"op":"delete",
                   "revision":1,"modifiedMs":1000,"committedMs":1100,
                   "deviceName":"Mac","platform":"macos"},
                  {"candidateId":"\(String(repeating: "d", count: 32))","kind":1,
                   "op":"upsert","revision":2,"modifiedMs":1200,"committedMs":1300,
                   "deviceName":"iPhone","platform":"ios",
                   "bodyB64":"\(competingCipher.base64EncodedString())",
                   "sha256":"\(SyncConflict.sha256Hex(competingCipher))"}]}]}
                """, request: request)
            default:
                XCTFail("Unexpected rekey adoption endpoint \(request.url?.path ?? "")")
                return self.respond("{}", request: request)
            }
        }

        var state = RowSyncState()
        state.pendingConflicts[itemID] = RowSyncPendingConflict(
            conflictID: conflictID,
            candidateID: oldIdentity.candidateID,
            fingerprint: oldIdentity.fingerprint,
            baseRevision: 1,
            kind: 1,
            isDelete: true)
        state.markDeleted(uuid: itemID, at: deletedAt)

        let adopted = try await RowSync.adoptRemoteRekey(
            client: makeClient(), token: "t", vaultId: "v1",
            oldKey: oldKey, newKey: newKey,
            localDatabase: PasswordDatabase(), state: state)

        XCTAssertNil(adopted.database.card(id: itemID))
        XCTAssertEqual(adopted.state.pendingConflicts[itemID]?.candidateID, newIdentity.candidateID)
        XCTAssertEqual(adopted.state.pendingConflicts[itemID]?.fingerprint, newIdentity.fingerprint)
        XCTAssertEqual(adopted.state.dirtyDeletes[itemID], deletedAt)
    }

    func testAdoptRemoteRekeyVerifiesResolvedRetainedCandidate() async throws {
        let oldKey = key
        let newKey = RowSyncKey(raw: Data(repeating: 75, count: 32))
        let (localDatabase, localCard, _) = sampleDatabase()
        let conflictID = String(repeating: "e", count: 32)
        let oldIdentity = RowSyncCipher.conflictCandidateIdentity(
            plaintext: DatabaseItemCodec.xmlData(.card(localCard)), key: oldKey,
            uuid: localCard.id, baseRevision: 1, kind: 1, isDelete: false)
        let newIdentity = RowSyncCipher.conflictCandidateIdentity(
            plaintext: DatabaseItemCodec.xmlData(.card(localCard)), key: newKey,
            uuid: localCard.id, baseRevision: 1, kind: 1, isDelete: false)
        var winnerCard = localCard
        winnerCard.title = "Resolved remote winner"
        let winnerCipher = try RowSyncCipher.encrypt(
            DatabaseItemCodec.xmlData(.card(winnerCard)), key: newKey, uuid: localCard.id)
        let retainedCipher = try RowSyncCipher.encrypt(
            DatabaseItemCodec.xmlData(.card(localCard)), key: newKey, uuid: localCard.id)
        let winnerCandidateID = String(repeating: "f", count: 32)

        MockURLProtocol.handler = { request in
            switch request.url?.path {
            case "/v1/vaults/v1/seq":
                return self.respond(#"{"headSeq":12,"passwordVersion":2}"#, request: request)
            case "/v1/vaults/v1/items":
                return self.respond("""
                {"headSeq":12,"items":[{"uuid":"\(localCard.id.uuidString)","kind":1,
                "revision":2,"bodyB64":"\(winnerCipher.base64EncodedString())",
                "modifiedMs":1500}],"nextCursor":null}
                """, request: request)
            case "/v1/vaults/v1/changes":
                return self.respond(#"{"headSeq":12,"changes":[]}"#, request: request)
            case "/v1/vaults/v1/conflicts":
                return self.respond(#"{"conflicts":[]}"#, request: request)
            case "/v1/vaults/v1/conflict-history":
                return self.respond("""
                {"snapshotMs":5000000,"totalCandidates":1,"nextCursor":null,
                "candidates":[{"conflictId":"\(conflictID)",
                "itemUuid":"\(localCard.id.uuidString)","baseRevision":1,
                "currentRevision":2,"currentDeletedSeq":0,"generation":1,
                "createdMs":1000,"updatedMs":2000,"resolvedMs":4000000,
                "expiresMs":6000000,"selectedCandidateId":"\(winnerCandidateID)",
                "candidate":{"candidateId":"\(newIdentity.candidateID)","kind":1,
                "op":"upsert","revision":1,"modifiedMs":1000,"committedMs":1100,
                "deviceName":"Mac","platform":"macos",
                "bodyB64":"\(retainedCipher.base64EncodedString())",
                "sha256":"\(SyncConflict.sha256Hex(retainedCipher))"}}]}
                """, request: request)
            default:
                XCTFail("Unexpected rekey adoption endpoint \(request.url?.path ?? "")")
                return self.respond("{}", request: request)
            }
        }

        var state = RowSyncState()
        state.pendingConflicts[localCard.id] = RowSyncPendingConflict(
            conflictID: conflictID,
            candidateID: oldIdentity.candidateID,
            fingerprint: oldIdentity.fingerprint,
            baseRevision: 1,
            kind: 1,
            isDelete: false)
        let localLabel = try XCTUnwrap(localDatabase.labels.first)
        try markSynced(.label(localLabel), revision: 1, state: &state)

        let adopted = try await RowSync.adoptRemoteRekey(
            client: makeClient(), token: "t", vaultId: "v1",
            oldKey: oldKey, newKey: newKey,
            localDatabase: localDatabase, state: state)

        XCTAssertEqual(adopted.database.card(id: localCard.id)?.title, winnerCard.title)
        XCTAssertNil(adopted.state.pendingConflicts[localCard.id])
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
        try markSynced(.card(card), revision: 3, state: &state) // 本端已知 rev 3(自己刚推上去的)
        let sealed = try sealedBody(.card(card))

        MockURLProtocol.handler = { [card, sealed] request in
            if request.url?.path.hasSuffix("/conflicts") == true {
                return self.respond("""
                {"conflictId":"\(String(repeating: "b", count: 32))","generation":1,
                 "candidateCount":2,"currentRevision":4}
                """, request: request)
            }
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
        try markSynced(.card(card), revision: 1, state: &state)

        MockURLProtocol.handler = { [card] request in
            let body = """
            {"headSeq":9,"changes":[{"seq":9,"uuid":"\(card.id.uuidString)","op":"purge","revision":2,"deleted":true}]}
            """
            return self.respond(body, request: request)
        }
        _ = try await RowSync.pull(client: makeClient(), token: "t", vaultId: "v1",
                                   key: key, database: &db, state: &state)
        XCTAssertNil(db.card(id: card.id))
        XCTAssertNil(state.dirtyUpserts[card.id])
        XCTAssertNil(state.revisions[card.id])
    }

    func testPullResolutionAppliesWinnerAndClearsMatchingConflictMarker() async throws {
        let base = Card(title: "Base")
        var local = base
        local.title = "Local candidate"
        let remote = Card(id: base.id, title: "Selected winner")
        let remoteBody = try sealedBody(.card(remote))
        let plaintext = DatabaseItemCodec.xmlData(.card(local))
        let identity = RowSyncCipher.conflictCandidateIdentity(
            plaintext: plaintext, key: key, uuid: base.id,
            baseRevision: 1, kind: 1, isDelete: false)
        let conflictID = String(repeating: "d", count: 32)
        var database = PasswordDatabase()
        database.cards = [local]
        var state = RowSyncState()
        state.cursor = 1
        try markSynced(.card(base), revision: 1, state: &state)
        state.markDirty(uuid: local.id, modifiedMs: local.modified)
        state.pendingConflicts[local.id] = RowSyncPendingConflict(
            conflictID: conflictID,
            candidateID: identity.candidateID,
            fingerprint: identity.fingerprint,
            baseRevision: 1,
            kind: 1,
            isDelete: false)

        MockURLProtocol.handler = { request in
            let intermediateBody = try self.sealedBody(.card(Card(id: base.id, title: "Other peer edit")))
            return self.respond("""
            {"headSeq":3,"changes":[
            {"seq":2,"uuid":"\(base.id.uuidString)","op":"upsert","revision":2,
             "bodyB64":"\(intermediateBody)","kind":1,"modifiedMs":\(remote.modified - 1)},
            {"seq":3,"uuid":"\(base.id.uuidString)","op":"resolve","revision":3,
             "conflictId":"\(conflictID)","resolvedItemUuid":"\(base.id.uuidString)",
             "resolvedRevision":3,"baseRevision":1,"winnerCandidateId":"\(identity.candidateID)",
             "winnerKind":1,"winnerOp":"upsert","resolutionType":"candidate",
             "bodyB64":"\(remoteBody)","kind":1,
             "modifiedMs":\(remote.modified)}]}
            """, request: request)
        }

        _ = try await RowSync.pull(client: makeClient(), token: "t", vaultId: "v1",
                                   key: key, database: &database, state: &state)

        XCTAssertEqual(state.cursor, 3)
        XCTAssertEqual(database.card(id: base.id)?.title, "Selected winner")
        XCTAssertNil(state.pendingConflicts[base.id])
        XCTAssertEqual(state.revisions[base.id], 3)
        XCTAssertNil(state.dirtyUpserts[base.id])
    }

    func testPullResolutionRestoresDeletedWinnerWithNewIdentity() async throws {
        let original = Card(title: "Retained candidate")
        let restored = Card(title: "Retained candidate")
        let restoredBody = try sealedBody(.card(restored))
        let plaintext = DatabaseItemCodec.xmlData(.card(original))
        let identity = RowSyncCipher.conflictCandidateIdentity(
            plaintext: plaintext, key: key, uuid: original.id,
            baseRevision: 1, kind: 1, isDelete: false)
        let conflictID = String(repeating: "e", count: 32)
        var database = PasswordDatabase()
        database.cards = [original]
        var state = RowSyncState()
        state.cursor = 2
        try markSynced(.card(Card(id: original.id, title: "Before conflict")), revision: 1, state: &state)
        state.dirtyUpserts[original.id] = original.modified
        var unexpectedCandidateRegistration = false

        MockURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/conflicts") == true {
                unexpectedCandidateRegistration = true
                return self.respond("{}", request: request)
            }
            return self.respond("""
            {"headSeq":3,"changes":[{"seq":3,"uuid":"\(original.id.uuidString)","op":"resolve",
             "revision":2,"conflictId":"\(conflictID)","resolvedItemUuid":"\(restored.id.uuidString)",
             "resolvedRevision":1,"baseRevision":1,"winnerCandidateId":"\(identity.candidateID)",
             "winnerKind":1,"winnerOp":"upsert","resolutionType":"candidate",
             "bodyB64":"\(restoredBody)","kind":1,
             "modifiedMs":\(restored.modified)}]}
            """, request: request)
        }

        _ = try await RowSync.pull(client: makeClient(), token: "t", vaultId: "v1",
                                   key: key, database: &database, state: &state)

        XCTAssertNil(database.card(id: original.id))
        XCTAssertEqual(database.card(id: restored.id)?.title, "Retained candidate")
        XCTAssertNil(state.pendingConflicts[original.id])
        XCTAssertNil(state.revisions[original.id])
        XCTAssertEqual(state.revisions[restored.id], 1)
        XCTAssertFalse(unexpectedCandidateRegistration)
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

    func testPushNotFoundProtectsLocalItem() async throws {
        var (db, card, _) = sampleDatabase()
        var state = RowSyncState()
        state.markDirty(uuid: card.id, modifiedMs: 1000)

        var candidateRegistered = false
        MockURLProtocol.handler = { [card] request in
            if request.url?.path.hasSuffix("/conflicts") == true {
                let body = try XCTUnwrap(self.bodyData(request))
                let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
                XCTAssertEqual(payload["expectedDeletedSeq"] as? Int, 5)
                XCTAssertEqual(payload["expectedRevision"] as? Int, 2)
                candidateRegistered = true
                return self.respond("""
                {"conflictId":"\(String(repeating: "d", count: 32))","generation":1,
                 "candidateCount":2,"currentRevision":2}
                """, request: request)
            }
            let body = """
            {"results":[{"uuid":"\(card.id.uuidString)","status":"not_found",
             "deletedAt":123.0,"deletedRevision":2,"seq":5}]}
            """
            return self.respond(body, request: request)
        }
        do {
            _ = try await RowSync.push(client: makeClient(), token: "t", vaultId: "v1",
                                      key: key, database: &db, state: &state)
            XCTFail("Deletion conflict must retain local changes")
        } catch let error as RowSyncSafetyError {
            XCTAssertEqual(error, .remoteDeletionNeedsRecovery)
        }
        XCTAssertTrue(candidateRegistered)
        XCTAssertEqual(db.card(id: card.id)?.title, card.title)
        XCTAssertTrue(state.hasPendingWork)
    }

    func testPushConflictPreservesBothSidesRegardlessOfTime() async throws {
        var (db, card, _) = sampleDatabase()
        var state = RowSyncState()
        state.markDirty(uuid: card.id, modifiedMs: 1000) // 本地 modified=1000

        var remote = card
        remote.title = "Peer Wins"
        remote.modified = 9000 // 对端更新 → 采纳
        let sealed = try sealedBody(.card(remote))

        var candidateRegistered = false
        MockURLProtocol.handler = { [card, sealed] request in
            if request.url?.path.hasSuffix("/conflicts") == true {
                candidateRegistered = true
                return self.respond("""
                {"conflictId":"\(String(repeating: "b", count: 32))","generation":1,
                 "candidateCount":2,"currentRevision":4}
                """, request: request)
            }
            let body = """
            {"results":[{"uuid":"\(card.id.uuidString)","status":"conflict",
             "current":{"revision":4,"bodyB64":"\(sealed)"}}]}
            """
            return self.respond(body, request: request)
        }
        do {
            _ = try await RowSync.push(client: makeClient(), token: "t", vaultId: "v1",
                                      key: key, database: &db, state: &state)
            XCTFail("Concurrent values require user resolution")
        } catch let error as RowSyncSafetyError {
            XCTAssertEqual(error, .conflictNeedsResolution)
        }
        XCTAssertEqual(db.card(id: card.id)?.title, card.title)
        XCTAssertNotNil(state.dirtyUpserts[card.id])
        XCTAssertNil(state.revisions[card.id])
        XCTAssertTrue(candidateRegistered)
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

    func testEncryptedBaselineUsesSeparateAuthenticatedDomainAndOmitsAttachmentBytes() throws {
        var card = Card(title: "Baseline")
        let attachmentBytes = Data("private attachment bytes".utf8)
        card.images = [Attachment(name: "private-image.png", data: attachmentBytes)]
        let encrypted = try RowSyncCipher.encryptBaseline(.card(card), key: key)

        XCTAssertNil(encrypted.range(of: attachmentBytes))
        XCTAssertNil(encrypted.range(of: Data("private-image.png".utf8)))
        XCTAssertNil(RowSyncCipher.decrypt(encrypted, key: key, uuid: card.id))
        XCTAssertNil(RowSyncCipher.decryptBaseline(encrypted, key: key, uuid: UUID()))

        var tampered = encrypted
        tampered[tampered.index(before: tampered.endIndex)] ^= 1
        XCTAssertNil(RowSyncCipher.decryptBaseline(tampered, key: key, uuid: card.id))

        let baseline = try XCTUnwrap(RowSyncCipher.decryptBaseline(encrypted, key: key, uuid: card.id))
        XCTAssertTrue(baseline.matches(.card(card)))
    }

    func testRekeySeedsBaselinesWithNewKeyAfterRemoteCommit() async throws {
        var (database, card, label) = sampleDatabase()
        var profile = UserProfile()
        profile.fields = [Field(name: "Email", type: .email, value: "profile@example.test")]
        database.userProfiles = [profile]
        let newKey = RowSyncKey(raw: Data(repeating: 91, count: 32))
        var state = RowSyncState()
        state.cursor = 12
        state.markDirty(uuid: card.id, modifiedMs: card.modified)
        state.markDeleted(uuid: UUID(), at: 100)
        let quarantinedEntry = RelayClient.ChangeEntry(
            seq: 8, uuid: UUID(), op: "upsert", revision: 2, deleted: false,
            bodyB64: "damaged", kind: 1, modifiedMs: 100)
        let quarantined = try RowSyncCipher.quarantine(
            quarantinedEntry, reason: .authenticationFailed, key: key)
        state.quarantinedItems[quarantined.id] = quarantined
        let items = RowSync.allItems(database: database)

        MockURLProtocol.handler = { request in
            switch request.url?.path {
            case "/v1/vaults/v1/attachment-versions":
                return self.respond(
                    #"{"versions":[],"nextOffset":0,"hasMore":false}"#,
                    request: request)
            case "/v1/vaults/v1/rekey/begin":
                return self.respond(#"{"rekeyId":"0123456789abcdef0123456789abcdef","passwordVersion":2,"conflictCount":0}"#, request: request)
            case "/v1/vaults/v1/rekey/0123456789abcdef0123456789abcdef/chunk":
                return self.respond("{}", request: request)
            case "/v1/vaults/v1/rekey/0123456789abcdef0123456789abcdef/commit":
                return self.respond("{}", request: request)
            default:
                XCTFail("Unexpected rekey endpoint \(request.url?.path ?? "")")
                return self.respond("{}", request: request)
            }
        }

        try await RowSync.rekey(
            client: makeClient(), token: "t", vaultId: "v1", database: database,
            oldKey: key, newKey: newKey, newEnvelope: Data("envelope".utf8), state: &state)

        XCTAssertEqual(state.cursor, 0)
        XCTAssertTrue(state.revisions.isEmpty)
        XCTAssertFalse(state.hasPendingWork)
        XCTAssertEqual(Set(state.encryptedItemBaselines.keys), Set(items.map(\.uuid)))
        for item in items {
            let encrypted = try XCTUnwrap(state.encryptedItemBaselines[item.uuid])
            let baseline = try XCTUnwrap(
                RowSyncCipher.decryptBaseline(encrypted, key: newKey, uuid: item.uuid))
            XCTAssertTrue(baseline.matches(item))
            XCTAssertNil(RowSyncCipher.decryptBaseline(encrypted, key: key, uuid: item.uuid))
        }
        XCTAssertEqual(items.count, 3, "card, label, and profile baselines must be seeded")
        XCTAssertNotEqual(label.id, profile.id)
        let rekeyedQuarantine = try XCTUnwrap(state.quarantinedItems[quarantined.id])
        guard case .change(let preservedEntry) = try RowSyncCipher.openQuarantine(
            rekeyedQuarantine, key: newKey) else {
            return XCTFail("Expected retained change payload")
        }
        XCTAssertEqual(preservedEntry.bodyB64, "damaged")
        XCTAssertThrowsError(try RowSyncCipher.openQuarantine(rekeyedQuarantine, key: key))
    }

    func testRekeyFailureDoesNotPublishProposedBaselineState() async throws {
        let (database, card, _) = sampleDatabase()
        let newKey = RowSyncKey(raw: Data(repeating: 91, count: 32))
        var state = RowSyncState()
        state.cursor = 12
        state.markDirty(uuid: card.id, modifiedMs: card.modified)
        let before = state

        MockURLProtocol.handler = { request in
            if request.url?.path == "/v1/vaults/v1/attachment-versions" {
                return self.respond(
                    #"{"versions":[],"nextOffset":0,"hasMore":false}"#,
                    request: request)
            }
            if request.url?.path.hasSuffix("/rekey/begin") == true {
                return self.respond(#"{"rekeyId":"0123456789abcdef0123456789abcdef","passwordVersion":2,"conflictCount":0}"#, request: request)
            }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"error":"server_error"}"#.utf8))
        }

        do {
            try await RowSync.rekey(
                client: makeClient(), token: "t", vaultId: "v1", database: database,
                oldKey: key, newKey: newKey, newEnvelope: Data("envelope".utf8), state: &state)
            XCTFail("A failed rekey chunk must not publish the proposed state")
        } catch {
            XCTAssertEqual(state, before)
        }
    }

    func testPullIsolatesUnreadableEntryAndStopsAtAtomicCheckpoint() async throws {
        var (database, card, _) = sampleDatabase()
        var state = RowSyncState()
        state.cursor = 3
        try markSynced(.card(card), revision: 1, state: &state)
        var remote = card
        remote.title = "Must not partially commit"
        remote.modified = 5000
        let good = try sealedBody(.card(remote))
        let badID = UUID()
        MockURLProtocol.handler = { request in
            return self.respond("""
            {"headSeq":5,"changes":[
            {"seq":4,"uuid":"\(card.id)","op":"upsert","revision":2,"kind":1,"bodyB64":"\(good)"},
            {"seq":5,"uuid":"\(badID)","op":"upsert","revision":1,"kind":1,"bodyB64":"AAAA"}]}
            """, request: request)
        }
        let outcome = try await RowSync.pull(
            client: makeClient(), token: "t", vaultId: "v1",
            key: key, database: &database, state: &state)

        XCTAssertEqual(database.card(id: card.id)?.title, remote.title)
        XCTAssertEqual(state.cursor, 5)
        XCTAssertTrue(state.needsSyncContinuation)
        XCTAssertEqual(outcome.quarantinedItems, 1)
        XCTAssertTrue(outcome.requiresFollowUpSync)
        let isolated = try XCTUnwrap(state.quarantinedItems["change:5"])
        XCTAssertEqual(isolated.uuid, badID)
        XCTAssertEqual(isolated.reason, .authenticationFailed)
        guard case .change(let original) = try RowSyncCipher.openQuarantine(isolated, key: key) else {
            return XCTFail("Expected the original change payload")
        }
        XCTAssertEqual(original.bodyB64, "AAAA")
        XCTAssertEqual(original.seq, 5)
    }

    func testRetryQuarantinedChangeAppliesAfterTheDecoderCanReadIt() async throws {
        var remote = Card(title: "Recovered cloud row")
        remote.modified = 5000
        let body = try sealedBody(.card(remote))
        let entry = RelayClient.ChangeEntry(
            seq: 5, uuid: remote.id, op: "upsert", revision: 2, deleted: false,
            bodyB64: body, kind: 1, modifiedMs: remote.modified)
        let quarantined = try RowSyncCipher.quarantine(
            entry, reason: .unsupportedFormat, key: key)
        var state = RowSyncState()
        state.cursor = 5
        state.quarantinedItems[quarantined.id] = quarantined
        var database = PasswordDatabase()
        MockURLProtocol.handler = { request in
            XCTFail("Retrying a retained payload must not require another network request")
            return self.respond("{}", request: request)
        }

        let recovered = try await RowSync.retryQuarantinedItems(
            client: makeClient(), token: "t", vaultId: "v1", key: key,
            database: &database, state: &state)

        XCTAssertEqual(recovered, 1)
        XCTAssertEqual(database.card(id: remote.id)?.title, remote.title)
        XCTAssertTrue(state.quarantinedItems.isEmpty)
        XCTAssertEqual(state.revisions[remote.id], 2)
    }

    func testPullDeletionProtectsLocalPendingContent() async throws {
        var (database, card, _) = sampleDatabase()
        var state = RowSyncState()
        try markSynced(.card(card), revision: 1, state: &state)
        state.markDirty(uuid: card.id, modifiedMs: card.modified)
        let before = state
        var candidateRegistered = false
        MockURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/conflicts") == true {
                let body = try XCTUnwrap(self.bodyData(request))
                let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
                XCTAssertEqual(payload["expectedDeletedSeq"] as? Int, 2)
                XCTAssertEqual(payload["expectedRevision"] as? Int, 2)
                candidateRegistered = true
                return self.respond("""
                {"conflictId":"\(String(repeating: "d", count: 32))","generation":1,
                 "candidateCount":2,"currentRevision":2}
                """, request: request)
            }
            return self.respond("""
            {"headSeq":2,"changes":[{"seq":2,"uuid":"\(card.id)",
            "op":"purge","revision":2,"deleted":true}]}
            """, request: request)
        }
        do {
            _ = try await RowSync.pull(client: makeClient(), token: "t", vaultId: "v1",
                                      key: key, database: &database, state: &state)
            XCTFail("Pending deletion conflict must not be discarded")
        } catch let error as RowSyncSafetyError {
            XCTAssertEqual(error, .remoteDeletionNeedsRecovery)
        }
        XCTAssertEqual(database.card(id: card.id)?.title, card.title)
        XCTAssertEqual(state.cursor, before.cursor)
        XCTAssertEqual(state.revisions, before.revisions)
        XCTAssertEqual(state.dirtyUpserts, before.dirtyUpserts)
        XCTAssertEqual(state.pendingConflicts[card.id]?.conflictID, String(repeating: "d", count: 32))
        XCTAssertTrue(candidateRegistered)
    }

    func testPullDeletionDetectsChangedContentEvenWithoutDirtyMarker() async throws {
        var (database, base, _) = sampleDatabase()
        var local = base
        local.title = "Unmarked local edit"
        database.cards = [local]
        var state = RowSyncState()
        try markSynced(.card(base), revision: 1, state: &state)
        let before = state
        var candidateRegistered = false
        MockURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/conflicts") == true {
                let body = try XCTUnwrap(self.bodyData(request))
                let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
                XCTAssertEqual(payload["expectedDeletedSeq"] as? Int, 2)
                XCTAssertEqual(payload["expectedRevision"] as? Int, 2)
                candidateRegistered = true
                return self.respond("""
                {"conflictId":"\(String(repeating: "e", count: 32))","generation":1,
                 "candidateCount":2,"currentRevision":2}
                """, request: request)
            }
            return self.respond("""
            {"headSeq":2,"changes":[{"seq":2,"uuid":"\(base.id)",
            "op":"purge","revision":2,"deleted":true}]}
            """, request: request)
        }

        do {
            _ = try await RowSync.pull(client: makeClient(), token: "t", vaultId: "v1",
                                       key: key, database: &database, state: &state)
            XCTFail("A changed local row must survive a remote deletion even when unmarked")
        } catch let error as RowSyncSafetyError {
            XCTAssertEqual(error, .remoteDeletionNeedsRecovery)
        }

        XCTAssertEqual(database.card(id: base.id)?.title, "Unmarked local edit")
        XCTAssertEqual(state.cursor, before.cursor)
        XCTAssertEqual(state.revisions, before.revisions)
        XCTAssertEqual(state.dirtyUpserts, before.dirtyUpserts)
        XCTAssertEqual(state.pendingConflicts[base.id]?.conflictID, String(repeating: "e", count: 32))
        XCTAssertTrue(candidateRegistered)
    }

    func testPushMissingOperationResultPreservesAllPendingState() async throws {
        var (database, card, _) = sampleDatabase()
        var state = RowSyncState()
        state.markDirty(uuid: card.id, modifiedMs: card.modified)
        let before = state
        MockURLProtocol.handler = { request in
            self.respond(#"{"results":[]}"#, request: request)
        }
        do {
            _ = try await RowSync.push(client: makeClient(), token: "t", vaultId: "v1",
                                      key: key, database: &database, state: &state)
            XCTFail("Missing result must not be treated as deletion")
        } catch let error as RowSyncSafetyError {
            XCTAssertEqual(error, .invalidResponse)
        }
        XCTAssertEqual(database.card(id: card.id)?.title, card.title)
        XCTAssertEqual(state, before)
    }

    func testPullInvalidIdentityOrKindRejectsPageWithoutAdvancing() async throws {
        for (identity, kind) in [("invalid-uuid", 1), (UUID().uuidString, 256)] {
            var database = PasswordDatabase()
            var state = RowSyncState()
            MockURLProtocol.handler = { request in
                self.respond("""
                {"headSeq":1,"changes":[{"seq":1,"uuid":"\(identity)","op":"upsert",
                "revision":1,"kind":\(kind),"bodyB64":"AAAA"}]}
                """, request: request)
            }
            do {
                _ = try await RowSync.pull(client: makeClient(), token: "t", vaultId: "v1",
                                          key: key, database: &database, state: &state)
                XCTFail("Malformed response must reject the page")
            } catch let error as RowSyncSafetyError {
                XCTAssertEqual(error, .invalidResponse)
            }
            XCTAssertEqual(state.cursor, 0)
            XCTAssertTrue(database.cards.isEmpty)
        }
    }

    func testFullRebuildProtectsUnsubmittedLocalContentBeforeNetwork() async throws {
        let (database, card, _) = sampleDatabase()
        var state = RowSyncState()
        state.markDirty(uuid: card.id, modifiedMs: card.modified)
        let before = state
        MockURLProtocol.handler = { _ in
            XCTFail("Must reject unsafe rebuild before making a request")
            throw URLError(.cancelled)
        }
        do {
            _ = try await RowSync.fullRebuild(
                client: makeClient(), token: "t", vaultId: "v1", key: key,
                localDatabase: database, state: &state)
            XCTFail("Pending local data must be protected")
        } catch let error as RowSyncSafetyError {
            XCTAssertEqual(error, .localDataNeedsRecovery)
        }
        XCTAssertEqual(state, before)
    }

    func testFullRebuildMigratesMatchingLegacyBaselineWithoutMarkingEveryRowDirty() async throws {
        var database = PasswordDatabase()
        let card = Card(title: "Already synced")
        database.cards = [card]
        var state = RowSyncState()
        state.cursor = 1
        state.revisions[card.id] = 1
        state.syncedMtimes[card.id] = card.modified
        MockURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/changes") == true {
                return self.emptyChanges(headSeq: 2, request: request)
            }
            if request.url?.path.hasSuffix("/seq") == true {
                return self.respond(#"{"headSeq":2,"passwordVersion":1}"#, request: request)
            }
            let sealed = try self.sealedBody(.card(card))
            return self.respond("""
            {"items":[{"uuid":"\(card.id)","kind":1,"revision":1,
            "bodyB64":"\(sealed)","modifiedMs":\(card.modified)}],
            "nextCursor":null,"headSeq":2}
            """, request: request)
        }

        let rebuilt = try await RowSync.fullRebuild(
            client: makeClient(), token: "t", vaultId: "v1", key: key,
            localDatabase: database, state: &state)

        XCTAssertEqual(rebuilt.card(id: card.id)?.title, card.title)
        XCTAssertFalse(state.needsContentBaselineMigration)
        XCTAssertFalse(state.hasPendingWork)
        let baselineData = try XCTUnwrap(state.encryptedItemBaselines[card.id])
        let baseline = try XCTUnwrap(RowSyncCipher.decryptBaseline(baselineData, key: key, uuid: card.id))
        XCTAssertTrue(baseline.matches(.card(card)))
    }

    func testFullRebuildRejectsChangedLegacyRowAndPreservesState() async throws {
        let local = Card(title: "Local value")
        var remote = Card(id: local.id, title: "Remote value")
        remote.modified = local.modified
        var database = PasswordDatabase()
        database.cards = [local]
        var state = RowSyncState()
        state.cursor = 1
        state.revisions[local.id] = 1
        state.syncedMtimes[local.id] = local.modified
        let before = state
        let sealed = try sealedBody(.card(remote))
        MockURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/changes") == true {
                return self.emptyChanges(headSeq: 2, request: request)
            }
            if request.url?.path.hasSuffix("/seq") == true {
                return self.respond(#"{"headSeq":2,"passwordVersion":1}"#, request: request)
            }
            return self.respond("""
            {"items":[{"uuid":"\(remote.id)","kind":1,"revision":2,
            "bodyB64":"\(sealed)","modifiedMs":\(remote.modified)}],
            "nextCursor":null,"headSeq":2}
            """, request: request)
        }

        do {
            _ = try await RowSync.fullRebuild(
                client: makeClient(), token: "t", vaultId: "v1", key: key,
                localDatabase: database, state: &state)
            XCTFail("Legacy baseline mismatch must not overwrite local content")
        } catch let error as RowSyncSafetyError {
            XCTAssertEqual(error, .conflictNeedsResolution)
        }
        XCTAssertEqual(state, before)
        XCTAssertEqual(database.card(id: local.id)?.title, local.title)
    }

    func testFullRebuildPreservesLocalNewRowsAlongsideRemoteSnapshot() async throws {
        let local = Card(title: "New local row")
        let remote = Card(title: "Remote row")
        var database = PasswordDatabase()
        database.cards = [local]
        var state = RowSyncState()
        let sealed = try sealedBody(.card(remote))
        MockURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/changes") == true {
                return self.emptyChanges(headSeq: 2, request: request)
            }
            if request.url?.path.hasSuffix("/seq") == true {
                return self.respond(#"{"headSeq":2,"passwordVersion":1}"#, request: request)
            }
            return self.respond("""
            {"items":[{"uuid":"\(remote.id)","kind":1,"revision":1,
            "bodyB64":"\(sealed)","modifiedMs":\(remote.modified)}],
            "nextCursor":null,"headSeq":2}
            """, request: request)
        }

        let rebuilt = try await RowSync.fullRebuild(
            client: makeClient(), token: "t", vaultId: "v1", key: key,
            localDatabase: database, state: &state)

        XCTAssertEqual(rebuilt.card(id: local.id)?.title, local.title)
        XCTAssertEqual(rebuilt.card(id: remote.id)?.title, remote.title)
        XCTAssertEqual(state.dirtyUpserts[local.id], local.modified)
        XCTAssertEqual(state.revisions[remote.id], 1)
    }

    func testFullRebuildDoesNotTreatSnapshotAbsenceAsDeletion() async throws {
        var database = PasswordDatabase()
        let card = Card(title: "Local known item")
        database.cards = [card]
        var state = RowSyncState()
        state.cursor = 1
        try markSynced(.card(card), revision: 1, state: &state)
        let before = state
        MockURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/changes") == true {
                return self.emptyChanges(headSeq: 2, request: request)
            }
            if request.url?.path.hasSuffix("/seq") == true {
                return self.respond(#"{"headSeq":2,"passwordVersion":1}"#, request: request)
            }
            return self.respond(#"{"items":[],"nextCursor":null,"headSeq":2}"#, request: request)
        }
        do {
            _ = try await RowSync.fullRebuild(
                client: makeClient(), token: "t", vaultId: "v1", key: key,
                localDatabase: database, state: &state)
            XCTFail("Snapshot absence needs lifecycle evidence")
        } catch let error as RowSyncSafetyError {
            XCTAssertEqual(error, .localDataNeedsRecovery)
        }
        XCTAssertEqual(state, before)
    }

    func testFullRebuildIsolatesUnreadableSnapshotRowAndKeepsCursor() async throws {
        var state = RowSyncState()
        state.cursor = 1
        let id = UUID()
        MockURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/seq") == true {
                return self.respond(#"{"headSeq":2,"passwordVersion":1}"#, request: request)
            }
            if request.url?.path.hasSuffix("/changes") == true {
                return self.emptyChanges(headSeq: 2, request: request)
            }
            return self.respond("""
            {"items":[{"uuid":"\(id)","kind":1,"revision":1,
            "bodyB64":"AAAA","modifiedMs":1}],"nextCursor":null,"headSeq":2}
            """, request: request)
        }
        let rebuilt = try await RowSync.fullRebuild(
            client: makeClient(), token: "t", vaultId: "v1", key: key, state: &state)

        XCTAssertTrue(rebuilt.cards.isEmpty)
        XCTAssertEqual(state.cursor, 2)
        XCTAssertEqual(state.quarantinedItems["snapshot:\(id.uuidString.lowercased()):1"]?.uuid, id)
        XCTAssertFalse(state.needsSyncContinuation)
    }

    func testPushWithUnavailableAttachmentStopsAfterCheckingRemoteVersion() async throws {
        var card = Card(title: "Account")
        card.files = [Attachment(name: "remote.bin", data: nil)]
        var database = PasswordDatabase()
        database.cards = [card]
        var state = RowSyncState()
        state.markDirty(uuid: card.id, modifiedMs: card.modified)
        let beforeDatabase = database
        let beforeState = state
        var requestCount = 0
        MockURLProtocol.handler = { request in
            requestCount += 1
            XCTAssertEqual(request.url?.path, "/v1/vaults/v1/attachment-versions")
            XCTAssertEqual(request.httpMethod, "GET")
            return self.respond(
                #"{"versions":[],"nextOffset":0,"hasMore":false}"#, request: request)
        }

        do {
            _ = try await RowSync.push(
                client: makeClient(), token: "t", vaultId: "v1", key: key,
                database: &database, state: &state)
            XCTFail("A metadata-only attachment must not be uploaded as a complete row")
        } catch let error as RowSyncSafetyError {
            XCTAssertEqual(error, .attachmentContentUnavailable)
        }

        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(database, beforeDatabase)
        XCTAssertEqual(state, beforeState)
    }

    func testPullCommitsAttachmentReferenceWithoutDownloadingBytes() async throws {
        let attachmentID = UUID()
        let contentVersion = UUID()
        var remote = Card(title: "Remote attachment")
        remote.files = [Attachment(
            id: attachmentID, contentVersion: contentVersion, name: "document.bin", data: nil)]
        let sealed = try sealedBody(.card(remote))
        var database = PasswordDatabase()
        var state = RowSyncState()
        state.cursor = 1
        var requestPaths: [String] = []
        MockURLProtocol.handler = { request in
            requestPaths.append(request.url?.path ?? "")
            return self.respond("""
            {"headSeq":2,"changes":[{"seq":2,"uuid":"\(remote.id)","op":"upsert",
            "revision":1,"bodyB64":"\(sealed)","kind":1,"modifiedMs":\(remote.modified)}]}
            """, request: request)
        }

        let outcome = try await RowSync.pull(
            client: makeClient(), token: "t", vaultId: "v1", key: key,
            database: &database, state: &state)

        XCTAssertEqual(outcome.pulledItems, 1)
        XCTAssertEqual(state.cursor, 2)
        XCTAssertEqual(requestPaths, ["/v1/vaults/v1/changes"])
        let downloaded = try XCTUnwrap(database.card(id: remote.id)?.files.first)
        XCTAssertEqual(downloaded.id, attachmentID)
        XCTAssertEqual(downloaded.contentVersion, contentVersion)
        XCTAssertNil(downloaded.data)
    }

    func testDownloadMissingAttachmentsHydratesOnlySelectedCards() async throws {
        let attachmentID = UUID()
        let contentVersion = UUID()
        let plaintext = Data("attachment bytes".utf8)
        let encrypted = try AttachmentSyncCipher.encrypt(
            data: plaintext, key: key, attachmentID: attachmentID, contentVersion: contentVersion)
        let hash = SyncConflict.sha256Hex(encrypted.cipher)
        var selectedCard = Card(title: "Selected")
        selectedCard.files = [Attachment(
            id: attachmentID, contentVersion: contentVersion, name: "document.bin", data: nil)]
        var otherCard = Card(title: "Deferred")
        otherCard.images = [Attachment(name: "later.png", data: nil)]
        var database = PasswordDatabase()
        database.cards = [selectedCard, otherCard]
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/vaults/v1/attachments/\(attachmentID.uuidString)")
            XCTAssertEqual(
                URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "version" })?.value,
                contentVersion.uuidString)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: [
                    "X-Content-Version": contentVersion.uuidString,
                    "X-Dek-Wrapped": encrypted.dekWrapped.base64EncodedString(),
                    "X-Sha256": hash,
                    "X-Bytes": String(encrypted.cipher.count),
                    "Content-Length": String(encrypted.cipher.count),
                ])!
            return (response, encrypted.cipher)
        }

        let result = try await RowSync.downloadMissingAttachments(
            client: makeClient(), token: "t", vaultId: "v1", key: key,
            database: database, cardIDs: [selectedCard.id])

        XCTAssertEqual(result.downloadedCount, 1)
        XCTAssertEqual(result.database.card(id: selectedCard.id)?.files.first?.data, plaintext)
        XCTAssertEqual(result.database.card(id: selectedCard.id)?.modified, selectedCard.modified)
        XCTAssertEqual(result.database.card(id: otherCard.id)?.images.first?.data, nil)
        XCTAssertNil(database.card(id: selectedCard.id)?.files.first?.data)
    }

    func testMergeDownloadedAttachmentBytesPreservesNewerCardAndAttachmentEdits() throws {
        let cardID = UUID()
        let attachmentID = UUID()
        let downloadedVersion = UUID()
        let currentVersion = UUID()
        var downloadedCard = Card(id: cardID, title: "Downloaded snapshot")
        downloadedCard.files = [Attachment(
            id: attachmentID, contentVersion: downloadedVersion,
            name: "old.bin", data: Data("verified bytes".utf8))]
        var currentCard = Card(id: cardID, title: "User edit")
        currentCard.files = [Attachment(
            id: attachmentID, contentVersion: currentVersion,
            name: "new.bin", data: nil)]
        var current = PasswordDatabase()
        current.cards = [currentCard]
        var downloaded = PasswordDatabase()
        downloaded.cards = [downloadedCard]

        let installed = RowSync.mergeDownloadedAttachmentContent(
            from: downloaded, into: &current)

        XCTAssertEqual(installed, 0)
        XCTAssertEqual(current.cards.first?.title, "User edit")
        XCTAssertEqual(current.cards.first?.files.first?.name, "new.bin")
        XCTAssertNil(current.cards.first?.files.first?.data)
    }

    func testMergeDownloadedAttachmentBytesOnlyInstallsMatchingVersion() throws {
        let cardID = UUID()
        let attachmentID = UUID()
        let contentVersion = UUID()
        var downloadedCard = Card(id: cardID, title: "Downloaded snapshot")
        downloadedCard.files = [Attachment(
            id: attachmentID, contentVersion: contentVersion,
            name: "document.bin", data: Data("verified bytes".utf8))]
        var currentCard = Card(id: cardID, title: "Latest edit")
        currentCard.files = [Attachment(
            id: attachmentID, contentVersion: contentVersion,
            name: "renamed.bin", data: nil)]
        var current = PasswordDatabase()
        current.cards = [currentCard]
        var downloaded = PasswordDatabase()
        downloaded.cards = [downloadedCard]

        let installed = RowSync.mergeDownloadedAttachmentContent(
            from: downloaded, into: &current)

        XCTAssertEqual(installed, 1)
        XCTAssertEqual(current.cards.first?.title, "Latest edit")
        XCTAssertEqual(current.cards.first?.files.first?.name, "renamed.bin")
        XCTAssertEqual(current.cards.first?.files.first?.data, Data("verified bytes".utf8))
    }

    func testAttachmentDownloadNetworkPolicy() {
        let wifi = AttachmentNetworkState(isAvailable: true, kind: .wifi, isConstrained: false)
        let wired = AttachmentNetworkState(isAvailable: true, kind: .wired, isConstrained: false)
        let cellular = AttachmentNetworkState(isAvailable: true, kind: .cellular, isConstrained: false)
        let unknown = AttachmentNetworkState(isAvailable: true, kind: .unknown, isConstrained: false)
        let constrained = AttachmentNetworkState(isAvailable: true, kind: .wifi, isConstrained: true)

        XCTAssertTrue(AttachmentDownloadPolicy.allowsBackground(
            on: wifi, allowsCellular: false, allowsUnknown: false))
        XCTAssertTrue(AttachmentDownloadPolicy.allowsBackground(
            on: wired, allowsCellular: false, allowsUnknown: false))
        XCTAssertFalse(AttachmentDownloadPolicy.allowsBackground(
            on: cellular, allowsCellular: false, allowsUnknown: false))
        XCTAssertTrue(AttachmentDownloadPolicy.allowsBackground(
            on: cellular, allowsCellular: true, allowsUnknown: false))
        XCTAssertFalse(AttachmentDownloadPolicy.allowsBackground(
            on: unknown, allowsCellular: true, allowsUnknown: false))
        XCTAssertTrue(AttachmentDownloadPolicy.allowsBackground(
            on: unknown, allowsCellular: false, allowsUnknown: true))
        XCTAssertFalse(AttachmentDownloadPolicy.allowsBackground(
            on: constrained, allowsCellular: true, allowsUnknown: true))
        XCTAssertFalse(AttachmentDownloadPolicy.allowsPrioritized(.unknown))
        XCTAssertTrue(AttachmentDownloadPolicy.allowsPrioritized(constrained))
    }

    func testAttachmentDownloadQueuePrioritizesDeduplicatesAndRequeues() throws {
        let backgroundCard = UUID()
        let openedCard = UUID()
        var queue = AttachmentDownloadQueue()
        queue.enqueue(cardID: backgroundCard, prioritized: false)
        queue.enqueue(cardID: openedCard, prioritized: false)
        queue.enqueue(cardID: backgroundCard, prioritized: false)
        queue.prioritize(cardID: openedCard)

        let opened = try XCTUnwrap(queue.takeNext())
        XCTAssertEqual(opened.cardID, openedCard)
        XCTAssertTrue(opened.isPrioritized)
        queue.prioritize(cardID: openedCard)
        XCTAssertTrue(queue.inFlightIsPrioritized)
        queue.requeueInFlight()

        let promoted = try XCTUnwrap(queue.takeNext())
        XCTAssertEqual(promoted.cardID, openedCard)
        XCTAssertTrue(promoted.isPrioritized)
        queue.finish(cardID: openedCard)
        XCTAssertEqual(queue.takeNext()?.cardID, backgroundCard)
    }

    func testAttachmentDownloadQueueCanRetrySameCardAfterSessionCancellation() throws {
        let cardID = UUID()
        var queue = AttachmentDownloadQueue()
        queue.enqueue(cardID: cardID, prioritized: false)
        _ = queue.takeNext()
        queue.cancelInFlight()
        queue.enqueue(cardID: cardID, prioritized: true)

        XCTAssertEqual(queue.firstCardID, cardID)
        queue.finish(cardID: cardID)
        let retry = try XCTUnwrap(queue.takeNext())
        XCTAssertEqual(retry.cardID, cardID)
        XCTAssertTrue(retry.isPrioritized)
    }

    func testPushIdenticalValuesConvergeWithoutTimestampWinner() async throws {
        var (database, card, _) = sampleDatabase()
        database.labels = []
        var state = RowSyncState()
        state.markDirty(uuid: card.id, modifiedMs: card.modified)
        var remote = card
        remote.modified = card.modified + 5000
        let sealed = try sealedBody(.card(remote))
        MockURLProtocol.handler = { request in
            self.respond("""
            {"results":[{"uuid":"\(card.id)","status":"conflict",
            "current":{"revision":4,"bodyB64":"\(sealed)"}}]}
            """, request: request)
        }
        let outcome = try await RowSync.push(
            client: makeClient(), token: "t", vaultId: "v1", key: key,
            database: &database, state: &state)
        XCTAssertEqual(outcome.conflictsResolved, 1)
        XCTAssertFalse(state.hasPendingWork)
        XCTAssertEqual(state.revisions[card.id], 4)
        try state.recomputeDirty(database: database, key: key)
        XCTAssertFalse(state.hasPendingWork)
    }

    func testPushAutomaticallyMergesIndependentFieldsAndRetries() async throws {
        let username = Field(name: "Username", value: "before")
        let password = Field(name: "Password", type: .password, value: "before")
        var base = Card(title: "Account")
        base.modified = 1000
        base.fields = [username, password]
        var local = base
        local.fields[0].value = "local username"
        local.modified = 1100
        var remote = base
        remote.fields[1].value = "remote password"
        remote.modified = 1200
        let remoteBody = try sealedBody(.card(remote))
        var database = PasswordDatabase()
        database.cards = [local]
        var state = RowSyncState()
        try markSynced(.card(base), revision: 1, state: &state)
        state.markDirty(uuid: local.id, modifiedMs: local.modified)
        var postCount = 0
        var uploadedCard: Card?
        var uploadedBodyStatus = "not inspected"

        MockURLProtocol.handler = { request in
            postCount += 1
            if postCount == 1 {
                return self.respond("""
                {"results":[{"uuid":"\(base.id)","status":"conflict",
                "current":{"revision":2,"bodyB64":"\(remoteBody)"}}]}
                """, request: request)
            }
            guard let httpBody = self.bodyData(request) else {
                uploadedBodyStatus = "missing body"
                return self.respond("""
                {"results":[{"uuid":"\(base.id)","status":"ok","revision":3}]}
                """, request: request)
            }
            guard let object = try? JSONSerialization.jsonObject(with: httpBody) as? [String: Any] else {
                uploadedBodyStatus = "invalid JSON"
                return self.respond("""
                {"results":[{"uuid":"\(base.id)","status":"ok","revision":3}]}
                """, request: request)
            }
            guard let items = object["items"] as? [[String: Any]],
                  let first = items.first,
                  let bodyB64 = first["bodyB64"] as? String,
                  let sealed = Data(base64Encoded: bodyB64),
                  let plaintext = RowSyncCipher.decrypt(sealed, key: self.key, uuid: base.id),
                  case let .card(uploaded) = DatabaseItemCodec.parse(
                    kind: 1, uuid: base.id, data: plaintext) else {
                uploadedBodyStatus = "invalid item"
                return self.respond("""
                {"results":[{"uuid":"\(base.id)","status":"ok","revision":3}]}
                """, request: request)
            }
            uploadedCard = uploaded
            uploadedBodyStatus = "decoded"
            return self.respond("""
            {"results":[{"uuid":"\(base.id)","status":"ok","revision":3}]}
            """, request: request)
        }

        let outcome = try await RowSync.push(
            client: makeClient(), token: "t", vaultId: "v1", key: key,
            database: &database, state: &state)

        XCTAssertEqual(postCount, 2)
        XCTAssertEqual(outcome.conflictsResolved, 1)
        XCTAssertEqual(outcome.pushedItems, 1)
        XCTAssertFalse(state.hasPendingWork)
        XCTAssertEqual(state.revisions[base.id], 3)
        XCTAssertEqual(uploadedBodyStatus, "decoded")
        XCTAssertEqual(uploadedCard?.fields[0].value, "local username")
        XCTAssertEqual(uploadedCard?.fields[1].value, "remote password")
        XCTAssertEqual(database.card(id: base.id)?.fields[0].value, "local username")
        XCTAssertEqual(database.card(id: base.id)?.fields[1].value, "remote password")
    }

    func testPullMergesIndependentFieldsAndKeepsMergedValueDirty() async throws {
        let username = Field(name: "Username", value: "before")
        let password = Field(name: "Password", type: .password, value: "before")
        var base = Card(title: "Account")
        base.modified = 1000
        base.fields = [username, password]
        var local = base
        local.fields[0].value = "local username"
        local.modified = 1100
        var remote = base
        remote.fields[1].value = "remote password"
        remote.modified = 1200
        let remoteBody = try sealedBody(.card(remote))
        var database = PasswordDatabase()
        database.cards = [local]
        var state = RowSyncState()
        state.cursor = 1
        try markSynced(.card(base), revision: 1, state: &state)
        state.markDirty(uuid: local.id, modifiedMs: local.modified)

        MockURLProtocol.handler = { request in
            return self.respond("""
            {"headSeq":2,"changes":[{"seq":2,"uuid":"\(base.id)","op":"upsert",
            "revision":2,"bodyB64":"\(remoteBody)","kind":1,"modifiedMs":1200}]}
            """, request: request)
        }

        let outcome = try await RowSync.pull(
            client: makeClient(), token: "t", vaultId: "v1", key: key,
            database: &database, state: &state)

        XCTAssertEqual(outcome.pulledItems, 1)
        XCTAssertEqual(state.cursor, 2)
        XCTAssertEqual(state.revisions[base.id], 2)
        XCTAssertNotNil(state.dirtyUpserts[base.id])
        XCTAssertEqual(database.card(id: base.id)?.fields[0].value, "local username")
        XCTAssertEqual(database.card(id: base.id)?.fields[1].value, "remote password")
        XCTAssertTrue(try XCTUnwrap(state.validatedBaselines(key: key)[base.id]).matches(.card(remote)))
    }

    func testPullSameFieldConflictRetainsLocalSnapshotAndCursor() async throws {
        let field = Field(name: "Password", type: .password, value: "before")
        var base = Card(title: "Account")
        base.fields = [field]
        var local = base
        local.fields[0].value = "local"
        var remote = base
        remote.fields[0].value = "remote"
        let remoteBody = try sealedBody(.card(remote))
        var database = PasswordDatabase()
        database.cards = [local]
        var state = RowSyncState()
        state.cursor = 1
        try markSynced(.card(base), revision: 1, state: &state)
        state.markDirty(uuid: local.id, modifiedMs: local.modified)
        let originalState = state
        var candidateRegistered = false

        MockURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/conflicts") == true {
                let body = try XCTUnwrap(self.bodyData(request))
                let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
                XCTAssertEqual(payload["baseRevision"] as? Int, 1)
                XCTAssertEqual(payload["expectedRevision"] as? Int, 2)
                XCTAssertNotNil(payload["bodyB64"] as? String)
                candidateRegistered = true
                return self.respond("""
                {"conflictId":"\(String(repeating: "f", count: 32))","generation":1,
                 "candidateCount":2,"currentRevision":2}
                """, request: request)
            }
            return self.respond("""
            {"headSeq":2,"changes":[{"seq":2,"uuid":"\(base.id)","op":"upsert",
            "revision":2,"bodyB64":"\(remoteBody)","kind":1,"modifiedMs":\(remote.modified)}]}
            """, request: request)
        }
        do {
            _ = try await RowSync.pull(
                client: makeClient(), token: "t", vaultId: "v1", key: key,
                database: &database, state: &state)
            XCTFail("Same-field concurrent changes require resolution")
        } catch let error as RowSyncSafetyError {
            XCTAssertEqual(error, .conflictNeedsResolution)
        }

        XCTAssertEqual(database.card(id: base.id)?.fields[0].value, "local")
        XCTAssertEqual(state.cursor, originalState.cursor)
        XCTAssertEqual(state.revisions, originalState.revisions)
        XCTAssertEqual(state.dirtyUpserts, originalState.dirtyUpserts)
        XCTAssertEqual(state.pendingConflicts[base.id]?.conflictID, String(repeating: "f", count: 32))
        XCTAssertEqual(state.pendingConflicts[base.id]?.baseRevision, 1)
        XCTAssertTrue(candidateRegistered)
    }

    func testPushUnknownOrDuplicateResultDoesNotPretendDeletion() async throws {
        for duplicate in [false, true] {
            var (database, card, _) = sampleDatabase()
            var state = RowSyncState()
            state.markDirty(uuid: card.id, modifiedMs: card.modified)
            let before = state
            MockURLProtocol.handler = { request in
                let result = """
                {"uuid":"\(card.id)","status":"\(duplicate ? "ok" : "unknown")","revision":1}
                """
                return self.respond("{\"results\":[\(result)\(duplicate ? "," + result : "")]}", request: request)
            }
            do {
                _ = try await RowSync.push(client: makeClient(), token: "t", vaultId: "v1",
                                          key: key, database: &database, state: &state)
                XCTFail("Unsupported or duplicate results must fail")
            } catch let error as RowSyncSafetyError {
                XCTAssertEqual(error, .invalidResponse)
            }
            XCTAssertEqual(state, before)
            XCTAssertEqual(database.card(id: card.id)?.title, card.title)
        }
    }

    func testFullRebuildCompleteSnapshotSeedsContentBaseline() async throws {
        var state = RowSyncState()
        let card = Card(title: "Cloud item")
        let sealed = try sealedBody(.card(card))
        MockURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/changes") == true {
                return self.emptyChanges(headSeq: 2, request: request)
            }
            if request.url?.path.hasSuffix("/seq") == true {
                return self.respond(#"{"headSeq":2,"passwordVersion":1}"#, request: request)
            }
            return self.respond("""
            {"items":[{"uuid":"\(card.id)","kind":1,"revision":1,
            "bodyB64":"\(sealed)","modifiedMs":0}],"nextCursor":null,"headSeq":2}
            """, request: request)
        }
        let rebuilt = try await RowSync.fullRebuild(
            client: makeClient(), token: "t", vaultId: "v1", key: key, state: &state)
        XCTAssertEqual(rebuilt.card(id: card.id)?.title, card.title)
        XCTAssertEqual(state.cursor, 2)
        try state.recomputeDirty(database: rebuilt, key: key)
        XCTAssertFalse(state.hasPendingWork)
    }

    func testFullRebuildCatchesChangesWrittenDuringPagination() async throws {
        var state = RowSyncState()
        let snapshotCard = Card(title: "Snapshot version")
        var latestCard = Card(id: snapshotCard.id, title: "Latest version")
        latestCard.modified = snapshotCard.modified + 1_000
        let snapshotBody = try sealedBody(.card(snapshotCard))
        let latestBody = try sealedBody(.card(latestCard))
        MockURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/seq") == true {
                return self.respond(#"{"headSeq":1,"passwordVersion":1}"#, request: request)
            }
            if request.url?.path.hasSuffix("/changes") == true {
                return self.respond("""
                {"headSeq":2,"changes":[{"seq":2,"uuid":"\(latestCard.id)",
                "op":"upsert","revision":2,"kind":1,"bodyB64":"\(latestBody)",
                "modifiedMs":\(latestCard.modified)}]}
                """, request: request)
            }
            return self.respond("""
            {"items":[{"uuid":"\(snapshotCard.id)","kind":1,"revision":1,
            "bodyB64":"\(snapshotBody)","modifiedMs":\(snapshotCard.modified)}],
            "nextCursor":null,"headSeq":1}
            """, request: request)
        }

        let rebuilt = try await RowSync.fullRebuild(
            client: makeClient(), token: "t", vaultId: "v1", key: key, state: &state)

        XCTAssertEqual(rebuilt.card(id: snapshotCard.id)?.title, latestCard.title)
        XCTAssertEqual(state.cursor, 2)
        XCTAssertEqual(state.revisions[snapshotCard.id], 2)
        let baselineData = try XCTUnwrap(state.encryptedItemBaselines[snapshotCard.id])
        let baseline = try XCTUnwrap(
            RowSyncCipher.decryptBaseline(baselineData, key: key, uuid: snapshotCard.id))
        XCTAssertTrue(baseline.matches(.card(latestCard)))
    }

    func testFullRebuildRepeatingPageRejectsIncompleteSnapshot() async throws {
        var state = RowSyncState()
        state.cursor = 1
        let before = state
        let card = Card(title: "Repeated page")
        let sealed = try sealedBody(.card(card))
        MockURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/seq") == true {
                return self.respond(#"{"headSeq":2,"passwordVersion":1}"#, request: request)
            }
            return self.respond("""
            {"items":[{"uuid":"\(card.id)","kind":1,"revision":1,
            "bodyB64":"\(sealed)","modifiedMs":0}],
            "nextCursor":{"ms":1,"uuid":"\(card.id)"},"headSeq":2}
            """, request: request)
        }
        do {
            _ = try await RowSync.fullRebuild(
                client: makeClient(), token: "t", vaultId: "v1", key: key, state: &state)
            XCTFail("Repeating pages must not return a partial snapshot")
        } catch let error as RowSyncSafetyError {
            XCTAssertEqual(error, .incompleteSnapshot)
        }
        XCTAssertEqual(state, before)
    }

    func testConflictCandidateIdentityIsStableAndKeyed() {
        let plaintext = Data("encrypted row plaintext".utf8)
        let uuid = UUID(uuidString: "123e4567-e89b-12d3-a456-426614174000")!
        let identity = RowSyncCipher.conflictCandidateIdentity(
            plaintext: plaintext, key: key, uuid: uuid,
            baseRevision: 4, kind: 1, isDelete: false)
        let retried = RowSyncCipher.conflictCandidateIdentity(
            plaintext: plaintext, key: key, uuid: uuid,
            baseRevision: 4, kind: 1, isDelete: false)
        let changedContent = RowSyncCipher.conflictCandidateIdentity(
            plaintext: Data("different row plaintext".utf8), key: key, uuid: uuid,
            baseRevision: 4, kind: 1, isDelete: false)
        let changedRevision = RowSyncCipher.conflictCandidateIdentity(
            plaintext: plaintext, key: key, uuid: uuid,
            baseRevision: 5, kind: 1, isDelete: false)
        let changedKey = RowSyncCipher.conflictCandidateIdentity(
            plaintext: plaintext, key: RowSyncKey(raw: Data(repeating: 9, count: 32)), uuid: uuid,
            baseRevision: 4, kind: 1, isDelete: false)

        XCTAssertEqual(identity.candidateID, retried.candidateID)
        XCTAssertEqual(identity.fingerprint, retried.fingerprint)
        XCTAssertEqual(identity.candidateID, String(identity.fingerprint.prefix(32)))
        XCTAssertNotEqual(identity.candidateID, changedContent.candidateID)
        XCTAssertNotEqual(identity.candidateID, changedRevision.candidateID)
        XCTAssertNotEqual(identity.candidateID, changedKey.candidateID)
    }

    func testConflictCandidateClientListsAndRegistersEncryptedVersions() async throws {
        let candidateBody = Data([1, 2, 3]).base64EncodedString()
        let candidateHash = SyncConflict.sha256Hex(Data([1, 2, 3]))
        let conflictID = String(repeating: "b", count: 32)
        let itemID = UUID(uuidString: "123e4567-e89b-12d3-a456-426614174000")!
        MockURLProtocol.handler = { request in
            if request.httpMethod == "GET" {
                XCTAssertEqual(request.url?.path, "/v1/vaults/v1/conflicts")
                return self.respond("""
                {"conflicts":[{"conflictId":"\(conflictID)","itemUuid":"\(itemID)",
                "baseRevision":1,"currentRevision":2,"currentDeletedSeq":0,
                "generation":1,"createdMs":1000,
                "updatedMs":2000,"candidates":[
                  {"candidateId":"\(String(repeating: "c", count: 32))","kind":1,
                   "op":"delete","revision":2,"modifiedMs":1500,"committedMs":1600,
                   "deviceName":"Mac","platform":"macos"},
                  {"candidateId":"\(String(repeating: "a", count: 32))","kind":1,
                   "op":"upsert","revision":1,"modifiedMs":1200,"committedMs":1700,
                   "deviceName":"iPhone","platform":"ios","bodyB64":"\(candidateBody)",
                   "sha256":"\(candidateHash)"}
                ]}]}
                """, request: request)
            }

            XCTAssertEqual(request.url?.path, "/v1/vaults/v1/items/\(itemID.uuidString)/conflicts")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
            let body = try XCTUnwrap(self.bodyData(request))
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(payload["candidateId"] as? String, String(repeating: "a", count: 32))
            XCTAssertEqual(payload["candidateFingerprint"] as? String, String(repeating: "a", count: 64))
            XCTAssertEqual(payload["expectedRevision"] as? Int, 2)
            XCTAssertEqual(payload["baseRevision"] as? Int, 1)
            XCTAssertEqual(payload["bodyB64"] as? String, candidateBody)
            return self.respond("""
            {"conflictId":"\(conflictID)","generation":1,"candidateCount":2,
             "currentRevision":2}
            """, request: request)
        }

        let client = makeClient()
        let conflicts = try await client.listConflicts(token: "token", vaultId: "v1")
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts[0].itemUUID, itemID)
        XCTAssertEqual(conflicts[0].generation, 1)
        XCTAssertEqual(conflicts[0].currentDeletedSequence, 0)
        XCTAssertEqual(conflicts[0].candidates.count, 2)
        XCTAssertTrue(conflicts[0].candidates[0].isDelete)
        XCTAssertEqual(conflicts[0].candidates[1].bodyB64, candidateBody)

        let operation = RelayClient.ItemOp(
            uuid: itemID, kind: 1, isDelete: false, baseRevision: 1,
            bodyB64: candidateBody, modifiedMs: 1200)
        let registration = try await client.registerConflictCandidate(
            token: "token", vaultId: "v1", operation: operation,
            expectedRevision: 2, candidateID: String(repeating: "a", count: 32),
            fingerprint: String(repeating: "a", count: 64))
        XCTAssertEqual(registration.conflictID, conflictID)
        XCTAssertEqual(registration.candidateCount, 2)
        XCTAssertEqual(registration.currentRevision, 2)
    }

    func testConflictCandidateListAllowsCreateBaseRevisionAndVerifiesCiphertext() async throws {
        let localCiphertext = Data([1, 2, 3])
        let remoteCiphertext = Data([4, 5, 6])
        let localBody = localCiphertext.base64EncodedString()
        let remoteBody = remoteCiphertext.base64EncodedString()
        let localHash = SyncConflict.sha256Hex(localCiphertext)
        let remoteHash = SyncConflict.sha256Hex(remoteCiphertext)
        let itemID = UUID(uuidString: "123e4567-e89b-12d3-a456-426614174000")!
        var corruptHash = false
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            let hash = corruptHash ? String(repeating: "0", count: 64) : localHash
            return self.respond("""
            {"conflicts":[{"conflictId":"\(String(repeating: "b", count: 32))",
            "itemUuid":"\(itemID)","baseRevision":0,"currentRevision":1,
            "currentDeletedSeq":0,
            "generation":1,"createdMs":1000,"updatedMs":2000,"candidates":[
              {"candidateId":"\(String(repeating: "a", count: 32))","kind":1,
               "op":"upsert","revision":0,"modifiedMs":1200,"committedMs":1600,
               "deviceName":"iPhone","platform":"ios","bodyB64":"\(localBody)",
               "sha256":"\(hash)"},
              {"candidateId":"\(String(repeating: "c", count: 32))","kind":1,
               "op":"upsert","revision":1,"modifiedMs":1300,"committedMs":1700,
               "deviceName":"Mac","platform":"macos","bodyB64":"\(remoteBody)",
               "sha256":"\(remoteHash)"}]}]}
            """, request: request)
        }

        let client = makeClient()
        let conflicts = try await client.listConflicts(token: "token", vaultId: "v1")
        XCTAssertEqual(conflicts.first?.candidates.first?.revision, 0)

        corruptHash = true
        do {
            _ = try await client.listConflicts(token: "token", vaultId: "v1")
            XCTFail("Mismatched candidate ciphertext digest must be rejected")
        } catch let error as RowSyncSafetyError {
            XCTAssertEqual(error, .invalidResponse)
        }
    }

    func testPushRegistersCandidateOnlyAfterAutomaticMergeFails() async throws {
        let base = Card(title: "Base")
        var local = base
        local.title = "Local title"
        var remote = base
        remote.title = "Remote title"
        let remoteBody = try sealedBody(.card(remote))
        var database = PasswordDatabase()
        database.cards = [local]
        var state = RowSyncState()
        state.revisions[base.id] = 1
        state.dirtyUpserts[base.id] = local.modified
        state.syncedMtimes[base.id] = base.modified
        state.encryptedItemBaselines[base.id] = try RowSyncCipher.encryptBaseline(.card(base), key: key)
        let originalDatabase = database
        let originalState = state
        var conflictRegistered = false

        MockURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/items") == true {
                XCTAssertEqual(request.httpMethod, "POST")
                return self.respond("""
                {"results":[{"uuid":"\(base.id)","status":"conflict",
                "current":{"revision":2,"bodyB64":"\(remoteBody)"}}]}
                """, request: request)
            }
            XCTAssertTrue(request.url?.path.hasSuffix("/items/\(base.id.uuidString)/conflicts") == true)
            conflictRegistered = true
            return self.respond("""
            {"conflictId":"\(String(repeating: "b", count: 32))","generation":1,
             "candidateCount":2,"currentRevision":2}
            """, request: request)
        }

        do {
            _ = try await RowSync.push(
                client: makeClient(), token: "token", vaultId: "v1", key: key,
                database: &database, state: &state)
            XCTFail("A conflicting field must pause after retaining a candidate")
        } catch let error as RowSyncSafetyError {
            XCTAssertEqual(error, .conflictNeedsResolution)
        }

        XCTAssertTrue(conflictRegistered)
        XCTAssertEqual(database.xmlData(), originalDatabase.xmlData())
        XCTAssertEqual(state.cursor, originalState.cursor)
        XCTAssertEqual(state.revisions, originalState.revisions)
        XCTAssertEqual(state.dirtyUpserts, originalState.dirtyUpserts)
        XCTAssertEqual(state.pendingConflicts[base.id]?.conflictID, String(repeating: "b", count: 32))
    }

}
