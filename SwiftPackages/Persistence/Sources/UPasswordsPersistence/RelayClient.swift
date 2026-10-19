import Foundation
import UPasswordsCore

/// api.upasswords.com 协调服务客户端(见 Cloud/DESIGN.md v7):
/// 账户(邮箱验证码)+ 库注册表 + 行级条目同步(items/changes)+
/// 附件(R2 blob)+ 改密 rekey。零知识红线:所有请求只携带密文/哈希/
/// 元数据,绝不携带主密码或库密钥。
public struct RelayClient {
    /// 验证码位数(与服务端 randomCode6 同源约定;UI 输入门槛与校验共用)。
    public static let verificationCodeLength = 6

    /// 验证码用途:登录 / 敏感操作(删库、注销)。
    public enum Purpose: String {
        case login, sensitive
    }

    /// 客户端平台标识(会话表 platform 列,设备管理页展示)。
    public enum Platform: String {
        case macos, ios, autofill
        case extSafari = "ext-safari"
        case extChrome = "ext-chrome"
        case extEdge = "ext-edge"
        case extFirefox = "ext-firefox"
        case other
    }

    /// 登录会话(令牌只在签发响应出现一次,本地经 RelayTokenKeychain 保存)。
    public struct Session: Equatable {
        public let token: String
        public let expiresAt: Date
        public let userId: String
    }

    /// 已登录设备(会话管理页展示与撤销)。isCurrent=发起列表请求的本机会话。
    public struct DeviceSession: Identifiable, Equatable {
        public let id: String
        public let deviceName: String
        public let platform: String
        public let isCurrent: Bool
        public let lastSeenAt: Date?
        public init(id: String, deviceName: String, platform: String,
                    isCurrent: Bool = false, lastSeenAt: Date? = nil) {
            self.id = id
            self.deviceName = deviceName
            self.platform = platform
            self.isCurrent = isCurrent
            self.lastSeenAt = lastSeenAt
        }
    }

    /// 注册表单库记录;envelope 密文仅单库查询返回。
    public struct VaultRecord: Equatable {
        public let vaultId: String
        public let name: String
        public let passwordVersion: Int
        public let passwordChangedAt: Date?
        public let envelopeChangedAt: Date?
        public let hasEnvelope: Bool
        public let envelope: Data?
        public let headSeq: Int
        public let itemCount: Int
    }

    /// 条目上行操作(§6.2):upsert 携新密文体,delete 携原 baseRevision。
    public struct ItemOp {
        public let uuid: UUID
        public let kind: UInt8          // 1=card 2=label(与 DatabaseItem.syncKind 对齐)
        public let isDelete: Bool
        public let baseRevision: UInt64
        public let bodyB64: String?
        public let sha256: String?
        public let modifiedMs: TimeInterval
        public init(uuid: UUID, kind: UInt8, isDelete: Bool, baseRevision: UInt64,
                    bodyB64: String? = nil, sha256: String? = nil, modifiedMs: TimeInterval) {
            self.uuid = uuid
            self.kind = kind
            self.isDelete = isDelete
            self.baseRevision = baseRevision
            self.bodyB64 = bodyB64
            self.sha256 = sha256
            self.modifiedMs = modifiedMs
        }
    }

    /// 条目上行结果:ok / 冲突(附现行行) / 缺席即删除(§6.6)。
    public enum ItemOutcome: Equatable {
        case ok(revision: UInt64)
        case conflict(revision: UInt64, bodyB64: String?)
        case notFound(deletedAt: Date?)
    }

    /// 变更日志条目(§6.3 下行)。
    public struct ChangeEntry {
        public let seq: Int
        public let uuid: UUID
        public let op: String            // upsert | purge | rekey
        public let revision: UInt64
        public let deleted: Bool
        public let bodyB64: String?
        public let kind: UInt8?
        public let modifiedMs: TimeInterval?
        public init(seq: Int, uuid: UUID, op: String, revision: UInt64, deleted: Bool,
                    bodyB64: String?, kind: UInt8?, modifiedMs: TimeInterval?) {
            self.seq = seq
            self.uuid = uuid
            self.op = op
            self.revision = revision
            self.deleted = deleted
            self.bodyB64 = bodyB64
            self.kind = kind
            self.modifiedMs = modifiedMs
        }
    }

    /// 全量重建条目(§6.3 快照分页)。
    public struct ListedItem {
        public let uuid: UUID
        public let kind: UInt8
        public let revision: UInt64
        public let bodyB64: String
        public let modifiedMs: TimeInterval
    }

    public enum RelayError: LocalizedError, Equatable {
        case invalidEmail
        case invalidCode
        case rateLimited(retryAfter: Int)
        case unauthorized
        case notFound
        case nameExists
        case quotaExceeded
        case invalidEnvelope
        case cursorExpired
        case rekeyInProgress
        case rekeyStale
        case itemTooLarge
        case server(Int)
        case network(String)

        public var errorDescription: String? {
            switch self {
            case .invalidEmail: return L10n.t("invalid_email_error")
            case .invalidCode: return L10n.t("wrong_code_error")
            case .rateLimited(let wait):
                return L10n.t("relay_error_rate_limited") + " (\(wait)s)"
            case .unauthorized: return L10n.t("relay_error_session_expired")
            case .notFound: return L10n.t("cloud_database_not_found")
            case .nameExists: return L10n.t("local_database_exists_error")
            case .quotaExceeded: return L10n.t("relay_error_quota")
            case .invalidEnvelope: return L10n.t("envelope_missing_error")
            case .cursorExpired: return L10n.t("sync_error", fallback: "同步需要全量重建")
            case .rekeyInProgress: return L10n.t("sync_error", fallback: "改密同步进行中")
            case .rekeyStale: return L10n.t("sync_error", fallback: "改密同步已过期,请重试")
            case .itemTooLarge: return L10n.t("sync_error", fallback: "条目过大")
            case .server(let code): return "\(L10n.t("sync_error")) (\(code))"
            // 调用方展示时统一加"同步错误:"前缀,这里只给原始细节,避免叠成
            // "同步错误:同步错误:…"(下拉刷新取消事故的真实输出)
            case .network(let detail): return detail
            }
        }
    }

    /// 逻辑保证:合法字面量 URL
    private let baseURL: URL
    private let session: URLSession

    /// 服务端时间戳一律 Unix epoch 毫秒(Contracts 总则);Date 构造必须
    /// 除以 1000——曾按秒构造,过期/最近活跃显示成公元 59000 年。
    private static func dateFromServerMs(_ ms: Double) -> Date {
        Date(timeIntervalSince1970: ms / 1000)
    }

    public init(baseURL: URL = URL(string: "https://api.upasswords.com")!,
                session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    // MARK: - 账户(注册=登录)

    /// 请求发送验证码(202 恒定;限速抛 rateLimited)。
    /// - Parameter lang: 生效语言(邮件文案按它渲染;缺省英文)
    public func requestCode(email: String, purpose: Purpose = .login, lang: String = "en") async throws {
        struct Empty: Decodable {}
        let _: Empty = try await send(
            "POST", "/v2/auth/code",
            body: ["email": email, "purpose": purpose.rawValue, "lang": lang],
            token: nil)
    }

    /// 校验验证码;账户不存在则自动注册,返回新签发的会话令牌。
    public func verify(email: String, code: String, deviceName: String,
                       platform: Platform = .other) async throws -> Session {
        struct Response: Decodable {
            let token: String
            let expiresAt: Double
            let userId: String
        }
        let response: Response = try await send(
            "POST", "/v2/auth/verify",
            body: ["email": email, "code": code, "deviceName": deviceName, "platform": platform.rawValue],
            token: nil)
        return Session(
            token: response.token,
            expiresAt: Self.dateFromServerMs(response.expiresAt),
            userId: response.userId)
    }

    /// 本账户设备会话列表(管理/登出用;服务端会把发起请求的会话标 current)。
    public func listSessions(token: String) async throws -> [DeviceSession] {
        struct Response: Decodable {
            struct Item: Decodable {
                let id: String
                let deviceName: String
                let platform: String?
                let current: Bool?
                let lastSeenAt: Double?
            }
            let sessions: [Item]
        }
        let response: Response = try await send("GET", "/v2/auth/sessions", body: nil, token: token)
        return response.sessions.map {
            DeviceSession(id: $0.id, deviceName: $0.deviceName, platform: $0.platform ?? "other",
                          isCurrent: $0.current ?? false,
                          lastSeenAt: $0.lastSeenAt.map(Self.dateFromServerMs))
        }
    }

    /// 撤销指定设备会话。
    public func revokeSession(token: String, id: String) async throws {
        struct Empty: Decodable {}
        let _: Empty = try await send("DELETE", "/v2/auth/sessions/\(id)", body: nil, token: token)
    }

    /// 自撤销:吊销调用方令牌自己的会话(登出/重登收尾,鉴权即身份)。
    public func revokeOwnSession(token: String) async throws {
        struct Empty: Decodable {}
        let _: Empty = try await send("DELETE", "/v2/auth/session", body: nil, token: token)
    }

    /// 会话自命名:调用方会话更新自己的设备名(解锁后刷新)。
    public func renameSession(token: String, deviceName: String) async throws {
        struct Empty: Decodable {}
        let _: Empty = try await send(
            "PATCH", "/v2/auth/session",
            body: ["deviceName": deviceName],
            token: token)
    }

    /// 注销账户(需 sensitive 验证码;立即清空服务端数据并吊销全部会话)。
    public func deregister(token: String, code: String) async throws {
        struct Empty: Decodable {}
        let _: Empty = try await send("DELETE", "/v2/account", body: ["code": code], token: token)
    }

    // MARK: - 库注册表

    /// 登记新库(创建即携带初始信封——绑定即全量上行的第一块)。
    public func createVault(token: String, name: String, envelope: Data?) async throws -> String {
        struct Response: Decodable { let vaultId: String }
        let response: Response = try await send(
            "POST", "/v2/vaults",
            body: ["name": name, "envelope": envelope?.base64EncodedString() as Any? ?? NSNull()],
            token: token)
        Log.info("sync", "relay vault registered id=\(response.vaultId.prefix(8))… name-length=\(name.count)")
        return response.vaultId
    }

    /// 名下库列表(不含信封密文)。
    public func listVaults(token: String) async throws -> [VaultRecord] {
        struct Response: Decodable { let vaults: [Item] }
        struct Item: Decodable {
            let vaultId: String
            let name: String
            let passwordVersion: Int
            let passwordChangedAt: Double?
            let envelopeChangedAt: Double?
            let hasEnvelope: Bool
            let headSeq: Int?
            let itemCount: Int?
        }
        let response: Response = try await send("GET", "/v2/vaults", body: nil, token: token)
        return response.vaults.map {
            VaultRecord(
                vaultId: $0.vaultId, name: $0.name, passwordVersion: $0.passwordVersion,
                passwordChangedAt: $0.passwordChangedAt.map(Self.dateFromServerMs),
                envelopeChangedAt: $0.envelopeChangedAt.map(Self.dateFromServerMs),
                hasEnvelope: $0.hasEnvelope, envelope: nil,
                headSeq: $0.headSeq ?? 0, itemCount: $0.itemCount ?? 0)
        }
    }

    /// 单库详情(含信封密文——同步/解锁引导的数据源)。
    public func getVault(token: String, vaultId: String) async throws -> VaultRecord {
        struct Item: Decodable {
            let vaultId: String
            let name: String
            let passwordVersion: Int
            let passwordChangedAt: Double?
            let envelopeChangedAt: Double?
            let hasEnvelope: Bool
            let envelope: String?
            let headSeq: Int?
            let itemCount: Int?
        }
        let item: Item = try await send("GET", "/v2/vaults/\(vaultId)", body: nil, token: token)
        return VaultRecord(
            vaultId: item.vaultId, name: item.name, passwordVersion: item.passwordVersion,
            passwordChangedAt: item.passwordChangedAt.map(Self.dateFromServerMs),
            envelopeChangedAt: item.envelopeChangedAt.map(Self.dateFromServerMs),
            hasEnvelope: item.hasEnvelope,
            envelope: item.envelope.flatMap { Data(base64Encoded: $0) },
            headSeq: item.headSeq ?? 0, itemCount: item.itemCount ?? 0)
    }

    /// 便宜轮询:库变更高水位 + 改密版本(活跃设备每 60s 打一次)。
    public func vaultSeq(token: String, vaultId: String) async throws -> (headSeq: Int, passwordVersion: Int) {
        struct Response: Decodable { let headSeq: Int; let passwordVersion: Int }
        let response: Response = try await send("GET", "/v2/vaults/\(vaultId)/seq", body: nil, token: token)
        return (response.headSeq, response.passwordVersion)
    }

    /// 解绑库注册(需 sensitive 验证码;行级数据与 R2 附件一并清除)。
    public func deleteVault(token: String, vaultId: String, code: String) async throws {
        struct Empty: Decodable {}
        let _: Empty = try await send(
            "DELETE", "/v2/vaults/\(vaultId)", body: ["code": code], token: token)
    }

    /// 库改名(vaultId 不变)。
    public func renameVault(token: String, vaultId: String, name: String) async throws {
        struct Empty: Decodable {}
        let _: Empty = try await send(
            "PATCH", "/v2/vaults/\(vaultId)", body: ["name": name], token: token)
        Log.info("sync", "relay vault renamed id=\(vaultId.prefix(8))… name-length=\(name.count)")
    }

    /// 换绑邮箱:注册表整体迁移到新邮箱名下,并直接返回新账户的本机会话。
    public func transferVault(token: String, vaultId: String, email: String,
                              code: String, currentCode: String, deviceName: String,
                              platform: Platform = .other) async throws -> Session {
        struct Response: Decodable {
            let token: String
            let expiresAt: Double
            let userId: String
        }
        let response: Response = try await send(
            "POST", "/v2/vaults/\(vaultId)/transfer",
            body: ["email": email, "code": code, "currentCode": currentCode,
                   "deviceName": deviceName, "platform": platform.rawValue],
            token: token)
        Log.info("sync", "relay vault transferred to new email (vault=\(vaultId.prefix(8))…)")
        return Session(
            token: response.token,
            expiresAt: Self.dateFromServerMs(response.expiresAt),
            userId: response.userId)
    }

    // MARK: - 行级条目同步

    /// 批量上行(§6.2 CAS);逐条返回 ok/conflict/notFound。
    public func postItems(token: String, vaultId: String, items: [ItemOp]) async throws -> [UUID: ItemOutcome] {
        struct Response: Decodable {
            struct Result: Decodable {
                let uuid: String
                let status: String
                let revision: UInt64?
                let current: Current?
                let deletedAt: Double?
                struct Current: Decodable {
                    let revision: UInt64
                    let bodyB64: String?
                }
            }
            let results: [Result]
        }
        let payload: [[String: Any]] = items.map { op in
            var entry: [String: Any] = [
                "uuid": op.uuid.uuidString,
                "kind": Int(op.kind),
                "op": op.isDelete ? "delete" : "upsert",
                "baseRevision": Int(op.baseRevision),
                "modifiedMs": Int(op.modifiedMs),
            ]
            if let body = op.bodyB64 {
                entry["bodyB64"] = body
                if let sha = op.sha256 { entry["sha256"] = sha }
            }
            return entry
        }
        let response: Response = try await send(
            "POST", "/v2/vaults/\(vaultId)/items",
            body: ["items": payload], token: token)
        var out: [UUID: ItemOutcome] = [:]
        for r in response.results {
            guard let uuid = UUID(uuidString: r.uuid) else { continue }
            switch r.status {
            case "ok":
                out[uuid] = .ok(revision: r.revision ?? 0)
            case "conflict":
                out[uuid] = .conflict(revision: r.current?.revision ?? 0, bodyB64: r.current?.bodyB64)
            default:
                out[uuid] = .notFound(deletedAt: r.deletedAt.map(Self.dateFromServerMs))
            }
        }
        return out
    }

    /// 游标增量下行(§6.3);游标越过保留地板抛 cursorExpired(走全量重建)。
    public func getChanges(token: String, vaultId: String, since: Int,
                           limit: Int = 200) async throws -> (headSeq: Int, changes: [ChangeEntry]) {
        struct Response: Decodable {
            struct Entry: Decodable {
                let seq: Int
                let uuid: String
                let op: String
                let revision: UInt64
                let deleted: Bool?
                let bodyB64: String?
                let kind: Int?
                let modifiedMs: Double?
            }
            let headSeq: Int
            let changes: [Entry]
        }
        let response: Response = try await send(
            "GET", "/v2/vaults/\(vaultId)/changes?since=\(since)&limit=\(limit)",
            body: nil, token: token)
        let entries = response.changes.compactMap { e -> ChangeEntry? in
            // 库级 op=rekey 条目 uuid 为空串(无条目归属),映射全零 UUID
            guard let uuid = e.uuid.isEmpty
                ? UUID(uuidString: "00000000-0000-0000-0000-000000000000")
                : UUID(uuidString: e.uuid) else { return nil }
            return ChangeEntry(
                seq: e.seq, uuid: uuid, op: e.op, revision: e.revision,
                deleted: e.deleted ?? (e.op == "purge"),
                bodyB64: e.bodyB64, kind: e.kind.map(UInt8.init),
                modifiedMs: e.modifiedMs)
        }
        return (response.headSeq, entries)
    }

    /// 全量重建快照分页(§6.3);nextCursor 为 nil 表示拉平。
    public func listItems(token: String, vaultId: String, cursorMs: Int = 0, cursorUuid: String = "",
                          limit: Int = 500) async throws -> (items: [ListedItem], nextCursor: (ms: Int, uuid: String)?, headSeq: Int) {
        struct Response: Decodable {
            struct Item: Decodable {
                let uuid: String
                let kind: Int
                let revision: UInt64
                let bodyB64: String
                let modifiedMs: Double
            }
            let items: [Item]
            let nextCursor: Cursor?
            let headSeq: Int
            struct Cursor: Decodable {
                let ms: Int
                let uuid: String
            }
        }
        let response: Response = try await send(
            "GET", "/v2/vaults/\(vaultId)/items?cursorMs=\(cursorMs)&cursorUuid=\(cursorUuid)&limit=\(limit)",
            body: nil, token: token)
        let items = response.items.compactMap { i -> ListedItem? in
            guard let uuid = UUID(uuidString: i.uuid) else { return nil }
            return ListedItem(uuid: uuid, kind: UInt8(i.kind), revision: i.revision,
                              bodyB64: i.bodyB64, modifiedMs: i.modifiedMs)
        }
        return (items, response.nextCursor.map { ($0.ms, $0.uuid) }, response.headSeq)
    }

    // MARK: - 附件(R2 密文 blob)

    /// 附件密文上传(staging→commit 原子换入)。
    public func putAttachment(token: String, vaultId: String, attachUuid: UUID,
                              cardUuid: UUID, cipher: Data, dekWrapped: Data) async throws {
        let uploadId = Self.randomUploadId()
        let sha = SyncConflict.sha256Hex(cipher)
        guard let url = URL(
            string: "/v2/vaults/\(vaultId)/attachments/\(attachUuid.uuidString)?upload=\(uploadId)",
            relativeTo: baseURL) else {
            throw RelayError.network("bad url")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = cipher
        _ = try await runRaw(request)
        struct Empty: Decodable {}
        let _: Empty = try await send(
            "POST", "/v2/vaults/\(vaultId)/attachments/\(attachUuid.uuidString)/commit",
            body: ["uploadId": uploadId, "sha256": sha, "cardUuid": cardUuid.uuidString,
                   "dekWrapped": dekWrapped.base64EncodedString()],
            token: token)
        Log.info("sync", "relay attachment pushed id=\(attachUuid.uuidString.prefix(8))… size=\(cipher.count)")
    }

    /// 附件密文拉取(懒拉取;无副本抛 notFound)。
    public func getAttachment(token: String, vaultId: String, attachUuid: UUID) async throws -> Data {
        guard let url = URL(
            string: "/v2/vaults/\(vaultId)/attachments/\(attachUuid.uuidString)",
            relativeTo: baseURL) else {
            throw RelayError.network("bad url")
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let data = try await runRaw(request)
        Log.info("sync", "relay attachment pulled id=\(attachUuid.uuidString.prefix(8))… size=\(data.count)")
        return data
    }

    /// 附件删除(随条目硬清除触发)。
    public func deleteAttachment(token: String, vaultId: String, attachUuid: UUID) async throws {
        struct Empty: Decodable {}
        let _: Empty = try await send(
            "DELETE", "/v2/vaults/\(vaultId)/attachments/\(attachUuid.uuidString)",
            body: nil, token: token)
    }

    // MARK: - 改密 rekey(§6.5)

    /// 开始 rekey:此后该库普通条目写会撞 rekeyInProgress,直到 commit/abort。
    public func rekeyBegin(token: String, vaultId: String, envelope: Data,
                           itemCount: Int, dekCount: Int) async throws -> (rekeyId: String, passwordVersion: Int) {
        struct Response: Decodable { let rekeyId: String; let passwordVersion: Int }
        let response: Response = try await send(
            "POST", "/v2/vaults/\(vaultId)/rekey/begin",
            body: ["envelope": envelope.base64EncodedString(),
                   "itemCount": itemCount, "dekCount": dekCount],
            token: token)
        return (response.rekeyId, response.passwordVersion)
    }

    /// 分块上传新 VEK 密文条目(断点续传;重传同 uuid 幂等)。
    public func rekeyChunk(token: String, vaultId: String, rekeyId: String,
                           items: [(uuid: UUID, kind: UInt8, bodyB64: String, sha256: String)]) async throws {
        struct Empty: Decodable {}
        let payload = items.map { [
            "uuid": $0.uuid.uuidString,
            "bodyB64": $0.bodyB64,
            "sha256": $0.sha256,
        ] as [String: Any] }
        let _: Empty = try await send(
            "POST", "/v2/vaults/\(vaultId)/rekey/\(rekeyId)/chunk",
            body: ["items": payload], token: token)
    }

    /// 提交换入:全部行 revision+1、信封与 password_version 原子切换。
    public func rekeyCommit(token: String, vaultId: String, rekeyId: String) async throws {
        struct Empty: Decodable {}
        let _: Empty = try await send(
            "POST", "/v2/vaults/\(vaultId)/rekey/\(rekeyId)/commit",
            body: [:], token: token)
    }

    /// 放弃 rekey(库回旧态,暂存清空)。
    public func rekeyAbort(token: String, vaultId: String, rekeyId: String) async throws {
        struct Empty: Decodable {}
        let _: Empty = try await send(
            "DELETE", "/v2/vaults/\(vaultId)/rekey/\(rekeyId)",
            body: nil, token: token)
    }

    // MARK: - 传输

    /// 请求不随调用任务的取消而中断:手势任务(如下拉刷新被打断)被 SwiftUI
    /// 取消时,URLSession.data(for:) 会连带取消在途请求,把一次正常同步变成
    /// "已取消"错误弹给用户。这里在无取消关联的子任务里跑请求,外层仅等待
    /// 结果——取消只影响"等待",不影响传输。
    private func dataDetachedFromCancellation(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            Task {
                do {
                    let (data, response) = try await session.data(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw RelayError.network("no http response")
                    }
                    continuation.resume(returning: (data, http))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func runRaw(_ request: URLRequest) async throws -> Data {
        do {
            let (data, http) = try await dataDetachedFromCancellation(request)
            guard (200..<300).contains(http.statusCode) else {
                throw Self.mapError(http: http, body: data)
            }
            return data
        } catch let error as RelayError {
            throw error
        } catch {
            throw RelayError.network(error.localizedDescription)
        }
    }

    private func send<T: Decodable>(_ method: String, _ path: String,
                                    body: [String: Any]?, token: String?) async throws -> T {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw RelayError.network("bad url")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let body {
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, http) = try await dataDetachedFromCancellation(request)
            guard (200..<300).contains(http.statusCode) else {
                throw Self.mapError(http: http, body: data)
            }
            guard let decoded = try? JSONDecoder().decode(T.self, from: data) else {
                throw RelayError.network("bad response body")
            }
            return decoded
        } catch let error as RelayError {
            throw error
        } catch {
            throw RelayError.network(error.localizedDescription)
        }
    }

    /// 32 hex 上传会话号(服务端 staging 键)。
    private static func randomUploadId() -> String {
        (0..<16).map { _ in String(format: "%02x", Int.random(in: 0...255)) }.joined()
    }

    private static func mapError(http: HTTPURLResponse, body: Data) -> RelayError {
        struct ErrorBody: Decodable { let error: String? }
        let code = (try? JSONDecoder().decode(ErrorBody.self, from: body))?.error ?? ""
        switch code {
        case "invalid_email": return .invalidEmail
        case "invalid_code": return .invalidCode
        case "rate_limited":
            let wait = Int(http.value(forHTTPHeaderField: "retry-after") ?? "") ?? 60
            return .rateLimited(retryAfter: wait)
        case "unauthorized": return .unauthorized
        case "not_found", "body_not_found": return .notFound
        case "name_exists": return .nameExists
        case "quota_exceeded", "too_many_items": return .quotaExceeded
        case "invalid_envelope": return .invalidEnvelope
        case "cursor_expired": return .cursorExpired
        case "rekey_in_progress": return .rekeyInProgress
        case "rekey_stale": return .rekeyStale
        case "item_too_large": return .itemTooLarge
        default: return .server(http.statusCode)
        }
    }
}
