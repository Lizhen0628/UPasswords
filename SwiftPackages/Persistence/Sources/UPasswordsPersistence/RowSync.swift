import CryptoKit
import Foundation
import UPasswordsCore

// MARK: - RowSync 引擎(v7 行级同步)
//
// 职责:脏集合上行(批量 CAS + 冲突合并重试)、变更游标增量应用、
// 全量重建(快照+差量)、改密 rekey 编排。`.upw` 永远是唯一本地真源,
// 本引擎只做增量收敛,任何失败都不阻塞本地使用(Cloud/DESIGN.md §6)。
//
// 条目体加密:AES-GCM(VEK),AAD 绑定条目 uuid(行搬运防护,§3.1);
// 密文布局 = nonce(12) + ct + tag(16)。
// 隐私红线:引擎只经手条目密文、uuid 与 revision;日志只记计数/耗时/结果。

/// 同步游标与脏集合的持久化 sidecar(`<名>.upwsync`,JSON,无敏感值)。
public struct RowSyncState: Codable, Equatable {
    public var cursor: Int = 0
    /// 各条目已知的服务端 revision(baseRevision 来源;上行的 CAS 令牌)。
    public var revisions: [UUID: UInt64] = [:]
    /// 待上行修改(uuid → 本地最后修改时间,毫秒)。
    public var dirtyUpserts: [UUID: TimeInterval] = [:]
    /// 待上行删除(uuid → 删除时间,毫秒;删除胜语义,§6.6)。
    public var dirtyDeletes: [UUID: TimeInterval] = [:]
    /// 最近一次成功同步到服务端的各条目 mtime(快照差分脏采集的基线,
    /// 崩溃安全:重启后未上行的修改仍会被差分出来)。
    public var syncedMtimes: [UUID: TimeInterval] = [:]

    public init() {}

    /// 快照差分采集脏集合:与 syncedMtimes 比对,新改/新增入 upserts,
    /// 消失的入 deletes。覆盖一切编辑路径(含跨进程对 .upw 的写入在
    /// 重新解锁后可见),无需在各数据入口插桩。
    public mutating func recomputeDirty(database: PasswordDatabase) {
        let current = Dictionary(
            uniqueKeysWithValues: RowSync.allItems(database: database).map { ($0.uuid, $0.modifiedMs) })
        for (uuid, ms) in current where ms > (syncedMtimes[uuid] ?? -1) {
            dirtyUpserts[uuid] = ms
        }
        for uuid in syncedMtimes.keys where current[uuid] == nil {
            dirtyDeletes[uuid] = max(dirtyDeletes[uuid] ?? 0, Date().millis)
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

    public var hasPendingWork: Bool { !dirtyUpserts.isEmpty || !dirtyDeletes.isEmpty }
}

/// 增量/重建结果(供 UI 呈现同步状态)。
public struct RowSyncOutcome: Equatable {
    public var pulledItems = 0
    public var pushedItems = 0
    public var conflictsResolved = 0
    public var headSeq = 0
    public init() {}
}

/// 对端改密信号:password_version 前进,本端旧 VEK 将解不开新密文,
/// 调用方应强制锁定并引导用户输入新密码后走全量重建(§6.5 步骤 5)。
public struct RowSyncRekeySignal: Error, Equatable {
    public let passwordVersion: Int
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

public enum RowSyncCipher {
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
}

public enum RowSync {

    // MARK: - 下行(游标增量,§6.3)

    /// 拉取并应用变更直到追平 headSeq。
    /// - Throws: cursorExpired(调用方走全量重建)、RowSyncRekeySignal(对端改密)
    @discardableResult
    public static func pull(client: RelayClient, token: String, vaultId: String, key: RowSyncKey,
                            database: inout PasswordDatabase, state: inout RowSyncState) async throws -> RowSyncOutcome {
        var outcome = RowSyncOutcome()
        let startedAt = Date()
        for _ in 0..<200 {
            let (headSeq, changes) = try await client.getChanges(token: token, vaultId: vaultId, since: state.cursor)
            if changes.isEmpty {
                outcome.headSeq = headSeq
                break
            }
            for entry in changes {
                // 只统计实际改变本地内容的条目:自己上轮上传的回声在此为
                // 空操作,不计入"拉取 N 条"(否则删一条会显示"拉取 1 上传 1")
                if try apply(entry, key: key, to: &database, state: &state) {
                    outcome.pulledItems += 1
                }
                state.cursor = entry.seq
            }
            if state.cursor >= headSeq {
                outcome.headSeq = headSeq
                break
            }
        }
        Log.info("sync", "rowsync pulled \(outcome.pulledItems) item(s) to seq=\(state.cursor) ms=\(Int(Date().timeIntervalSince(startedAt) * 1000))")
        return outcome
    }

    /// 应用单条变更:upsert 按 revision 前进才采纳(与本地脏改按 mtime 决胜),
    /// 删除即移除(删除胜)。
    /// - Returns: 是否实际改变了本地内容。自己上一轮上传的回声(revision 未
    ///   超过本地已知)是空操作,返回 false——"拉取 N 条"只统计真变化,否则
    ///   用户删一条会看到"拉取 1 上传 1"的误导。
    private static func apply(_ entry: RelayClient.ChangeEntry, key: RowSyncKey,
                              to database: inout PasswordDatabase,
                              state: inout RowSyncState) throws -> Bool {
        if entry.op == "rekey" {
            // 对端改密:本端旧 VEK 已解不开新密文,交调用方强制锁定接管
            throw RowSyncRekeySignal(passwordVersion: Int(entry.revision))
        }
        guard entry.revision > (state.revisions[entry.uuid] ?? 0) else { return false }
        if entry.deleted {
            let existed = localItem(uuid: entry.uuid, in: database) != nil
            removeItem(uuid: entry.uuid, from: &database, state: &state)
            return existed
        }
        guard let bodyB64 = entry.bodyB64, let sealed = Data(base64Encoded: bodyB64),
              let plaintext = RowSyncCipher.decrypt(sealed, key: key, uuid: entry.uuid),
              let kind = entry.kind,
              let item = DatabaseItemCodec.parse(kind: kind, uuid: entry.uuid, data: plaintext) else {
            // 密文解不开(改密窗口/AAD 捕捉到行搬运)或损坏:按删除收敛,
            // 让全量对账自愈;不中断本轮拉取
            Log.warn("sync", "rowsync entry \(entry.uuid.uuidString.prefix(8))… undecodable, dropped")
            let existed = localItem(uuid: entry.uuid, in: database) != nil
            removeItem(uuid: entry.uuid, from: &database, state: &state)
            return existed
        }
        // 本地有未上行修改:按 LWW 决胜,本地新则保留待上行(服务端 CAS 会裁决)。
        // 即使保留本地也要追平 revision 基准——否则下次上行仍带旧 base,
        // 必撞冲突再空跑一轮(曾致每轮同步固定 25 个冲突的重演)。
        if state.dirtyUpserts[entry.uuid] != nil {
            let localMs = localItem(uuid: entry.uuid, in: database)?.modifiedMs ?? 0
            if localMs >= (entry.modifiedMs ?? 0) {
                state.revisions[entry.uuid] = entry.revision
                return false
            }
        }
        applyItem(item, to: &database)
        state.revisions[entry.uuid] = entry.revision
        state.syncedMtimes[entry.uuid] = item.modifiedMs
        return true
    }

    private static func removeItem(uuid: UUID, from database: inout PasswordDatabase, state: inout RowSyncState) {
        database.deleteCardPermanently(id: uuid)
        database.deleteLabelPermanently(id: uuid)
        state.revisions.removeValue(forKey: uuid)
        state.syncedMtimes.removeValue(forKey: uuid)
        // 删除胜:本地未上行的修改一并丢弃(§6.6)
        state.dirtyUpserts.removeValue(forKey: uuid)
        state.dirtyDeletes.removeValue(forKey: uuid)
    }

    static func localItem(uuid: UUID, in database: PasswordDatabase) -> DatabaseItem? {
        if let c = database.card(id: uuid) { return .card(c) }
        if let l = database.label(id: uuid) { return .label(l) }
        return nil
    }

    static func applyItem(_ item: DatabaseItem, to database: inout PasswordDatabase) {
        switch item {
        case .card(let card):
            if let i = database.cards.firstIndex(where: { $0.id == card.id }) {
                database.cards[i] = card
            } else {
                database.cards.append(card)
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

    /// 推送脏集合(修改 + 删除);冲突就地在端上按 LWW/删除胜合并后重试(至多 3 轮)。
    @discardableResult
    public static func push(client: RelayClient, token: String, vaultId: String, key: RowSyncKey,
                            database: inout PasswordDatabase, state: inout RowSyncState) async throws -> RowSyncOutcome {
        var outcome = RowSyncOutcome()
        let startedAt = Date()
        let labelNames = Dictionary(uniqueKeysWithValues: database.labels.map { ($0.id, $0.name) })
        // 连续排干整个脏集合:collectOps 每轮只取 ≤200 条,此前"无冲突即
        // 收工"会让大脏集(新绑定/导入)每轮同步只推 200 条,余量悬到下轮
        // (曾致 pending=142 反复出现)。这里直到无批可发或仅剩冲突重试。
        for _ in 0..<50 {
            let ops = try collectOps(database: database, state: state, key: key, labelNames: labelNames)
            if ops.isEmpty { break }
            let results = try await client.postItems(token: token, vaultId: vaultId, items: ops)
            var needRetry = false
            let wasFullBatch = ops.count >= 200
            for op in ops {
                switch results[op.uuid] ?? .notFound(deletedAt: nil) {
                case .ok(let revision):
                    state.revisions[op.uuid] = revision
                    if let ms = state.dirtyUpserts.removeValue(forKey: op.uuid) {
                        state.syncedMtimes[op.uuid] = ms
                    }
                    state.dirtyDeletes.removeValue(forKey: op.uuid)
                    outcome.pushedItems += 1
                case .notFound:
                    // 缺席即删除(§6.6):本地丢弃,绝不当新条目重新插入
                    removeItem(uuid: op.uuid, from: &database, state: &state)
                    outcome.conflictsResolved += 1
                    Log.info("sync", "rowsync push \(op.uuid.uuidString.prefix(8))… not_found → dropped (deleted remotely)")
                case .conflict(let revision, let bodyB64):
                    state.revisions[op.uuid] = revision
                    if resolveConflict(op, revision: revision, bodyB64: bodyB64, key: key,
                                       database: &database, state: &state) {
                        outcome.conflictsResolved += 1
                    } else {
                        needRetry = true
                    }
                }
            }
            // 未满批且无冲突 = 脏集已排干;满批则继续取下一批
            if !needRetry && !wasFullBatch { break }
        }
        Log.info("sync", "rowsync pushed \(outcome.pushedItems) item(s), conflicts \(outcome.conflictsResolved) ms=\(Int(Date().timeIntervalSince(startedAt) * 1000))")
        return outcome
    }

    /// 冲突裁决:对端现行行 vs 本地脏条目,LWW;对端胜(或平局值相同)返回
    /// true(清脏收敛),本地胜返回 false(需带新 base 重试)。
    private static func resolveConflict(_ op: RelayClient.ItemOp, revision: UInt64, bodyB64: String?,
                                        key: RowSyncKey,
                                        database: inout PasswordDatabase, state: inout RowSyncState) -> Bool {
        if op.isDelete {
            // 删除撞冲突:现行行没拿到,下一轮以新 base 重删
            return false
        }
        guard let bodyB64, let sealed = Data(base64Encoded: bodyB64),
              let plaintext = RowSyncCipher.decrypt(sealed, key: key, uuid: op.uuid),
              let remote = DatabaseItemCodec.parse(kind: op.kind, uuid: op.uuid, data: plaintext),
              let local = localItem(uuid: op.uuid, in: database) else {
            return false
        }
        let winner = DatabaseItemCodec.resolve(local: local, remote: remote)
        applyItem(winner, to: &database)
        if winner == remote {
            state.dirtyUpserts.removeValue(forKey: op.uuid)
            state.syncedMtimes[op.uuid] = remote.modifiedMs
            return true
        }
        return false
    }

    /// 从脏集合构造上行批(≤200/批),upsert 条目体按 VEK 加密。
    private static func collectOps(database: PasswordDatabase, state: RowSyncState,
                                   key: RowSyncKey, labelNames: [UUID: String]) throws -> [RelayClient.ItemOp] {
        var ops: [RelayClient.ItemOp] = []
        for (uuid, ms) in state.dirtyDeletes.sorted(by: { $0.value < $1.value }) {
            ops.append(RelayClient.ItemOp(uuid: uuid, kind: 1, isDelete: true,
                                          baseRevision: state.revisions[uuid] ?? 0, modifiedMs: ms))
        }
        for (uuid, ms) in state.dirtyUpserts.sorted(by: { $0.value < $1.value }) {
            guard let item = localItem(uuid: uuid, in: database) else { continue }
            let plaintext = DatabaseItemCodec.xmlData(item, labelNames: labelNames)
            let sealed = try RowSyncCipher.encrypt(plaintext, key: key, uuid: uuid)
            ops.append(RelayClient.ItemOp(uuid: uuid, kind: item.syncKind, isDelete: false,
                                          baseRevision: state.revisions[uuid] ?? 0,
                                          bodyB64: sealed.base64EncodedString(),
                                          sha256: SyncConflict.sha256Hex(sealed),
                                          modifiedMs: ms))
        }
        return Array(ops.prefix(200))
    }

    // MARK: - 全量重建(快照+差量,§6.3)

    /// 新设备恢复 / 游标过期 / 手动修复:分页拉全部条目重建本地库。
    /// 完成后游标对齐重建开始时的 headSeq(重建期间的并发写由随后的增量补齐)。
    public static func fullRebuild(client: RelayClient, token: String, vaultId: String, key: RowSyncKey,
                                   state: inout RowSyncState) async throws -> PasswordDatabase {
        let startedAt = Date()
        let headSeqAtStart = try await client.vaultSeq(token: token, vaultId: vaultId).headSeq
        var database = PasswordDatabase()
        var revisions: [UUID: UInt64] = [:]
        var cursorMs = 0
        var cursorUuid = ""
        loop: for _ in 0..<1000 {
            let (items, next, _) = try await client.listItems(
                token: token, vaultId: vaultId, cursorMs: cursorMs, cursorUuid: cursorUuid)
            for listed in items {
                guard let sealed = Data(base64Encoded: listed.bodyB64),
                      let plaintext = RowSyncCipher.decrypt(sealed, key: key, uuid: listed.uuid),
                      let item = DatabaseItemCodec.parse(kind: listed.kind, uuid: listed.uuid, data: plaintext) else {
                    Log.warn("sync", "rowsync rebuild entry \(listed.uuid.uuidString.prefix(8))… undecodable, skipped")
                    continue
                }
                applyItem(item, to: &database)
                revisions[listed.uuid] = listed.revision
            }
            guard let next else { break loop }
            cursorMs = next.ms
            cursorUuid = next.uuid
        }
        state.revisions = revisions
        state.dirtyUpserts = [:]
        state.dirtyDeletes = [:]
        state.syncedMtimes = Dictionary(
            uniqueKeysWithValues: allItems(database: database).map { ($0.uuid, $0.modifiedMs) })
        state.cursor = headSeqAtStart
        Log.info("sync", "rowsync rebuilt \(database.cards.count) card(s), \(database.labels.count) label(s) ms=\(Int(Date().timeIntervalSince(startedAt) * 1000))")
        return database
    }

    // MARK: - 改密 rekey(§6.5)

    /// 改密上行:全部条目按新 VEK 重加密分块上传,终批原子切换。
    /// - Parameter newEnvelope: 新密码包裹新 VEK 的 .upwkey 信封字节
    public static func rekey(client: RelayClient, token: String, vaultId: String,
                             database: PasswordDatabase, newKey: RowSyncKey, newEnvelope: Data,
                             state: inout RowSyncState) async throws {
        let labelNames = Dictionary(uniqueKeysWithValues: database.labels.map { ($0.id, $0.name) })
        let items = allItems(database: database)
        let (rekeyId, _) = try await client.rekeyBegin(
            token: token, vaultId: vaultId, envelope: newEnvelope,
            itemCount: items.count, dekCount: 0)
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
            try await client.rekeyChunk(token: token, vaultId: vaultId, rekeyId: rekeyId, items: payload)
            start += chunkSize
        }
        try await client.rekeyCommit(token: token, vaultId: vaultId, rekeyId: rekeyId)
        // 换入后服务端全部行 revision+1:清空游标与 revision 映射,下次同步全量对账
        state.cursor = 0
        state.revisions = [:]
        Log.info("sync", "rowsync rekey committed (\(items.count) item(s))")
    }

    /// 全部条目(卡片 + 标签)。
    public static func allItems(database: PasswordDatabase) -> [DatabaseItem] {
        database.cards.map(DatabaseItem.card) + database.labels.map(DatabaseItem.label)
    }
}
