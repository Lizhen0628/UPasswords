import Foundation
import Testing

import UPasswordsCore
@testable import UPasswordsPersistence

@Suite("Durable attachment downloads")
struct AttachmentDownloadLedgerTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let version = AttachmentDownloadLedger.Version(
        cardID: UUID(), attachmentID: UUID(), contentVersion: UUID())

    @Test("A first failure schedules exactly five bounded retries and survives restart")
    func persistsBoundedRetries() throws {
        var ledger = AttachmentDownloadLedger()
        #expect(ledger.isReady(version, now: now))
        for (index, delay) in AttachmentDownloadLedger.retryDelays.enumerated() {
            ledger.recordFailure(for: version, failure: .transient, now: now)
            ledger = try JSONDecoder().decode(AttachmentDownloadLedger.self, from: JSONEncoder().encode(ledger))
            #expect(ledger.records[version]?.failureCount == index + 1)
            #expect(ledger.records[version]?.retryAt == now.addingTimeInterval(delay))
            #expect(!ledger.isReady(version, now: now))
            #expect(ledger.isReady(version, now: now.addingTimeInterval(delay)))
        }
        ledger.recordFailure(for: version, failure: .transient, now: now)
        #expect(ledger.records[version]?.failureCount == 6)
        #expect(ledger.records[version]?.retryAt == nil)
        #expect(!ledger.isReady(version, now: now.addingTimeInterval(3600)))
        ledger.request(version, resetFailures: false)
        #expect(!ledger.isReady(version, now: now.addingTimeInterval(3600)))
        ledger.request(version, resetFailures: true)
        #expect(ledger.isReady(version, now: now))
        #expect(ledger.records[version]?.failureCount == 0)
    }

    @Test("Retry-After is a lower bound, and another content version has an independent round")
    func honorsServerBackoffAndVersion() {
        var ledger = AttachmentDownloadLedger()
        ledger.recordFailure(for: version, failure: .transient, now: now, minimumDelay: 120)
        #expect(ledger.records[version]?.retryAt == now.addingTimeInterval(120))
        let replacement = AttachmentDownloadLedger.Version(
            cardID: version.identity.cardID, attachmentID: version.identity.attachmentID, contentVersion: UUID())
        #expect(ledger.isReady(replacement, now: now))
        #expect(!ledger.isReady(version, now: now))
    }

    @Test("Network recovery resumes transient failures and preserves authorization, integrity, and eviction pauses")
    func recoveryIsSelective() {
        var ledger = AttachmentDownloadLedger()
        ledger.recordFailure(for: version, failure: .transient, now: now)
        let blocked = [AttachmentDownloadLedger.Failure.authorization, .integrity, .unavailable, .storage, .permanent]
            .map { failure -> AttachmentDownloadLedger.Version in
                let key = AttachmentDownloadLedger.Version(cardID: UUID(), attachmentID: UUID(), contentVersion: UUID())
                ledger.recordFailure(for: key, failure: failure, now: now)
                return key
            }
        let evicted = AttachmentDownloadLedger.Version(cardID: UUID(), attachmentID: UUID(), contentVersion: UUID())
        ledger.recordEviction(of: evicted)
        ledger.restartTransientFailures()
        #expect(ledger.isReady(version, now: now))
        #expect(blocked.allSatisfy { !ledger.isReady($0, now: now.addingTimeInterval(3600)) })
        #expect(!ledger.isReady(evicted, now: now))
    }

    @Test("Only a changed authorization resumes authorization failures across process restart")
    func authorizationIsDurable() throws {
        var ledger = AttachmentDownloadLedger()
        ledger.resumeAfterAuthorization(fingerprint: Data([1]))
        ledger.recordFailure(for: version, failure: .authorization, now: now)
        ledger = try JSONDecoder().decode(AttachmentDownloadLedger.self, from: JSONEncoder().encode(ledger))
        ledger.resumeAfterAuthorization(fingerprint: Data([1]))
        #expect(!ledger.isReady(version, now: now))
        ledger.resumeAfterAuthorization(fingerprint: Data([2]))
        #expect(ledger.isReady(version, now: now))
    }

    @Test("Offline retention follows attachment identity while suppression follows content version")
    func retentionAndEviction() throws {
        var ledger = AttachmentDownloadLedger()
        ledger.setKeptOffline(true, for: version.identity)
        ledger.recordEviction(of: version)
        ledger = try JSONDecoder().decode(AttachmentDownloadLedger.self, from: JSONEncoder().encode(ledger))
        #expect(ledger.offlineAttachments.contains(version.identity))
        #expect(!ledger.isReady(version, now: now))
        ledger.request(version, resetFailures: false)
        #expect(ledger.isReady(version, now: now))
        ledger.setKeptOffline(false, for: version.identity)
        #expect(ledger.offlineAttachments.isEmpty)
    }

    @Test("A completed exact version clears retry state without discarding offline retention")
    func completion() {
        var ledger = AttachmentDownloadLedger()
        ledger.setKeptOffline(true, for: version.identity)
        ledger.recordFailure(for: version, failure: .integrity, now: now)
        ledger.recordSuccess(for: version, now: now)
        #expect(ledger.isReady(version, now: now))
        #expect(ledger.records[version]?.failure == nil)
        #expect(ledger.records[version]?.lastAccess == now)
        #expect(ledger.offlineAttachments.contains(version.identity))
    }

    @Test("Old version retries do not survive a confirmed metadata replacement")
    func reconcileAndNextRetry() {
        var ledger = AttachmentDownloadLedger()
        ledger.recordFailure(for: version, failure: .transient, now: now)
        var card = Card(id: version.identity.cardID)
        card.files = [Attachment(id: version.identity.attachmentID, contentVersion: version.contentVersion,
                                 name: "remote", data: nil)]
        var database = PasswordDatabase()
        database.cards = [card]
        #expect(ledger.nextRetry(in: database, now: now) == now.addingTimeInterval(2))
        database.cards[0].files = [Attachment(id: version.identity.attachmentID, name: "replacement", data: nil)]
        ledger.reconcile(with: database)
        #expect(ledger.records[version] == nil)
        #expect(ledger.nextRetry(in: database, now: now) == nil)
    }

    @Test("An incomplete whole-library request survives restart and releases protection only at completion")
    func persistsWholeLibraryRequest() throws {
        var card = Card()
        card.files = [Attachment(name: "cached", data: Data([1])),
                      Attachment(name: "missing", data: nil)]
        var database = PasswordDatabase()
        database.cards = [card]
        let versions = AttachmentDownloadLedger.versions(in: database)
        var ledger = AttachmentDownloadLedger()
        ledger.recordEviction(of: versions[1])
        ledger.requestAll(in: database)
        ledger.setKeptOffline(true, for: versions[0].identity)
        ledger = try JSONDecoder().decode(AttachmentDownloadLedger.self, from: JSONEncoder().encode(ledger))
        #expect(ledger.downloadAllVersions == Set(versions))
        #expect(ledger.isReady(versions[1], now: now))
        ledger.reconcile(with: database)
        #expect(ledger.downloadAllVersions == Set(versions))
        #expect(RowSync.installDownloadedAttachmentContent(Data([2]), for: versions[1], into: &database))
        ledger.reconcile(with: database)
        #expect(ledger.downloadAllVersions.isEmpty)
        #expect(ledger.offlineAttachments == [versions[0].identity])
    }

    @Test("Ending a whole-library request releases its protection and preserves retention and failures")
    func endsWholeLibraryRequest() {
        var card = Card()
        card.files = [Attachment(name: "missing", data: nil)]
        var database = PasswordDatabase()
        database.cards = [card]
        let version = AttachmentDownloadLedger.versions(in: database)[0]
        var ledger = AttachmentDownloadLedger()
        ledger.requestAll(in: database)
        ledger.setKeptOffline(true, for: version.identity)
        ledger.recordFailure(for: version, failure: .integrity, now: now)
        ledger.cancelDownloadAll()
        #expect(ledger.downloadAllVersions.isEmpty)
        #expect(ledger.offlineAttachments == [version.identity])
        #expect(!ledger.isReady(version, now: now))
    }

    @Test("Malformed and unknown ledger formats are rejected")
    func rejectsCorruption() throws {
        let data = try JSONEncoder().encode(AttachmentDownloadLedger())
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["formatVersion"] = 2
        let unknown = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(AttachmentDownloadLedger.self, from: unknown)
        }
        object["formatVersion"] = 1
        object["records"] = "damaged"
        let damaged = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(AttachmentDownloadLedger.self, from: damaged)
        }
    }

    @Test("Impossible retry counters and schedules cannot silently reset durable policy",
          arguments: ["zeroFailureCount", "missingRetryDate", "permanentRetryDate"])
    func rejectsInvalidRetryState(reason: String) throws {
        var ledger = AttachmentDownloadLedger()
        ledger.recordFailure(for: version, failure: .transient, now: now)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(ledger)) as? [String: Any])
        var entries = try #require(object["records"] as? [Any])
        #expect(entries.count == 2)
        var record = try #require(entries.last as? [String: Any])
        switch reason {
        case "zeroFailureCount": record["failureCount"] = 0
        case "missingRetryDate": record.removeValue(forKey: "retryAt")
        default: record["failure"] = "permanent"
        }
        entries[entries.count - 1] = record
        object["records"] = entries
        let malformed = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(AttachmentDownloadLedger.self, from: malformed)
        }
    }

    @Test("Renaming cannot adopt another database's orphan download policy")
    func rejectsOccupiedLedgerDestination() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("UPWLedgerRename-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DatabaseStore(root: root)
        let key = DatabaseCipher.generateVaultKey()
        try store.commitSyncSnapshot(PasswordDatabase(), name: "Original", vaultKey: key, state: RowSyncState())
        let orphan = Data("preserve-policy".utf8)
        try orphan.write(to: store.attachmentDownloadLedgerURL(for: "Occupied"))
        #expect(throws: (any Error).self) { try store.rename("Original", to: "Occupied") }
        #expect(store.exists("Original"))
        #expect(!store.exists("Occupied"))
        #expect(try Data(contentsOf: store.attachmentDownloadLedgerURL(for: "Occupied")) == orphan)
    }

    @Test("Local policy persists independently of sync snapshots and follows database rename/delete")
    func persistenceLifecycle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("UPWDownloadLedger-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DatabaseStore(root: root)
        let source = "LedgerSource\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let destination = "LedgerDestination\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let key = DatabaseCipher.generateVaultKey()
        let envelope = try DatabaseCipher.wrapVaultKey(key, password: "local-only")
        try store.commitSyncSnapshot(PasswordDatabase(), name: source, vaultKey: key,
                                     state: RowSyncState(), envelope: envelope)
        var ledger = AttachmentDownloadLedger()
        ledger.recordFailure(for: version, failure: .transient, now: now)
        ledger.setKeptOffline(true, for: version.identity)
        try store.saveAttachmentDownloadLedger(ledger, for: source)
        try store.commitSyncSnapshot(PasswordDatabase(), name: source, vaultKey: key, state: RowSyncState())
        #expect(try store.loadAttachmentDownloadLedger(for: source) == ledger)
        #expect(try store.loadAttachmentDownloadLedger(for: "Other") == AttachmentDownloadLedger())
        try store.rename(source, to: destination)
        #expect(try store.loadAttachmentDownloadLedger(for: destination) == ledger)
        #expect(!FileManager.default.fileExists(atPath: store.attachmentDownloadLedgerURL(for: source).path))
        try store.delete(name: destination)
        #expect(!FileManager.default.fileExists(atPath: store.attachmentDownloadLedgerURL(for: destination).path))
    }

    @Test("Corrupt policy is preserved and cannot silently become an empty retry state")
    func preservesCorruptPolicy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("UPWCorruptLedger-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DatabaseStore(root: root)
        let bytes = Data("invalid-policy".utf8)
        try bytes.write(to: store.attachmentDownloadLedgerURL(for: "Source"))
        #expect(throws: (any Error).self) { try store.loadAttachmentDownloadLedger(for: "Source") }
        #expect(try Data(contentsOf: store.attachmentDownloadLedgerURL(for: "Source")) == bytes)
    }

    @Test("Failure classification retries temporary failures and respects permanent boundaries")
    func classifiesFailures() {
        #expect(AttachmentDownloadFailure.classify(RelayClient.RelayError.server(503)).failure == .transient)
        #expect(AttachmentDownloadFailure.classify(RelayClient.RelayError.rateLimited(retryAfter: 90)).minimumDelay == 90)
        #expect(AttachmentDownloadFailure.classify(RelayClient.RelayError.unauthorized).failure == .authorization)
        #expect(AttachmentDownloadFailure.classify(RelayClient.RelayError.attachmentIntegrityFailure).failure == .integrity)
        #expect(AttachmentDownloadFailure.classify(RelayClient.RelayError.attachmentVersionMissing).failure == .unavailable)
        #expect(AttachmentDownloadFailure.classify(RelayClient.RelayError.server(403)).failure == .permanent)
        #expect(AttachmentDownloadFailure.classify(URLError(.timedOut)).failure == .transient)
        #expect(AttachmentDownloadFailure.classify(URLError(.serverCertificateUntrusted)).failure == .permanent)
        #expect(AttachmentDownloadFailure.classify(CocoaError(.fileWriteOutOfSpace)).failure == .storage)
    }
}
