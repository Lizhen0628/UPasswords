import Foundation
import UPasswordsCore

/// api.upasswords.com 协调服务客户端(见 Cloud/DESIGN.md):
/// 账户(邮箱验证码)与库注册表(版本元数据/信封/哈希)。
/// 零知识红线:所有请求只携带密文/哈希/元数据,绝不携带主密码或库密钥。
public struct RelayClient {
    /// 验证码用途:登录 / 敏感操作(删库、注销)。
    public enum Purpose: String {
        case login, sensitive
    }

    /// 登录会话(令牌只在签发响应出现一次,本地经 RelayTokenKeychain 保存)。
    public struct Session: Equatable {
        public let token: String
        public let expiresAt: Date
        public let userId: String
    }

    /// 已登录设备(会话管理页展示与撤销)。
    public struct DeviceSession: Identifiable, Equatable {
        public let id: String
        public let deviceName: String
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
        public let cipherSha256: String?
        public let xmlSha256: String?
        public let bodySha256: String?
        public let bodyBytes: Int?
        public let bodyUpdatedAt: Date?
    }

    /// 信封上报结果:新值生效 / 过期写被拒(服务端保留现值,changedAt 决胜)。
    public enum EnvelopePutOutcome: Equatable {
        case accepted(version: Int, changedAt: Date)
        case stale(changedAt: Date)
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
            case .server(let code): return "\(L10n.t("sync_error")) (\(code))"
            case .network(let detail): return "\(L10n.t("sync_error")): \(detail)"
            }
        }
    }

    /// 逻辑保证:合法字面量 URL
    private let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL = URL(string: "https://api.upasswords.com")!,
                session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    // MARK: - 账户(注册=登录)

    /// 请求发送验证码(202 恒定;限速抛 rateLimited)。
    public func requestCode(email: String, purpose: Purpose = .login) async throws {
        struct Empty: Decodable {}
        let _: Empty = try await send(
            "POST", "/v1/auth/code",
            body: ["email": email, "purpose": purpose.rawValue],
            token: nil)
    }

    /// 校验验证码;账户不存在则自动注册,返回新签发的会话令牌。
    public func verify(email: String, code: String, deviceName: String) async throws -> Session {
        struct Response: Decodable {
            let token: String
            let expiresAt: Double
            let userId: String
        }
        let response: Response = try await send(
            "POST", "/v1/auth/verify",
            body: ["email": email, "code": code, "deviceName": deviceName],
            token: nil)
        return Session(
            token: response.token,
            expiresAt: Date(timeIntervalSince1970: response.expiresAt),
            userId: response.userId)
    }

    /// 本账户设备会话列表(管理/登出用)。
    public func listSessions(token: String) async throws -> [DeviceSession] {
        struct Response: Decodable {
            struct Item: Decodable {
                let id: String
                let deviceName: String
            }
            let sessions: [Item]
        }
        let response: Response = try await send("GET", "/v1/auth/sessions", body: nil, token: token)
        return response.sessions.map { DeviceSession(id: $0.id, deviceName: $0.deviceName) }
    }

    /// 撤销指定设备会话。
    public func revokeSession(token: String, id: String) async throws {
        struct Empty: Decodable {}
        let _: Empty = try await send("DELETE", "/v1/auth/sessions/\(id)", body: nil, token: token)
    }

    /// 注销账户(需 sensitive 验证码;立即清空服务端敏感数据并吊销全部会话)。
    public func deregister(token: String, code: String) async throws {
        struct Empty: Decodable {}
        let _: Empty = try await send("DELETE", "/v1/account", body: ["code": code], token: token)
    }

    // MARK: - 库注册表

    /// 登记新库,返回服务端签发的 vaultId。
    public func createVault(token: String, name: String) async throws -> String {
        struct Response: Decodable { let vaultId: String }
        let response: Response = try await send("POST", "/v1/vaults", body: ["name": name], token: token)
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
            let cipherSha256: String?
            let xmlSha256: String?
            let bodySha256: String?
            let bodyBytes: Int?
            let bodyUpdatedAt: Double?
        }
        let response: Response = try await send("GET", "/v1/vaults", body: nil, token: token)
        return response.vaults.map {
            VaultRecord(
                vaultId: $0.vaultId, name: $0.name, passwordVersion: $0.passwordVersion,
                passwordChangedAt: $0.passwordChangedAt.map(Date.init(timeIntervalSince1970:)),
                envelopeChangedAt: $0.envelopeChangedAt.map(Date.init(timeIntervalSince1970:)),
                hasEnvelope: $0.hasEnvelope, envelope: nil,
                cipherSha256: $0.cipherSha256, xmlSha256: $0.xmlSha256,
                bodySha256: $0.bodySha256, bodyBytes: $0.bodyBytes,
                bodyUpdatedAt: $0.bodyUpdatedAt.map(Date.init(timeIntervalSince1970:)))
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
            let cipherSha256: String?
            let xmlSha256: String?
            let bodySha256: String?
            let bodyBytes: Int?
            let bodyUpdatedAt: Double?
        }
        let item: Item = try await send("GET", "/v1/vaults/\(vaultId)", body: nil, token: token)
        return VaultRecord(
            vaultId: item.vaultId, name: item.name, passwordVersion: item.passwordVersion,
            passwordChangedAt: item.passwordChangedAt.map(Date.init(timeIntervalSince1970:)),
            envelopeChangedAt: item.envelopeChangedAt.map(Date.init(timeIntervalSince1970:)),
            hasEnvelope: item.hasEnvelope,
            envelope: item.envelope.flatMap { Data(base64Encoded: $0) },
            cipherSha256: item.cipherSha256, xmlSha256: item.xmlSha256,
            bodySha256: item.bodySha256, bodyBytes: item.bodyBytes,
            bodyUpdatedAt: item.bodyUpdatedAt.map(Date.init(timeIntervalSince1970:)))
    }

    /// 上报新信封(改密后);changedAt 决胜,过期写返回 .stale 不覆盖。
    public func putEnvelope(token: String, vaultId: String, envelope: Data, changedAt: Date) async throws -> EnvelopePutOutcome {
        struct Response: Decodable {
            let stale: Bool?
            let changedAt: Double
            let passwordVersion: Int?
        }
        let response: Response = try await send(
            "PUT", "/v1/vaults/\(vaultId)/envelope",
            body: ["envelope": envelope.base64EncodedString(),
                   "changedAt": changedAt.timeIntervalSince1970],
            token: token)
        if response.stale == true {
            return .stale(changedAt: Date(timeIntervalSince1970: response.changedAt))
        }
        return .accepted(
            version: response.passwordVersion ?? 0,
            changedAt: Date(timeIntervalSince1970: response.changedAt))
    }

    /// 会话自命名:调用方会话更新自己的设备名(解锁后刷新,
    /// 让"管理设备"里的历史通用名自愈为型号+设备名)。
    public func renameSession(token: String, deviceName: String) async throws {
        struct Empty: Decodable {}
        let _: Empty = try await send(
            "PATCH", "/v1/auth/session",
            body: ["deviceName": deviceName],
            token: token)
    }

    /// 网盘上传成功后上报双哈希(密文=网盘文件身份,明文 XML=同步短路判据)。
    public func putHashes(token: String, vaultId: String, cipherSha256: String, xmlSha256: String) async throws {
        struct Empty: Decodable {}
        let _: Empty = try await send(
            "PUT", "/v1/vaults/\(vaultId)/hashes",
            body: ["cipherSha256": cipherSha256, "xmlSha256": xmlSha256],
            token: token)
    }

    /// 库体密文副本推送(standalone 扩展数据通路):单请求上传到服务端
    /// R2(staging→commit 原子换入)。内容仍是库密钥加密的密文,服务端零知识;
    /// 与网盘互为副本,任一可读即可恢复。配额超限抛 quotaExceeded。
    public func putBody(token: String, vaultId: String, cipher: Data) async throws {
        let uploadId = Self.randomUploadId()
        guard let url = URL(
            string: "/v1/vaults/\(vaultId)/body?upload=\(uploadId)",
            relativeTo: baseURL) else {
            throw RelayError.network("bad url")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = cipher
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw RelayError.network("no http response")
            }
            guard (200..<300).contains(http.statusCode) else {
                throw Self.mapError(http: http, body: data)
            }
        } catch let error as RelayError {
            throw error
        } catch {
            throw RelayError.network(error.localizedDescription)
        }
        struct Empty: Decodable {}
        let _: Empty = try await send(
            "POST", "/v1/vaults/\(vaultId)/body/commit",
            body: ["uploadId": uploadId, "sha256": SyncConflict.sha256Hex(cipher)],
            token: token)
        Log.info("sync", "relay body pushed id=\(vaultId.prefix(8))… size=\(cipher.count)")
    }

    /// 库体密文拉取(恢复/无网盘通道设备);库尚无副本时抛 notFound。
    public func getBody(token: String, vaultId: String) async throws -> Data {
        guard let url = URL(string: "/v1/vaults/\(vaultId)/body", relativeTo: baseURL) else {
            throw RelayError.network("bad url")
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw RelayError.network("no http response")
            }
            guard (200..<300).contains(http.statusCode) else {
                throw Self.mapError(http: http, body: data)
            }
            Log.info("sync", "relay body pulled id=\(vaultId.prefix(8))… size=\(data.count)")
            return data
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

    /// 解绑库注册(需 sensitive 验证码;不动网盘文件)。
    public func deleteVault(token: String, vaultId: String, code: String) async throws {
        struct Empty: Decodable {}
        let _: Empty = try await send(
            "DELETE", "/v1/vaults/\(vaultId)", body: ["code": code], token: token)
    }

    /// 库改名(vaultId 不变,注册表名与网盘文件名同步更换;
    /// 客户端先改网盘文件、成功后才调用本接口)。
    public func renameVault(token: String, vaultId: String, name: String) async throws {
        struct Empty: Decodable {}
        let _: Empty = try await send(
            "PATCH", "/v1/vaults/\(vaultId)", body: ["name": name], token: token)
        Log.info("sync", "relay vault renamed id=\(vaultId.prefix(8))… name-length=\(name.count)")
    }

    /// 换绑邮箱:注册表记录迁移到新邮箱名下(vaultId/信封/哈希不变),
    /// 并直接返回新账户的本机会话——前置:客户端已验当前主密码,
    /// 新邮箱须先收 sensitive 验证码。
    public func transferVault(token: String, vaultId: String, email: String,
                              code: String, deviceName: String) async throws -> Session {
        struct Response: Decodable {
            let token: String
            let expiresAt: Double
            let userId: String
        }
        let response: Response = try await send(
            "POST", "/v1/vaults/\(vaultId)/transfer",
            body: ["email": email, "code": code, "deviceName": deviceName],
            token: token)
        Log.info("sync", "relay vault transferred to new email (vault=\(vaultId.prefix(8))…)")
        return Session(
            token: response.token,
            expiresAt: Date(timeIntervalSince1970: response.expiresAt),
            userId: response.userId)
    }

    // MARK: - 传输

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
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw RelayError.network("no http response")
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
        } catch {
            throw RelayError.network(error.localizedDescription)
        }
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
        case "not_found": return .notFound
        case "name_exists": return .nameExists
        case "quota_exceeded": return .quotaExceeded
        case "invalid_envelope": return .invalidEnvelope
        default: return .server(http.statusCode)
        }
    }
}
