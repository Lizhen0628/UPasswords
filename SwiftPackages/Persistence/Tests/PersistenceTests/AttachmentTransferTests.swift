import CryptoKit
import Foundation
import Testing

import UPasswordsCore
@testable import UPasswordsPersistence

@Suite("Exact attachment version transfers")
struct AttachmentTransferTests {
    private let key = RowSyncKey(raw: Data(repeating: 19, count: 32))

    // Each session has its own host and handler. The registry lock protects URLProtocol callbacks.
    private final class StubProtocol: URLProtocol {
        typealias Handler = (URLRequest) throws -> (HTTPURLResponse, Data)
        private static let lock = NSLock()
        nonisolated(unsafe) private static var handlers: [String: Handler] = [:]

        static func register(_ handler: @escaping Handler, host: String) {
            lock.withLock { handlers[host] = handler }
        }

        static func unregister(host: String) {
            _ = lock.withLock { handlers.removeValue(forKey: host) }
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let handler = Self.lock.withLock { Self.handlers[request.url?.host ?? ""] }
            do {
                guard let handler else { throw URLError(.unsupportedURL) }
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

    private final class Network {
        let client: RelayClient
        private let session: URLSession
        private let host = "transfer-\(UUID().uuidString.lowercased()).test"
        private let lock = NSLock()
        private var requests: [String] = []

        var operations: [String] { lock.withLock { requests } }

        init(handler: @escaping StubProtocol.Handler) throws {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [StubProtocol.self]
            session = URLSession(configuration: configuration)
            let url = try #require(URL(string: "https://\(host)"))
            client = RelayClient(baseURL: url, session: session)
            StubProtocol.register({ [weak self] request in
                self?.lock.withLock {
                    self?.requests.append("\(request.httpMethod ?? "") \(request.url?.path ?? "")")
                }
                return try handler(request)
            }, host: host)
        }

        deinit {
            StubProtocol.unregister(host: host)
            session.invalidateAndCancel()
        }
    }

    private func response(
        _ body: String, request: URLRequest, status: Int = 200, headers: [String: String] = [:]
    ) throws -> (HTTPURLResponse, Data) {
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(
            url: url, statusCode: status, httpVersion: nil, headerFields: headers))
        return (response, Data(body.utf8))
    }

    private func versions(card: Card, parentID: UUID? = nil, contentVersion: UUID? = nil) throws -> String {
        let attachment = try #require(card.files.first)
        let wrappedKey = Data(repeating: 7, count: 60).base64EncodedString()
        return """
        {"versions":[{"attachmentId":"\(attachment.id)","cardUuid":"\(parentID ?? card.id)",
        "contentVersion":"\(contentVersion ?? attachment.contentVersion)","dekWrapped":"\(wrappedKey)",
        "sha256":"\(String(repeating: "a", count: 64))","bytes":1,"isCurrent":true}],
        "nextOffset":1,"hasMore":false}
        """
    }

    @Test("Editing a metadata-only card reuses its exact cloud version without uploading bytes")
    func reusesCloudVersion() async throws {
        var card = Card(title: "Edited account")
        card.files = [Attachment(name: "remote", data: nil)]
        let expected = card
        let network = try Network { request in
            if request.url?.path.hasSuffix("/attachment-versions") == true {
                let query = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)
                #expect(query?.queryItems?.first { $0.name == "cardUuid" }?.value == expected.id.uuidString)
                return try response(versions(card: expected), request: request)
            }
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path.hasSuffix("/items") == true)
            return try response("""
            {"results":[{"uuid":"\(expected.id)","status":"ok","revision":2}]}
            """, request: request)
        }
        var database = PasswordDatabase()
        database.cards = [card]
        var state = RowSyncState()
        state.markDirty(uuid: card.id, modifiedMs: card.modified)
        _ = try await RowSync.push(client: network.client, token: "test", vaultId: "v1", key: key,
                                   database: &database, state: &state)
        #expect(state.revisions[card.id] == 2)
        #expect(!state.hasPendingWork)
        #expect(database.cards == [expected])
        #expect(network.operations == ["GET /v1/vaults/v1/attachment-versions", "POST /v1/vaults/v1/items"])
    }

    @Test("Missing, foreign-parent, and different cloud versions cannot publish unavailable bytes",
          arguments: ["missing", "foreignParent", "differentVersion"])
    func rejectsUnusableCloudVersion(reason: String) async throws {
        var card = Card(title: "Pending account")
        card.files = [Attachment(name: "remote", data: nil)]
        let expected = card
        let network = try Network { request in
            let body: String
            switch reason {
            case "foreignParent": body = try versions(card: expected, parentID: UUID())
            case "differentVersion": body = try versions(card: expected, contentVersion: UUID())
            default: body = #"{"versions":[],"nextOffset":0,"hasMore":false}"#
            }
            return try response(body, request: request)
        }
        var database = PasswordDatabase()
        database.cards = [card]
        let before = database
        var state = RowSyncState()
        state.markDirty(uuid: card.id, modifiedMs: card.modified)
        let beforeState = state
        await #expect(throws: RowSyncSafetyError.attachmentContentUnavailable) {
            try await RowSync.push(client: network.client, token: "test", vaultId: "v1", key: key,
                                   database: &database, state: &state)
        }
        #expect(database == before)
        #expect(state == beforeState)
        #expect(network.operations == ["GET /v1/vaults/v1/attachment-versions"])
    }

    @Test("An upload conflict cannot be accepted using a foreign parent's version")
    func rejectsForeignParentAfterUploadConflict() async throws {
        var card = Card(title: "Pending upload")
        card.files = [Attachment(name: "local", data: Data([1, 2]))]
        let expected = card
        let foreignID = UUID()
        let network = try Network { request in
            if request.url?.path.hasSuffix("/attachment-versions") == true {
                return try response(versions(card: expected, parentID: foreignID), request: request)
            }
            if request.url?.path.hasSuffix("/commit") == true {
                return try response(#"{"error":"attachment_version_conflict"}"#, request: request, status: 409)
            }
            return try response("{}", request: request)
        }
        var database = PasswordDatabase()
        database.cards = [card]
        var state = RowSyncState()
        state.markDirty(uuid: card.id, modifiedMs: card.modified)
        let before = state
        await #expect(throws: RelayClient.RelayError.attachmentVersionConflict) {
            try await RowSync.push(client: network.client, token: "test", vaultId: "v1", key: key,
                                   database: &database, state: &state)
        }
        #expect(state == before)
        #expect(database.cards == [expected])
        #expect(network.operations.count == 4)
        #expect(!network.operations.contains("POST /v1/vaults/v1/items"))
    }

    @Test("The original-size limit accepts the exact boundary and rejects one extra byte",
          arguments: [AttachmentPolicy.maximumOriginalBytes, AttachmentPolicy.maximumOriginalBytes + 1])
    func enforcesNewUploadLimit(size: Int) async throws {
        var card = Card(title: "New attachment")
        card.files = [Attachment(name: "new", data: Data(repeating: 7, count: size))]
        let cardID = card.id
        let network = try Network { request in
            if request.url?.path.hasSuffix("/attachment-versions") == true {
                return try response(#"{"versions":[],"nextOffset":0,"hasMore":false}"#, request: request)
            }
            if request.url?.path.hasSuffix("/items") == true {
                return try response("""
                {"results":[{"uuid":"\(cardID)","status":"ok","revision":1}]}
                """, request: request)
            }
            return try response("{}", request: request)
        }
        var database = PasswordDatabase()
        database.cards = [card]
        var state = RowSyncState()
        state.markDirty(uuid: card.id, modifiedMs: card.modified)
        if size <= AttachmentPolicy.maximumOriginalBytes {
            _ = try await RowSync.push(client: network.client, token: "test", vaultId: "v1", key: key,
                                       database: &database, state: &state)
            #expect(!state.hasPendingWork)
            #expect(network.operations.filter { $0.hasPrefix("PUT ") }.count == 1)
            #expect(network.operations.last == "POST /v1/vaults/v1/items")
        } else {
            let before = state
            await #expect(throws: RelayClient.RelayError.itemTooLarge) {
                try await RowSync.push(client: network.client, token: "test", vaultId: "v1", key: key,
                                       database: &database, state: &state)
            }
            #expect(state == before)
            #expect(database.cards == [card])
            #expect(network.operations == ["GET /v1/vaults/v1/attachment-versions"])
        }
    }

    @Test("A saved attachment success remains durable when the next version fails")
    func commitsEachSuccessfulVersion() async throws {
        var card = Card(title: "Two attachments")
        card.files = [Attachment(name: "first", data: nil), Attachment(name: "second", data: nil)]
        var database = PasswordDatabase()
        database.cards = [card]
        let versions = AttachmentDownloadLedger.versions(in: database)
        let plaintext = Data("verified attachment".utf8)
        let encrypted = try AttachmentSyncCipher.encrypt(data: plaintext, key: key,
            attachmentID: versions[0].identity.attachmentID, contentVersion: versions[0].contentVersion)
        let network = try Network { request in
            if request.url?.path.hasSuffix(versions[1].identity.attachmentID.uuidString) == true {
                return try response(#"{"error":"attachment_version_missing"}"#, request: request, status: 404)
            }
            let reply = try response("", request: request, headers: [
                "X-Content-Version": versions[0].contentVersion.uuidString,
                "X-Dek-Wrapped": encrypted.dekWrapped.base64EncodedString(),
                "X-Sha256": SyncConflict.sha256Hex(encrypted.cipher),
                "X-Bytes": String(encrypted.cipher.count),
                "Content-Length": String(encrypted.cipher.count),
            ])
            return (reply.0, encrypted.cipher)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("UPWTransfer-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DatabaseStore(root: root)
        let vaultKey = SymmetricKey(data: key.raw)
        let envelope = try DatabaseCipher.wrapVaultKey(vaultKey, password: "test-only")
        let downloaded = try await RowSync.downloadAttachment(version: versions[0], client: network.client,
            token: "test", vaultId: "v1", key: key)
        #expect(downloaded == plaintext)
        #expect(RowSync.installDownloadedAttachmentContent(downloaded, for: versions[0], into: &database))
        try store.commitSyncSnapshot(database, name: "Transfer", vaultKey: vaultKey,
                                     state: RowSyncState(), envelope: envelope)
        await #expect(throws: RelayClient.RelayError.attachmentVersionMissing) {
            try await RowSync.downloadAttachment(version: versions[1], client: network.client,
                token: "test", vaultId: "v1", key: key)
        }
        let reopened = try store.load(name: "Transfer", password: "test-only")
        #expect(reopened.cards[0].files[0].data == plaintext)
        #expect(reopened.cards[0].files[0].contentVersion == versions[0].contentVersion)
        #expect(!reopened.cards[0].files[1].hasContent)
        #expect(network.operations.count == 2)
    }

    @Test("Download transport errors retain their retry category", arguments: [URLError.timedOut, .serverCertificateUntrusted])
    func preservesTransportError(code: URLError.Code) async throws {
        let network = try Network { _ in throw URLError(code) }
        let version = AttachmentDownloadLedger.Version(cardID: UUID(), attachmentID: UUID(), contentVersion: UUID())
        do {
            _ = try await RowSync.downloadAttachment(version: version, client: network.client,
                token: "test", vaultId: "v1", key: key)
            Issue.record("A transport failure must not return attachment bytes")
        } catch let error as URLError {
            #expect(error.code == code)
            let classification = AttachmentDownloadFailure.classify(error)
            #expect(classification.failure == (code == .timedOut ? .transient : .permanent))
        }
        #expect(network.operations.count == 1)
    }

    @Test("A cancelled attachment GET is cancellation rather than a new failed attempt")
    func preservesCancellation() async throws {
        let network = try Network { _ in throw URLError(.cancelled) }
        let version = AttachmentDownloadLedger.Version(cardID: UUID(), attachmentID: UUID(), contentVersion: UUID())
        await #expect(throws: CancellationError.self) {
            try await RowSync.downloadAttachment(version: version, client: network.client,
                token: "test", vaultId: "v1", key: key)
        }
        #expect(network.operations.count == 1)
    }

    @Test("An existing oversized cloud version remains reusable without a new upload")
    func reusesHistoricalOversizedVersion() async throws {
        var card = Card(title: "Legacy attachment")
        card.files = [Attachment(name: "legacy", data: Data(repeating: 4, count: AttachmentPolicy.maximumOriginalBytes + 1))]
        let expected = card
        let network = try Network { request in
            if request.url?.path.hasSuffix("/attachment-versions") == true {
                return try response(versions(card: expected), request: request)
            }
            return try response("""
            {"results":[{"uuid":"\(expected.id)","status":"ok","revision":2}]}
            """, request: request)
        }
        var database = PasswordDatabase()
        database.cards = [card]
        var state = RowSyncState()
        state.markDirty(uuid: card.id, modifiedMs: card.modified)
        _ = try await RowSync.push(client: network.client, token: "test", vaultId: "v1", key: key,
                                   database: &database, state: &state)
        #expect(!state.hasPendingWork)
        #expect(database.cards == [expected])
        #expect(network.operations == ["GET /v1/vaults/v1/attachment-versions", "POST /v1/vaults/v1/items"])
    }
}
