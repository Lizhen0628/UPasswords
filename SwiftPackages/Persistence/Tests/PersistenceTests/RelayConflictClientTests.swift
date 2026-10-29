import XCTest
@testable import UPasswordsPersistence

final class RelayConflictClientTests: XCTestCase {
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

    private let itemUUID = UUID(uuidString: "123e4567-e89b-12d3-a456-426614174000")!

    private func makeClient() -> RelayClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return RelayClient(
            baseURL: URL(string: "https://api.test")!,
            session: URLSession(configuration: configuration))
    }

    private func respond(
        _ body: String,
        request: URLRequest,
        status: Int = 200
    ) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil)!
        return (response, Data(body.utf8))
    }

    private func bodyData(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        let stream = try XCTUnwrap(request.httpBodyStream)
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
        return data
    }

    private func conflict(currentDeletedSequence: Int = 0) -> RelayClient.ConflictRecord {
        let local = RelayClient.ConflictCandidate(
            candidateID: String(repeating: "c", count: 32),
            kind: 1,
            isDelete: false,
            revision: 1,
            modifiedAt: Date(timeIntervalSince1970: 1),
            committedAt: Date(timeIntervalSince1970: 2),
            deviceName: "Mac",
            platform: "macos",
            bodyB64: Data([1, 2, 3]).base64EncodedString(),
            sha256: nil)
        let remote = RelayClient.ConflictCandidate(
            candidateID: String(repeating: "a", count: 32),
            kind: 1,
            isDelete: false,
            revision: 2,
            modifiedAt: Date(timeIntervalSince1970: 3),
            committedAt: Date(timeIntervalSince1970: 4),
            deviceName: "iPhone",
            platform: "ios",
            bodyB64: Data([4, 5, 6]).base64EncodedString(),
            sha256: nil)
        return RelayClient.ConflictRecord(
            conflictID: String(repeating: "b", count: 32),
            itemUUID: itemUUID,
            baseRevision: 1,
            currentRevision: 2,
            currentDeletedSequence: currentDeletedSequence,
            generation: 7,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 4),
            candidates: [local, remote])
    }

    func testResolveConflictSendsCompleteCandidateSetAndCASValues() async throws {
        let conflict = conflict()
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(
                request.url?.path,
                "/v1/vaults/v1/conflicts/\(conflict.conflictID)/resolve")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
            let data = try self.bodyData(request)
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(payload["generation"] as? Int, 7)
            XCTAssertEqual(
                payload["candidateIds"] as? [String],
                [String(repeating: "a", count: 32), String(repeating: "c", count: 32)])
            XCTAssertEqual(payload["winnerCandidateId"] as? String, String(repeating: "c", count: 32))
            XCTAssertEqual(payload["expectedCurrentRevision"] as? Int, 2)
            XCTAssertEqual(payload["expectedDeletedSeq"] as? Int, 0)
            XCTAssertEqual((payload["attachmentRefs"] as? [[String: Any]])?.count, 0)
            XCTAssertNil(payload["restoreItemUuid"])
            XCTAssertNil(payload["bodyB64"])
            return self.respond(
                "{\"status\":\"resolved\",\"itemUuid\":\"\(self.itemUUID)\",\"itemCount\":3,\"headSeq\":18}",
                request: request)
        }

        let result = try await makeClient().resolveConflict(
            token: "token",
            vaultId: "v1",
            conflict: conflict,
            winningCandidateID: String(repeating: "c", count: 32),
            attachmentReferences: [])
        XCTAssertEqual(result.itemUUID, itemUUID)
        XCTAssertEqual(result.itemCount, 3)
        XCTAssertEqual(result.headSequence, 18)
    }

    func testResolveCompositionSendsEncryptedBodyAndModifiedTime() async throws {
        let conflict = conflict()
        let composedBody = Data([7, 8, 9, 10])
        MockURLProtocol.handler = { request in
            let data = try self.bodyData(request)
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(payload["winnerCandidateId"] as? String, String(repeating: "c", count: 32))
            XCTAssertEqual(payload["mergedBodyB64"] as? String, composedBody.base64EncodedString())
            XCTAssertEqual(payload["mergedModifiedMs"] as? Int64, 1_800_000_000_000)
            XCTAssertNil(payload["bodyB64"])
            XCTAssertNil(payload["restoreItemUuid"])
            return self.respond(
                "{\"status\":\"resolved\",\"itemUuid\":\"\(self.itemUUID)\",\"itemCount\":3,\"headSeq\":18}",
                request: request)
        }

        let result = try await makeClient().resolveConflict(
            token: "token",
            vaultId: "v1",
            conflict: conflict,
            winningCandidateID: String(repeating: "c", count: 32),
            attachmentReferences: [],
            composedBody: composedBody,
            composedModifiedMs: 1_800_000_000_000)
        XCTAssertEqual(result.itemUUID, itemUUID)
    }

    func testResolveRejectsIncompleteOrDeletedCompositionBeforeNetwork() async {
        var requestStarted = false
        MockURLProtocol.handler = { request in
            requestStarted = true
            return self.respond("{}", request: request)
        }
        let deletedConflict = conflict(currentDeletedSequence: 11)

        do {
            _ = try await makeClient().resolveConflict(
                token: "token",
                vaultId: "v1",
                conflict: deletedConflict,
                winningCandidateID: String(repeating: "c", count: 32),
                attachmentReferences: [],
                composedBody: Data([1]))
            XCTFail("Composition requires an active item and a modified time")
        } catch let error as RowSyncSafetyError {
            XCTAssertEqual(error, .invalidResponse)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertFalse(requestStarted)
    }

    func testResolveDeletedConflictRequiresNewIdentityAndSendsReencryptedBody() async throws {
        let conflict = conflict(currentDeletedSequence: 11)
        let restoredUUID = UUID(uuidString: "223e4567-e89b-12d3-a456-426614174000")!
        let restoredBody = Data([9, 8, 7, 6])
        MockURLProtocol.handler = { request in
            let data = try self.bodyData(request)
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(payload["expectedDeletedSeq"] as? Int, 11)
            XCTAssertEqual(payload["restoreItemUuid"] as? String, restoredUUID.uuidString)
            XCTAssertEqual(payload["bodyB64"] as? String, restoredBody.base64EncodedString())
            return self.respond(
                "{\"status\":\"resolved\",\"itemUuid\":\"\(restoredUUID)\",\"itemCount\":4,\"headSeq\":19}",
                request: request)
        }

        let result = try await makeClient().resolveConflict(
            token: "token",
            vaultId: "v1",
            conflict: conflict,
            winningCandidateID: String(repeating: "c", count: 32),
            attachmentReferences: [],
            restoreItemUUID: restoredUUID,
            restoredBody: restoredBody)
        XCTAssertEqual(result.itemUUID, restoredUUID)
        XCTAssertEqual(result.headSequence, 19)
    }

    func testResolveRejectsDeletedRestoreUsingOriginalIdentityBeforeNetwork() async {
        let conflict = conflict(currentDeletedSequence: 11)
        var requestStarted = false
        MockURLProtocol.handler = { request in
            requestStarted = true
            return self.respond("{}", request: request)
        }

        do {
            _ = try await makeClient().resolveConflict(
                token: "token",
                vaultId: "v1",
                conflict: conflict,
                winningCandidateID: String(repeating: "c", count: 32),
                attachmentReferences: [],
                restoreItemUUID: itemUUID,
                restoredBody: Data([1]))
            XCTFail("A deleted row must not be restored with its former identity")
        } catch let error as RowSyncSafetyError {
            XCTAssertEqual(error, .invalidResponse)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertFalse(requestStarted)
    }

    func testResolveMapsStaleCASResponse() async {
        let conflict = conflict()
        MockURLProtocol.handler = { request in
            self.respond("{\"error\":\"conflict_stale\"}", request: request, status: 409)
        }

        do {
            _ = try await makeClient().resolveConflict(
                token: "token",
                vaultId: "v1",
                conflict: conflict,
                winningCandidateID: String(repeating: "c", count: 32),
                attachmentReferences: [])
            XCTFail("A stale conflict must be rejected")
        } catch let error as RelayClient.RelayError {
            XCTAssertEqual(error, .conflictStale)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testConflictListRejectsMissingDeletionSequence() async {
        MockURLProtocol.handler = { request in
            self.respond("""
            {"conflicts":[{"conflictId":"\(String(repeating: "b", count: 32))",
            "itemUuid":"\(self.itemUUID)","baseRevision":1,"currentRevision":2,
            "generation":1,"createdMs":1000,"updatedMs":2000,"candidates":[]}]}
            """, request: request)
        }

        do {
            _ = try await makeClient().listConflicts(token: "token", vaultId: "v1")
            XCTFail("Conflict deletion evidence is required for safe restore decisions")
        } catch let error as RowSyncSafetyError {
            XCTAssertEqual(error, .invalidResponse)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
