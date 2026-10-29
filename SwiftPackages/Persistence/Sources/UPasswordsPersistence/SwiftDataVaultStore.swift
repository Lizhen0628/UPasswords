import CryptoKit
import Foundation
import SwiftData

import UPasswordsCore

/// A local encrypted vault row. The field names intentionally mirror the
/// cloud business table; `body` remains client-side ciphertext.
@Model
public final class LocalVaultRecord {
    @Attribute(.unique) public var vaultID: String
    @Attribute(.unique) public var name: String
    public var passwordVersion: Int64
    public var passwordChangedMS: Int64
    public var envelopeEnc: Data
    public var createdMS: Int64
    public var updatedMS: Int64

    public init(
        vaultID: String,
        name: String,
        passwordVersion: Int64 = 1,
        passwordChangedMS: Int64,
        envelopeEnc: Data,
        createdMS: Int64,
        updatedMS: Int64
    ) {
        self.vaultID = vaultID
        self.name = name
        self.passwordVersion = passwordVersion
        self.passwordChangedMS = passwordChangedMS
        self.envelopeEnc = envelopeEnc
        self.createdMS = createdMS
        self.updatedMS = updatedMS
    }
}

/// Encrypted card or label row matching the cloud `vault_items` business table.
@Model
public final class LocalVaultItemRecord {
    @Attribute(.unique) public var rowKey: String
    public var vaultID: String
    public var itemUUID: String
    public var kind: Int16
    public var revision: Int64
    public var body: Data
    public var bodySHA256: String
    public var bodyBytes: Int64
    public var modifiedMS: Int64
    public var createdMS: Int64
    public var updatedMS: Int64
    public var originSessionID: String?
    public var originDeviceName: String
    public var originPlatform: String

    public init(
        vaultID: String,
        itemUUID: String,
        kind: Int16,
        revision: Int64,
        body: Data,
        bodySHA256: String,
        bodyBytes: Int64,
        modifiedMS: Int64,
        createdMS: Int64,
        updatedMS: Int64,
        originSessionID: String? = nil,
        originDeviceName: String = "",
        originPlatform: String = "other"
    ) {
        self.rowKey = "\(vaultID):\(itemUUID.lowercased())"
        self.vaultID = vaultID
        self.itemUUID = itemUUID.lowercased()
        self.kind = kind
        self.revision = revision
        self.body = body
        self.bodySHA256 = bodySHA256
        self.bodyBytes = bodyBytes
        self.modifiedMS = modifiedMS
        self.createdMS = createdMS
        self.updatedMS = updatedMS
        self.originSessionID = originSessionID
        self.originDeviceName = originDeviceName
        self.originPlatform = originPlatform
    }
}

/// Local copy of the cloud attachment metadata table. Attachment bytes are
/// stored separately as encrypted cache records, so metadata survives cache
/// eviction and can still participate in version comparison.
@Model
public final class LocalAttachmentRecord {
    @Attribute(.unique) public var attachmentKey: String
    public var vaultID: String
    public var attachUUID: String
    public var cardUUID: String
    public var contentVersion: String
    public var objectKey: String
    public var dekWrapped: Data
    public var sha256: String
    public var bytes: Int64
    public var createdMS: Int64
    public var retiredMS: Int64?
    public var unreferencedMS: Int64?
    public var purgeStartedMS: Int64?

    public init(
        vaultID: String,
        attachUUID: String,
        cardUUID: String,
        contentVersion: String,
        objectKey: String = "",
        dekWrapped: Data = Data(),
        sha256: String,
        bytes: Int64,
        createdMS: Int64,
        retiredMS: Int64? = nil,
        unreferencedMS: Int64? = nil,
        purgeStartedMS: Int64? = nil
    ) {
        self.attachmentKey = "\(vaultID):\(attachUUID.lowercased()):\(contentVersion.lowercased())"
        self.vaultID = vaultID
        self.attachUUID = attachUUID.lowercased()
        self.cardUUID = cardUUID.lowercased()
        self.contentVersion = contentVersion.lowercased()
        self.objectKey = objectKey
        self.dekWrapped = dekWrapped
        self.sha256 = sha256
        self.bytes = bytes
        self.createdMS = createdMS
        self.retiredMS = retiredMS
        self.unreferencedMS = unreferencedMS
        self.purgeStartedMS = purgeStartedMS
    }
}

/// Encrypted local attachment bytes. It is intentionally not part of the
/// shared cloud business schema because it is a device cache.
@Model
public final class LocalAttachmentContentRecord {
    @Attribute(.unique) public var contentKey: String
    public var vaultID: String
    public var attachUUID: String
    public var contentVersion: String
    public var cipher: Data
    public var updatedMS: Int64

    public init(
        vaultID: String,
        attachUUID: String,
        contentVersion: String,
        cipher: Data,
        updatedMS: Int64
    ) {
        self.contentKey = "\(vaultID):\(attachUUID.lowercased()):\(contentVersion.lowercased())"
        self.vaultID = vaultID
        self.attachUUID = attachUUID.lowercased()
        self.contentVersion = contentVersion.lowercased()
        self.cipher = cipher
        self.updatedMS = updatedMS
    }
}

/// SwiftData-backed native store used by macOS, iOS, and the App Group.
/// Every business payload is encrypted before it reaches SQLite.
public final class SwiftDataVaultStore {
    public let container: ModelContainer
    private let context: ModelContext

    public init(root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let configuration = ModelConfiguration(
            "UPasswordsNativeVault",
            schema: Schema([
                LocalVaultRecord.self,
                LocalVaultItemRecord.self,
                LocalVaultProfileRecord.self,
                LocalAttachmentRecord.self,
                LocalAttachmentContentRecord.self
            ]),
            url: root.appendingPathComponent("UPasswordsNativeVault.store"),
            cloudKitDatabase: .none
        )
        container = try ModelContainer(
            for: LocalVaultRecord.self,
            LocalVaultItemRecord.self,
            LocalVaultProfileRecord.self,
            LocalAttachmentRecord.self,
            LocalAttachmentContentRecord.self,
            configurations: configuration
        )
        context = ModelContext(container)
        context.autosaveEnabled = false
        try migrateProfileRows()
    }

    /// Returns whether a migrated local vault exists without attempting to unlock it.
    public func containsVault(name: String) throws -> Bool {
        try fetchVault(name: name) != nil
    }

    /// Deletes one local vault and all of its business rows and attachment cache.
    ///
    /// This only removes the local SwiftData copy. The legacy file store and any
    /// cloud vault are owned by their callers and are not changed here.
    public func deleteVault(name: String) throws {
        guard let vault = try fetchVault(name: name) else { return }
        let vaultID = vault.vaultID
        try fetchItems(vaultID: vaultID).forEach(context.delete)
        try fetchProfiles(vaultID: vaultID).forEach(context.delete)
        try fetchAttachments(vaultID: vaultID).forEach(context.delete)
        try fetchContents(vaultID: vaultID).forEach(context.delete)
        context.delete(vault)
        try context.save()
        Log.info("db", "deleted SwiftData vault \"\(name)\"")
    }

    /// Deletes every local SwiftData vault, including orphaned migration rows.
    public func deleteAllVaults() throws {
        try context.fetch(FetchDescriptor<LocalVaultItemRecord>()).forEach(context.delete)
        try context.fetch(FetchDescriptor<LocalVaultProfileRecord>()).forEach(context.delete)
        try context.fetch(FetchDescriptor<LocalAttachmentRecord>()).forEach(context.delete)
        try context.fetch(FetchDescriptor<LocalAttachmentContentRecord>()).forEach(context.delete)
        try context.fetch(FetchDescriptor<LocalVaultRecord>()).forEach(context.delete)
        try context.save()
        Log.info("db", "deleted all SwiftData vaults")
    }

    /// Renames a local vault without changing its encrypted business rows.
    public func renameVault(from oldName: String, to newName: String) throws {
        guard oldName != newName else { return }
        guard let vault = try fetchVault(name: oldName) else {
            throw DatabaseStore.StoreError(L10n.t("database_not_found_error"))
        }
        guard try fetchVault(name: newName) == nil else {
            throw DatabaseStore.StoreError(L10n.t("database_already_exists_error"))
        }
        vault.name = newName
        try context.save()
        Log.info("db", "renamed SwiftData vault \"\(oldName)\" → \"\(newName)\"")
    }

    /// Removes cached ciphertext for an explicitly evicted attachment version.
    public func evictAttachmentContent(
        vaultName: String,
        attachmentID: UUID,
        contentVersion: UUID
    ) throws {
        guard let vault = try fetchVault(name: vaultName) else { return }
        let contentKey = "\(vault.vaultID):\(attachmentID.uuidString.lowercased()):\(contentVersion.uuidString.lowercased())"
        guard let content = try fetchContents(vaultID: vault.vaultID)
            .first(where: { $0.contentKey == contentKey }) else { return }
        context.delete(content)
        try context.save()
        Log.info("db", "evicted SwiftData attachment content id=\(attachmentID.uuidString.prefix(8))…")
    }

    /// Imports an existing encrypted `.upw` database exactly once.
    /// The legacy files are never removed; they remain the rollback source.
    @discardableResult
    public func importLegacyIfNeeded(
        name: String,
        password: String,
        legacyStore: DatabaseStore
    ) throws -> Bool {
        let existing = try fetchVault(name: name)
        guard existing == nil else { return false }
        let (database, key) = try legacyStore.loadUnlocked(name: name, password: password)
        let envelope = try Data(contentsOf: legacyStore.keyURL(for: name))
        try replace(database, name: name, envelope: envelope, vaultKey: key, passwordVersion: 1)
        Log.info("db", "imported legacy vault \"\(name)\" into SwiftData")
        return true
    }

    /// Loads and decrypts the local row tables using the supplied master password.
    public func loadUnlocked(
        name: String,
        password: String
    ) throws -> (PasswordDatabase, SymmetricKey) {
        guard let vault = try fetchVault(name: name) else {
            throw DatabaseStore.StoreError(L10n.t("database_not_found_error"))
        }
        let key = try DatabaseCipher.unwrapVaultKey(vault.envelopeEnc, password: password)
        let rows = try fetchItems(vaultID: vault.vaultID)
        let profileRows = try fetchProfiles(vaultID: vault.vaultID)
        var database = PasswordDatabase()
        let encryptedRows = rows.map { ($0.itemUUID, $0.kind, $0.body) }
            + profileRows.map { ($0.itemUUID, $0.kind, $0.body) }
        for (itemUUID, kind, body) in encryptedRows {
            guard let uuid = UUID(uuidString: itemUUID),
                  let plaintext = RowSyncCipher.decrypt(
                    body,
                    key: RowSyncKey(raw: key.withUnsafeBytes { Data($0) }),
                    uuid: uuid
                  ),
                  let item = DatabaseItemCodec.parse(
                    kind: UInt8(kind), uuid: uuid, data: plaintext
                  ) else {
                throw DatabaseStore.StoreError(L10n.t("database_corrupt_error"))
            }
            apply(item, to: &database)
        }
        try hydrateAttachmentContent(in: &database, vaultID: vault.vaultID, key: key)
        return (database, key)
    }

    /// Replaces one local vault in a single SwiftData transaction.
    public func replace(
        _ database: PasswordDatabase,
        name: String,
        vaultKey: SymmetricKey,
        passwordVersion: Int64? = nil,
        revisions: [UUID: UInt64] = [:],
        previousVaultKey: SymmetricKey? = nil
    ) throws {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let vaultID = (try fetchVault(name: name))?.vaultID ?? UUID().uuidString.lowercased()
        let envelope: Data
        if let current = try fetchVault(name: name) {
            envelope = current.envelopeEnc
        } else {
            throw DatabaseStore.StoreError(L10n.t("envelope_missing_error"))
        }
        try replace(
            database,
            name: name,
            vaultID: vaultID,
            envelope: envelope,
            vaultKey: vaultKey,
            passwordVersion: passwordVersion,
            revisions: revisions,
            previousVaultKey: previousVaultKey,
            now: now
        )
    }

    /// Creates or replaces the local record while retaining the encrypted envelope.
    public func replace(
        _ database: PasswordDatabase,
        name: String,
        envelope: Data,
        vaultKey: SymmetricKey,
        passwordVersion: Int64? = nil,
        revisions: [UUID: UInt64] = [:],
        previousVaultKey: SymmetricKey? = nil
    ) throws {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let vaultID = (try fetchVault(name: name))?.vaultID ?? UUID().uuidString.lowercased()
        try replace(
            database,
            name: name,
            vaultID: vaultID,
            envelope: envelope,
            vaultKey: vaultKey,
            passwordVersion: passwordVersion,
            revisions: revisions,
            previousVaultKey: previousVaultKey,
            now: now
        )
    }

    private func replace(
        _ database: PasswordDatabase,
        name: String,
        vaultID: String,
        envelope: Data,
        vaultKey: SymmetricKey,
        passwordVersion: Int64?,
        revisions: [UUID: UInt64],
        previousVaultKey: SymmetricKey?,
        now: Int64
    ) throws {
        let rowKey = RowSyncKey(raw: vaultKey.withUnsafeBytes { Data($0) })
        let existingRows = try fetchItems(vaultID: vaultID)
        let rowsByKey = Dictionary(uniqueKeysWithValues: existingRows.map { ($0.rowKey, $0) })
        let existingProfiles = try fetchProfiles(vaultID: vaultID)
        let profilesByKey = Dictionary(uniqueKeysWithValues: existingProfiles.map { ($0.rowKey, $0) })
        let existingAttachments = try fetchAttachments(vaultID: vaultID)
        let attachmentsByKey = Dictionary(uniqueKeysWithValues: existingAttachments.map { ($0.attachmentKey, $0) })
        let existingContents = try fetchContents(vaultID: vaultID)
        let contentsByKey = Dictionary(uniqueKeysWithValues: existingContents.map { ($0.contentKey, $0) })
        let vault = try fetchVault(name: name) ?? LocalVaultRecord(
            vaultID: vaultID,
            name: name,
            passwordVersion: passwordVersion ?? 1,
            passwordChangedMS: now,
            envelopeEnc: envelope,
            createdMS: now,
            updatedMS: now
        )
        let envelopeChanged = vault.envelopeEnc != envelope
        vault.vaultID = vaultID
        vault.name = name
        vault.passwordVersion = passwordVersion ?? (envelopeChanged ? vault.passwordVersion + 1 : vault.passwordVersion)
        vault.envelopeEnc = envelope
        if envelopeChanged { vault.passwordChangedMS = now }
        vault.updatedMS = now
        if vault.modelContext == nil { context.insert(vault) }
        if let previousVaultKey, previousVaultKey != vaultKey {
            let oldKey = RowSyncKey(raw: previousVaultKey.withUnsafeBytes { Data($0) })
            for attachment in existingAttachments where !attachment.dekWrapped.isEmpty {
                guard let attachmentID = UUID(uuidString: attachment.attachUUID),
                      let version = UUID(uuidString: attachment.contentVersion) else {
                    throw DatabaseStore.StoreError(L10n.t("database_corrupt_error"))
                }
                attachment.dekWrapped = try AttachmentSyncCipher.rewrap(
                    attachment.dekWrapped,
                    oldKey: oldKey,
                    newKey: rowKey,
                    attachmentID: attachmentID,
                    contentVersion: version
                )
            }
        }
        var retainedRowKeys = Set<String>()
        var retainedProfileKeys = Set<String>()
        var activeAttachmentKeys = Set<String>()
        for item in RowSync.allItems(database: database) {
            let plaintext = DatabaseItemCodec.xmlData(item)
            let body = try RowSyncCipher.encrypt(plaintext, key: rowKey, uuid: item.uuid)
            let itemKey = "\(vaultID):\(item.uuid.uuidString.lowercased())"
            if case .userProfile = item {
                retainedProfileKeys.insert(itemKey)
                let prior = profilesByKey[itemKey]
                let revision = revisions[item.uuid].map(Int64.init) ?? max(1, prior?.revision ?? 1)
                let row = profilesByKey[itemKey] ?? LocalVaultProfileRecord(
                    vaultID: vaultID,
                    itemUUID: item.uuid.uuidString,
                    revision: revision,
                    body: body,
                    bodySHA256: SyncConflict.sha256Hex(body),
                    bodyBytes: Int64(body.count),
                    modifiedMS: Int64(item.modifiedMs),
                    createdMS: now,
                    updatedMS: now
                )
                row.revision = revision
                row.body = body
                row.bodySHA256 = SyncConflict.sha256Hex(body)
                row.bodyBytes = Int64(body.count)
                row.modifiedMS = Int64(item.modifiedMs)
                row.updatedMS = now
                if row.modelContext == nil { context.insert(row) }
            } else {
                retainedRowKeys.insert(itemKey)
                let prior = rowsByKey[itemKey]
                let revision = revisions[item.uuid].map(Int64.init) ?? max(1, prior?.revision ?? 1)
                let row = rowsByKey[itemKey] ?? LocalVaultItemRecord(
                    vaultID: vaultID,
                    itemUUID: item.uuid.uuidString,
                    kind: Int16(item.syncKind),
                    revision: revision,
                    body: body,
                    bodySHA256: SyncConflict.sha256Hex(body),
                    bodyBytes: Int64(body.count),
                    modifiedMS: Int64(item.modifiedMs),
                    createdMS: now,
                    updatedMS: now
                )
                row.kind = Int16(item.syncKind)
                row.revision = revision
                row.body = body
                row.bodySHA256 = SyncConflict.sha256Hex(body)
                row.bodyBytes = Int64(body.count)
                row.modifiedMS = Int64(item.modifiedMs)
                row.updatedMS = now
                if row.modelContext == nil { context.insert(row) }
            }
            try persistAttachments(
                from: item,
                vaultID: vaultID,
                key: rowKey,
                now: now,
                attachmentsByKey: attachmentsByKey,
                contentsByKey: contentsByKey,
                activeKeys: &activeAttachmentKeys
            )
        }
        for row in existingRows where !retainedRowKeys.contains(row.rowKey) { context.delete(row) }
        for row in existingProfiles where !retainedProfileKeys.contains(row.rowKey) { context.delete(row) }
        for attachment in existingAttachments where !activeAttachmentKeys.contains(attachment.attachmentKey) {
            if attachment.retiredMS == nil { attachment.retiredMS = now }
            if attachment.unreferencedMS == nil { attachment.unreferencedMS = now }
        }
        try context.save()
    }

    private func persistAttachments(
        from item: DatabaseItem,
        vaultID: String,
        key: RowSyncKey,
        now: Int64,
        attachmentsByKey: [String: LocalAttachmentRecord],
        contentsByKey: [String: LocalAttachmentContentRecord],
        activeKeys: inout Set<String>
    ) throws {
        guard case .card(let card) = item else { return }
        for attachment in card.images + card.files where attachment.hasPersistentID && attachment.hasPersistentContentVersion {
            let contentKey = encryptedContentKey(
                vaultID: vaultID,
                attachmentID: attachment.id,
                contentVersion: attachment.contentVersion
            )
            activeKeys.insert(contentKey)
            let encrypted: EncryptedAttachment?
            if let data = attachment.data {
                encrypted = try AttachmentSyncCipher.encrypt(
                    data: data,
                    key: key,
                    attachmentID: attachment.id,
                    contentVersion: attachment.contentVersion
                )
            } else {
                encrypted = nil
            }
            let record = attachmentsByKey[contentKey] ?? LocalAttachmentRecord(
                vaultID: vaultID,
                attachUUID: attachment.id.uuidString,
                cardUUID: card.id.uuidString,
                contentVersion: attachment.contentVersion.uuidString,
                dekWrapped: encrypted?.dekWrapped ?? Data(),
                sha256: encrypted.map { SyncConflict.sha256Hex($0.cipher) } ?? "",
                bytes: Int64(attachment.data?.count ?? 0),
                createdMS: now
            )
            record.cardUUID = card.id.uuidString.lowercased()
            if let encrypted {
                record.dekWrapped = encrypted.dekWrapped
                record.sha256 = SyncConflict.sha256Hex(encrypted.cipher)
                record.bytes = Int64(attachment.data?.count ?? 0)
                record.retiredMS = nil
                record.unreferencedMS = nil
                record.purgeStartedMS = nil
                let content = contentsByKey[contentKey] ?? LocalAttachmentContentRecord(
                    vaultID: vaultID,
                    attachUUID: attachment.id.uuidString,
                    contentVersion: attachment.contentVersion.uuidString,
                    cipher: encrypted.cipher,
                    updatedMS: now
                )
                content.cipher = encrypted.cipher
                content.updatedMS = now
                if content.modelContext == nil { context.insert(content) }
            }
            if record.modelContext == nil { context.insert(record) }
        }
    }

    private func encryptedContentKey(vaultID: String, attachmentID: UUID, contentVersion: UUID) -> String {
        "\(vaultID):\(attachmentID.uuidString.lowercased()):\(contentVersion.uuidString.lowercased())"
    }

    private func hydrateAttachmentContent(
        in database: inout PasswordDatabase,
        vaultID: String,
        key: SymmetricKey
    ) throws {
        let rowKey = RowSyncKey(raw: key.withUnsafeBytes { Data($0) })
        let records = try fetchAttachments(vaultID: vaultID)
        let contents = try fetchContents(vaultID: vaultID)
        let contentByKey = Dictionary(uniqueKeysWithValues: contents.map { ($0.contentKey, $0) })
        for cardIndex in database.cards.indices {
            for attachmentIndex in database.cards[cardIndex].images.indices {
                try hydrate(
                    &database.cards[cardIndex].images[attachmentIndex],
                    cardID: database.cards[cardIndex].id,
                    records: records,
                    contentByKey: contentByKey,
                    key: rowKey
                )
            }
            for attachmentIndex in database.cards[cardIndex].files.indices {
                try hydrate(
                    &database.cards[cardIndex].files[attachmentIndex],
                    cardID: database.cards[cardIndex].id,
                    records: records,
                    contentByKey: contentByKey,
                    key: rowKey
                )
            }
        }
    }

    private func hydrate(
        _ attachment: inout Attachment,
        cardID: UUID,
        records: [LocalAttachmentRecord],
        contentByKey: [String: LocalAttachmentContentRecord],
        key: RowSyncKey
    ) throws {
        guard let record = records.first(where: {
            $0.attachUUID.caseInsensitiveCompare(attachment.id.uuidString) == .orderedSame
                && $0.cardUUID.caseInsensitiveCompare(cardID.uuidString) == .orderedSame
                && $0.contentVersion.caseInsensitiveCompare(attachment.contentVersion.uuidString) == .orderedSame
        }), let content = contentByKey[record.attachmentKey] else { return }
        let data = try AttachmentSyncCipher.decrypt(
            cipher: content.cipher,
            dekWrapped: record.dekWrapped,
            key: key,
            attachmentID: attachment.id,
            contentVersion: attachment.contentVersion
        )
        _ = attachment.installDownloadedContent(data, for: attachment.contentVersion)
    }

    private func fetchVault(name: String) throws -> LocalVaultRecord? {
        try context.fetch(FetchDescriptor<LocalVaultRecord>(predicate: #Predicate { $0.name == name })).first
    }

    private func fetchItems(vaultID: String) throws -> [LocalVaultItemRecord] {
        try context.fetch(FetchDescriptor<LocalVaultItemRecord>(predicate: #Predicate { $0.vaultID == vaultID }))
    }

    private func fetchProfiles(vaultID: String) throws -> [LocalVaultProfileRecord] {
        try context.fetch(FetchDescriptor<LocalVaultProfileRecord>(predicate: #Predicate { $0.vaultID == vaultID }))
    }

    private func migrateProfileRows() throws {
        let legacyRows = try context.fetch(FetchDescriptor<LocalVaultItemRecord>())
            .filter { $0.kind == 3 }
        guard !legacyRows.isEmpty else { return }

        let existingProfiles = try context.fetch(FetchDescriptor<LocalVaultProfileRecord>())
        let profilesByKey = Dictionary(uniqueKeysWithValues: existingProfiles.map { ($0.rowKey, $0) })
        for legacy in legacyRows {
            if profilesByKey[legacy.rowKey] == nil {
                context.insert(LocalVaultProfileRecord(
                    vaultID: legacy.vaultID,
                    itemUUID: legacy.itemUUID,
                    revision: legacy.revision,
                    body: legacy.body,
                    bodySHA256: legacy.bodySHA256,
                    bodyBytes: legacy.bodyBytes,
                    modifiedMS: legacy.modifiedMS,
                    createdMS: legacy.createdMS,
                    updatedMS: legacy.updatedMS,
                    originSessionID: legacy.originSessionID,
                    originDeviceName: legacy.originDeviceName,
                    originPlatform: legacy.originPlatform
                ))
            }
            context.delete(legacy)
        }
        try context.save()
        Log.info("db", "migrated \(legacyRows.count) profile rows to the dedicated SwiftData table")
    }

    private func fetchAttachments(vaultID: String) throws -> [LocalAttachmentRecord] {
        try context.fetch(FetchDescriptor<LocalAttachmentRecord>(predicate: #Predicate { $0.vaultID == vaultID }))
    }

    private func fetchContents(vaultID: String) throws -> [LocalAttachmentContentRecord] {
        try context.fetch(FetchDescriptor<LocalAttachmentContentRecord>(predicate: #Predicate { $0.vaultID == vaultID }))
    }

    private func apply(_ item: DatabaseItem, to database: inout PasswordDatabase) {
        switch item {
        case .card(let card): database.cards.append(card)
        case .label(let label): database.labels.append(label)
        case .userProfile(let profile): database.userProfiles.append(profile)
        }
    }
}
