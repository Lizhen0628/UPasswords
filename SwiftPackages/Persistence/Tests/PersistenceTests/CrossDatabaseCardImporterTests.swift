import CryptoKit
import Foundation
import Testing

import UPasswordsCore
@testable import UPasswordsPersistence

@Suite("Selected card imports")
struct CrossDatabaseCardImporterTests {
    private typealias Importer = CrossDatabaseCardImporter
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(_ cards: [Card], labels: [CardLabel] = [], token: UInt8 = 7) -> Importer.SourceSnapshot {
        var database = PasswordDatabase()
        database.cards = cards
        database.labels = labels
        return Importer.SourceSnapshot(database: database, fingerprint: Data(repeating: token, count: 32))
    }

    @Test("Copies complete cards with fresh identities and preserves destination content")
    func copiesCompleteCards() throws {
        let label = CardLabel(name: "Work", color: "blue", type: "web_accounts", pinToTop: true)
        var card = Card(title: "Existing title")
        card.notes = "A private note"
        card.created = 42_000
        card.favorite = true
        card.archived = true
        card.iconData = Data([1, 2, 3])
        card.fields = [Field(name: "Password", type: .password, value: "secret", autofill: .currentPassword,
                             history: [HistoryEntry(value: "older", time: 100)])]
        card.labelIds = [label.id]
        card.images = [Attachment(name: "image.png", data: Data([4, 5]))]
        card.files = [Attachment(name: "empty.txt", data: Data())]
        let source = snapshot([card], labels: [label])
        var destination = PasswordDatabase()
        destination.cards = [Card(id: card.id, title: card.title)]
        destination.labels = [CardLabel(id: label.id, name: "Existing label")]
        var state = RowSyncState()
        state.cursor = 23
        state.revisions[card.id] = 8
        state.dirtyDeletes[UUID()] = 10

        let plan = try Importer.makePlan(from: source, into: destination, syncState: state,
                                         selecting: [card.id], now: now)
        let importedID = try #require(plan.importedCardIDs.first)
        let imported = try #require(plan.database.card(id: importedID))
        let importedLabel = try #require(plan.database.labels.last)
        #expect(importedID != card.id)
        #expect(plan.database.cards.first == destination.cards.first)
        #expect(plan.database.labels.first?.name == "Existing label")
        #expect(imported.labelIds == [importedLabel.id])
        #expect(importedLabel.id != label.id)
        #expect(importedLabel.name == label.name)
        #expect(importedLabel.color == label.color)
        #expect(importedLabel.type == label.type)
        #expect(importedLabel.pinToTop)
        #expect(imported.fields.first?.id != card.fields.first?.id)
        #expect(imported.fields.first?.history == card.fields.first?.history)
        #expect(imported.fields.first?.value == card.fields.first?.value)
        #expect(imported.fields.first?.autofill == .currentPassword)
        #expect(imported.images.first?.id != card.images.first?.id)
        #expect(imported.images.first?.contentVersion != card.images.first?.contentVersion)
        #expect(imported.images.first?.data == card.images.first?.data)
        #expect(imported.files.first?.id != card.files.first?.id)
        #expect(imported.files.first?.data == Data())
        #expect(imported.notes == card.notes)
        #expect(imported.iconData == card.iconData)
        #expect(imported.favorite && imported.archived)
        #expect(imported.created == card.created)
        #expect(imported.modified == now.timeIntervalSince1970 * 1000)
        #expect(plan.syncState.cursor == state.cursor)
        #expect(plan.syncState.revisions == state.revisions)
        #expect(plan.syncState.dirtyDeletes == state.dirtyDeletes)
        #expect(plan.syncState.dirtyUpserts[importedID] == imported.modified)
        #expect(plan.syncState.dirtyUpserts[importedLabel.id] == importedLabel.timeStamp)
        #expect(plan.syncState.importedSourceKeys.count == 1)
        #expect(plan.createdLabelCount == 1)
        #expect(source.database.cards == [card])
        #expect(destination.cards.count == 1)
        #expect(state.importedSourceKeys.isEmpty)
    }

    @Test("Selected cards preserve source order and share a remapped source label")
    func preservesOrderAndSharedLabels() throws {
        let label = CardLabel(name: "Shared")
        var first = Card(title: "First")
        first.labelIds = [label.id]
        var second = Card(title: "Second")
        second.labelIds = [label.id]
        let source = snapshot([first, Card(title: "Unselected"), second], labels: [label])
        let plan = try Importer.makePlan(from: source, into: PasswordDatabase(), syncState: RowSyncState(),
                                         selecting: [second.id, first.id], now: now)
        #expect(plan.database.cards.map(\.title) == [first.title, second.title])
        #expect(plan.database.cards[0].labelIds == plan.database.cards[1].labelIds)
        #expect(plan.database.labels.count == 1)
        #expect(plan.createdLabelCount == 1)
    }

    @Test("Retrying the same reviewed snapshot does not append cards or labels")
    func retriesAreIdempotent() throws {
        let card = Card(title: "Selected")
        let source = snapshot([card])
        let first = try Importer.makePlan(from: source, into: PasswordDatabase(), syncState: RowSyncState(),
                                          selecting: [card.id], now: now)
        let persisted = try JSONDecoder().decode(RowSyncState.self, from: JSONEncoder().encode(first.syncState))
        let retry = try Importer.makePlan(from: source, into: first.database, syncState: persisted,
                                          selecting: [card.id], now: now)
        #expect(retry.database == first.database)
        #expect(retry.syncState == first.syncState)
        #expect(retry.importedCardIDs.isEmpty)
        #expect(retry.createdLabelCount == 0)
        #expect(retry.alreadyImportedCount == 1)
        let assessment = try #require(Importer.assess(source: source, syncState: persisted).first)
        #expect(assessment.rejections == [.alreadyImported])
    }

    @Test("An expanded selection skips receipts while importing newly selected cards")
    func expandedSelection() throws {
        let first = Card(title: "First")
        let second = Card(title: "Second")
        let source = snapshot([first, second])
        let initial = try Importer.makePlan(from: source, into: PasswordDatabase(), syncState: RowSyncState(),
                                            selecting: [first.id], now: now)
        let expanded = try Importer.makePlan(from: source, into: initial.database, syncState: initial.syncState,
                                             selecting: [first.id, second.id], now: now)
        #expect(expanded.database.cards.map(\.title) == [first.title, second.title])
        #expect(expanded.alreadyImportedCount == 1)
        #expect(expanded.importedCardIDs.count == 1)
    }

    @Test("Preflight explains incomplete, oversized, deleted, and template cards")
    func rejectsIneligibleCards() throws {
        var missing = Card(title: "Missing")
        missing.labelIds = [UUID()]
        missing.files = [Attachment(name: "remote", data: nil)]
        var oversized = Card(title: "Oversized")
        oversized.images = [Attachment(name: "large", data: Data(
            repeating: 1, count: Importer.maximumAttachmentBytes + 1))]
        var template = Card(title: "Template")
        template.template = true
        var trashed = Card(title: "Deleted")
        trashed.trashed = true
        let ready = Card(title: "Ready")
        let source = snapshot([missing, oversized, template, trashed, ready])
        let assessed = try Importer.assess(source: source, syncState: RowSyncState())
        #expect(assessed[0].rejections == [.missingLabel, .unavailableAttachment])
        #expect(assessed[1].rejections == [.attachmentTooLarge])
        #expect(assessed[2].rejections == [.template])
        #expect(assessed[3].rejections == [.trashed])
        #expect(assessed[4].isEligible)
        #expect(throws: Importer.ImportError.selectionBlocked) {
            try Importer.makePlan(from: source, into: PasswordDatabase(), syncState: RowSyncState(),
                                  selecting: [missing.id, ready.id])
        }
        let plan = try Importer.makePlan(from: source, into: PasswordDatabase(), syncState: RowSyncState(),
                                         selecting: [ready.id])
        #expect(plan.database.cards.map(\.title) == [ready.title])
    }

    @Test("The exact 20 MiB boundary is allowed and empty files remain present")
    func permitsAttachmentBoundaries() throws {
        var card = Card(title: "Boundary")
        card.files = [Attachment(name: "boundary", data: Data(
            repeating: 1, count: Importer.maximumAttachmentBytes)), Attachment(name: "empty", data: Data())]
        let source = snapshot([card])
        let plan = try Importer.makePlan(from: source, into: PasswordDatabase(), syncState: RowSyncState(),
                                         selecting: [card.id])
        #expect(plan.database.cards.first?.files.map(\.length) == [Importer.maximumAttachmentBytes, 0])
        #expect(plan.database.cards.first?.files.allSatisfy(\.hasContent) == true)
    }

    @Test("A remote attachment must be materialized before a card can be copied")
    func rejectsUnmaterializedAttachment() throws {
        var card = Card(title: "Remote attachment")
        card.images = [Attachment(name: "remote.png", data: nil)]
        let source = snapshot([card])

        #expect(throws: Importer.ImportError.selectionBlocked) {
            try Importer.makePlan(
                from: source,
                into: PasswordDatabase(),
                syncState: RowSyncState(),
                selecting: [card.id])
        }
    }

    @Test("Empty, stale, and ambiguous selections fail before any commit")
    func validatesSelectionAndIdentities() throws {
        let card = Card(title: "Source")
        let source = snapshot([card])
        #expect(throws: Importer.ImportError.noSelection) {
            try Importer.makePlan(from: source, into: PasswordDatabase(), syncState: RowSyncState(), selecting: [])
        }
        #expect(throws: Importer.ImportError.selectionChanged) {
            try Importer.makePlan(from: source, into: PasswordDatabase(), syncState: RowSyncState(), selecting: [UUID()])
        }
        for invalid in [snapshot([card, card]),
                        snapshot([card], labels: [CardLabel(id: card.id, name: "Duplicate row")]),
                        Importer.SourceSnapshot(database: source.database, fingerprint: Data())] {
            #expect(throws: Importer.ImportError.invalidSourceSnapshot) {
                try Importer.assess(source: invalid, syncState: RowSyncState())
            }
        }
    }

    @Test("A changed encrypted source must be reviewed again")
    func revalidatesEncryptedSource() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("UPWImport-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DatabaseStore(root: root)
        let key = DatabaseCipher.generateVaultKey()
        let envelope = try DatabaseCipher.wrapVaultKey(key, password: "source-password")
        var database = PasswordDatabase()
        database.cards = [Card(title: "Source")]
        try store.commitSyncSnapshot(database, name: "Source", vaultKey: key, state: RowSyncState(), envelope: envelope)
        let reviewed = try store.loadCardImportSource(name: "Source", password: "source-password")
        #expect(reviewed.database == database)
        let encryptedBody = try Data(contentsOf: store.url(for: "Source"))
        #expect(reviewed.fingerprint == Data(SHA256.hash(data: encryptedBody)))
        #expect(throws: (any Error).self) {
            try store.loadCardImportSource(name: "Source", password: "wrong")
        }
        database.cards[0].title = "Changed"
        try store.save(database, name: "Source", vaultKey: key)
        #expect(throws: Importer.ImportError.selectionChanged) {
            try store.loadCardImportSource(name: "Source", password: "source-password", matching: reviewed.fingerprint)
        }
        #expect(try store.load(name: "Source", password: "source-password").cards[0].title == "Changed")
    }

    @Test("Import commit recovery keeps cards and retry receipts in the same generation")
    func recoversImportCommit() throws {
        enum Interruption: Error { case interrupted }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("UPWImportCommit-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DatabaseStore(root: root)
        let key = DatabaseCipher.generateVaultKey()
        let envelope = try DatabaseCipher.wrapVaultKey(key, password: "destination-password")
        try store.commitSyncSnapshot(PasswordDatabase(), name: "Destination", vaultKey: key,
                                     state: RowSyncState(), envelope: envelope)
        let card = Card(title: "Selected")
        let source = snapshot([card])
        let plan = try Importer.makePlan(from: source, into: PasswordDatabase(), syncState: RowSyncState(),
                                         selecting: [card.id], now: now)
        store.transactionFaultInjector = { if $0 == "body" { throw Interruption.interrupted } }
        #expect(throws: Interruption.self) {
            try store.commitSyncSnapshot(plan.database, name: "Destination", vaultKey: key, state: plan.syncState)
        }
        let restarted = DatabaseStore(root: root)
        let committedState = try restarted.loadSyncState(for: "Destination")
        let committed = try restarted.load(name: "Destination", password: "destination-password")
        #expect(committedState == plan.syncState)
        #expect(committed == plan.database)
        let retry = try Importer.makePlan(from: source, into: committed, syncState: committedState,
                                          selecting: [card.id], now: now)
        #expect(retry.importedCardIDs.isEmpty)
        #expect(retry.alreadyImportedCount == 1)
    }
}
