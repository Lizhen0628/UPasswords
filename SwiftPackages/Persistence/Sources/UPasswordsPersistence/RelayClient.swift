import Foundation
import UPasswordsCore

/// api.upasswords.com 协调服务客户端(见 Cloud/DESIGN.md):
/// 账户(邮箱验证码)+ 库注册表 + 行级条目同步(items/changes)+
/// 附件(R2 blob)+ 改密 rekey。零知识红线:所有请求只携带密文/哈希/
/// 元数据,绝不携带主密码或库密钥。
public struct RelayClient {
    /// 验证码位数(与服务端 randomCode6 同源约定;UI 输入门槛与校验共用)。
    public static let verificationCodeLength = 6
    /// Attachment-safe conflict-aware row-sync protocol; older clients are rejected before vault sync.
    public static let syncProtocolVersion = 5

    private static let attachmentVersionPageLimit = 200
    private static let attachmentVersionPageMaximumBytes = 2 * 1024 * 1024
    private static let maximumAttachmentVersionCount = 50_000
    private static let conflictHistoryPageLimit = 50
    private static let conflictHistoryPageMaximumBytes = 9 * 1024 * 1024
    private static let maximumConflictHistoryCandidateCount = 1_600_000
    private static let rekeyConflictPageLimit = 200

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
        /// 账户会话的 Bearer 令牌；不得写入日志、通知或普通偏好。
        public let token: String
        /// 服务端毫秒时间戳转换后的会话过期日期。
        public let expiresAt: Date
        /// 服务端账户身份。
        public let userId: String
    }

    /// 已登录设备(会话管理页展示与撤销)。isCurrent=发起列表请求的本机会话。
    public struct DeviceSession: Identifiable, Equatable {
        /// 服务端会话标识，用于撤销设备授权。
        public let id: String
        /// 设备展示名，与会话身份无关。
        public let deviceName: String
        /// 服务端保存的平台词条，未知词条由展示层回退处理。
        public let platform: String
        /// 是否为发起此次设备列表查询的会话。
        public let isCurrent: Bool
        /// 最近活动日期；服务端缺失该字段时为 nil。
        public let lastSeenAt: Date?
        /// 创建设备会话的展示值。
        ///
        /// - Parameters:
        ///   - id: 服务端会话标识。
        ///   - deviceName: 设备展示名。
        ///   - platform: 平台词条。
        ///   - isCurrent: 是否为请求方当前会话。
        ///   - lastSeenAt: 可选最近活动日期。
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
        /// 服务端密码库稳定身份，与本地库名分开保存。
        public let vaultId: String
        /// 密码库展示名称。
        public let name: String
        /// 服务端库密钥轮换版本；前进时需重新解锁。
        public let passwordVersion: Int
        /// 服务端记录的最近改密日期。
        public let passwordChangedAt: Date?
        /// 密钥信封记录的最近变化日期。
        public let envelopeChangedAt: Date?
        /// 服务端是否保存有信封；列表接口不一定同时返回信封内容。
        public let hasEnvelope: Bool
        /// 可选的加密库密钥信封，单库详情接口返回。
        public let envelope: Data?
        /// 该库当前的变更序列高水位，不等同于单条目 revision。
        public let headSeq: Int
        /// 服务端记录的条目数量。
        public let itemCount: Int
    }

    /// 条目上行操作(§6.2):upsert 携新密文体,delete 携原 baseRevision。
    public struct ItemOp {
        /// 条目的稳定 UUID；加解密时须与 AAD 使用同一身份。
        public let uuid: UUID
        /// 同步类型码，与 DatabaseItem.syncKind 及服务端约定一致。
        public let kind: UInt8          // 1=card 2=label(与 DatabaseItem.syncKind 对齐)
        /// 是否请求永久删除；删除操作不携带新密文体。
        public let isDelete: Bool
        /// 此次写入预期的服务端版本；0 仅用于创建。
        public let baseRevision: UInt64
        /// 可选的 AES-GCM 条目密文 Base64，包含 nonce 和认证标签。
        public let bodyB64: String?
        /// 条目密文字节的 SHA-256 十六进制摘要。
        public let sha256: String?
        /// 客户端条目的 Unix 毫秒修改时间，用于冲突合并。
        public let modifiedMs: TimeInterval
        /// Optional opaque attachment references activated with this row.
        public let attachmentRefs: [AttachmentReference]?
        /// 创建一个不执行网络请求的 CAS 操作值。
        ///
        /// - Parameters:
        ///   - uuid: 稳定条目身份。
        ///   - kind: 同步类型码。
        ///   - isDelete: 是否永久删除。
        ///   - baseRevision: 预期现行版本；0 仅用于创建。
        ///   - bodyB64: upsert 的完整 AES-GCM 密文 Base64。
        ///   - sha256: 可选密文摘要。
        ///   - modifiedMs: 客户端 Unix 毫秒修改时间。
        ///   - attachmentRefs: Card attachment versions to activate with the row.
        public init(uuid: UUID, kind: UInt8, isDelete: Bool, baseRevision: UInt64,
                    bodyB64: String? = nil, sha256: String? = nil, modifiedMs: TimeInterval,
                    attachmentRefs: [AttachmentReference]? = nil) {
            self.uuid = uuid
            self.kind = kind
            self.isDelete = isDelete
            self.baseRevision = baseRevision
            self.bodyB64 = bodyB64
            self.sha256 = sha256
            self.modifiedMs = modifiedMs
            self.attachmentRefs = attachmentRefs
        }
    }

    /// A logical attachment identity and content version referenced by an encrypted card.
    public struct AttachmentReference: Equatable {
        /// Stable attachment identity.
        public let attachmentID: UUID
        /// Stable content version token.
        public let contentVersion: UUID
        /// Whether the user explicitly restored a previously deleted identity.
        public let restoreDeleted: Bool

        /// Creates a reference to a previously uploaded attachment version.
        public init(attachmentID: UUID, contentVersion: UUID, restoreDeleted: Bool = false) {
            self.attachmentID = attachmentID
            self.contentVersion = contentVersion
            self.restoreDeleted = restoreDeleted
        }
    }

    /// Server metadata for one current or retained encrypted attachment version.
    public struct AttachmentVersionMetadata: Equatable {
        /// Stable logical attachment identity.
        public let attachmentID: UUID
        /// Parent card identity used for ownership validation.
        public let cardID: UUID
        /// Stable content version token; nil denotes a pre-version legacy object.
        public let contentVersion: UUID?
        /// VEK-wrapped data encryption key.
        public let dekWrapped: Data
        /// Ciphertext SHA-256 digest.
        public let sha256: String
        /// Ciphertext byte length.
        public let bytes: Int64
        /// Whether the version is referenced by the live card row.
        public let isCurrent: Bool

        /// Creates validated metadata for one attachment version.
        public init(attachmentID: UUID, cardID: UUID, contentVersion: UUID?,
                    dekWrapped: Data, sha256: String, bytes: Int64, isCurrent: Bool) {
            self.attachmentID = attachmentID
            self.cardID = cardID
            self.contentVersion = contentVersion
            self.dekWrapped = dekWrapped
            self.sha256 = sha256
            self.bytes = bytes
            self.isCurrent = isCurrent
        }
    }

    /// An encrypted version retained for an unresolved row conflict.
    public struct ConflictCandidate: Codable, Equatable, Identifiable {
        public let candidateID: String
        public var id: String { candidateID }
        public let kind: UInt8
        public let isDelete: Bool
        public let revision: UInt64
        public let modifiedAt: Date
        public let committedAt: Date
        public let deviceName: String
        public let platform: String
        public let bodyB64: String?
        public let sha256: String?
    }

    /// An encrypted conflict candidate included in a fixed rekey inventory.
    public struct RekeyConflictCandidate: Equatable, Identifiable {
        /// Conflict group containing the candidate.
        public let conflictID: String
        /// Item identity used as AES-GCM additional authenticated data.
        public let itemUUID: UUID
        /// Existing server-side candidate identity before rekey.
        public let oldCandidateID: String
        /// Candidate kind (card, label, or user profile).
        public let kind: UInt8
        /// Candidate operation is deletion rather than upsert.
        public let isDelete: Bool
        /// Base revision stored with this candidate.
        public let revision: UInt64
        /// Existing encrypted candidate body; nil for deletion candidates.
        public let body: Data?
        /// Digest of the existing encrypted candidate body.
        public let sha256: String?

        public var id: String { "\(conflictID):\(oldCandidateID)" }

        /// Creates a validated candidate page entry.
        public init(conflictID: String, itemUUID: UUID, oldCandidateID: String,
                    kind: UInt8, isDelete: Bool, revision: UInt64,
                    body: Data?, sha256: String?) {
            self.conflictID = conflictID
            self.itemUUID = itemUUID
            self.oldCandidateID = oldCandidateID
            self.kind = kind
            self.isDelete = isDelete
            self.revision = revision
            self.body = body
            self.sha256 = sha256
        }
    }

    /// Conflict candidate set and the CAS generation required for future resolution.
    public struct ConflictRecord: Equatable, Identifiable {
        public let conflictID: String
        public var id: String { conflictID }
        public let itemUUID: UUID
        public let baseRevision: UInt64
        public let currentRevision: UInt64
        public let currentDeletedSequence: Int
        public let generation: UInt64
        public let createdAt: Date
        public let updatedAt: Date
        public let candidates: [ConflictCandidate]
    }

    /// Retained candidates and immutable resolution metadata for a completed conflict.
    public struct RetainedConflictRecord: Equatable, Identifiable {
        public let conflictID: String
        public var id: String { conflictID }
        public let itemUUID: UUID
        public let baseRevision: UInt64
        public let currentRevision: UInt64
        public let currentDeletedSequence: Int
        public let generation: UInt64
        public let createdAt: Date
        public let updatedAt: Date
        public let resolvedAt: Date
        public let expiresAt: Date
        public let selectedCandidateID: String?
        public let candidates: [ConflictCandidate]
    }

    private struct RetainedConflictBuilder {
        let conflictID: String
        let itemUUID: UUID
        let baseRevision: UInt64
        let currentRevision: UInt64
        let currentDeletedSequence: Int
        let generation: UInt64
        let createdAt: Date
        let updatedAt: Date
        let resolvedAt: Date
        let expiresAt: Date
        let selectedCandidateID: String?
        var candidates: [ConflictCandidate]

        func record() -> RetainedConflictRecord {
            RetainedConflictRecord(
                conflictID: conflictID,
                itemUUID: itemUUID,
                baseRevision: baseRevision,
                currentRevision: currentRevision,
                currentDeletedSequence: currentDeletedSequence,
                generation: generation,
                createdAt: createdAt,
                updatedAt: updatedAt,
                resolvedAt: resolvedAt,
                expiresAt: expiresAt,
                selectedCandidateID: selectedCandidateID,
                candidates: candidates)
        }
    }

    /// Server acknowledgement for a candidate registration.
    public struct ConflictRegistration: Equatable {
        public let conflictID: String
        public let generation: UInt64
        public let candidateCount: Int
        public let currentRevision: UInt64
    }

    /// Result of atomically resolving a retained row conflict.
    public struct ConflictResolutionResult: Equatable {
        public let itemUUID: UUID?
        public let itemCount: Int
        public let headSequence: Int
    }

    /// Describes whether a conflict resolution selected one candidate or composed fields.
    public enum ConflictResolutionType: String, Codable, Equatable {
        case candidate
        case composed
    }

    /// 条目上行结果；notFound 不能独自证明用户删除，须保留本地未上传内容。
    public enum ItemOutcome: Equatable {
        case ok(revision: UInt64)
        case conflict(revision: UInt64, bodyB64: String?)
        case notFound(deletedAt: Date?, revision: UInt64?, sequence: Int?)
    }

    /// 变更日志条目(§6.3 下行)。
    public struct ChangeEntry: Codable, Equatable {
        /// 库级变更序列，用于增量下行游标。
        public let seq: Int
        /// 条目的稳定 UUID；加解密时须与 AAD 使用同一身份。
        public let uuid: UUID
        /// 变更操作词条：upsert、purge、resolve 或库级 rekey。
        public let op: String            // upsert | purge | resolve | rekey
        /// 事件源条目 revision；库级 rekey 事件中承载新的密码版本。
        public let revision: UInt64
        /// 裁决事件的最终活动条目身份；nil 表示裁决结果为删除。
        public let resolvedItemUUID: UUID?
        /// 裁决事件对应的服务端冲突组身份。
        public let conflictID: String?
        /// 裁决目标条目的当前 revision；目标已删除时为 nil。
        public let resolvedRevision: UInt64?
        /// 裁决开始时的共同 revision，用于识别本机是否持有获胜候选。
        public let conflictBaseRevision: UInt64?
        /// 服务端选中的稳定候选身份。
        public let winnerCandidateID: String?
        /// 服务端选中候选的同步类型。
        public let winnerKind: UInt8?
        /// 服务端选中候选是否为删除操作。
        public let winnerIsDelete: Bool?
        /// Candidate selection or client-encrypted field composition.
        public let resolutionType: ConflictResolutionType?
        /// 是否应移除本地条目；删除收敛优先于未上行修改。
        public let deleted: Bool
        /// 可选的 AES-GCM 条目密文 Base64，包含 nonce 和认证标签。
        public let bodyB64: String?
        /// 同步类型码，与 DatabaseItem.syncKind 及服务端约定一致。
        public let kind: UInt8?
        /// 客户端条目的 Unix 毫秒修改时间，用于冲突合并。
        public let modifiedMs: TimeInterval?
        /// 创建一个已解码的变更事件值。
        ///
        /// - Parameters:
        ///   - seq: 库级变更序列。
        ///   - uuid: 条目身份；库级 rekey 使用全零 UUID。
        ///   - op: 变更操作词条。
        ///   - revision: 条目版本或 rekey 的密码版本。
        ///   - resolvedItemUUID: 可选裁决结果身份。
        ///   - conflictID: 可选裁决冲突组身份。
        ///   - resolvedRevision: 可选裁决目标版本。
        ///   - conflictBaseRevision: 可选裁决共同 revision。
        ///   - winnerCandidateID: 可选获胜候选身份。
        ///   - winnerKind: 可选获胜候选类型。
        ///   - winnerIsDelete: 可选获胜候选删除标志。
        ///   - deleted: 是否移除本地条目。
        ///   - bodyB64: 可选密文。
        ///   - kind: 可选同步类型码。
        ///   - modifiedMs: 可选客户端 Unix 毫秒修改时间。
        public init(seq: Int, uuid: UUID, op: String, revision: UInt64, deleted: Bool,
                    bodyB64: String?, kind: UInt8?, modifiedMs: TimeInterval?,
                    resolvedItemUUID: UUID? = nil, conflictID: String? = nil,
                    resolvedRevision: UInt64? = nil, conflictBaseRevision: UInt64? = nil,
                    winnerCandidateID: String? = nil, winnerKind: UInt8? = nil,
                    winnerIsDelete: Bool? = nil,
                    resolutionType: ConflictResolutionType? = nil) {
            self.seq = seq
            self.uuid = uuid
            self.op = op
            self.revision = revision
            self.resolvedItemUUID = resolvedItemUUID
            self.conflictID = conflictID
            self.resolvedRevision = resolvedRevision
            self.conflictBaseRevision = conflictBaseRevision
            self.winnerCandidateID = winnerCandidateID
            self.winnerKind = winnerKind
            self.winnerIsDelete = winnerIsDelete
            self.resolutionType = resolutionType
            self.deleted = deleted
            self.bodyB64 = bodyB64
            self.kind = kind
            self.modifiedMs = modifiedMs
        }
    }

    /// 全量重建条目(§6.3 快照分页)。
    public struct ListedItem: Codable {
        /// 条目的稳定 UUID；加解密时须与 AAD 使用同一身份。
        public let uuid: UUID
        /// 同步类型码，与 DatabaseItem.syncKind 及服务端约定一致。
        public let kind: UInt8
        /// 条目版本；库级 rekey 事件中承载新的密码版本。
        public let revision: UInt64
        /// 可选的 AES-GCM 条目密文 Base64，包含 nonce 和认证标签。
        public let bodyB64: String
        /// 客户端条目的 Unix 毫秒修改时间，用于冲突合并。
        public let modifiedMs: TimeInterval
    }

    /// 中继协议、授权、配额及传输失败的可识别错误域。
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
        case attachmentIntegrityFailure
        case attachmentVersionConflict
        case attachmentDeleted
        case attachmentVersionMissing
        case conflictCandidatesRetained
        case conflictStale
        case conflictCandidatesChanged
        case conflictResolved
        case conflictAttachmentsPending
        case clientUpgradeRequired
        case server(Int)
        case network(String)

        /// 供界面展示的本地化协议或传输错误。
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
            case .attachmentIntegrityFailure: return L10n.t("sync_attachment_integrity_failed")
            case .attachmentVersionConflict: return L10n.t("sync_conflict_stale")
            case .attachmentDeleted: return L10n.t("sync_conflict_stale")
            case .attachmentVersionMissing: return L10n.t("sync_error", fallback: "附件版本尚未上传")
            case .conflictCandidatesRetained: return L10n.t("sync_conflict_rekey_blocked")
            case .conflictStale: return L10n.t("sync_conflict_stale")
            case .conflictCandidatesChanged: return L10n.t("sync_conflict_candidates_changed")
            case .conflictResolved: return L10n.t("sync_conflict_already_resolved")
            case .conflictAttachmentsPending: return L10n.t("sync_conflict_attachments_pending")
            case .clientUpgradeRequired: return L10n.t("sync_client_upgrade_required")
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

    /// 创建可注入 API 根地址和 URLSession 的客户端。
    ///
    /// - Parameters:
    ///   - baseURL: API 根地址，默认值为合法 HTTPS 字面量。
    ///   - session: 请求使用的会话；测试可注入 URLProtocol 桩。
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
            "POST", "/v1/auth/code",
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
            "POST", "/v1/auth/verify",
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
        let response: Response = try await send("GET", "/v1/auth/sessions", body: nil, token: token)
        return response.sessions.map {
            DeviceSession(id: $0.id, deviceName: $0.deviceName, platform: $0.platform ?? "other",
                          isCurrent: $0.current ?? false,
                          lastSeenAt: $0.lastSeenAt.map(Self.dateFromServerMs))
        }
    }

    /// 撤销指定设备会话。
    public func revokeSession(token: String, id: String) async throws {
        struct Empty: Decodable {}
        let _: Empty = try await send("DELETE", "/v1/auth/sessions/\(id)", body: nil, token: token)
    }

    /// 自撤销:吊销调用方令牌自己的会话(登出/重登收尾,鉴权即身份)。
    public func revokeOwnSession(token: String) async throws {
        struct Empty: Decodable {}
        let _: Empty = try await send("DELETE", "/v1/auth/session", body: nil, token: token)
    }

    /// 会话自命名:调用方会话更新自己的设备名(解锁后刷新)。
    public func renameSession(token: String, deviceName: String) async throws {
        struct Empty: Decodable {}
        let _: Empty = try await send(
            "PATCH", "/v1/auth/session",
            body: ["deviceName": deviceName],
            token: token)
    }

    /// 注销账户(需 sensitive 验证码;立即清空服务端数据并吊销全部会话)。
    public func deregister(token: String, code: String) async throws {
        struct Empty: Decodable {}
        let _: Empty = try await send("DELETE", "/v1/account", body: ["code": code], token: token)
    }

    // MARK: - 库注册表

    /// 登记新库(创建即携带初始信封——绑定即全量上行的第一块)。
    public func createVault(token: String, name: String, envelope: Data?) async throws -> String {
        struct Response: Decodable { let vaultId: String }
        let response: Response = try await send(
            "POST", "/v1/vaults",
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
        let response: Response = try await send("GET", "/v1/vaults", body: nil, token: token)
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
        let item: Item = try await send("GET", "/v1/vaults/\(vaultId)", body: nil, token: token)
        return VaultRecord(
            vaultId: item.vaultId, name: item.name, passwordVersion: item.passwordVersion,
            passwordChangedAt: item.passwordChangedAt.map(Self.dateFromServerMs),
            envelopeChangedAt: item.envelopeChangedAt.map(Self.dateFromServerMs),
            hasEnvelope: item.hasEnvelope,
            envelope: item.envelope.flatMap { Data(base64Encoded: $0) },
            headSeq: item.headSeq ?? 0, itemCount: item.itemCount ?? 0)
    }

    /// Fetches the row, attachment, and conflict high-water marks used by backup consistency checks.
    ///
    /// The endpoints are independent reads, so callers must capture this inventory again after
    /// downloading payloads and compare fingerprints before publishing a complete backup.
    /// - Parameters:
    ///   - token: Account session token.
    ///   - vaultId: Bound cloud vault identity.
    /// - Returns: Canonical cloud inventory and row sequence high-water mark.
    /// - Throws: Network, response validation, or inventory consistency errors.
    public func getBackupSnapshotInventory(
        token: String,
        vaultId: String
    ) async throws -> BackupSnapshotInventory {
        async let vaultTask = getVault(token: token, vaultId: vaultId)
        async let attachmentTask = getAttachmentVersions(token: token, vaultId: vaultId)
        async let conflictTask = listConflicts(token: token, vaultId: vaultId)
        let (vault, attachmentVersions, conflicts) = try await (
            vaultTask,
            attachmentTask,
            conflictTask)
        let retainedConflicts: [RetainedConflictRecord]
        let retainedHistoryAvailable: Bool
        do {
            retainedConflicts = try await listRetainedConflicts(token: token, vaultId: vaultId)
            retainedHistoryAvailable = true
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            Log.warn(
                "backup",
                "retained conflict history unavailable vault=\(vaultId) error=\(type(of: error))")
            retainedConflicts = []
            retainedHistoryAvailable = false
        }
        return try BackupSnapshotInventory(
            headSequence: vault.headSeq,
            attachmentVersions: attachmentVersions,
            conflicts: conflicts,
            retainedConflicts: retainedConflicts,
            retainedHistoryAvailable: retainedHistoryAvailable)
    }

    /// 便宜轮询:库变更高水位 + 改密版本(活跃设备每 60s 打一次)。
    public func vaultSeq(token: String, vaultId: String) async throws -> (headSeq: Int, passwordVersion: Int) {
        struct Response: Decodable { let headSeq: Int; let passwordVersion: Int }
        let response: Response = try await send("GET", "/v1/vaults/\(vaultId)/seq", body: nil, token: token)
        return (response.headSeq, response.passwordVersion)
    }

    /// 解绑库注册(需 sensitive 验证码;行级数据与 R2 附件一并清除)。
    public func deleteVault(token: String, vaultId: String, code: String) async throws {
        struct Empty: Decodable {}
        let _: Empty = try await send(
            "DELETE", "/v1/vaults/\(vaultId)", body: ["code": code], token: token)
    }

    /// 库改名(vaultId 不变)。
    public func renameVault(token: String, vaultId: String, name: String) async throws {
        struct Empty: Decodable {}
        let _: Empty = try await send(
            "PATCH", "/v1/vaults/\(vaultId)", body: ["name": name], token: token)
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
            "POST", "/v1/vaults/\(vaultId)/transfer",
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
                let deletedRevision: UInt64?
                let seq: Int?
                struct Current: Decodable {
                    let revision: UInt64
                    let bodyB64: String?
                }
            }
            let results: [Result]
        }
        guard Set(items.map(\.uuid)).count == items.count,
              items.allSatisfy({ $0.baseRevision <= UInt64(Int.max) }) else {
            throw RowSyncSafetyError.invalidResponse
        }
        guard items.allSatisfy({ $0.isDelete || $0.kind != 1 || $0.attachmentRefs != nil }) else {
            Log.error("sync", "card upsert missing attachment references")
            throw RowSyncSafetyError.attachmentReferencesUnavailable
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
            if let references = op.attachmentRefs {
                entry["attachmentRefs"] = references.map { reference in
                    [
                        "attachmentId": reference.attachmentID.uuidString,
                        "contentVersion": reference.contentVersion.uuidString,
                        "restoreDeleted": reference.restoreDeleted,
                    ]
                }
            }
            return entry
        }
        let response: Response = try await send(
            "POST", "/v1/vaults/\(vaultId)/items",
            body: ["items": payload], token: token)
        let expected = Dictionary(items.map { ($0.uuid, $0) }, uniquingKeysWith: { first, _ in first })
        guard expected.count == items.count else { throw RowSyncSafetyError.invalidResponse }
        var out: [UUID: ItemOutcome] = [:]
        for result in response.results {
            guard let uuid = UUID(uuidString: result.uuid), let operation = expected[uuid],
                  out[uuid] == nil else {
                Log.error("sync", "relay item response has unknown or duplicate identity")
                throw RowSyncSafetyError.invalidResponse
            }
            switch result.status {
            case "ok":
                guard operation.isDelete || (result.revision ?? 0) > operation.baseRevision else {
                    throw RowSyncSafetyError.invalidResponse
                }
                out[uuid] = .ok(revision: result.revision ?? 0)
            case "conflict":
                guard let current = result.current, current.revision > 0 else {
                    throw RowSyncSafetyError.invalidResponse
                }
                out[uuid] = .conflict(revision: current.revision, bodyB64: current.bodyB64)
            case "not_found":
                out[uuid] = .notFound(
                    deletedAt: result.deletedAt.map(Self.dateFromServerMs),
                    revision: result.deletedRevision,
                    sequence: result.seq)
            default:
                Log.error("sync", "relay item response has unsupported status")
                throw RowSyncSafetyError.invalidResponse
            }
        }
        guard out.count == expected.count else {
            Log.error("sync", "relay item response is missing operation results")
            throw RowSyncSafetyError.invalidResponse
        }
        return out
    }

    /// Lists unresolved encrypted conflict candidates for one cloud vault.
    public func listConflicts(token: String, vaultId: String) async throws -> [ConflictRecord] {
        struct Response: Decodable {
            struct Candidate: Decodable {
                let candidateId: String
                let kind: Int
                let op: String
                let revision: UInt64
                let modifiedMs: Double
                let committedMs: Double
                let deviceName: String
                let platform: String
                let bodyB64: String?
                let sha256: String?
            }
            struct Conflict: Decodable {
                let conflictId: String
                let itemUuid: String
                let baseRevision: UInt64
                let currentRevision: UInt64
                let currentDeletedSeq: Int?
                let generation: UInt64
                let createdMs: Double
                let updatedMs: Double
                let candidates: [Candidate]
            }
            let conflicts: [Conflict]
        }

        let response: Response = try await send(
            "GET", "/v1/vaults/\(vaultId)/conflicts", body: nil, token: token)
        var conflictIDs = Set<String>()
        let conflicts = try response.conflicts.map { conflict -> ConflictRecord in
            guard let itemUUID = UUID(uuidString: conflict.itemUuid),
                  let currentDeletedSequence = conflict.currentDeletedSeq,
                  conflict.conflictId.count == 32,
                  conflict.conflictId == conflict.conflictId.lowercased(),
                  conflict.conflictId.allSatisfy(\.isHexDigit),
                  conflictIDs.insert(conflict.conflictId).inserted,
                  Int(exactly: conflict.baseRevision) != nil,
                  Int(exactly: conflict.currentRevision) != nil,
                  conflict.baseRevision < conflict.currentRevision,
                  currentDeletedSequence >= 0,
                  Int(exactly: conflict.generation) != nil,
                  conflict.generation > 0 else {
                throw RowSyncSafetyError.invalidResponse
            }
            var candidateIDs = Set<String>()
            let candidates = try conflict.candidates.map { candidate -> ConflictCandidate in
                guard let kind = UInt8(exactly: candidate.kind), (1...3).contains(kind),
                      candidate.op == "upsert" || candidate.op == "delete",
                      candidate.candidateId.count == 32,
                      candidate.candidateId == candidate.candidateId.lowercased(),
                      candidate.candidateId.allSatisfy(\.isHexDigit),
                      candidateIDs.insert(candidate.candidateId).inserted,
                      Int(exactly: candidate.revision) != nil,
                      candidate.revision <= conflict.currentRevision,
                      candidate.modifiedMs.isFinite, candidate.modifiedMs >= 0,
                      candidate.committedMs.isFinite, candidate.committedMs >= 0 else {
                    throw RowSyncSafetyError.invalidResponse
                }
                if candidate.op == "upsert" {
                    guard let bodyB64 = candidate.bodyB64,
                          let ciphertext = Data(base64Encoded: bodyB64), !ciphertext.isEmpty,
                          let sha256 = candidate.sha256,
                          sha256.count == 64,
                          sha256 == sha256.lowercased(),
                          sha256.allSatisfy(\.isHexDigit),
                          SyncConflict.sha256Hex(ciphertext) == sha256.lowercased() else {
                        throw RowSyncSafetyError.invalidResponse
                    }
                } else if candidate.bodyB64 != nil || candidate.sha256 != nil {
                    throw RowSyncSafetyError.invalidResponse
                }
                return ConflictCandidate(
                    candidateID: candidate.candidateId,
                    kind: kind,
                    isDelete: candidate.op == "delete",
                    revision: candidate.revision,
                    modifiedAt: Self.dateFromServerMs(candidate.modifiedMs),
                    committedAt: Self.dateFromServerMs(candidate.committedMs),
                    deviceName: candidate.deviceName,
                    platform: candidate.platform,
                    bodyB64: candidate.bodyB64,
                    sha256: candidate.sha256)
            }
            guard (2...32).contains(candidates.count) else {
                throw RowSyncSafetyError.invalidResponse
            }
            return ConflictRecord(
                conflictID: conflict.conflictId,
                itemUUID: itemUUID,
                baseRevision: conflict.baseRevision,
                currentRevision: conflict.currentRevision,
                currentDeletedSequence: currentDeletedSequence,
                generation: conflict.generation,
                createdAt: Self.dateFromServerMs(conflict.createdMs),
                updatedAt: Self.dateFromServerMs(conflict.updatedMs),
                candidates: candidates)
        }
        return conflicts
    }

    /// Pages through retained conflict candidates using one authenticated server snapshot.
    /// Lists retained candidates and resolution metadata using one fixed server snapshot.
    /// - Parameters:
    ///   - token: Account authorization token.
    ///   - vaultId: Bound remote vault identity.
    /// - Returns: All retained candidate groups visible in the snapshot.
    /// - Throws: Network or response validation errors.
    public func listRetainedConflicts(
        token: String,
        vaultId: String
    ) async throws -> [RetainedConflictRecord] {
        struct Candidate: Decodable {
            let candidateId: String
            let kind: Int
            let op: String
            let revision: UInt64
            let modifiedMs: Double
            let committedMs: Double
            let deviceName: String
            let platform: String
            let bodyB64: String?
            let sha256: String?
        }
        struct Entry: Decodable {
            let conflictId: String
            let itemUuid: String
            let baseRevision: UInt64
            let currentRevision: UInt64
            let currentDeletedSeq: Int
            let generation: UInt64
            let createdMs: Double
            let updatedMs: Double
            let resolvedMs: Double
            let expiresMs: Double
            let selectedCandidateId: String?
            let candidate: Candidate
        }
        struct Response: Decodable {
            let snapshotMs: Int64
            let totalCandidates: Int
            let candidates: [Entry]
            let nextCursor: String?
        }

        let basePath = "/v1/vaults/\(vaultId)/conflict-history?limit=\(Self.conflictHistoryPageLimit)"
        var cursor: String?
        var snapshotMS: Int64?
        var totalCandidates: Int?
        var receivedCandidates = 0
        var seenCursors = Set<String>()
        var seenCandidateIDs = Set<String>()
        var builders: [String: RetainedConflictBuilder] = [:]

        while true {
            let path: String
            if let cursor {
                let allowedCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.")
                guard let encodedCursor = cursor.addingPercentEncoding(withAllowedCharacters: allowedCharacters) else {
                    throw RowSyncSafetyError.invalidResponse
                }
                path = "\(basePath)&cursor=\(encodedCursor)"
            } else {
                path = basePath
            }
            let response: Response = try await send(
                "GET",
                path,
                body: nil,
                token: token,
                maximumResponseBytes: Self.conflictHistoryPageMaximumBytes)
            guard response.snapshotMs > 0,
                  response.totalCandidates >= 0,
                  response.totalCandidates <= Self.maximumConflictHistoryCandidateCount,
                  response.candidates.count <= response.totalCandidates - receivedCandidates,
                  snapshotMS == nil || snapshotMS == response.snapshotMs,
                  totalCandidates == nil || totalCandidates == response.totalCandidates else {
                throw RowSyncSafetyError.invalidResponse
            }
            snapshotMS = response.snapshotMs
            totalCandidates = response.totalCandidates

            for entry in response.candidates {
                guard let itemUUID = UUID(uuidString: entry.itemUuid),
                      Self.isConflictIdentifier(entry.conflictId),
                      entry.baseRevision < entry.currentRevision,
                      entry.currentDeletedSeq >= 0,
                      entry.generation > 0,
                      Int(exactly: entry.generation) != nil,
                      entry.createdMs.isFinite, entry.createdMs >= 0,
                      entry.updatedMs.isFinite, entry.updatedMs >= 0,
                      entry.resolvedMs.isFinite, entry.resolvedMs > 0,
                      entry.resolvedMs <= Double(response.snapshotMs),
                      entry.expiresMs.isFinite, entry.expiresMs > Double(response.snapshotMs),
                      entry.selectedCandidateId.map(Self.isConflictIdentifier) ?? true,
                      entry.candidate.candidateId.count == 32,
                      Self.isConflictIdentifier(entry.candidate.candidateId),
                      (1...3).contains(entry.candidate.kind),
                      entry.candidate.revision <= entry.currentRevision,
                      entry.candidate.modifiedMs.isFinite, entry.candidate.modifiedMs >= 0,
                      entry.candidate.committedMs.isFinite, entry.candidate.committedMs >= 0,
                      entry.candidate.op == "upsert" || entry.candidate.op == "delete" else {
                    throw RowSyncSafetyError.invalidResponse
                }
                let candidateKey = "\(entry.conflictId):\(entry.candidate.candidateId)"
                guard seenCandidateIDs.insert(candidateKey).inserted else {
                    throw RowSyncSafetyError.invalidResponse
                }
                let candidate: ConflictCandidate
                if entry.candidate.op == "upsert" {
                    guard let bodyB64 = entry.candidate.bodyB64,
                          let cipher = Data(base64Encoded: bodyB64), !cipher.isEmpty,
                          let sha256 = entry.candidate.sha256,
                          Self.isSHA256(sha256),
                          SyncConflict.sha256Hex(cipher) == sha256 else {
                        throw RowSyncSafetyError.invalidResponse
                    }
                    candidate = ConflictCandidate(
                        candidateID: entry.candidate.candidateId,
                        kind: UInt8(entry.candidate.kind),
                        isDelete: false,
                        revision: entry.candidate.revision,
                        modifiedAt: Self.dateFromServerMs(entry.candidate.modifiedMs),
                        committedAt: Self.dateFromServerMs(entry.candidate.committedMs),
                        deviceName: entry.candidate.deviceName,
                        platform: entry.candidate.platform,
                        bodyB64: bodyB64,
                        sha256: sha256)
                } else {
                    guard entry.candidate.bodyB64 == nil, entry.candidate.sha256 == nil else {
                        throw RowSyncSafetyError.invalidResponse
                    }
                    candidate = ConflictCandidate(
                        candidateID: entry.candidate.candidateId,
                        kind: UInt8(entry.candidate.kind),
                        isDelete: true,
                        revision: entry.candidate.revision,
                        modifiedAt: Self.dateFromServerMs(entry.candidate.modifiedMs),
                        committedAt: Self.dateFromServerMs(entry.candidate.committedMs),
                        deviceName: entry.candidate.deviceName,
                        platform: entry.candidate.platform,
                        bodyB64: nil,
                        sha256: nil)
                }
                let builder = RetainedConflictBuilder(
                    conflictID: entry.conflictId,
                    itemUUID: itemUUID,
                    baseRevision: entry.baseRevision,
                    currentRevision: entry.currentRevision,
                    currentDeletedSequence: entry.currentDeletedSeq,
                    generation: entry.generation,
                    createdAt: Self.dateFromServerMs(entry.createdMs),
                    updatedAt: Self.dateFromServerMs(entry.updatedMs),
                    resolvedAt: Self.dateFromServerMs(entry.resolvedMs),
                    expiresAt: Self.dateFromServerMs(entry.expiresMs),
                    selectedCandidateID: entry.selectedCandidateId,
                    candidates: [])
                if var existing = builders[entry.conflictId] {
                    guard existing.conflictID == builder.conflictID,
                          existing.itemUUID == builder.itemUUID,
                          existing.baseRevision == builder.baseRevision,
                          existing.currentRevision == builder.currentRevision,
                          existing.currentDeletedSequence == builder.currentDeletedSequence,
                          existing.generation == builder.generation,
                          existing.createdAt == builder.createdAt,
                          existing.updatedAt == builder.updatedAt,
                          existing.resolvedAt == builder.resolvedAt,
                          existing.expiresAt == builder.expiresAt,
                          existing.selectedCandidateID == builder.selectedCandidateID else {
                        throw RowSyncSafetyError.invalidResponse
                    }
                    existing.candidates.append(candidate)
                    builders[entry.conflictId] = existing
                } else {
                    var newBuilder = builder
                    newBuilder.candidates.append(candidate)
                    builders[entry.conflictId] = newBuilder
                }
                receivedCandidates += 1
            }

            guard let nextCursor = response.nextCursor else {
                guard receivedCandidates == response.totalCandidates else {
                    throw RowSyncSafetyError.invalidResponse
                }
                return builders.values.map { $0.record() }.sorted { $0.conflictID < $1.conflictID }
            }
            guard !nextCursor.isEmpty,
                  seenCursors.insert(nextCursor).inserted,
                  !response.candidates.isEmpty,
                  receivedCandidates < response.totalCandidates else {
                throw RowSyncSafetyError.invalidResponse
            }
            cursor = nextCursor
        }
    }

    /// Atomically chooses one retained candidate using the complete server candidate set.
    ///
    /// For a previously deleted item, an upsert winner must be re-encrypted by the caller
    /// with `restoreItemUUID` as its authenticated-data identity.
    ///
    /// - Parameters:
    ///   - token: Account session token.
    ///   - vaultId: Cloud vault identity.
    ///   - conflict: The latest conflict record returned by `listConflicts`.
    ///   - winningCandidateID: Candidate selected by the user.
    ///   - attachmentReferences: Attachment versions selected with the encrypted card candidate.
    ///   - restoreItemUUID: New identity required when restoring a deleted item.
    ///   - restoredBody: Candidate plaintext re-encrypted for `restoreItemUUID`.
    ///   - composedBody: Client-encrypted composed item body for an active conflict.
    ///   - composedModifiedMs: Modified time authenticated inside `composedBody`.
    /// - Returns: The resolved item identity, vault item count, and change cursor.
    /// - Throws: Relay errors for stale candidate sets, unsupported attachment references,
    ///   authorization failures, or transport errors.
    public func resolveConflict(
        token: String,
        vaultId: String,
        conflict: ConflictRecord,
        winningCandidateID: String,
        attachmentReferences: [AttachmentReference],
        restoreItemUUID: UUID? = nil,
        restoredBody: Data? = nil,
        composedBody: Data? = nil,
        composedModifiedMs: Int64? = nil
    ) async throws -> ConflictResolutionResult {
        struct Response: Decodable {
            let status: String
            let itemUuid: String?
            let itemCount: Int
            let headSeq: Int
        }

        let zeroUUID = "00000000-0000-0000-0000-000000000000"
        let candidateIDs = conflict.candidates.map(\.candidateID).sorted()
        guard let generation = Int(exactly: conflict.generation),
              Int(exactly: conflict.baseRevision) != nil,
              let currentRevision = Int(exactly: conflict.currentRevision),
              conflict.conflictID.count == 32,
              conflict.conflictID == conflict.conflictID.lowercased(),
              conflict.conflictID.allSatisfy(\.isHexDigit),
              conflict.generation > 0,
              conflict.currentDeletedSequence >= 0,
              conflict.baseRevision < conflict.currentRevision,
              (2...32).contains(candidateIDs.count),
              Set(candidateIDs).count == candidateIDs.count,
              candidateIDs.allSatisfy({
                  $0.count == 32 && $0 == $0.lowercased() && $0.allSatisfy(\.isHexDigit)
              }),
              candidateIDs.contains(winningCandidateID),
              let winner = conflict.candidates.first(where: {
                  $0.candidateID == winningCandidateID
              }),
              attachmentReferences.count <= 500,
              Set(attachmentReferences.map(\.attachmentID)).count == attachmentReferences.count,
              attachmentReferences.allSatisfy({
                  $0.attachmentID.uuidString.lowercased() != zeroUUID
                      && $0.contentVersion.uuidString.lowercased() != zeroUUID
              }),
              winner.kind == 1 || attachmentReferences.isEmpty else {
            throw RowSyncSafetyError.invalidResponse
        }

        let restoringDeletedItem = conflict.currentDeletedSequence > 0 && !winner.isDelete
        let composing = composedBody != nil || composedModifiedMs != nil
        if restoringDeletedItem {
            guard !composing,
                  let restoreItemUUID, restoreItemUUID != conflict.itemUUID,
                  let restoredBody, !restoredBody.isEmpty else {
                throw RowSyncSafetyError.invalidResponse
            }
        } else {
            guard restoreItemUUID == nil, restoredBody == nil else {
                throw RowSyncSafetyError.invalidResponse
            }
            if composing {
                guard conflict.currentDeletedSequence == 0,
                      !winner.isDelete,
                      let composedBody, !composedBody.isEmpty,
                      let composedModifiedMs,
                      (0...253_402_300_799_999).contains(composedModifiedMs) else {
                    throw RowSyncSafetyError.invalidResponse
                }
            }
        }

        var payload: [String: Any] = [
            "generation": generation,
            "candidateIds": candidateIDs,
            "winnerCandidateId": winningCandidateID,
            "expectedCurrentRevision": currentRevision,
            "expectedDeletedSeq": conflict.currentDeletedSequence,
            "attachmentRefs": attachmentReferences.map { reference in
                [
                    "attachmentId": reference.attachmentID.uuidString.lowercased(),
                    "contentVersion": reference.contentVersion.uuidString.lowercased(),
                    "restoreDeleted": reference.restoreDeleted,
                ]
            },
        ]
        if let restoreItemUUID, let restoredBody {
            payload["restoreItemUuid"] = restoreItemUUID.uuidString
            payload["bodyB64"] = restoredBody.base64EncodedString()
        }
        if let composedBody, let composedModifiedMs {
            payload["mergedBodyB64"] = composedBody.base64EncodedString()
            payload["mergedModifiedMs"] = composedModifiedMs
        }

        let response: Response = try await send(
            "POST", "/v1/vaults/\(vaultId)/conflicts/\(conflict.conflictID)/resolve",
            body: payload, token: token)
        guard response.status == "resolved",
              response.itemCount >= 0,
              response.headSeq >= 0 else {
            throw RowSyncSafetyError.invalidResponse
        }
        let resolvedItemUUID = response.itemUuid.flatMap(UUID.init(uuidString:))
        guard response.itemUuid == nil || resolvedItemUUID != nil,
              resolvedItemUUID == (winner.isDelete ? nil : (restoreItemUUID ?? conflict.itemUUID)) else {
            throw RowSyncSafetyError.invalidResponse
        }
        return ConflictResolutionResult(
            itemUUID: resolvedItemUUID,
            itemCount: response.itemCount,
            headSequence: response.headSeq)
    }

    /// Registers an encrypted local version only after automatic merge has failed.
    public func registerConflictCandidate(
        token: String,
        vaultId: String,
        operation: ItemOp,
        expectedRevision: UInt64,
        candidateID: String,
        fingerprint: String,
        expectedDeletedSequence: Int? = nil
    ) async throws -> ConflictRegistration {
        struct Response: Decodable {
            let conflictId: String
            let generation: UInt64
            let candidateCount: Int
            let currentRevision: UInt64
        }

        guard expectedRevision > operation.baseRevision,
              expectedRevision <= UInt64(Int.max),
              operation.baseRevision <= UInt64(Int.max),
              candidateID.count == 32,
              candidateID.allSatisfy({ $0.isHexDigit }),
              fingerprint.count == 64,
              fingerprint.allSatisfy({ $0.isHexDigit }),
              candidateID.lowercased() == fingerprint.lowercased().prefix(32),
              expectedDeletedSequence.map({ $0 > 0 }) ?? true,
              operation.isDelete || operation.bodyB64 != nil else {
            throw RowSyncSafetyError.invalidResponse
        }
        var payload: [String: Any] = [
            "expectedRevision": Int(expectedRevision),
            "baseRevision": Int(operation.baseRevision),
            "candidateId": candidateID.lowercased(),
            "candidateFingerprint": fingerprint,
            "kind": Int(operation.kind),
            "op": operation.isDelete ? "delete" : "upsert",
            "modifiedMs": Int(operation.modifiedMs),
        ]
        if let bodyB64 = operation.bodyB64 {
            payload["bodyB64"] = bodyB64
            if let sha256 = operation.sha256 { payload["sha256"] = sha256 }
        }
        if let expectedDeletedSequence {
            payload["expectedDeletedSeq"] = expectedDeletedSequence
        }

        let response: Response
        do {
            response = try await send(
                "POST", "/v1/vaults/\(vaultId)/items/\(operation.uuid.uuidString)/conflicts",
                body: payload, token: token)
        } catch RelayError.notFound {
            // An older API has no conflict route; keep the normal protective pause.
            throw RowSyncSafetyError.conflictNeedsResolution
        } catch RelayError.server(409) {
            throw RowSyncSafetyError.conflictNeedsResolution
        }
        guard response.conflictId.count == 32,
              response.conflictId.allSatisfy(\.isHexDigit),
              response.generation > 0, (2...32).contains(response.candidateCount),
              response.currentRevision == expectedRevision else {
            throw RowSyncSafetyError.invalidResponse
        }
        return ConflictRegistration(
            conflictID: response.conflictId,
            generation: response.generation,
            candidateCount: response.candidateCount,
            currentRevision: response.currentRevision)
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
                let resolvedItemUuid: String?
                let conflictId: String?
                let resolvedRevision: UInt64?
                let baseRevision: UInt64?
                let winnerCandidateId: String?
                let winnerKind: Int?
                let winnerOp: String?
                let resolutionType: String?
                let bodyB64: String?
                let kind: Int?
                let modifiedMs: Double?
            }
            let headSeq: Int
            let changes: [Entry]
        }
        let response: Response = try await send(
            "GET", "/v1/vaults/\(vaultId)/changes?since=\(since)&limit=\(limit)",
            body: nil, token: token)
        guard response.headSeq >= since else { throw RowSyncSafetyError.invalidResponse }
        var previousSeq = since
        let entries = try response.changes.map { entry -> ChangeEntry in
            guard entry.seq > previousSeq, entry.seq <= response.headSeq, entry.revision > 0,
                  ["upsert", "purge", "resolve", "rekey"].contains(entry.op) else {
                throw RowSyncSafetyError.invalidResponse
            }
            previousSeq = entry.seq
            let uuid: UUID
            if entry.op == "rekey" {
                guard entry.uuid.isEmpty, Int(exactly: entry.revision) != nil else {
                    throw RowSyncSafetyError.invalidResponse
                }
                uuid = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
            } else {
                guard let parsed = UUID(uuidString: entry.uuid) else {
                    throw RowSyncSafetyError.invalidResponse
                }
                uuid = parsed
            }
            let kind: UInt8?
            if let rawKind = entry.kind {
                guard let parsed = UInt8(exactly: rawKind), parsed > 0 else {
                    throw RowSyncSafetyError.invalidResponse
                }
                kind = parsed
            } else {
                kind = nil
            }
            if entry.op == "upsert" {
                guard entry.deleted != true, kind != nil, entry.bodyB64 != nil else {
                    throw RowSyncSafetyError.invalidResponse
                }
            }
            let resolvedItemUUID: UUID?
            if let rawResolvedUUID = entry.resolvedItemUuid {
                guard entry.op == "resolve", let parsed = UUID(uuidString: rawResolvedUUID) else {
                    throw RowSyncSafetyError.invalidResponse
                }
                resolvedItemUUID = parsed
            } else {
                resolvedItemUUID = nil
            }
            if entry.op == "resolve" {
                guard let conflictID = entry.conflictId,
                      conflictID.count == 32,
                      conflictID == conflictID.lowercased(),
                      conflictID.allSatisfy(\.isHexDigit),
                      let baseRevision = entry.baseRevision,
                      baseRevision < entry.revision,
                      let winnerCandidateID = entry.winnerCandidateId,
                      winnerCandidateID.count == 32,
                      winnerCandidateID == winnerCandidateID.lowercased(),
                      winnerCandidateID.allSatisfy(\.isHexDigit),
                      let rawWinnerKind = entry.winnerKind,
                      let winnerKind = UInt8(exactly: rawWinnerKind), winnerKind > 0,
                      let winnerOp = entry.winnerOp,
                      ["upsert", "delete"].contains(winnerOp),
                      let rawResolutionType = entry.resolutionType,
                      let resolutionType = ConflictResolutionType(rawValue: rawResolutionType) else {
                    throw RowSyncSafetyError.invalidResponse
                }
                let winnerIsDelete = winnerOp == "delete"
                guard resolutionType != .composed || !winnerIsDelete else {
                    throw RowSyncSafetyError.invalidResponse
                }
                guard (resolvedItemUUID == nil) == winnerIsDelete,
                      (kind == nil) == winnerIsDelete else {
                    throw RowSyncSafetyError.invalidResponse
                }
                if resolvedItemUUID == nil {
                    guard entry.deleted == true, entry.bodyB64 == nil, kind == nil,
                          entry.resolvedRevision == nil else {
                        throw RowSyncSafetyError.invalidResponse
                    }
                } else if entry.deleted == true {
                    guard entry.bodyB64 == nil, kind == nil, entry.resolvedRevision == nil else {
                        throw RowSyncSafetyError.invalidResponse
                    }
                } else {
                    guard entry.deleted != true, entry.bodyB64 != nil, kind != nil,
                          kind == winnerKind, entry.modifiedMs != nil,
                          let resolvedRevision = entry.resolvedRevision,
                          resolvedRevision > 0 else {
                        throw RowSyncSafetyError.invalidResponse
                    }
                }
            } else if entry.resolvedItemUuid != nil || entry.conflictId != nil || entry.resolvedRevision != nil
                || entry.baseRevision != nil || entry.winnerCandidateId != nil
                || entry.winnerKind != nil || entry.winnerOp != nil || entry.resolutionType != nil {
                throw RowSyncSafetyError.invalidResponse
            }
            return ChangeEntry(
                seq: entry.seq, uuid: uuid, op: entry.op, revision: entry.revision,
                deleted: entry.deleted ?? (entry.op == "purge"),
                bodyB64: entry.bodyB64, kind: kind, modifiedMs: entry.modifiedMs,
                resolvedItemUUID: resolvedItemUUID, conflictID: entry.conflictId,
                resolvedRevision: entry.resolvedRevision,
                conflictBaseRevision: entry.baseRevision,
                winnerCandidateID: entry.winnerCandidateId,
                winnerKind: entry.winnerKind.flatMap(UInt8.init(exactly:)),
                winnerIsDelete: entry.winnerOp.map { $0 == "delete" },
                resolutionType: entry.resolutionType.flatMap(ConflictResolutionType.init(rawValue:)))
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
            "GET", "/v1/vaults/\(vaultId)/items?cursorMs=\(cursorMs)&cursorUuid=\(cursorUuid)&limit=\(limit)",
            body: nil, token: token)
        guard response.headSeq >= 0 else { throw RowSyncSafetyError.invalidResponse }
        var seen = Set<UUID>()
        let items = try response.items.map { item -> ListedItem in
            guard let uuid = UUID(uuidString: item.uuid), seen.insert(uuid).inserted,
                  let kind = UInt8(exactly: item.kind), kind > 0, item.revision > 0 else {
                throw RowSyncSafetyError.invalidResponse
            }
            return ListedItem(uuid: uuid, kind: kind, revision: item.revision,
                              bodyB64: item.bodyB64, modifiedMs: item.modifiedMs)
        }
        if let next = response.nextCursor {
            guard next.ms >= 0, UUID(uuidString: next.uuid) != nil, !items.isEmpty else {
                throw RowSyncSafetyError.invalidResponse
            }
        }
        return (items, response.nextCursor.map { ($0.ms, $0.uuid) }, response.headSeq)
    }

    // MARK: - 附件(R2 密文 blob)

    /// Uploads an immutable ciphertext version before the card row CAS activates its reference.
    public func putAttachment(token: String, vaultId: String, attachUuid: UUID,
                              contentVersion: UUID, cardUuid: UUID,
                              cipher: Data, dekWrapped: Data) async throws {
        let uploadId = Self.randomUploadId()
        let sha = SyncConflict.sha256Hex(cipher)
        guard let url = URL(
            string: "/v1/vaults/\(vaultId)/attachments/\(attachUuid.uuidString)?upload=\(uploadId)&version=\(contentVersion.uuidString)",
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
            "POST", "/v1/vaults/\(vaultId)/attachments/\(attachUuid.uuidString)/commit",
            body: ["uploadId": uploadId, "sha256": sha, "cardUuid": cardUuid.uuidString,
                   "contentVersion": contentVersion.uuidString,
                   "dekWrapped": dekWrapped.base64EncodedString()],
            token: token)
        Log.info("sync", "relay attachment version pushed id=\(attachUuid.uuidString.prefix(8))… size=\(cipher.count)")
    }

    /// Lists every current and retained attachment version, following all bounded pages.
    public func getAttachmentVersions(token: String, vaultId: String) async throws -> [AttachmentVersionMetadata] {
        try await getAttachmentVersions(token: token, vaultId: vaultId, cardUuid: nil)
    }

    /// Lists current and retained attachment versions for one card.
    public func getAttachmentVersions(token: String, vaultId: String,
                                      cardUuid: UUID) async throws -> [AttachmentVersionMetadata] {
        try await getAttachmentVersions(token: token, vaultId: vaultId, cardUuid: Optional(cardUuid))
    }

    private func getAttachmentVersions(token: String, vaultId: String,
                                       cardUuid: UUID?) async throws -> [AttachmentVersionMetadata] {
        struct Response: Decodable {
            struct Entry: Decodable {
                let attachmentId: String
                let cardUuid: String
                let contentVersion: String?
                let dekWrapped: String
                let sha256: String
                let bytes: Int64
                let isCurrent: Bool
            }
            let versions: [Entry]
            let nextOffset: Int
            let hasMore: Bool
        }
        var offset = 0
        var versions: [AttachmentVersionMetadata] = []
        var identities = Set<String>()
        repeat {
            var query = "limit=\(Self.attachmentVersionPageLimit)&offset=\(offset)"
            if let cardUuid {
                query += "&cardUuid=\(cardUuid.uuidString)"
            }
            let path = "/v1/vaults/\(vaultId)/attachment-versions?\(query)"
            let response: Response = try await send(
                "GET",
                path,
                body: nil,
                token: token,
                maximumResponseBytes: Self.attachmentVersionPageMaximumBytes)
            guard response.versions.count <= Self.attachmentVersionPageLimit,
                  versions.count <= Self.maximumAttachmentVersionCount - response.versions.count,
                  response.nextOffset == offset + response.versions.count,
                  !response.hasMore || !response.versions.isEmpty else {
                throw RowSyncSafetyError.invalidResponse
            }

            for entry in response.versions {
                guard let attachmentID = UUID(uuidString: entry.attachmentId),
                      let cardID = UUID(uuidString: entry.cardUuid),
                      let dekWrapped = Data(base64Encoded: entry.dekWrapped),
                      (28...256).contains(dekWrapped.count),
                      Self.isSHA256(entry.sha256), entry.bytes > 0 else {
                    throw RowSyncSafetyError.invalidResponse
                }
                let contentVersion = entry.contentVersion.flatMap(UUID.init(uuidString:))
                guard entry.contentVersion == nil || contentVersion != nil else {
                    throw RowSyncSafetyError.invalidResponse
                }
                guard identities.insert(Self.attachmentVersionIdentity(
                    attachmentID: attachmentID,
                    contentVersion: contentVersion)).inserted else {
                    throw RowSyncSafetyError.invalidResponse
                }
                versions.append(AttachmentVersionMetadata(
                    attachmentID: attachmentID, cardID: cardID,
                    contentVersion: contentVersion, dekWrapped: dekWrapped,
                    sha256: entry.sha256.lowercased(), bytes: entry.bytes,
                    isCurrent: entry.isCurrent))
            }
            offset = response.nextOffset
            if !response.hasMore { break }
            guard offset < Self.maximumAttachmentVersionCount else {
                throw RowSyncSafetyError.invalidResponse
            }
        } while true
        return versions
    }

    private static func attachmentVersionIdentity(
        attachmentID: UUID,
        contentVersion: UUID?
    ) -> String {
        "\(attachmentID.uuidString.lowercased()):\(contentVersion?.uuidString.lowercased() ?? "legacy")"
    }

    private func dataDetachedFromCancellation(
        _ request: URLRequest,
        maximumResponseBytes: Int
    ) async throws -> (Data, HTTPURLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw RelayError.network("no http response")
                    }
                    guard maximumResponseBytes > 0,
                          http.expectedContentLength <= Int64(maximumResponseBytes) else {
                        throw RowSyncSafetyError.invalidResponse
                    }

                    let expectedLength = max(0, Int(clamping: http.expectedContentLength))
                    var buffer: [UInt8] = []
                    buffer.reserveCapacity(min(expectedLength, maximumResponseBytes))
                    for try await byte in bytes {
                        guard buffer.count < maximumResponseBytes else {
                            throw RowSyncSafetyError.invalidResponse
                        }
                        buffer.append(byte)
                    }
                    continuation.resume(returning: (Data(buffer), http))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Downloads, verifies, and returns one exact encrypted attachment version.
    public func getAttachment(token: String, vaultId: String, attachUuid: UUID,
                              contentVersion: UUID) async throws -> EncryptedAttachment {
        guard let url = URL(
            string: "/v1/vaults/\(vaultId)/attachments/\(attachUuid.uuidString)?version=\(contentVersion.uuidString)",
            relativeTo: baseURL) else {
            throw RelayError.network("bad url")
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (cipher, response) = try await runRawResponse(request, isCancellable: true)
        guard response.value(forHTTPHeaderField: "X-Content-Version")?.lowercased()
                == contentVersion.uuidString.lowercased(),
              let wrappedValue = response.value(forHTTPHeaderField: "X-Dek-Wrapped"),
              let dekWrapped = Data(base64Encoded: wrappedValue),
              dekWrapped.count >= 28, dekWrapped.count <= 256,
              let expectedBytes = Int64(response.value(forHTTPHeaderField: "X-Bytes") ?? ""),
              expectedBytes > 0, expectedBytes == Int64(cipher.count),
              let contentLength = Int64(response.value(forHTTPHeaderField: "Content-Length") ?? ""),
              contentLength == expectedBytes,
              let expectedHash = response.value(forHTTPHeaderField: "X-Sha256"),
              Self.isSHA256(expectedHash),
              SyncConflict.sha256Hex(cipher) == expectedHash.lowercased() else {
            throw RelayError.attachmentIntegrityFailure
        }
        Log.info("sync", "relay attachment version pulled id=\(attachUuid.uuidString.prefix(8))… size=\(cipher.count)")
        return EncryptedAttachment(cipher: cipher, dekWrapped: dekWrapped)
    }

    /// 下载并校验附件密文的服务端摘要与声明长度。
    public func getAttachment(token: String, vaultId: String, attachUuid: UUID) async throws -> Data {
        guard let url = URL(
            string: "/v1/vaults/\(vaultId)/attachments/\(attachUuid.uuidString)",
            relativeTo: baseURL) else {
            throw RelayError.network("bad url")
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await runRawResponse(request, isCancellable: true)
        guard let expectedBytes = Int64(response.value(forHTTPHeaderField: "X-Bytes") ?? ""),
              expectedBytes > 0,
              expectedBytes == Int64(data.count),
              let contentLength = Int64(response.value(forHTTPHeaderField: "Content-Length") ?? ""),
              contentLength == expectedBytes,
              let expectedHash = response.value(forHTTPHeaderField: "X-Sha256"),
              Self.isSHA256(expectedHash),
              SyncConflict.sha256Hex(data) == expectedHash.lowercased() else {
            Log.error(
                "sync",
                "relay attachment integrity failed id=\(attachUuid.uuidString.prefix(8))… bytes=\(data.count)")
            throw RelayError.attachmentIntegrityFailure
        }
        Log.info("sync", "relay attachment pulled id=\(attachUuid.uuidString.prefix(8))… size=\(data.count)")
        return data
    }

    /// 附件删除(随条目硬清除触发)。
    public func deleteAttachment(token: String, vaultId: String, attachUuid: UUID) async throws {
        struct Empty: Decodable {}
        let _: Empty = try await send(
            "DELETE", "/v1/vaults/\(vaultId)/attachments/\(attachUuid.uuidString)",
            body: nil, token: token)
    }

    // MARK: - 改密 rekey(§6.5)

    /// 开始 rekey:此后该库普通条目写会撞 rekeyInProgress,直到 commit/abort。
    public func rekeyBegin(token: String, vaultId: String, envelope: Data,
                           itemCount: Int, dekCount: Int) async throws -> (
                            rekeyId: String, passwordVersion: Int, conflictCount: Int
                           ) {
        struct Response: Decodable {
            let rekeyId: String
            let passwordVersion: Int
            let conflictCount: Int
        }
        let response: Response = try await send(
            "POST", "/v1/vaults/\(vaultId)/rekey/begin",
            body: ["envelope": envelope.base64EncodedString(),
                   "itemCount": itemCount, "dekCount": dekCount],
            token: token)
        guard Self.isConflictIdentifier(response.rekeyId), response.passwordVersion > 0,
              (0...Self.maximumConflictHistoryCandidateCount).contains(response.conflictCount) else {
            throw RowSyncSafetyError.invalidResponse
        }
        return (response.rekeyId, response.passwordVersion, response.conflictCount)
    }

    /// Reads one page from the candidate inventory captured by an active rekey session.
    public func rekeyConflictCandidates(
        token: String,
        vaultId: String,
        rekeyId: String,
        offset: Int
    ) async throws -> (total: Int, candidates: [RekeyConflictCandidate]) {
        struct Response: Decodable {
            struct Candidate: Decodable {
                let conflictId: String
                let itemUuid: String
                let candidateId: String
                let kind: Int
                let op: String
                let revision: UInt64
                let bodyB64: String?
                let sha256: String?
            }

            let totalCandidates: Int
            let offset: Int
            let candidates: [Candidate]
        }

        guard Self.isConflictIdentifier(rekeyId), offset >= 0 else {
            throw RowSyncSafetyError.invalidResponse
        }
        let response: Response = try await send(
            "GET",
            "/v1/vaults/\(vaultId)/rekey/\(rekeyId)/conflicts?offset=\(offset)&limit=\(Self.rekeyConflictPageLimit)",
            body: nil,
            token: token,
            maximumResponseBytes: Self.conflictHistoryPageMaximumBytes)
        guard response.totalCandidates >= 0,
              response.totalCandidates <= Self.maximumConflictHistoryCandidateCount,
              offset <= response.totalCandidates,
              response.offset == offset,
              response.candidates.count <= Self.rekeyConflictPageLimit,
              response.candidates.count <= response.totalCandidates - offset else {
            throw RowSyncSafetyError.invalidResponse
        }
        var identities = Set<String>()
        let candidates = try response.candidates.map { candidate -> RekeyConflictCandidate in
            guard Self.isConflictIdentifier(candidate.conflictId),
                  Self.isConflictIdentifier(candidate.candidateId),
                  let itemUUID = UUID(uuidString: candidate.itemUuid),
                  let kind = UInt8(exactly: candidate.kind), (1...3).contains(kind),
                  candidate.revision <= UInt64(Int.max),
                  candidate.op == "upsert" || candidate.op == "delete",
                  identities.insert("\(candidate.conflictId):\(candidate.candidateId)").inserted else {
                throw RowSyncSafetyError.invalidResponse
            }
            let body: Data?
            if candidate.op == "upsert" {
                guard let encoded = candidate.bodyB64,
                      let decoded = Data(base64Encoded: encoded), !decoded.isEmpty,
                      let sha256 = candidate.sha256, Self.isSHA256(sha256),
                      SyncConflict.sha256Hex(decoded) == sha256 else {
                    throw RowSyncSafetyError.invalidResponse
                }
                body = decoded
            } else {
                guard candidate.bodyB64 == nil, candidate.sha256 == nil else {
                    throw RowSyncSafetyError.invalidResponse
                }
                body = nil
            }
            return RekeyConflictCandidate(
                conflictID: candidate.conflictId,
                itemUUID: itemUUID,
                oldCandidateID: candidate.candidateId,
                kind: kind,
                isDelete: candidate.op == "delete",
                revision: candidate.revision,
                body: body,
                sha256: candidate.sha256)
        }
        return (response.totalCandidates, candidates)
    }

    /// Stages one page of VEK-reencrypted conflict candidates for an active rekey.
    public func rekeyConflictChunk(
        token: String,
        vaultId: String,
        rekeyId: String,
        candidates: [(conflictID: String, oldCandidateID: String, candidateID: String,
                     fingerprint: String, bodyB64: String?, sha256: String?)]
    ) async throws {
        struct Empty: Decodable {}
        guard Self.isConflictIdentifier(rekeyId),
              !candidates.isEmpty, candidates.count <= Self.rekeyConflictPageLimit else {
            throw RowSyncSafetyError.invalidResponse
        }
        let payload = try candidates.map { candidate -> [String: String] in
            guard Self.isConflictIdentifier(candidate.conflictID),
                  Self.isConflictIdentifier(candidate.oldCandidateID),
                  Self.isConflictIdentifier(candidate.candidateID),
                  Self.isSHA256(candidate.fingerprint),
                  candidate.candidateID == String(candidate.fingerprint.prefix(32)) else {
                throw RowSyncSafetyError.invalidResponse
            }
            var entry = [
                "conflictId": candidate.conflictID,
                "oldCandidateId": candidate.oldCandidateID,
                "candidateId": candidate.candidateID,
                "fingerprint": candidate.fingerprint,
            ]
            if let bodyB64 = candidate.bodyB64, let sha256 = candidate.sha256,
               let body = Data(base64Encoded: bodyB64), Self.isSHA256(sha256),
               SyncConflict.sha256Hex(body) == sha256 {
                entry["bodyB64"] = bodyB64
                entry["sha256"] = sha256
            } else if candidate.bodyB64 != nil || candidate.sha256 != nil {
                throw RowSyncSafetyError.invalidResponse
            }
            return entry
        }
        let _: Empty = try await send(
            "POST", "/v1/vaults/\(vaultId)/rekey/\(rekeyId)/conflicts",
            body: ["candidates": payload], token: token)
    }

    /// 分块上传新 VEK 密文条目(断点续传;重传同 uuid 幂等)。
    public func rekeyChunk(
        token: String,
        vaultId: String,
        rekeyId: String,
        items: [(uuid: UUID, kind: UInt8, bodyB64: String, sha256: String)],
        dekWraps: [(uuid: UUID, contentVersion: UUID, dekB64: String)] = []
    ) async throws {
        struct Empty: Decodable {}
        let payload = items.map { [
            "uuid": $0.uuid.uuidString,
            "bodyB64": $0.bodyB64,
            "sha256": $0.sha256,
        ] as [String: Any] }
        let dekPayload = dekWraps.map { [
            "uuid": $0.uuid.uuidString,
            "contentVersion": $0.contentVersion.uuidString,
            "dekB64": $0.dekB64,
        ] }
        let _: Empty = try await send(
            "POST", "/v1/vaults/\(vaultId)/rekey/\(rekeyId)/chunk",
            body: ["items": payload, "dekWraps": dekPayload], token: token)
    }

    /// 提交换入:全部行 revision+1、信封与 password_version 原子切换。
    public func rekeyCommit(token: String, vaultId: String, rekeyId: String) async throws {
        struct Empty: Decodable {}
        let _: Empty = try await send(
            "POST", "/v1/vaults/\(vaultId)/rekey/\(rekeyId)/commit",
            body: [:], token: token)
    }

    /// 放弃 rekey(库回旧态,暂存清空)。
    public func rekeyAbort(token: String, vaultId: String, rekeyId: String) async throws {
        struct Empty: Decodable {}
        let _: Empty = try await send(
            "DELETE", "/v1/vaults/\(vaultId)/rekey/\(rekeyId)",
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
        try await runRawResponse(request).0
    }

    private func runRawResponse(
        _ request: URLRequest, isCancellable: Bool = false
    ) async throws -> (Data, HTTPURLResponse) {
        var request = request
        request.setValue(String(Self.syncProtocolVersion), forHTTPHeaderField: "X-UPW-Sync-Protocol")
        do {
            let data: Data
            let http: HTTPURLResponse
            if isCancellable {
                let result = try await session.data(for: request)
                guard let response = result.1 as? HTTPURLResponse else {
                    throw RelayError.network("no http response")
                }
                data = result.0
                http = response
            } else {
                (data, http) = try await dataDetachedFromCancellation(request)
            }
            guard (200..<300).contains(http.statusCode) else {
                throw Self.mapError(http: http, body: data)
            }
            return (data, http)
        } catch let error as RelayError {
            throw error
        } catch let error as URLError where isCancellable {
            if error.code == .cancelled || Task.isCancelled { throw CancellationError() }
            throw error
        } catch {
            throw RelayError.network(error.localizedDescription)
        }
    }

    private func send<T: Decodable>(_ method: String, _ path: String,
                                    body: [String: Any]?, token: String?,
                                    maximumResponseBytes: Int? = nil) async throws -> T {
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
        request.setValue(String(Self.syncProtocolVersion), forHTTPHeaderField: "X-UPW-Sync-Protocol")
        do {
            let (data, http): (Data, HTTPURLResponse)
            if let maximumResponseBytes {
                (data, http) = try await dataDetachedFromCancellation(
                    request,
                    maximumResponseBytes: maximumResponseBytes)
            } else {
                (data, http) = try await dataDetachedFromCancellation(request)
            }
            guard (200..<300).contains(http.statusCode) else {
                throw Self.mapError(http: http, body: data)
            }
            guard let decoded = try? JSONDecoder().decode(T.self, from: data) else {
                throw RelayError.network("bad response body")
            }
            return decoded
        } catch let error as RelayError {
            throw error
        } catch let error as RowSyncSafetyError {
            throw error
        } catch {
            throw RelayError.network(error.localizedDescription)
        }
    }

    /// 32 hex 上传会话号(服务端 staging 键)。
    private static func randomUploadId() -> String {
        (0..<16).map { _ in String(format: "%02x", Int.random(in: 0...255)) }.joined()
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy(\.isHexDigit)
    }

    private static func isConflictIdentifier(_ value: String) -> Bool {
        value.count == 32 && value == value.lowercased() && value.allSatisfy(\.isHexDigit)
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
        case "attachment_version_conflict", "attachment_version_reused": return .attachmentVersionConflict
        case "attachment_deleted": return .attachmentDeleted
        case "attachment_version_missing": return .attachmentVersionMissing
        case "attachment_owner_mismatch", "bad_attachment_reference", "duplicate_attachment_reference":
            return .attachmentVersionConflict
        case "conflict_candidates_retained": return .conflictCandidatesRetained
        case "conflict_stale": return .conflictStale
        case "conflict_candidates_changed": return .conflictCandidatesChanged
        case "conflict_resolved": return .conflictResolved
        case "conflict_attachments_pending": return .conflictAttachmentsPending
        case "client_upgrade_required": return .clientUpgradeRequired
        default: return .server(http.statusCode)
        }
    }
}
