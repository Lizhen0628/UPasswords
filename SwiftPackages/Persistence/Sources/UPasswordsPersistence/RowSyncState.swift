import Foundation
import UPasswordsCore

/// Local non-secret identity needed to resume a registered conflict safely.
public struct RowSyncPendingConflict: Codable, Equatable {
    public let conflictID: String
    public let candidateID: String
    public let fingerprint: String
    public let baseRevision: UInt64
    public let kind: UInt8
    public let isDelete: Bool

    /// Creates the retry marker without retaining plaintext or ciphertext.
    public init(conflictID: String, candidateID: String, fingerprint: String,
                baseRevision: UInt64, kind: UInt8, isDelete: Bool) {
        self.conflictID = conflictID
        self.candidateID = candidateID
        self.fingerprint = fingerprint
        self.baseRevision = baseRevision
        self.kind = kind
        self.isDelete = isDelete
    }
}

/// 同步游标、脏集合与加密共同基线的持久化 sidecar(`<名>.upwsync`,JSON)。
public struct RowSyncState: Codable, Equatable {
    /// 最后已应用的库级变更序列；须与对应数据库快照一起提交。
    public var cursor: Int = 0
    /// 各条目已知的服务端 revision(baseRevision 来源;上行的 CAS 令牌)。
    public var revisions: [UUID: UInt64] = [:]
    /// 待上行修改(uuid → 本地最后修改时间,毫秒)。
    public var dirtyUpserts: [UUID: TimeInterval] = [:]
    /// 待上行删除(uuid → 删除时间,毫秒;删除胜语义,§6.6)。
    public var dirtyDeletes: [UUID: TimeInterval] = [:]
    /// 最近一次成功同步的修改时间；保留条目集合用于发现本地删除，不作为冲突胜负依据。
    public var syncedMtimes: [UUID: TimeInterval] = [:]

    /// VEK 加密的共同祖先快照；每项使用独立 nonce，并以行 UUID 绑定 AAD。
    public var encryptedItemBaselines: [UUID: Data] = [:]
    /// 已登记候选的服务端身份和 keyed fingerprint；不保存任何条目内容。
    public var pendingConflicts: [UUID: RowSyncPendingConflict] = [:]
    /// Locally encrypted remote records that could not be authenticated or parsed.
    public var quarantinedItems: [String: RowSyncQuarantinedItem] = [:]
    /// Locally encrypted conflict candidates that could not be authenticated or parsed.
    public var quarantinedCandidates: [String: RowSyncQuarantinedCandidate] = [:]
    /// A durable checkpoint marker for a pull that stopped immediately after isolation.
    public var needsSyncContinuation = false
    /// One-way source-card keys already imported into this local database.
    public var importedSourceKeys: Set<String> = []

    /// 旧 sidecar 中已有同步身份但尚未建立加密共同基线的条目。
    public var needsContentBaselineMigration: Bool {
        let knownIDs = Set(syncedMtimes.keys)
            .union(revisions.keys)
        let quarantinedIDs = Set(quarantinedItems.values.map(\.uuid))
        return knownIDs.contains { encryptedItemBaselines[$0] == nil && !quarantinedIDs.contains($0) }
    }

    private enum CodingKeys: String, CodingKey {
        case cursor, revisions, dirtyUpserts, dirtyDeletes, syncedMtimes
        case encryptedItemBaselines, pendingConflicts, quarantinedItems, quarantinedCandidates
        case needsSyncContinuation, importedSourceKeys
    }

    /// 兼容未保存内容基线的旧 sidecar；缺少基线时首次同步保守地重新核对。
    /// - Parameter decoder: sidecar JSON 解码器。
    /// - Throws: 已存在字段类型不匹配时保留解码错误，不吞掉损坏数据。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cursor = try container.decode(Int.self, forKey: .cursor)
        revisions = try container.decode([UUID: UInt64].self, forKey: .revisions)
        dirtyUpserts = try container.decode([UUID: TimeInterval].self, forKey: .dirtyUpserts)
        dirtyDeletes = try container.decode([UUID: TimeInterval].self, forKey: .dirtyDeletes)
        syncedMtimes = try container.decode([UUID: TimeInterval].self, forKey: .syncedMtimes)
        encryptedItemBaselines = try container.decodeIfPresent(
            [UUID: Data].self, forKey: .encryptedItemBaselines) ?? [:]
        pendingConflicts = try container.decodeIfPresent(
            [UUID: RowSyncPendingConflict].self, forKey: .pendingConflicts) ?? [:]
        quarantinedItems = try container.decodeIfPresent(
            [String: RowSyncQuarantinedItem].self, forKey: .quarantinedItems) ?? [:]
        quarantinedCandidates = try container.decodeIfPresent(
            [String: RowSyncQuarantinedCandidate].self, forKey: .quarantinedCandidates) ?? [:]
        needsSyncContinuation = try container.decodeIfPresent(
            Bool.self, forKey: .needsSyncContinuation) ?? false
        importedSourceKeys = try container.decodeIfPresent(
            Set<String>.self, forKey: .importedSourceKeys) ?? []
    }

    /// 创建尚未同步的空游标、版本和脏集合。
    public init() {}

    /// 根据 VEK 加密的共同基线采集修改；缺少旧基线时保守重核。
    /// - Parameter database: 当前已解锁的完整数据库。
    /// - Parameter key: 当前数据库的 VEK。
    /// - Throws: 基线无法认证或与条目身份不符时抛出保护性错误，不修改状态。
    public mutating func recomputeDirty(database: PasswordDatabase, key: RowSyncKey) throws {
        var next = self
        let baselines = try validatedBaselines(key: key)
        let items = RowSync.allItems(database: database)
        let currentIDs = Set(items.map(\.uuid))
        let quarantinedIDs = Set(next.quarantinedItems.values.map(\.uuid))
        for item in items {
            guard next.dirtyDeletes[item.uuid] == nil,
                  next.pendingConflicts[item.uuid] == nil,
                  !quarantinedIDs.contains(item.uuid) else { continue }
            if let baseline = baselines[item.uuid] {
                if baseline.matches(item) {
                    next.dirtyUpserts.removeValue(forKey: item.uuid)
                } else {
                    next.dirtyUpserts[item.uuid] = item.modifiedMs
                }
            } else if let syncedMtime = next.syncedMtimes[item.uuid] {
                if syncedMtime != item.modifiedMs {
                    next.dirtyUpserts[item.uuid] = item.modifiedMs
                }
            } else {
                next.dirtyUpserts[item.uuid] = item.modifiedMs
            }
        }
        let knownIDs = Set(next.syncedMtimes.keys)
            .union(next.revisions.keys)
            .union(next.encryptedItemBaselines.keys)
        for uuid in knownIDs where !currentIDs.contains(uuid)
            && next.pendingConflicts[uuid] == nil && !quarantinedIDs.contains(uuid) {
            next.dirtyDeletes[uuid] = max(next.dirtyDeletes[uuid] ?? 0, Date().millis)
        }
        self = next
    }

    func validatedBaselines(key: RowSyncKey) throws -> [UUID: RowSyncBaseline] {
        var baselines: [UUID: RowSyncBaseline] = [:]
        for (uuid, ciphertext) in encryptedItemBaselines {
            guard let baseline = RowSyncCipher.decryptBaseline(ciphertext, key: key, uuid: uuid) else {
                throw RowSyncSafetyError.baselineUnavailable
            }
            baselines[uuid] = baseline
        }
        return baselines
    }

    func validateQuarantinedItems(key: RowSyncKey) throws {
        guard !needsSyncContinuation || !quarantinedItems.isEmpty else {
            throw RowSyncSafetyError.quarantineUnavailable
        }
        for (id, item) in quarantinedItems {
            guard id == item.id else { throw RowSyncSafetyError.quarantineUnavailable }
            _ = try RowSyncCipher.openQuarantine(item, key: key)
        }
        for (id, candidate) in quarantinedCandidates {
            guard id == candidate.id else { throw RowSyncSafetyError.quarantineUnavailable }
            _ = try RowSyncCipher.openQuarantineCandidate(candidate, key: key)
        }
    }

    /// 标记条目已改(新建/编辑;AppContext 数据变更入口统一调用)。
    public mutating func markDirty(uuid: UUID, modifiedMs: TimeInterval) {
        dirtyDeletes.removeValue(forKey: uuid)
        dirtyUpserts[uuid] = modifiedMs
    }

    /// 标记条目删除(回收站二段式的第二段)。
    public mutating func markDeleted(uuid: UUID, at ms: TimeInterval) {
        dirtyUpserts.removeValue(forKey: uuid)
        dirtyDeletes[uuid] = ms
    }

    /// 是否仍有待上行的修改或永久删除。
    public var hasPendingWork: Bool {
        !dirtyUpserts.isEmpty || !dirtyDeletes.isEmpty || !pendingConflicts.isEmpty
    }
}
