import CryptoKit
import Foundation
import UPasswordsCore

// MARK: - RowSync 引擎
//
// 职责:脏集合上行(批量 CAS + 冲突合并重试)、变更游标增量应用、
// 全量重建(快照+差量)、改密 rekey 编排。`.upw` 永远是唯一本地真源,
// 本引擎只做增量收敛,任何失败都不阻塞本地使用(Cloud/DESIGN.md §6)。
//
// 条目体加密:AES-GCM(VEK),AAD 绑定条目 uuid(行搬运防护,§3.1);
// 密文布局 = nonce(12) + ct + tag(16)。
// 隐私边界:引擎在内存中编解码明文条目;日志只记计数、身份、耗时与结果。

/// 增量/重建结果(供 UI 呈现同步状态)。
public struct RowSyncOutcome: Equatable {
    /// 实际改变本地内容的下行条目数，排除已知版本的回声。
    public var pulledItems = 0
    /// 本轮服务端确认成功的上行操作数。
    public var pushedItems = 0
    /// 本轮已收敛的冲突或远端删除数。
    public var conflictsResolved = 0
    /// 本轮隔离的单条异常云端记录数。
    public var quarantinedItems = 0
    /// 是否应先提交隔离检查点，再发起下一轮拉取。
    public var requiresFollowUpSync = false
    /// 本轮获知的服务端变更高水位。
    public var headSeq = 0
    /// 创建全部统计为零的同步结果。
    public init() {}
}

/// 对端改密信号:password_version 前进,本端旧 VEK 将解不开新密文,
/// 调用方应强制锁定并引导用户输入新密码后走全量重建(§6.5 步骤 5)。
public struct RowSyncRekeySignal: Error, Equatable {
    /// 触发重新解锁的远端密码版本。
    public let passwordVersion: Int
    /// 创建需要重新解锁的远端改密信号。
    ///
    /// - Parameter passwordVersion: 服务端最新密码版本。
    public init(passwordVersion: Int) {
        self.passwordVersion = passwordVersion
    }
}

/// 对称密钥的值语义包装(VEK 原料;避免 CryptoKit 类型穿透公共 API)。
public struct RowSyncKey: Equatable {
    let raw: Data

    /// - Parameter raw: 32 字节 VEK 原料(长度由调用方逻辑保证)
    public init(raw: Data) {
        self.raw = raw
    }
}

/// 同步条目的 AES-GCM 编解码，使用 UUID 字符串绑定认证附加数据。
public enum RowSyncCipher {
    private static let baselineAADPrefix = "UPW-SYNC-BASELINE-V1:"
    private static let conflictIdentityPrefix = "UPW-SYNC-CONFLICT-CANDIDATE-V1\0"
    private static let quarantineAADPrefix = "UPW-SYNC-QUARANTINE-V1\0"

    /// AES-GCM(VEK) 加密条目体;AAD 绑定条目 uuid。
    public static func encrypt(_ plaintext: Data, key: RowSyncKey, uuid: UUID) throws -> Data {
        do {
            let sealed = try AES.GCM.seal(
                plaintext, using: SymmetricKey(data: key.raw),
                authenticating: Data(uuid.uuidString.utf8))
            guard let combined = sealed.combined else {
                throw DatabaseCipher.CipherError(message: "AES-GCM combined representation unavailable")
            }
            return combined
        } catch {
            Log.error("sync", "rowsync encrypt failed for \(uuid.uuidString.prefix(8))…: \(error)")
            throw error
        }
    }

    /// 解密条目体;失败(密钥不符/AAD 不符/损坏)返回 nil。
    public static func decrypt(_ ciphertext: Data, key: RowSyncKey, uuid: UUID) -> Data? {
        do {
            let box = try AES.GCM.SealedBox(combined: ciphertext)
            return try AES.GCM.open(
                box, using: SymmetricKey(data: key.raw),
                authenticating: Data(uuid.uuidString.utf8))
        } catch {
            return nil
        }
    }

    /// Derives an opaque, stable identity for retries without reusing an AES-GCM nonce.
    static func conflictCandidateIdentity(plaintext: Data, key: RowSyncKey, uuid: UUID,
                                          baseRevision: UInt64, kind: UInt8,
                                          isDelete: Bool) -> (candidateID: String, fingerprint: String) {
        var message = Data(conflictIdentityPrefix.utf8)
        message.append(contentsOf: uuid.uuidString.lowercased().utf8)
        message.append(0)
        message.append(contentsOf: withUnsafeBytes(of: baseRevision.bigEndian, Array.init))
        message.append(kind)
        message.append(isDelete ? 2 : 1)
        message.append(contentsOf: withUnsafeBytes(of: UInt64(plaintext.count).bigEndian, Array.init))
        message.append(plaintext)

        let authenticationCode = Data(HMAC<SHA256>.authenticationCode(
            for: message, using: SymmetricKey(data: key.raw)))
        let fingerprint = authenticationCode.map { String(format: "%02x", $0) }.joined()
        let candidateID = authenticationCode.prefix(16)
            .map { String(format: "%02x", $0) }
            .joined()
        return (candidateID, fingerprint)
    }

    /// Encrypts a common ancestor with a domain-separated AAD namespace.
    static func encryptBaseline(_ item: DatabaseItem, key: RowSyncKey) throws -> Data {
        let baseline = RowSyncBaseline(item: item)
        guard baseline.isValid(uuid: item.uuid, kind: item.syncKind) else {
            throw RowSyncSafetyError.baselineUnavailable
        }
        do {
            let plaintext = try JSONEncoder().encode(baseline)
            let sealed = try AES.GCM.seal(
                plaintext, using: SymmetricKey(data: key.raw),
                authenticating: baselineAAD(uuid: item.uuid))
            guard let combined = sealed.combined else {
                throw DatabaseCipher.CipherError(message: "AES-GCM combined representation unavailable")
            }
            return combined
        } catch {
            Log.error("sync", "rowsync baseline encrypt failed for \(item.uuid): \(error)")
            throw error
        }
    }

    /// Decrypts and validates a baseline; authentication and identity failures return nil.
    static func decryptBaseline(_ ciphertext: Data, key: RowSyncKey, uuid: UUID) -> RowSyncBaseline? {
        do {
            let box = try AES.GCM.SealedBox(combined: ciphertext)
            let plaintext = try AES.GCM.open(
                box, using: SymmetricKey(data: key.raw), authenticating: baselineAAD(uuid: uuid))
            let baseline = try JSONDecoder().decode(RowSyncBaseline.self, from: plaintext)
            guard baseline.isValid(uuid: uuid, kind: baseline.syncKind) else { return nil }
            return baseline
        } catch {
            return nil
        }
    }

    static func quarantine(
        _ entry: RelayClient.ChangeEntry,
        reason: RowSyncQuarantinedItem.Reason,
        key: RowSyncKey
    ) throws -> RowSyncQuarantinedItem {
        try sealQuarantine(
            .change(entry), uuid: entry.uuid, sequence: entry.seq,
            revision: entry.revision, source: .change, reason: reason,
            capturedAt: Date(), key: key)
    }

    static func quarantine(
        _ item: RelayClient.ListedItem,
        reason: RowSyncQuarantinedItem.Reason,
        key: RowSyncKey
    ) throws -> RowSyncQuarantinedItem {
        try sealQuarantine(
            .snapshot(item), uuid: item.uuid, sequence: nil,
            revision: item.revision, source: .snapshot, reason: reason,
            capturedAt: Date(), key: key)
    }

    static func openQuarantine(
        _ item: RowSyncQuarantinedItem,
        key: RowSyncKey
    ) throws -> RowSyncQuarantinedItem.Payload {
        do {
            let box = try AES.GCM.SealedBox(combined: item.encryptedPayload)
            let plaintext = try AES.GCM.open(
                box, using: SymmetricKey(data: key.raw),
                authenticating: quarantineAAD(item))
            let payload = try JSONDecoder().decode(RowSyncQuarantinedItem.Payload.self, from: plaintext)
            switch payload {
            case .change(let entry):
                guard item.source == .change, item.sequence == entry.seq,
                      item.uuid == entry.uuid, item.revision == entry.revision else {
                    throw RowSyncSafetyError.quarantineUnavailable
                }
            case .snapshot(let listed):
                guard item.source == .snapshot, item.sequence == nil,
                      item.uuid == listed.uuid, item.revision == listed.revision else {
                    throw RowSyncSafetyError.quarantineUnavailable
                }
            }
            return payload
        } catch {
            Log.error("sync", "quarantine payload authentication or decoding failed id=\(item.id): \(error)")
            throw RowSyncSafetyError.quarantineUnavailable
        }
    }

    static func rekeyQuarantine(
        _ item: RowSyncQuarantinedItem,
        from oldKey: RowSyncKey,
        to newKey: RowSyncKey
    ) throws -> RowSyncQuarantinedItem {
        let payload = try openQuarantine(item, key: oldKey)
        return try sealQuarantine(
            payload, uuid: item.uuid, sequence: item.sequence,
            revision: item.revision, source: item.source, reason: item.reason,
            capturedAt: item.capturedAt, key: newKey)
    }

    public static func quarantineCandidate(
        _ candidate: RelayClient.ConflictCandidate,
        conflict: RelayClient.ConflictRecord,
        reason: RowSyncQuarantinedCandidate.Reason,
        key: RowSyncKey
    ) throws -> RowSyncQuarantinedCandidate {
        let identity = RowSyncQuarantinedCandidate(
            conflictID: conflict.conflictID,
            candidateID: candidate.candidateID,
            itemUUID: conflict.itemUUID,
            kind: candidate.kind,
            revision: candidate.revision,
            capturedAt: Date(),
            reason: reason,
            encryptedPayload: Data())
        do {
            let plaintext = try JSONEncoder().encode(candidate)
            let sealed = try AES.GCM.seal(
                plaintext,
                using: SymmetricKey(data: key.raw),
                authenticating: quarantineCandidateAAD(identity))
            guard let encryptedPayload = sealed.combined else {
                throw RowSyncSafetyError.quarantineUnavailable
            }
            return RowSyncQuarantinedCandidate(
                conflictID: conflict.conflictID,
                candidateID: candidate.candidateID,
                itemUUID: conflict.itemUUID,
                kind: candidate.kind,
                revision: candidate.revision,
                capturedAt: identity.capturedAt,
                reason: reason,
                encryptedPayload: encryptedPayload)
        } catch {
            Log.error(
                "sync",
                "candidate quarantine encryption failed id=\(identity.id): \(error)")
            throw RowSyncSafetyError.quarantineUnavailable
        }
    }

    static func openQuarantineCandidate(
        _ item: RowSyncQuarantinedCandidate,
        key: RowSyncKey
    ) throws -> RelayClient.ConflictCandidate {
        do {
            let box = try AES.GCM.SealedBox(combined: item.encryptedPayload)
            let plaintext = try AES.GCM.open(
                box,
                using: SymmetricKey(data: key.raw),
                authenticating: quarantineCandidateAAD(item))
            let candidate = try JSONDecoder().decode(
                RelayClient.ConflictCandidate.self, from: plaintext)
            guard item.candidateID == candidate.candidateID,
                  item.kind == candidate.kind,
                  item.revision == candidate.revision else {
                throw RowSyncSafetyError.quarantineUnavailable
            }
            return candidate
        } catch {
            Log.error(
                "sync",
                "candidate quarantine authentication or decoding failed id=\(item.id): \(error)")
            throw RowSyncSafetyError.quarantineUnavailable
        }
    }

    static func rekeyQuarantineCandidate(
        _ item: RowSyncQuarantinedCandidate,
        from oldKey: RowSyncKey,
        to newKey: RowSyncKey
    ) throws -> RowSyncQuarantinedCandidate {
        let candidate = try openQuarantineCandidate(item, key: oldKey)
        let identity = RowSyncQuarantinedCandidate(
            conflictID: item.conflictID,
            candidateID: item.candidateID,
            itemUUID: item.itemUUID,
            kind: item.kind,
            revision: item.revision,
            capturedAt: item.capturedAt,
            reason: item.reason,
            encryptedPayload: Data())
        do {
            let plaintext = try JSONEncoder().encode(candidate)
            let sealed = try AES.GCM.seal(
                plaintext,
                using: SymmetricKey(data: newKey.raw),
                authenticating: quarantineCandidateAAD(identity))
            guard let encryptedPayload = sealed.combined else {
                throw RowSyncSafetyError.quarantineUnavailable
            }
            return RowSyncQuarantinedCandidate(
                conflictID: item.conflictID,
                candidateID: item.candidateID,
                itemUUID: item.itemUUID,
                kind: item.kind,
                revision: item.revision,
                capturedAt: item.capturedAt,
                reason: item.reason,
                encryptedPayload: encryptedPayload)
        } catch {
            Log.error(
                "sync",
                "candidate quarantine rekey failed id=\(item.id): \(error)")
            throw RowSyncSafetyError.quarantineUnavailable
        }
    }

    private static func sealQuarantine(
        _ payload: RowSyncQuarantinedItem.Payload,
        uuid: UUID,
        sequence: Int?,
        revision: UInt64,
        source: RowSyncQuarantinedItem.Source,
        reason: RowSyncQuarantinedItem.Reason,
        capturedAt: Date,
        key: RowSyncKey
    ) throws -> RowSyncQuarantinedItem {
        let item = RowSyncQuarantinedItem(
            uuid: uuid, sequence: sequence, revision: revision, source: source,
            reason: reason, capturedAt: capturedAt, encryptedPayload: Data())
        do {
            let plaintext = try JSONEncoder().encode(payload)
            let sealed = try AES.GCM.seal(
                plaintext, using: SymmetricKey(data: key.raw),
                authenticating: quarantineAAD(item))
            guard let encryptedPayload = sealed.combined else {
                throw RowSyncSafetyError.quarantineUnavailable
            }
            return RowSyncQuarantinedItem(
                uuid: uuid, sequence: sequence, revision: revision, source: source,
                reason: reason, capturedAt: capturedAt, encryptedPayload: encryptedPayload)
        } catch {
            Log.error("sync", "quarantine payload encryption failed id=\(item.id): \(error)")
            throw RowSyncSafetyError.quarantineUnavailable
        }
    }

    private static func quarantineAAD(_ item: RowSyncQuarantinedItem) -> Data {
        Data("\(quarantineAADPrefix)\(item.id):\(item.reason.rawValue)".utf8)
    }

    private static func quarantineCandidateAAD(_ item: RowSyncQuarantinedCandidate) -> Data {
        Data("\(quarantineAADPrefix)candidate:\(item.id):\(item.reason.rawValue)".utf8)
    }

    private static func baselineAAD(uuid: UUID) -> Data {
        Data("\(baselineAADPrefix)\(uuid.uuidString)".utf8)
    }
}

/// 对调用方传入的数据库与同步状态执行增量收敛的无持久化引擎。
///
/// 单次拉取/推送成功后才发布 inout 值；失败保留调用前的局部状态。
/// 会话层仍须在局部副本上运行，校验会话后经 DatabaseStore.commitSyncSnapshot 配套持久化。
public enum RowSync {

    /// Attachment transfer state exposed to native detail views.
    public enum AttachmentDownloadState: Equatable {
        case queued
        case downloading
        case failed
    }

    /// Result of hydrating missing attachment bytes independently from row synchronization.
    public struct AttachmentDownloadResult {
        /// Database copy with verified attachment bytes installed.
        public let database: PasswordDatabase
        /// Number of attachment versions installed in the copy.
        public let downloadedCount: Int

        /// Creates a result for a completed attachment hydration pass.
        public init(database: PasswordDatabase, downloadedCount: Int) {
            self.database = database
            self.downloadedCount = downloadedCount
        }
    }

    /// Reapplies authenticated isolated records after a client gains format support.
    /// - Parameters:
    ///   - client: Row-sync API client.
    ///   - token: Current account authorization.
    ///   - vaultId: Bound remote vault identity.
    ///   - key: Current vault encryption key.
    ///   - database: Local snapshot, changed only after every selected record succeeds.
    ///   - state: Paired sync state, changed only after every selected record succeeds.
    /// - Returns: Number of successfully recovered records.
    /// - Throws: Authentication, format, conflict, or network errors; state remains unchanged.
    public static func retryQuarantinedItems(
        client: RelayClient,
        token: String,
        vaultId: String,
        key: RowSyncKey,
        database: inout PasswordDatabase,
        state: inout RowSyncState
    ) async throws -> Int {
        var workingDatabase = database
        var workingState = state
        var recoveredCount = 0
        let items = workingState.quarantinedItems.values.sorted {
            ($0.sequence ?? Int.max, $0.uuid.uuidString) < ($1.sequence ?? Int.max, $1.uuid.uuidString)
        }
        for quarantined in items {
            try Task.checkCancellation()
            let payload = try RowSyncCipher.openQuarantine(quarantined, key: key)
            let entry: RelayClient.ChangeEntry
            switch payload {
            case .change(let change):
                entry = change
            case .snapshot(let listed):
                entry = RelayClient.ChangeEntry(
                    seq: workingState.cursor, uuid: listed.uuid, op: "upsert",
                    revision: listed.revision, deleted: false, bodyB64: listed.bodyB64,
                    kind: listed.kind, modifiedMs: listed.modifiedMs)
            }
            guard entry.op == "resolve" || workingState.pendingConflicts[entry.uuid] == nil else {
                throw RowSyncSafetyError.conflictNeedsResolution
            }
            _ = try await apply(
                entry, key: key, baseline: baseline(
                    uuid: entry.uuid, state: workingState, key: key),
                client: client, token: token, vaultId: vaultId,
                to: &workingDatabase, state: &workingState)
            workingState.quarantinedItems.removeValue(forKey: quarantined.id)
            recoveredCount += 1
        }
        database = workingDatabase
        state = workingState
        Log.info("sync", "quarantine retry finished recovered=\(recoveredCount)")
        return recoveredCount
    }

    // MARK: - 下行(游标增量,§6.3)

    /// 分页拉取并应用变更，追平 headSeq 或达到 200 页上限后返回。
    ///
    /// - Parameters:
    ///   - client: 行级同步 API 客户端。
    ///   - token: 当前账户的 Bearer 令牌。
    ///   - vaultId: 已绑定的远端库身份。
    ///   - key: 当前库的条目加密密钥。
    ///   - database: 局部数据库副本，按条目更新。
    ///   - state: 与数据库配对的局部游标和修订基线。
    /// - Returns: 本轮应用统计；调用方须检查游标判断是否完全追平。
    /// - Throws: 网络或协议错误、游标过期，或需重新解锁的 RowSyncRekeySignal。
    @discardableResult
    public static func pull(client: RelayClient, token: String, vaultId: String, key: RowSyncKey,
                            database: inout PasswordDatabase, state: inout RowSyncState) async throws -> RowSyncOutcome {
        let startedAt = Date()
        Log.info("sync", "rowsync pull started (cursor=\(state.cursor))")
        var workingDatabase = database
        var workingState = state
        do {
            let outcome = try await pullChanges(
                client: client, token: token, vaultId: vaultId, key: key,
                database: &workingDatabase, state: &workingState)
            database = workingDatabase
            state = workingState
            return outcome
        } catch {
            preserveNewConflictIDs(from: workingState, in: &state)
            let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
            Log.error("sync", "rowsync pull paused ms=\(elapsed); local snapshot retained: \(error)")
            throw error
        }
    }

    /// Downloads and authenticates exactly one referenced attachment version.
    /// - Parameters:
    ///   - version: Stable parent, attachment identity, and content token selected from the snapshot.
    ///   - client: Row-sync API client.
    ///   - token: Current account authorization.
    ///   - vaultId: Bound cloud vault identity.
    ///   - key: Current vault encryption key.
    /// - Returns: Authenticated plaintext bytes; callers revalidate session and version before install.
    /// - Throws: Network, integrity, decryption, or cancellation errors.
    public static func downloadAttachment(
        version: AttachmentDownloadLedger.Version,
        client: RelayClient,
        token: String,
        vaultId: String,
        key: RowSyncKey
    ) async throws -> Data {
        try Task.checkCancellation()
        let encrypted = try await client.getAttachment(
            token: token, vaultId: vaultId, attachUuid: version.identity.attachmentID,
            contentVersion: version.contentVersion)
        try Task.checkCancellation()
        return try AttachmentSyncCipher.decrypt(
            cipher: encrypted.cipher, dekWrapped: encrypted.dekWrapped, key: key,
            attachmentID: version.identity.attachmentID, contentVersion: version.contentVersion)
    }

    /// Downloads missing attachment bytes without changing row metadata or sync state.
    ///
    /// The returned database is a copy. Callers must validate the active vault session before
    /// publishing it. The row revision, modification time, and sync cursor remain unchanged.
    ///
    /// - Parameters:
    ///   - client: Row-sync API client.
    ///   - token: Current account authorization.
    ///   - vaultId: Bound remote vault identity.
    ///   - key: Current vault encryption key.
    ///   - database: Decrypted database snapshot to hydrate.
    ///   - cardIDs: Optional set of cards to hydrate; nil selects every card.
    /// - Returns: A database copy and the number of successfully installed versions.
    /// - Throws: Network, integrity, decryption, cancellation, or invalid-reference errors.
    public static func downloadMissingAttachments(
        client: RelayClient,
        token: String,
        vaultId: String,
        key: RowSyncKey,
        database: PasswordDatabase,
        cardIDs: Set<UUID>? = nil
    ) async throws -> AttachmentDownloadResult {
        let startedAt = Date()
        var hydrated = database
        var downloadedCount = 0
        let selectedCards = database.cards.filter { cardIDs?.contains($0.id) ?? true }
        Log.info("sync", "attachment hydration started cards=\(selectedCards.count)")
        do {
            for index in hydrated.cards.indices where cardIDs?.contains(hydrated.cards[index].id) ?? true {
                try Task.checkCancellation()
                let original = hydrated.cards[index]
                var card = original
                card.images = try await downloadMissingAttachmentVersions(
                    card.images, key: key, client: client, token: token, vaultId: vaultId)
                card.files = try await downloadMissingAttachmentVersions(
                    card.files, key: key, client: client, token: token, vaultId: vaultId)
                let originalCount = (original.images + original.files).count { $0.hasContent }
                let hydratedCount = (card.images + card.files).count { $0.hasContent }
                downloadedCount += hydratedCount - originalCount
                hydrated.cards[index] = card
            }
            let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
            Log.info("sync", "attachment hydration finished versions=\(downloadedCount) ms=\(elapsed)")
            return AttachmentDownloadResult(database: hydrated, downloadedCount: downloadedCount)
        } catch {
            let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
            Log.error("sync", "attachment hydration failed ms=\(elapsed): \(error)")
            throw error
        }
    }

    /// Merges verified downloaded bytes into the latest database without replacing row edits.
    /// Only an attachment with the same persistent ID and content version can receive bytes.
    ///
    /// - Parameters:
    ///   - downloaded: Database copy containing authenticated downloaded bytes.
    ///   - current: Latest session database, mutated only for matching missing byte caches.
    ///   - cardIDs: Optional card allowlist; nil considers all cards.
    /// - Returns: Number of attachment versions installed.
    @discardableResult
    public static func mergeDownloadedAttachmentContent(
        from downloaded: PasswordDatabase,
        into current: inout PasswordDatabase,
        cardIDs: Set<UUID>? = nil
    ) -> Int {
        var installedCount = 0
        let downloadedCards = Dictionary(uniqueKeysWithValues: downloaded.cards.map { ($0.id, $0) })
        for cardIndex in current.cards.indices {
            let cardID = current.cards[cardIndex].id
            guard cardIDs?.contains(cardID) ?? true,
                  let source = downloadedCards[cardID] else { continue }
            installedCount += mergeDownloadedBytes(from: source.images, into: &current.cards[cardIndex].images)
            installedCount += mergeDownloadedBytes(from: source.files, into: &current.cards[cardIndex].files)
        }
        return installedCount
    }

    /// Installs one authenticated version without changing any row metadata or revision.
    /// - Parameters:
    ///   - data: Verified plaintext bytes.
    ///   - version: Identity captured before the download started.
    ///   - database: Current database; changed or removed references reject the result.
    /// - Returns: Whether the bytes were installed into the still-current missing version.
    @discardableResult
    public static func installDownloadedAttachmentContent(
        _ data: Data, for version: AttachmentDownloadLedger.Version, into database: inout PasswordDatabase
    ) -> Bool {
        guard let cardIndex = database.cards.firstIndex(where: { $0.id == version.identity.cardID }) else {
            return false
        }
        var card = database.cards[cardIndex]
        var installed = false
        for index in card.images.indices {
            if card.images[index].hasPersistentID,
               card.images[index].id == version.identity.attachmentID, !card.images[index].hasContent {
                installed = card.images[index].installDownloadedContent(data, for: version.contentVersion)
            }
        }
        for index in card.files.indices {
            if card.files[index].hasPersistentID,
               card.files[index].id == version.identity.attachmentID, !card.files[index].hasContent {
                installed = card.files[index].installDownloadedContent(data, for: version.contentVersion)
            }
        }
        if installed { database.cards[cardIndex] = card }
        return installed
    }

    private static func mergeDownloadedBytes(from source: [Attachment], into destination: inout [Attachment]) -> Int {
        var installedCount = 0
        for index in destination.indices where destination[index].data == nil {
            let target = destination[index]
            guard target.hasPersistentID, target.hasPersistentContentVersion,
                  let downloaded = source.first(where: {
                      $0.hasPersistentID && $0.hasPersistentContentVersion
                          && $0.id == target.id && $0.contentVersion == target.contentVersion
                  }), let data = downloaded.data,
                  destination[index].installDownloadedContent(data, for: target.contentVersion) else {
                continue
            }
            installedCount += 1
        }
        return installedCount
    }

    private static func pullChanges(client: RelayClient, token: String, vaultId: String,
                                    key: RowSyncKey, database: inout PasswordDatabase,
                                    state: inout RowSyncState) async throws -> RowSyncOutcome {
        guard !state.needsContentBaselineMigration else {
            throw RowSyncSafetyError.baselineUnavailable
        }
        _ = try state.validatedBaselines(key: key)
        try state.validateQuarantinedItems(key: key)
        var outcome = RowSyncOutcome()
        let startedAt = Date()
        var headSeq = state.cursor
        state.needsSyncContinuation = false
        for _ in 0..<200 {
            let (pageHeadSeq, changes) = try await client.getChanges(
                token: token, vaultId: vaultId, since: state.cursor)
            headSeq = pageHeadSeq
            if changes.isEmpty {
                guard state.cursor >= pageHeadSeq else { throw RowSyncSafetyError.invalidResponse }
                outcome.headSeq = pageHeadSeq
                break
            }
            for entry in changes {
                // 只统计实际改变本地内容的条目:自己上轮上传的回声在此为
                // 空操作,不计入"拉取 N 条"(否则删一条会显示"拉取 1 上传 1")
                do {
                    if try await apply(
                        entry, key: key, baseline: baseline(
                            uuid: entry.uuid, state: state, key: key),
                        client: client, token: token, vaultId: vaultId,
                        to: &database, state: &state) {
                        outcome.pulledItems += 1
                    }
                } catch let error as RowSyncSafetyError {
                    let reason: RowSyncQuarantinedItem.Reason
                    switch error {
                    case .unreadableItem:
                        reason = .authenticationFailed
                    case .unsupportedItemFormat:
                        reason = .unsupportedFormat
                    default:
                        throw error
                    }
                    let quarantined = try RowSyncCipher.quarantine(entry, reason: reason, key: key)
                    state.quarantinedItems[quarantined.id] = quarantined
                    state.cursor = entry.seq
                    state.needsSyncContinuation = true
                    outcome.quarantinedItems += 1
                    outcome.requiresFollowUpSync = true
                    outcome.headSeq = pageHeadSeq
                    Log.error(
                        "sync",
                        "rowsync isolated unreadable change seq=\(entry.seq) uuid=\(entry.uuid) reason=\(reason.rawValue)")
                    return outcome
                }
                state.cursor = entry.seq
            }
            if state.cursor >= pageHeadSeq {
                outcome.headSeq = pageHeadSeq
                break
            }
        }
        guard outcome.requiresFollowUpSync || state.cursor >= headSeq else {
            throw RowSyncSafetyError.incompleteSnapshot
        }
        Log.info("sync", "rowsync pulled \(outcome.pulledItems) item(s) to seq=\(state.cursor) ms=\(Int(Date().timeIntervalSince(startedAt) * 1000))")
        return outcome
    }

    /// 应用单条变更；无法读取或存在尚不能裁决的分歧时停止，不以时间覆盖。
    /// - Returns: 是否实际改变了本地内容。自己上一轮上传的回声(revision 未
    ///   超过本地已知)是空操作,返回 false——"拉取 N 条"只统计真变化,否则
    ///   用户删一条会看到"拉取 1 上传 1"的误导。
    private static func apply(
        _ entry: RelayClient.ChangeEntry,
        key: RowSyncKey,
        baseline: RowSyncBaseline?,
        client: RelayClient,
        token: String,
        vaultId: String,
        to database: inout PasswordDatabase,
        state: inout RowSyncState
    ) async throws -> Bool {
        if entry.op == "rekey" {
            // 对端改密:本端旧 VEK 已解不开新密文,交调用方强制锁定接管
            throw RowSyncRekeySignal(passwordVersion: Int(entry.revision))
        }
        if entry.op == "resolve" {
            return try await applyResolution(
                entry, key: key, baseline: baseline, client: client,
                token: token, vaultId: vaultId, to: &database, state: &state)
        }
        guard state.pendingConflicts[entry.uuid] == nil else { return false }
        guard entry.revision > (state.revisions[entry.uuid] ?? 0) else { return false }
        if entry.deleted {
            let local = localItem(uuid: entry.uuid, in: database)
            if let local {
                let unchanged = state.dirtyDeletes[entry.uuid] == nil
                    && state.dirtyUpserts[entry.uuid] == nil
                    && baseline?.matches(local) == true
                guard unchanged else {
                    Log.warn("sync", "rowsync deletion protected changed item \(entry.uuid)")
                    let labelNames = Dictionary(uniqueKeysWithValues: database.labels.map { ($0.id, $0.name) })
                    let registration = try await registerLocalItemCandidate(
                        local, modifiedMs: state.dirtyUpserts[entry.uuid] ?? local.modifiedMs,
                        baseRevision: state.revisions[entry.uuid] ?? 0,
                        expectedRevision: entry.revision,
                        expectedDeletedSequence: entry.seq,
                        key: key, labelNames: labelNames, client: client,
                        token: token, vaultId: vaultId)
                    state.pendingConflicts[entry.uuid] = registration
                    throw RowSyncSafetyError.remoteDeletionNeedsRecovery
                }
            } else if state.dirtyUpserts[entry.uuid] != nil {
                Log.warn("sync", "rowsync deletion protected missing pending item \(entry.uuid)")
                throw RowSyncSafetyError.remoteDeletionNeedsRecovery
            }
            removeItem(uuid: entry.uuid, from: &database, state: &state)
            return local != nil
        }
        guard let bodyB64 = entry.bodyB64, let sealed = Data(base64Encoded: bodyB64),
              let plaintext = RowSyncCipher.decrypt(sealed, key: key, uuid: entry.uuid),
              let kind = entry.kind else {
            Log.error("sync", "rowsync unreadable item \(entry.uuid); local content retained")
            throw RowSyncSafetyError.unreadableItem
        }
        guard let parsedItem = DatabaseItemCodec.parse(kind: kind, uuid: entry.uuid, data: plaintext)
                ?? (kind == 3
                    ? DatabaseItemCodec.parse(kind: 1, uuid: entry.uuid, data: plaintext)
                    : nil) else {
            Log.warn("sync", "rowsync unsupported item format \(entry.uuid); local content retained")
            throw RowSyncSafetyError.unsupportedItemFormat
        }
        let item = parsedItem
        if let deleteMs = state.dirtyDeletes[entry.uuid] {
            let operation = RelayClient.ItemOp(
                uuid: entry.uuid, kind: kind, isDelete: true,
                baseRevision: state.revisions[entry.uuid] ?? 0,
                modifiedMs: deleteMs)
            let registration = try await registerLocalCandidate(
                operation, plaintext: Data(), expectedRevision: entry.revision,
                key: key, client: client, token: token, vaultId: vaultId)
            state.pendingConflicts[entry.uuid] = registration
            throw RowSyncSafetyError.conflictNeedsResolution
        }
        var resolvedItem = item
        if let local = localItem(uuid: entry.uuid, in: database) {
            if hasSameContent(local, item) {
                state.dirtyUpserts.removeValue(forKey: entry.uuid)
            } else if let baseline {
                if baseline.matches(local) {
                    state.dirtyUpserts.removeValue(forKey: entry.uuid)
                } else if let merged = baseline.merging(local: local, remote: item) {
                    resolvedItem = merged
                    if hasSameContent(merged, item) {
                        state.dirtyUpserts.removeValue(forKey: entry.uuid)
                    } else {
                        state.dirtyUpserts[entry.uuid] = merged.modifiedMs
                    }
                } else {
                    Log.warn("sync", "rowsync concurrent item \(entry.uuid); automatic merge blocked")
                    let labelNames = Dictionary(uniqueKeysWithValues: database.labels.map { ($0.id, $0.name) })
                    let registration = try await registerLocalItemCandidate(
                        local, modifiedMs: state.dirtyUpserts[entry.uuid] ?? local.modifiedMs,
                        baseRevision: state.revisions[entry.uuid] ?? 0,
                        expectedRevision: entry.revision, key: key,
                        labelNames: labelNames, client: client,
                        token: token, vaultId: vaultId)
                    state.pendingConflicts[entry.uuid] = registration
                    throw RowSyncSafetyError.conflictNeedsResolution
                }
            } else {
                Log.warn("sync", "rowsync concurrent item \(entry.uuid); automatic merge blocked")
                let labelNames = Dictionary(uniqueKeysWithValues: database.labels.map { ($0.id, $0.name) })
                let registration = try await registerLocalItemCandidate(
                    local, modifiedMs: state.dirtyUpserts[entry.uuid] ?? local.modifiedMs,
                    baseRevision: state.revisions[entry.uuid] ?? 0,
                    expectedRevision: entry.revision, key: key,
                    labelNames: labelNames, client: client,
                    token: token, vaultId: vaultId)
                state.pendingConflicts[entry.uuid] = registration
                throw RowSyncSafetyError.conflictNeedsResolution
            }
        } else if state.dirtyUpserts[entry.uuid] != nil {
            throw RowSyncSafetyError.conflictNeedsResolution
        }
        let changed = localItem(uuid: entry.uuid, in: database).map {
            !hasSameContent($0, resolvedItem)
        } ?? true
        applyItem(resolvedItem, to: &database)
        state.revisions[entry.uuid] = entry.revision
        state.syncedMtimes[entry.uuid] = item.modifiedMs
        state.encryptedItemBaselines[entry.uuid] = try RowSyncCipher.encryptBaseline(
            item, key: key)
        return changed
    }

    private static func applyResolution(
        _ entry: RelayClient.ChangeEntry,
        key: RowSyncKey,
        baseline: RowSyncBaseline?,
        client: RelayClient,
        token: String,
        vaultId: String,
        to database: inout PasswordDatabase,
        state: inout RowSyncState
    ) async throws -> Bool {
        guard let conflictID = entry.conflictID else {
            throw RowSyncSafetyError.invalidResponse
        }
        let sourceUUID = entry.uuid
        let targetUUID = entry.resolvedItemUUID
        let resolvedItem: DatabaseItem?
        if entry.deleted {
            resolvedItem = nil
        } else {
            guard let targetUUID, let kind = entry.kind, let bodyB64 = entry.bodyB64,
                  let resolvedRevision = entry.resolvedRevision, resolvedRevision > 0,
                  let ciphertext = Data(base64Encoded: bodyB64),
                  let plaintext = RowSyncCipher.decrypt(ciphertext, key: key, uuid: targetUUID) else {
                throw RowSyncSafetyError.unreadableItem
            }
            guard let item = DatabaseItemCodec.parse(kind: kind, uuid: targetUUID, data: plaintext)
                    ?? (kind == 3
                        ? DatabaseItemCodec.parse(kind: 1, uuid: targetUUID, data: plaintext)
                        : nil) else {
                throw RowSyncSafetyError.unsupportedItemFormat
            }
            try requireAvailableAttachmentContent(item)
            resolvedItem = item
        }

        if !entry.deleted, let targetUUID, targetUUID != sourceUUID,
           localItem(uuid: targetUUID, in: database) != nil {
            throw RowSyncSafetyError.localDataNeedsRecovery
        }

        let sourceItem = localItem(uuid: sourceUUID, in: database)
        let marker = state.pendingConflicts[sourceUUID]
        let candidateStillRetained = marker.map {
            candidateMatches($0, item: sourceItem, uuid: sourceUUID, key: key,
                             labels: database.labels, hasPendingDelete: state.dirtyDeletes[sourceUUID] != nil)
        } ?? false
        let localIsWinner = isWinningCandidate(
            item: sourceItem, uuid: sourceUUID, state: state, entry: entry,
            key: key, labels: database.labels)
        let matchesResolution = sourceItem.flatMap { local in
            resolvedItem.map { hasSameContent(local, $0) }
        } ?? false
        let matchesBase = sourceItem.map { baseline?.matches($0) == true } ?? true
        let needsRetention = !localIsWinner && (state.dirtyDeletes[sourceUUID] != nil
            || (sourceItem != nil && !matchesResolution && !matchesBase)
            || (sourceItem == nil && state.dirtyUpserts[sourceUUID] != nil))

        if needsRetention && !candidateStillRetained {
            let labelNames = Dictionary(uniqueKeysWithValues: database.labels.map { ($0.id, $0.name) })
            let deletedSequence = targetUUID == sourceUUID && !entry.deleted ? nil : entry.seq
            let newMarker: RowSyncPendingConflict
            if let deleteMs = state.dirtyDeletes[sourceUUID] {
                let kind = sourceItem?.syncKind ?? baseline?.syncKind ?? 1
                let operation = RelayClient.ItemOp(
                    uuid: sourceUUID, kind: kind, isDelete: true,
                    baseRevision: state.revisions[sourceUUID] ?? 0,
                    modifiedMs: deleteMs)
                newMarker = try await registerLocalCandidate(
                    operation, plaintext: Data(), expectedRevision: entry.revision,
                    expectedDeletedSequence: deletedSequence, key: key,
                    client: client, token: token, vaultId: vaultId)
            } else if let sourceItem {
                newMarker = try await registerLocalItemCandidate(
                    sourceItem,
                    modifiedMs: state.dirtyUpserts[sourceUUID] ?? sourceItem.modifiedMs,
                    baseRevision: state.revisions[sourceUUID] ?? 0,
                    expectedRevision: entry.revision,
                    expectedDeletedSequence: deletedSequence,
                    key: key, labelNames: labelNames, client: client,
                    token: token, vaultId: vaultId)
            } else {
                throw RowSyncSafetyError.remoteDeletionNeedsRecovery
            }
            state.pendingConflicts[sourceUUID] = newMarker
        }

        let localBefore = sourceItem
        if targetUUID != sourceUUID || entry.deleted {
            removeItem(uuid: sourceUUID, from: &database, state: &state)
        }
        if let targetUUID, let resolvedItem, !entry.deleted {
            guard let resolvedRevision = entry.resolvedRevision else {
                throw RowSyncSafetyError.invalidResponse
            }
            applyItem(resolvedItem, to: &database)
            state.revisions[targetUUID] = resolvedRevision
            state.dirtyUpserts.removeValue(forKey: targetUUID)
            state.dirtyDeletes.removeValue(forKey: targetUUID)
            state.syncedMtimes[targetUUID] = resolvedItem.modifiedMs
            state.encryptedItemBaselines[targetUUID] = try RowSyncCipher.encryptBaseline(
                resolvedItem, key: key)
        }
        if state.pendingConflicts[sourceUUID]?.conflictID == conflictID {
            state.pendingConflicts.removeValue(forKey: sourceUUID)
        }
        return localBefore != nil || resolvedItem != nil
    }

    private static func candidateMatches(
        _ marker: RowSyncPendingConflict,
        item: DatabaseItem?,
        uuid: UUID,
        key: RowSyncKey,
        labels: [CardLabel],
        hasPendingDelete: Bool
    ) -> Bool {
        if marker.isDelete {
            return item == nil && hasPendingDelete
        }
        guard let item, item.uuid == uuid, item.syncKind == marker.kind else { return false }
        guard !item.hasUnavailableAttachmentContent else { return false }
        let labelNames = Dictionary(uniqueKeysWithValues: labels.map { ($0.id, $0.name) })
        let plaintext = DatabaseItemCodec.xmlData(item, labelNames: labelNames)
        let identity = RowSyncCipher.conflictCandidateIdentity(
            plaintext: plaintext, key: key, uuid: uuid,
            baseRevision: marker.baseRevision, kind: marker.kind, isDelete: false)
        return identity.candidateID == marker.candidateID
            && identity.fingerprint == marker.fingerprint
    }

    private static func isWinningCandidate(
        item: DatabaseItem?,
        uuid: UUID,
        state: RowSyncState,
        entry: RelayClient.ChangeEntry,
        key: RowSyncKey,
        labels: [CardLabel]
    ) -> Bool {
        guard let winnerCandidateID = entry.winnerCandidateID,
              let baseRevision = entry.conflictBaseRevision,
              let winnerKind = entry.winnerKind,
              let isDelete = entry.winnerIsDelete,
              entry.resolutionType == .candidate else {
            return false
        }
        let plaintext: Data
        if isDelete {
            guard state.dirtyDeletes[uuid] != nil else { return false }
            plaintext = Data()
        } else {
            guard let item, item.uuid == uuid, item.syncKind == winnerKind else { return false }
            guard !item.hasUnavailableAttachmentContent else { return false }
            let labelNames = Dictionary(uniqueKeysWithValues: labels.map { ($0.id, $0.name) })
            plaintext = DatabaseItemCodec.xmlData(item, labelNames: labelNames)
        }
        let identity = RowSyncCipher.conflictCandidateIdentity(
            plaintext: plaintext, key: key, uuid: uuid,
            baseRevision: baseRevision, kind: winnerKind, isDelete: isDelete)
        return identity.candidateID == winnerCandidateID
    }

    private static func preserveNewConflictIDs(from working: RowSyncState, in state: inout RowSyncState) {
        for (uuid, marker) in working.pendingConflicts where state.pendingConflicts[uuid] != marker {
            state.pendingConflicts[uuid] = marker
        }
    }

    private static func removeItem(uuid: UUID, from database: inout PasswordDatabase, state: inout RowSyncState) {
        database.deleteCardPermanently(id: uuid)
        database.deleteLabelPermanently(id: uuid)
        database.userProfiles.removeAll { $0.id == uuid }
        state.revisions.removeValue(forKey: uuid)
        state.syncedMtimes.removeValue(forKey: uuid)
        state.encryptedItemBaselines.removeValue(forKey: uuid)
        // 调用前必须确认没有需要保护的本地待上传内容。
        state.dirtyUpserts.removeValue(forKey: uuid)
        state.dirtyDeletes.removeValue(forKey: uuid)
    }

    static func localItem(uuid: UUID, in database: PasswordDatabase) -> DatabaseItem? {
        if let c = database.card(id: uuid) { return .card(c) }
        if let l = database.label(id: uuid) { return .label(l) }
        if let profile = database.userProfiles.first(where: { $0.id == uuid }) { return .userProfile(profile) }
        return nil
    }

    static func applyItem(_ item: DatabaseItem, to database: inout PasswordDatabase) {
        switch item {
        case .card(let card):
            database.userProfiles.removeAll { $0.id == card.id }
            if let i = database.cards.firstIndex(where: { $0.id == card.id }) {
                database.cards[i] = card
            } else {
                database.cards.append(card)
            }
        case .userProfile(let profile):
            database.cards.removeAll { $0.id == profile.id }
            if let index = database.userProfiles.firstIndex(where: { $0.id == profile.id }) {
                database.userProfiles[index] = profile
            } else {
                database.userProfiles.append(profile)
            }
        case .label(let label):
            if let i = database.labels.firstIndex(where: { $0.id == label.id }) {
                database.labels[i] = label
            } else {
                database.labels.append(label)
            }
        }
    }

    // MARK: - 上行(批量 CAS,§6.2)

    /// 推送脏集合；未能安全收敛的冲突暂停并保留内容，每批最多 200 项，最多 50 批。
    ///
    /// - Parameters:
    ///   - client: 行级同步 API 客户端。
    ///   - token: 当前账户的 Bearer 令牌。
    ///   - vaultId: 已绑定的远端库身份。
    ///   - key: 当前库的条目加密密钥。
    ///   - database: 已采集脏集合的局部数据库副本，可能按冲突结果更新。
    ///   - state: 待推送集合与已确认版本；成功操作从脏集合移除。
    /// - Returns: 已确认的推送和冲突统计；达到批次上限时可能仍有待推送项。
    /// - Throws: 加密、网络或协议错误；失败前已确认的远端写入不会回滚。
    @discardableResult
    public static func push(client: RelayClient, token: String, vaultId: String, key: RowSyncKey,
                            database: inout PasswordDatabase, state: inout RowSyncState) async throws -> RowSyncOutcome {
        let startedAt = Date()
        Log.info("sync", "rowsync push started (pending=\(state.dirtyUpserts.count + state.dirtyDeletes.count))")
        var workingDatabase = database
        var workingState = state
        do {
            let outcome = try await pushChanges(
                client: client, token: token, vaultId: vaultId, key: key,
                database: &workingDatabase, state: &workingState)
            database = workingDatabase
            state = workingState
            return outcome
        } catch {
            preserveNewConflictIDs(from: workingState, in: &state)
            let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
            Log.error("sync", "rowsync push paused ms=\(elapsed); pending content retained: \(error)")
            throw error
        }
    }

    private static func pushChanges(client: RelayClient, token: String, vaultId: String,
                                    key: RowSyncKey, database: inout PasswordDatabase,
                                    state: inout RowSyncState) async throws -> RowSyncOutcome {
        guard state.pendingConflicts.isEmpty else {
            throw RowSyncSafetyError.conflictNeedsResolution
        }
        try state.validateQuarantinedItems(key: key)
        guard !state.needsContentBaselineMigration else {
            throw RowSyncSafetyError.baselineUnavailable
        }
        _ = try state.validatedBaselines(key: key)
        var outcome = RowSyncOutcome()
        let startedAt = Date()
        let labelNames = Dictionary(uniqueKeysWithValues: database.labels.map { ($0.id, $0.name) })
        // 连续排干整个脏集合:collectOps 每轮只取 ≤200 条,此前"无冲突即
        // 收工"会让大脏集(新绑定/导入)每轮同步只推 200 条,余量悬到下轮
        // (曾致 pending=142 反复出现)。这里直到无批可发或仅剩冲突重试。
        for _ in 0..<50 {
            let ops = try collectOps(database: database, state: state, key: key, labelNames: labelNames)
            if ops.isEmpty { break }
            for operation in ops where !operation.isDelete {
                guard let item = localItem(uuid: operation.uuid, in: database) else {
                    throw RowSyncSafetyError.invalidResponse
                }
                try await uploadAttachmentVersions(
                    in: item, key: key, client: client, token: token, vaultId: vaultId)
            }
            let results = try await client.postItems(token: token, vaultId: vaultId, items: ops)
            let wasFullBatch = ops.count >= 200
            var mergedConflict = false
            for op in ops {
                guard let result = results[op.uuid] else { throw RowSyncSafetyError.invalidResponse }
                switch result {
                case .ok(let revision):
                    state.revisions[op.uuid] = revision
                    if let ms = state.dirtyUpserts.removeValue(forKey: op.uuid) {
                        state.syncedMtimes[op.uuid] = ms
                    }
                    if !op.isDelete {
                        guard let item = localItem(uuid: op.uuid, in: database) else {
                            throw RowSyncSafetyError.invalidResponse
                        }
                        state.syncedMtimes[op.uuid] = item.modifiedMs
                        state.encryptedItemBaselines[op.uuid] = try RowSyncCipher.encryptBaseline(
                            item, key: key)
                    } else {
                        state.revisions.removeValue(forKey: op.uuid)
                        state.syncedMtimes.removeValue(forKey: op.uuid)
                        state.encryptedItemBaselines.removeValue(forKey: op.uuid)
                    }
                    state.dirtyDeletes.removeValue(forKey: op.uuid)
                    outcome.pushedItems += 1
                case .notFound(let deletedAt, let revision, let sequence):
                    guard op.isDelete else {
                        if let revision, let sequence, deletedAt != nil {
                            let marker = try await registerDeletedRemoteConflict(
                                op, revision: revision, sequence: sequence, key: key,
                                client: client, token: token, vaultId: vaultId)
                            state.pendingConflicts[op.uuid] = marker
                        }
                        Log.warn("sync", "rowsync missing remote item \(op.uuid); pending content retained")
                        throw deletedAt == nil
                            ? RowSyncSafetyError.localDataNeedsRecovery
                            : RowSyncSafetyError.remoteDeletionNeedsRecovery
                    }
                    removeItem(uuid: op.uuid, from: &database, state: &state)
                case .conflict(let revision, let bodyB64):
                    try await resolveConflict(
                        op, revision: revision, bodyB64: bodyB64, key: key,
                        baseline: try baseline(uuid: op.uuid, state: state, key: key),
                        client: client, token: token, vaultId: vaultId,
                        database: &database, state: &state)
                    outcome.conflictsResolved += 1
                    mergedConflict = true
                }
            }
            if !wasFullBatch && !mergedConflict { break }
        }
        Log.info("sync", "rowsync pushed \(outcome.pushedItems) item(s), conflicts \(outcome.conflictsResolved) ms=\(Int(Date().timeIntervalSince(startedAt) * 1000))")
        return outcome
    }

    /// 以共同基线合并独立修改；身份不可靠或同内容分歧时保持双方并暂停。
    private static func resolveConflict(
        _ op: RelayClient.ItemOp,
        revision: UInt64,
        bodyB64: String?,
        key: RowSyncKey,
        baseline: RowSyncBaseline?,
        client: RelayClient,
        token: String,
        vaultId: String,
        database: inout PasswordDatabase,
        state: inout RowSyncState
    ) async throws {
        if op.isDelete {
            let marker = try await registerLocalCandidate(
                op, plaintext: Data(), expectedRevision: revision,
                key: key, client: client, token: token, vaultId: vaultId)
            state.pendingConflicts[op.uuid] = marker
            throw RowSyncSafetyError.conflictNeedsResolution
        }
        guard let bodyB64, let sealed = Data(base64Encoded: bodyB64),
              let plaintext = RowSyncCipher.decrypt(sealed, key: key, uuid: op.uuid),
              let remote = DatabaseItemCodec.parse(kind: op.kind, uuid: op.uuid, data: plaintext)
                ?? (op.kind == 3 ? DatabaseItemCodec.parse(kind: 1, uuid: op.uuid, data: plaintext) : nil)
        else { throw RowSyncSafetyError.unreadableItem }
        try requireAvailableAttachmentContent(remote)
        guard let local = localItem(uuid: op.uuid, in: database) else {
            throw RowSyncSafetyError.conflictNeedsResolution
        }
        let merged: DatabaseItem
        if hasSameContent(local, remote) {
            merged = remote
        } else if let baseline, let automaticMerge = baseline.merging(local: local, remote: remote) {
            merged = automaticMerge
        } else {
            Log.warn("sync", "rowsync conflict \(op.uuid); automatic overwrite blocked")
            let localCiphertext = try requireCandidateCiphertext(op)
            guard let localPlaintext = RowSyncCipher.decrypt(localCiphertext, key: key, uuid: op.uuid) else {
                throw RowSyncSafetyError.unreadableItem
            }
            let marker = try await registerLocalCandidate(
                op, plaintext: localPlaintext, expectedRevision: revision,
                key: key, client: client, token: token, vaultId: vaultId)
            state.pendingConflicts[op.uuid] = marker
            throw RowSyncSafetyError.conflictNeedsResolution
        }
        applyItem(merged, to: &database)
        state.revisions[op.uuid] = revision
        if hasSameContent(merged, remote) {
            state.dirtyUpserts.removeValue(forKey: op.uuid)
        } else {
            state.dirtyUpserts[op.uuid] = merged.modifiedMs
        }
        state.syncedMtimes[op.uuid] = remote.modifiedMs
        state.encryptedItemBaselines[op.uuid] = try RowSyncCipher.encryptBaseline(remote, key: key)
    }

    private static func registerLocalItemCandidate(
        _ item: DatabaseItem,
        modifiedMs: TimeInterval,
        baseRevision: UInt64,
        expectedRevision: UInt64,
        expectedDeletedSequence: Int? = nil,
        key: RowSyncKey,
        labelNames: [UUID: String],
        client: RelayClient,
        token: String,
        vaultId: String
    ) async throws -> RowSyncPendingConflict {
        try requireAvailableAttachmentContent(item)
        let plaintext = DatabaseItemCodec.xmlData(item, labelNames: labelNames)
        let ciphertext = try RowSyncCipher.encrypt(plaintext, key: key, uuid: item.uuid)
        let operation = RelayClient.ItemOp(
            uuid: item.uuid, kind: item.syncKind, isDelete: false,
            baseRevision: baseRevision,
            bodyB64: ciphertext.base64EncodedString(),
            sha256: SyncConflict.sha256Hex(ciphertext),
            modifiedMs: modifiedMs)
        return try await registerLocalCandidate(
            operation, plaintext: plaintext, expectedRevision: expectedRevision,
            expectedDeletedSequence: expectedDeletedSequence,
            key: key, client: client, token: token, vaultId: vaultId)
    }

    private static func registerLocalCandidate(
        _ operation: RelayClient.ItemOp,
        plaintext: Data,
        expectedRevision: UInt64,
        expectedDeletedSequence: Int? = nil,
        key: RowSyncKey,
        client: RelayClient,
        token: String,
        vaultId: String
    ) async throws -> RowSyncPendingConflict {
        let identity = RowSyncCipher.conflictCandidateIdentity(
            plaintext: plaintext, key: key, uuid: operation.uuid,
            baseRevision: operation.baseRevision, kind: operation.kind,
            isDelete: operation.isDelete)
        let registration = try await client.registerConflictCandidate(
            token: token, vaultId: vaultId, operation: operation,
            expectedRevision: expectedRevision,
            candidateID: identity.candidateID,
            fingerprint: identity.fingerprint,
            expectedDeletedSequence: expectedDeletedSequence)
        return RowSyncPendingConflict(
            conflictID: registration.conflictID,
            candidateID: identity.candidateID,
            fingerprint: identity.fingerprint,
            baseRevision: operation.baseRevision,
            kind: operation.kind,
            isDelete: operation.isDelete)
    }

    private static func registerDeletedRemoteConflict(
        _ op: RelayClient.ItemOp,
        revision: UInt64,
        sequence: Int,
        key: RowSyncKey,
        client: RelayClient,
        token: String,
        vaultId: String
    ) async throws -> RowSyncPendingConflict {
        guard let bodyB64 = op.bodyB64,
              let ciphertext = Data(base64Encoded: bodyB64),
              let plaintext = RowSyncCipher.decrypt(ciphertext, key: key, uuid: op.uuid) else {
            throw RowSyncSafetyError.unreadableItem
        }
        return try await registerLocalCandidate(
            op, plaintext: plaintext, expectedRevision: revision,
            expectedDeletedSequence: sequence,
            key: key, client: client, token: token, vaultId: vaultId)
    }

    private static func requireCandidateCiphertext(_ operation: RelayClient.ItemOp) throws -> Data {
        guard let bodyB64 = operation.bodyB64,
              let ciphertext = Data(base64Encoded: bodyB64) else {
            throw RowSyncSafetyError.invalidResponse
        }
        return ciphertext
    }

    private static func hasSameContent(_ local: DatabaseItem, _ remote: DatabaseItem) -> Bool {
        local.syncKind == remote.syncKind
            && RowSyncBaseline(item: local).matches(remote)
    }

    private static func requireAvailableAttachmentContent(_ item: DatabaseItem) throws {
        guard !item.hasUnavailableAttachmentContent else {
            throw RowSyncSafetyError.attachmentContentUnavailable
        }
    }

    private static func baseline(uuid: UUID, state: RowSyncState,
                                 key: RowSyncKey) throws -> RowSyncBaseline? {
        guard let encrypted = state.encryptedItemBaselines[uuid] else { return nil }
        guard let baseline = RowSyncCipher.decryptBaseline(encrypted, key: key, uuid: uuid) else {
            throw RowSyncSafetyError.baselineUnavailable
        }
        return baseline
    }

    /// 从脏集合构造上行批(≤200/批),upsert 条目体按 VEK 加密。
    private static func collectOps(database: PasswordDatabase, state: RowSyncState,
                                   key: RowSyncKey, labelNames: [UUID: String]) throws -> [RelayClient.ItemOp] {
        var ops: [RelayClient.ItemOp] = []
        for (uuid, ms) in state.dirtyDeletes.sorted(by: { $0.value < $1.value })
            where state.pendingConflicts[uuid] == nil {
            ops.append(RelayClient.ItemOp(uuid: uuid, kind: 1, isDelete: true,
                                          baseRevision: state.revisions[uuid] ?? 0, modifiedMs: ms))
        }
        for (uuid, ms) in state.dirtyUpserts.sorted(by: { $0.value < $1.value }) {
            guard state.pendingConflicts[uuid] == nil else { continue }
            guard let item = localItem(uuid: uuid, in: database) else { continue }
            let plaintext = DatabaseItemCodec.xmlData(item, labelNames: labelNames)
            let sealed = try RowSyncCipher.encrypt(plaintext, key: key, uuid: uuid)
            ops.append(RelayClient.ItemOp(uuid: uuid, kind: item.syncKind, isDelete: false,
                                          baseRevision: state.revisions[uuid] ?? 0,
                                          bodyB64: sealed.base64EncodedString(),
                                          sha256: SyncConflict.sha256Hex(sealed),
                                          modifiedMs: ms,
                                          attachmentRefs: try attachmentReferences(for: item)))
        }
        return Array(ops.prefix(200))
    }

    private static func attachmentReferences(
        for item: DatabaseItem
    ) throws -> [RelayClient.AttachmentReference] {
        guard case let .card(card) = item else { return [] }
        let attachments = card.images + card.files
        guard attachments.allSatisfy({ $0.hasPersistentID && $0.hasPersistentContentVersion }),
              Set(attachments.map(\.id)).count == attachments.count else {
            throw RowSyncSafetyError.invalidResponse
        }
        return attachments.map {
            RelayClient.AttachmentReference(
                attachmentID: $0.id, contentVersion: $0.contentVersion)
        }
    }

    private static func uploadAttachmentVersions(
        in item: DatabaseItem,
        key: RowSyncKey,
        client: RelayClient,
        token: String,
        vaultId: String
    ) async throws {
        guard case let .card(card) = item else { return }
        let attachments = card.images + card.files
        guard !attachments.isEmpty else { return }
        let remoteVersions = try await client.getAttachmentVersions(
            token: token, vaultId: vaultId, cardUuid: card.id)
        var uploaded = Set(remoteVersions.compactMap { entry -> String? in
            guard entry.cardID == card.id, let version = entry.contentVersion else { return nil }
            return "\(entry.attachmentID.uuidString):\(version.uuidString)"
        })
        for attachment in attachments {
            guard attachment.hasPersistentID, attachment.hasPersistentContentVersion else {
                throw RowSyncSafetyError.attachmentContentUnavailable
            }
            let identity = "\(attachment.id.uuidString):\(attachment.contentVersion.uuidString)"
            guard !uploaded.contains(identity) else { continue }
            guard let data = attachment.data else { throw RowSyncSafetyError.attachmentContentUnavailable }
            guard data.count <= AttachmentPolicy.maximumOriginalBytes else {
                throw RelayClient.RelayError.itemTooLarge
            }
            let encrypted = try AttachmentSyncCipher.encrypt(
                data: data, key: key,
                attachmentID: attachment.id, contentVersion: attachment.contentVersion)
            do {
                try await client.putAttachment(
                    token: token, vaultId: vaultId, attachUuid: attachment.id,
                    contentVersion: attachment.contentVersion, cardUuid: card.id,
                    cipher: encrypted.cipher, dekWrapped: encrypted.dekWrapped)
            } catch RelayClient.RelayError.attachmentVersionConflict {
                let refreshed = try await client.getAttachmentVersions(
                    token: token, vaultId: vaultId, cardUuid: card.id)
                guard refreshed.contains(where: {
                    $0.cardID == card.id && $0.attachmentID == attachment.id
                        && $0.contentVersion == attachment.contentVersion
                }) else {
                    throw RelayClient.RelayError.attachmentVersionConflict
                }
            }
            uploaded.insert(identity)
        }
    }

    private static func downloadMissingAttachmentVersions(
        _ attachments: [Attachment],
        key: RowSyncKey,
        client: RelayClient,
        token: String,
        vaultId: String
    ) async throws -> [Attachment] {
        var result = attachments
        for index in result.indices where result[index].data == nil {
            try Task.checkCancellation()
            let attachment = result[index]
            guard attachment.hasPersistentID, attachment.hasPersistentContentVersion else {
                throw RowSyncSafetyError.attachmentContentUnavailable
            }
            let version = attachment.contentVersion
            let encrypted = try await client.getAttachment(
                token: token, vaultId: vaultId,
                attachUuid: attachment.id, contentVersion: version)
            let data = try AttachmentSyncCipher.decrypt(
                cipher: encrypted.cipher, dekWrapped: encrypted.dekWrapped,
                key: key, attachmentID: attachment.id, contentVersion: version)
            guard result[index].installDownloadedContent(data, for: version) else {
                throw RowSyncSafetyError.invalidResponse
            }
        }
        return result
    }

    // MARK: - 全量重建(快照+差量,§6.3)

    /// 获取完整快照并追赶分页期间的增量；含有本地数据时应使用带 localDatabase 的重载。
    /// - Parameters:
    ///   - client: 行级同步客户端。
    ///   - token: 当前账户授权。
    ///   - vaultId: 云库身份。
    ///   - key: 配套库密钥。
    ///   - state: 无待同步修改的状态，成功后替换为已追平的快照基线。
    /// - Returns: 已取得并验证全部分页且追赶后续变更的数据库。
    /// - Throws: 网络、协议、无法读取条目或分页不完整错误；失败不改写状态。
    public static func fullRebuild(client: RelayClient, token: String, vaultId: String, key: RowSyncKey,
                                   state: inout RowSyncState) async throws -> PasswordDatabase {
        guard state.pendingConflicts.isEmpty else {
            throw RowSyncSafetyError.conflictNeedsResolution
        }
        try state.validateQuarantinedItems(key: key)
        guard !state.needsContentBaselineMigration else {
            throw RowSyncSafetyError.baselineUnavailable
        }
        _ = try state.validatedBaselines(key: key)
        return try await rebuild(client: client, token: token, vaultId: vaultId, key: key, state: &state)
    }

    private static func rebuild(client: RelayClient, token: String, vaultId: String, key: RowSyncKey,
                                state: inout RowSyncState) async throws -> PasswordDatabase {
        let startedAt = Date()
        Log.info("sync", "rowsync full rebuild started")
        do {
            var workingState = state
            var database = try await fetchSnapshot(
                client: client, token: token, vaultId: vaultId, key: key, state: &workingState)
            _ = try await pull(
                client: client, token: token, vaultId: vaultId, key: key,
                database: &database, state: &workingState)
            state = workingState
            return database
        } catch {
            let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
            Log.error("sync", "rowsync rebuild paused ms=\(elapsed); local state retained: \(error)")
            throw error
        }
    }

    private static func fetchSnapshot(client: RelayClient, token: String, vaultId: String,
                                      key: RowSyncKey, state: inout RowSyncState) async throws -> PasswordDatabase {
        guard !state.hasPendingWork else { throw RowSyncSafetyError.localDataNeedsRecovery }
        let startedAt = Date()
        let headSeqAtStart = try await client.vaultSeq(token: token, vaultId: vaultId).headSeq
        var database = PasswordDatabase()
        var revisions: [UUID: UInt64] = [:]
        var encryptedBaselines: [UUID: Data] = [:]
        var cursorMs = 0
        var cursorUuid = ""
        var isComplete = false
        var seenIDs = Set<UUID>()
        for _ in 0..<1000 {
            let (items, next, _) = try await client.listItems(
                token: token, vaultId: vaultId, cursorMs: cursorMs, cursorUuid: cursorUuid)
            for listed in items {
                guard seenIDs.insert(listed.uuid).inserted else {
                    throw RowSyncSafetyError.incompleteSnapshot
                }
                let plaintext = Data(base64Encoded: listed.bodyB64).flatMap {
                    RowSyncCipher.decrypt($0, key: key, uuid: listed.uuid)
                }
                guard let plaintext else {
                    let quarantined = try RowSyncCipher.quarantine(
                        listed, reason: .authenticationFailed, key: key)
                    state.quarantinedItems[quarantined.id] = quarantined
                    Log.error("sync", "rowsync rebuild isolated unreadable item \(listed.uuid)")
                    continue
                }
                guard let parsedItem = DatabaseItemCodec.parse(
                    kind: listed.kind, uuid: listed.uuid, data: plaintext) else {
                    let quarantined = try RowSyncCipher.quarantine(
                        listed, reason: .unsupportedFormat, key: key)
                    state.quarantinedItems[quarantined.id] = quarantined
                    Log.warn("sync", "rowsync rebuild isolated unsupported item \(listed.uuid)")
                    continue
                }
                applyItem(parsedItem, to: &database)
                revisions[listed.uuid] = listed.revision
                encryptedBaselines[listed.uuid] = try RowSyncCipher.encryptBaseline(parsedItem, key: key)
            }
            guard let next else {
                isComplete = true
                break
            }
            guard next.ms > cursorMs || (next.ms == cursorMs && next.uuid > cursorUuid) else {
                throw RowSyncSafetyError.incompleteSnapshot
            }
            cursorMs = next.ms
            cursorUuid = next.uuid
        }
        guard isComplete else { throw RowSyncSafetyError.incompleteSnapshot }
        state.revisions = revisions
        state.encryptedItemBaselines = encryptedBaselines
        state.dirtyUpserts = [:]
        state.dirtyDeletes = [:]
        state.syncedMtimes = Dictionary(
            uniqueKeysWithValues: allItems(database: database).map { ($0.uuid, $0.modifiedMs) })
        state.cursor = headSeqAtStart
        Log.info("sync", "rowsync rebuilt \(database.cards.count) card(s), \(database.labels.count) label(s) ms=\(Int(Date().timeIntervalSince(startedAt) * 1000))")
        return database
    }

    /// 全量重建前核对本地内容；缺席或分歧时停止，等待后续恢复流程处理。
    /// - Parameters:
    ///   - client: 行级同步客户端。
    ///   - token: 当前账户授权。
    ///   - vaultId: 云库身份。
    ///   - key: 配套库密钥。
    ///   - localDatabase: 需要保护的本地数据。
    ///   - state: 配套状态，仅验证成功后更新。
    /// - Returns: 核对完成的完整快照。
    /// - Throws: 网络、协议错误或 RowSyncSafetyError，不覆盖本机内容。
    public static func fullRebuild(client: RelayClient, token: String, vaultId: String,
                                   key: RowSyncKey, localDatabase: PasswordDatabase,
                                   state: inout RowSyncState) async throws -> PasswordDatabase {
        guard state.pendingConflicts.isEmpty else {
            throw RowSyncSafetyError.conflictNeedsResolution
        }
        try state.validateQuarantinedItems(key: key)
        var workingState = state
        var checkedState = state
        try checkedState.recomputeDirty(database: localDatabase, key: key)
        let localItems = allItems(database: localDatabase)
        let existingQuarantinedIDs = Set(state.quarantinedItems.values.map(\.uuid))
        let localNewIDs = Set(localItems.map(\.uuid).filter {
            state.revisions[$0] == nil && state.syncedMtimes[$0] == nil
                && state.encryptedItemBaselines[$0] == nil
                && !existingQuarantinedIDs.contains($0)
        })
        let pendingExistingIDs = Set(checkedState.dirtyUpserts.keys).subtracting(localNewIDs)
        guard pendingExistingIDs.isEmpty, checkedState.dirtyDeletes.isEmpty else {
            Log.warn("sync", "rowsync rebuild blocked: local pending changes retained")
            throw RowSyncSafetyError.localDataNeedsRecovery
        }
        let rebuilt = try await rebuild(
            client: client, token: token, vaultId: vaultId, key: key, state: &workingState)
        var mergedDatabase = rebuilt
        let quarantinedIDs = Set(workingState.quarantinedItems.values.map(\.uuid))
        for item in localItems {
            guard let remote = localItem(uuid: item.uuid, in: rebuilt) else {
                if quarantinedIDs.contains(item.uuid) {
                    applyItem(item, to: &mergedDatabase)
                    Log.warn("sync", "rowsync rebuild retained local item with quarantined cloud record \(item.uuid)")
                    continue
                }
                guard localNewIDs.contains(item.uuid) else {
                    Log.warn("sync", "known local item absent from snapshot \(item.uuid)")
                    throw RowSyncSafetyError.localDataNeedsRecovery
                }
                applyItem(item, to: &mergedDatabase)
                workingState.markDirty(uuid: item.uuid, modifiedMs: item.modifiedMs)
                continue
            }
            if state.encryptedItemBaselines[item.uuid] == nil && !hasSameContent(item, remote) {
                Log.warn("sync", "legacy sync baseline differs for item \(item.uuid)")
                throw RowSyncSafetyError.conflictNeedsResolution
            }
        }
        state = workingState
        return mergedDatabase
    }

    /// Rebuilds after a peer rekey, updating local markers for still-open candidates.
    /// - Parameters:
    ///   - client: Row-sync API client.
    ///   - token: Current account authorization.
    ///   - vaultId: Bound remote vault identity.
    ///   - oldKey: VEK used by the local database and sidecar before peer rekey.
    ///   - newKey: VEK from the newly adopted remote envelope.
    ///   - localDatabase: Local database decrypted with the previous password.
    ///   - state: Previous local row-sync sidecar.
    /// - Returns: Remote snapshot and new-key sidecar, preserving matching open candidates.
    /// - Throws: Network, authentication, or local data recovery errors.
    public static func adoptRemoteRekey(
        client: RelayClient,
        token: String,
        vaultId: String,
        oldKey: RowSyncKey,
        newKey: RowSyncKey,
        localDatabase: PasswordDatabase,
        state: RowSyncState
    ) async throws -> (database: PasswordDatabase, state: RowSyncState) {
        var previousState = state
        try previousState.recomputeDirty(database: localDatabase, key: oldKey)
        let pendingIDs = Set(previousState.pendingConflicts.keys)
        let unrelatedDirtyIDs = Set(previousState.dirtyUpserts.keys)
            .union(previousState.dirtyDeletes.keys)
            .subtracting(pendingIDs)
        guard unrelatedDirtyIDs.isEmpty else {
            throw RowSyncSafetyError.localDataNeedsRecovery
        }

        var adoptedState = RowSyncState()
        adoptedState.importedSourceKeys = previousState.importedSourceKeys
        adoptedState.needsSyncContinuation = previousState.needsSyncContinuation
        for (id, quarantined) in previousState.quarantinedItems {
            adoptedState.quarantinedItems[id] = try RowSyncCipher.rekeyQuarantine(
                quarantined, from: oldKey, to: newKey)
        }
        for (id, quarantined) in previousState.quarantinedCandidates {
            adoptedState.quarantinedCandidates[id] = try RowSyncCipher.rekeyQuarantineCandidate(
                quarantined, from: oldKey, to: newKey)
        }
        var database = try await fullRebuild(
            client: client, token: token, vaultId: vaultId, key: newKey,
            state: &adoptedState)
        guard !pendingIDs.isEmpty else {
            return (database, adoptedState)
        }

        let openConflicts = try await client.listConflicts(token: token, vaultId: vaultId)
        var retainedConflicts: [RelayClient.RetainedConflictRecord]?
        let labels = Dictionary(uniqueKeysWithValues: localDatabase.labels.map { ($0.id, $0.name) })

        for (uuid, marker) in previousState.pendingConflicts {
            let localItem = localItem(uuid: uuid, in: localDatabase)
            let plaintext: Data
            if marker.isDelete {
                guard localItem == nil else {
                    throw RowSyncSafetyError.localDataNeedsRecovery
                }
                plaintext = Data()
            } else {
                guard let localItem, localItem.syncKind == marker.kind,
                      !localItem.hasUnavailableAttachmentContent else {
                    throw RowSyncSafetyError.localDataNeedsRecovery
                }
                plaintext = DatabaseItemCodec.xmlData(localItem, labelNames: labels)
            }
            let identity = RowSyncCipher.conflictCandidateIdentity(
                plaintext: plaintext, key: newKey, uuid: uuid,
                baseRevision: marker.baseRevision, kind: marker.kind,
                isDelete: marker.isDelete)

            let openConflict = openConflicts.first {
                $0.conflictID == marker.conflictID && $0.itemUUID == uuid
            }
            let isOpenCandidate = openConflict?.candidates.contains {
                candidate in candidateMatchesRekeyedMarker(
                    candidate, marker: marker, identity: identity,
                    itemUUID: uuid, key: newKey)
            } ?? false
            if isOpenCandidate {
                adoptedState.pendingConflicts[uuid] = RowSyncPendingConflict(
                    conflictID: marker.conflictID,
                    candidateID: identity.candidateID,
                    fingerprint: identity.fingerprint,
                    baseRevision: marker.baseRevision,
                    kind: marker.kind,
                    isDelete: marker.isDelete)
                if marker.isDelete {
                    removeLocalItem(uuid: uuid, from: &database)
                    adoptedState.dirtyDeletes[uuid] =
                        previousState.dirtyDeletes[uuid] ?? Date().millis
                } else if let localItem {
                    applyItem(localItem, to: &database)
                }
                continue
            }

            if retainedConflicts == nil {
                retainedConflicts = try await client.listRetainedConflicts(
                    token: token, vaultId: vaultId)
            }
            let wasResolvedCandidate = retainedConflicts?.contains { conflict in
                conflict.conflictID == marker.conflictID && conflict.itemUUID == uuid
                    && conflict.candidates.contains { candidate in
                        candidateMatchesRekeyedMarker(
                            candidate, marker: marker, identity: identity,
                            itemUUID: uuid, key: newKey)
                    }
            } ?? false
            guard wasResolvedCandidate else {
                throw RowSyncSafetyError.localDataNeedsRecovery
            }
        }
        return (database, adoptedState)
    }

    private static func candidateMatchesRekeyedMarker(
        _ candidate: RelayClient.ConflictCandidate,
        marker: RowSyncPendingConflict,
        identity: (candidateID: String, fingerprint: String),
        itemUUID: UUID,
        key: RowSyncKey
    ) -> Bool {
        guard candidate.revision == marker.baseRevision,
              candidate.kind == marker.kind,
              candidate.isDelete == marker.isDelete else {
            return false
        }
        let plaintext: Data
        if candidate.isDelete {
            guard candidate.bodyB64 == nil else { return false }
            plaintext = Data()
        } else {
            guard let bodyB64 = candidate.bodyB64,
                  let ciphertext = Data(base64Encoded: bodyB64),
                  let decrypted = RowSyncCipher.decrypt(
                    ciphertext, key: key, uuid: itemUUID) else {
                return false
            }
            plaintext = decrypted
        }
        let candidateIdentity = RowSyncCipher.conflictCandidateIdentity(
            plaintext: plaintext, key: key, uuid: itemUUID,
            baseRevision: candidate.revision, kind: candidate.kind,
            isDelete: candidate.isDelete)
        return candidateIdentity.candidateID == identity.candidateID
            && candidateIdentity.fingerprint == identity.fingerprint
    }

    private static func removeLocalItem(uuid: UUID, from database: inout PasswordDatabase) {
        database.deleteCardPermanently(id: uuid)
        database.deleteLabelPermanently(id: uuid)
        database.userProfiles.removeAll { $0.id == uuid }
    }

    // MARK: - 改密 rekey(§6.5)

    /// 改密上行:全部条目按新 VEK 重加密分块上传,终批原子切换。
    ///
    /// - Parameters:
    ///   - client: 支持 rekey 事务的 API 客户端。
    ///   - token: 当前账户的 Bearer 令牌。
    ///   - vaultId: 目标远端库身份。
    ///   - database: 要重加密的完整本地数据库快照。
    ///   - oldKey: 当前附件 DEK 包装使用的库密钥。
    ///   - newKey: 本轮新库密钥。
    ///   - newEnvelope: 新密码包裹新库密钥的 .upwkey 信封字节。
    ///   - state: 远端提交成功后重置游标和 revision，供下次对账。
    /// - Throws: 加密、网络或 rekey 协议错误；调用方负责失败恢复与本地提交。
    public static func rekey(client: RelayClient, token: String, vaultId: String,
                             database: PasswordDatabase, oldKey: RowSyncKey,
                             newKey: RowSyncKey, newEnvelope: Data,
                             state: inout RowSyncState) async throws {
        let labelNames = Dictionary(uniqueKeysWithValues: database.labels.map { ($0.id, $0.name) })
        let items = allItems(database: database)
        var committedState = state
        committedState.cursor = 0
        committedState.revisions = [:]
        committedState.dirtyUpserts = [:]
        committedState.dirtyDeletes = [:]
        committedState.syncedMtimes = [:]
        committedState.encryptedItemBaselines = [:]
        committedState.needsSyncContinuation = false
        for (id, quarantined) in state.quarantinedItems {
            committedState.quarantinedItems[id] = try RowSyncCipher.rekeyQuarantine(
                quarantined, from: oldKey, to: newKey)
        }
        for (id, quarantined) in state.quarantinedCandidates {
            committedState.quarantinedCandidates[id] = try RowSyncCipher.rekeyQuarantineCandidate(
                quarantined, from: oldKey, to: newKey)
        }
        for item in items {
            committedState.syncedMtimes[item.uuid] = item.modifiedMs
            committedState.encryptedItemBaselines[item.uuid] = try RowSyncCipher.encryptBaseline(
                item, key: newKey)
        }
        let attachmentVersions = try await client.getAttachmentVersions(
            token: token, vaultId: vaultId)
        let rewrappedDEKs = try attachmentVersions.map { metadata
            -> (uuid: UUID, contentVersion: UUID, dekB64: String) in
            guard let contentVersion = metadata.contentVersion else {
                throw RowSyncSafetyError.attachmentKeyMigrationUnavailable
            }
            let wrapped = try AttachmentSyncCipher.rewrap(
                metadata.dekWrapped, oldKey: oldKey, newKey: newKey,
                attachmentID: metadata.attachmentID, contentVersion: contentVersion)
            return (metadata.attachmentID, contentVersion, wrapped.base64EncodedString())
        }
        let (rekeyId, _, expectedConflictCount) = try await client.rekeyBegin(
            token: token, vaultId: vaultId, envelope: newEnvelope,
            itemCount: items.count, dekCount: rewrappedDEKs.count)
        do {
            let chunkSize = 100
            var start = 0
            while start < items.count {
                let slice = items[start..<min(start + chunkSize, items.count)]
                let payload = try slice.map { item -> (uuid: UUID, kind: UInt8, bodyB64: String, sha256: String) in
                    let sealed = try RowSyncCipher.encrypt(
                        DatabaseItemCodec.xmlData(item, labelNames: labelNames), key: newKey, uuid: item.uuid)
                    return (item.uuid, item.syncKind, sealed.base64EncodedString(),
                            SyncConflict.sha256Hex(sealed))
                }
                try await client.rekeyChunk(
                    token: token, vaultId: vaultId, rekeyId: rekeyId, items: payload)
                start += chunkSize
            }
            start = 0
            while start < rewrappedDEKs.count {
                let slice = rewrappedDEKs[start..<min(start + chunkSize, rewrappedDEKs.count)]
                try await client.rekeyChunk(
                    token: token, vaultId: vaultId, rekeyId: rekeyId,
                    items: [], dekWraps: Array(slice))
                start += chunkSize
            }

            var offset = 0
            var receivedConflictCount = 0
            let originalPendingConflicts = state.pendingConflicts
            var pendingConflicts = originalPendingConflicts
            var updatedPendingConflictIDs = Set<UUID>()
            while receivedConflictCount < expectedConflictCount {
                let page = try await client.rekeyConflictCandidates(
                    token: token, vaultId: vaultId, rekeyId: rekeyId, offset: offset)
                guard page.total == expectedConflictCount, !page.candidates.isEmpty else {
                    throw RowSyncSafetyError.invalidResponse
                }
                let reencrypted = try page.candidates.map { candidate
                    -> (conflictID: String, oldCandidateID: String, candidateID: String,
                        fingerprint: String, bodyB64: String?, sha256: String?) in
                    let plaintext: Data
                    if candidate.isDelete {
                        guard candidate.body == nil else {
                            throw RowSyncSafetyError.invalidResponse
                        }
                        plaintext = Data()
                    } else {
                        guard let ciphertext = candidate.body,
                              let decrypted = RowSyncCipher.decrypt(
                                ciphertext, key: oldKey, uuid: candidate.itemUUID) else {
                            throw RowSyncSafetyError.unreadableItem
                        }
                        plaintext = decrypted
                    }
                    let identity = RowSyncCipher.conflictCandidateIdentity(
                        plaintext: plaintext, key: newKey, uuid: candidate.itemUUID,
                        baseRevision: candidate.revision, kind: candidate.kind,
                        isDelete: candidate.isDelete)
                    let ciphertext: Data?
                    if candidate.isDelete {
                        ciphertext = nil
                    } else {
                        ciphertext = try RowSyncCipher.encrypt(
                            plaintext, key: newKey, uuid: candidate.itemUUID)
                    }
                    if let stateUUID = originalPendingConflicts.first(where: {
                        $0.key == candidate.itemUUID
                            && $0.value.conflictID == candidate.conflictID
                            && $0.value.candidateID == candidate.oldCandidateID
                    })?.key, var marker = pendingConflicts[stateUUID] {
                        marker = RowSyncPendingConflict(
                            conflictID: marker.conflictID,
                            candidateID: identity.candidateID,
                            fingerprint: identity.fingerprint,
                            baseRevision: marker.baseRevision,
                            kind: marker.kind,
                            isDelete: marker.isDelete)
                        pendingConflicts[stateUUID] = marker
                        updatedPendingConflictIDs.insert(stateUUID)
                    }
                    return (
                        candidate.conflictID,
                        candidate.oldCandidateID,
                        identity.candidateID,
                        identity.fingerprint,
                        ciphertext?.base64EncodedString(),
                        ciphertext.map { SyncConflict.sha256Hex($0) })
                }
                try await client.rekeyConflictChunk(
                    token: token, vaultId: vaultId, rekeyId: rekeyId,
                    candidates: reencrypted)
                receivedConflictCount += page.candidates.count
                offset += page.candidates.count
            }
            guard receivedConflictCount == expectedConflictCount,
                  updatedPendingConflictIDs.count == state.pendingConflicts.count else {
                throw RowSyncSafetyError.conflictNeedsResolution
            }
            committedState.pendingConflicts = pendingConflicts
            for (uuid, marker) in pendingConflicts where marker.isDelete {
                committedState.dirtyDeletes[uuid] = state.dirtyDeletes[uuid] ?? Date().millis
            }
            try await client.rekeyCommit(token: token, vaultId: vaultId, rekeyId: rekeyId)
        } catch {
            do {
                try await client.rekeyAbort(token: token, vaultId: vaultId, rekeyId: rekeyId)
            } catch {
                Log.error("sync", "rowsync rekey abort failed for vault \(vaultId): \(error)")
            }
            throw error
        }
        // 服务端 revision 已变更；保留新 VEK 下的本地祖先，后续同步重建 revision。
        state = committedState
        Log.info(
            "sync", "rowsync rekey committed (\(items.count) item(s), \(rewrappedDEKs.count) attachment version(s), \(expectedConflictCount) conflict candidate(s))")
    }

    /// 按卡片、标签、个人资料的顺序返回全部同步条目。
    ///
    /// - Parameter database: 已解锁的数据库值。
    /// - Returns: 条目值副本；包含模板、归档和回收站中的卡片。
    public static func allItems(database: PasswordDatabase) -> [DatabaseItem] {
        database.cards.map(DatabaseItem.card) + database.labels.map(DatabaseItem.label)
            + database.userProfiles.map(DatabaseItem.userProfile)
    }
}
