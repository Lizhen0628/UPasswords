import CryptoKit
import Foundation
import UPasswordsCore

/// Cloud sync drivers. The WebDAV driver talks PUT/GET to any WebDAV server;
/// the iCloud driver reads/writes the encrypted container in the user's
/// iCloud Drive, where the system CloudDocs daemon performs the transfer.
/// Google Drive / Dropbox / OneDrive require vendor OAuth credentials; those
/// cloud entries remain visible in the UI but report `not_configured_state`.
public struct WebDavSettings: Codable, Equatable {
    public init(host: String = "", port: Int = 443, useHTTPS: Bool = true, user: String = "",
                password: String = "", path: String = "/UPasswords/") {
        self.host = host
        self.port = port
        self.useHTTPS = useHTTPS
        self.user = user
        self.password = password
        self.path = path
    }

    public var host: String = ""
    public var port: Int = 443
    public var useHTTPS: Bool = true
    public var user: String = ""
    public var password: String = ""
    public var path: String = "/UPasswords/"

    public var baseURL: URL? {
        let scheme = useHTTPS ? "https" : "http"
        var comps = URLComponents()
        comps.scheme = scheme
        comps.host = host
        if port != (useHTTPS ? 443 : 80) { comps.port = port }
        guard let url = comps.url else { return nil }
        var p = path
        if !p.hasPrefix("/") { p = "/" + p }
        return url.appendingPathComponent(p.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }
}

/// 云同步类型;仅 none/webdav/icloud 可用(见 functional)。
public enum CloudType: String, CaseIterable, Identifiable {
    case none, webdav, gdrive, dropbox, onedrive, icloud
    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .none: return L10n.t("none_cloud")
        case .webdav: return L10n.t("webdav_cloud")
        case .gdrive: return L10n.t("gdrive_cloud")
        case .dropbox: return "Dropbox"
        case .onedrive: return "OneDrive"
        case .icloud: return "iCloud Drive"
        }
    }

    /// Whether this cloud can actually synchronize.
    public var functional: Bool { self == .none || self == .webdav || self == .icloud }
}

/// 同步失败错误域(文案走字符串表)。
public enum SyncError: LocalizedError, Equatable {
    case badUrl
    case http(Int)
    case notConfigured
    case wrongPassword
    case icloudUnavailable
    /// 沙盒进程看不到 iCloud Drive 根目录(无 ubiquity entitlement):
    /// 只能经「选择 iCloud 文件夹」授权访问,与"未登录 iCloud"区分开。
    case icloudFolderInaccessible
    case databaseNotFound
    case localNameConflict
    /// iCloud 文件未物化/下载中超时:上层应视为「同步失败待重试」而非「解不开」
    case notDownloaded
    case downloadFailed(String)

    public var errorDescription: String? {
        switch self {
        case .badUrl: return L10n.t("invalid_address_text")
        case .http(let code):
            if code == 401 { return L10n.t("webdav_401_error") }
            if code == 405 { return L10n.t("webdav_405_error") }
            return "\(L10n.t("sync_error")) (\(code))"
        case .notConfigured: return L10n.t("not_configured_state")
        case .wrongPassword: return L10n.t("wrong_password_error")
        case .icloudUnavailable: return L10n.t("icloud_account_error")
        case .icloudFolderInaccessible: return L10n.t("icloud_folder_inaccessible_error")
        case .databaseNotFound: return L10n.t("cloud_database_not_found")
        case .localNameConflict: return L10n.t("local_database_exists_error")
        case .notDownloaded: return L10n.t("icloud_download_pending_error")
        case .downloadFailed(let detail): return "\(L10n.t("sync_error")): \(detail)"
        }
    }
}

/// 未决同步冲突的现场:暂存冲突时下载的远端容器(只存密文,解密推迟到
/// 用户裁决时)与双方概览计数,供冲突弹窗展示与裁决使用。
public struct PendingSyncConflict {
    public init(remoteData: Data, localCards: Int, localLabels: Int, remoteCards: Int, remoteLabels: Int) {
        self.remoteData = remoteData
        self.localCards = localCards
        self.localLabels = localLabels
        self.remoteCards = remoteCards
        self.remoteLabels = remoteLabels
    }

    public let remoteData: Data
    public let localCards: Int
    public let localLabels: Int
    public let remoteCards: Int
    public let remoteLabels: Int
}

/// 同步冲突判定:以上次成功同步记录的基线哈希为参照——本地明文 XML 与
/// 远端明文 XML **双方内容都变化**即判定冲突,交由用户决定覆盖方向;
/// 单侧变化或首次同步(尚无基线)沿用条目级合并。
/// 两侧均在明文内容域比较而非密文字节:容器每次落盘都换随机 nonce,
/// 同内容重传密文哈希必变,会把"对端无意义重传"误判成远端有修改。
/// 哈希仅做变更检测,不含任何敏感数据。
public enum SyncConflict {
    public enum Verdict: Equatable {
        case merge      // 非冲突:沿用条目级合并
        case conflict   // 双方都有修改:弹窗让用户选择覆盖方向
    }

    /// 上次成功同步的基线哈希;nil = 首次同步(或从未成功同步过),无从比较。
    public struct Baselines: Equatable {
    public init(localXMLHash: String? = nil, remoteXMLHash: String? = nil) {
        self.localXMLHash = localXMLHash
        self.remoteXMLHash = remoteXMLHash
    }

        public var localXMLHash: String?
        public var remoteXMLHash: String?
    }

    /// - Parameters:
    ///   - localXMLHash: 当前本地明文 XML 的 SHA-256。
    ///   - remoteXMLHash: 当前远端明文 XML 内容的 SHA-256;nil = 云端还没有文件。
    public static func evaluate(localXMLHash: String, remoteXMLHash: String?, baselines: Baselines) -> Verdict {
        guard let remoteXMLHash else { return .merge }
        guard let baseLocal = baselines.localXMLHash, let baseRemote = baselines.remoteXMLHash else { return .merge }
        let localChanged = localXMLHash != baseLocal
        let remoteChanged = remoteXMLHash != baseRemote
        return localChanged && remoteChanged ? .conflict : .merge
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// 云同步驱动的统一接口:sync() 以相同的 test/download/upload 流程驱动各实现;
/// listDatabases 供云端恢复流程枚举远端数据库。
/// v2 信封(<名>.upwkey)经 downloadKey/uploadKey 同步;
/// 默认实现返回 nil/空操作(不支持信封的驱动由调用方跳过信封环节)。
public protocol CloudDriver {
    func testConnection() async throws
    func download() async throws -> Data?
    func upload(_ data: Data) async throws
    func listDatabases() async throws -> [String]
    /// v2 信封(主密码包裹的库密钥)下载/上传
    func downloadKey() async throws -> Data?
    func uploadKey(_ data: Data) async throws
}

public extension CloudDriver {
    func downloadKey() async throws -> Data? { nil }
    func uploadKey(_ data: Data) async throws {}
    /// 上传替换前把远端当前件改名为 `<名>.upw.old` 留档(只保留一代),
    /// 作为上传失败恢复点(见 Cloud/DESIGN.md §4.3)。
    /// 默认无操作:未实现改名语义的驱动退化为直接覆盖。
    func backupRemoteForUpload() async throws {}
    /// 本地库改名后的远端文件改名(.upw/.upwkey/.upw.old 三件套);
    /// 缺失的文件跳过。默认无操作(旧文件残留由下轮同步自愈重建)。
    func renameRemoteFiles(to newName: String) async throws {}
}

/// WebDAV driver: PUT/GET of the encrypted database container, with an
/// item-level merge when both sides changed (XDatabase.mergeWithDatabase).
public final class WebDavDriver {
    public let settings: WebDavSettings
    public let databaseName: String

    public init(settings: WebDavSettings, databaseName: String) {
        self.settings = settings
        self.databaseName = databaseName
    }

    private func request(method: String, url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        let cred = "\(settings.user):\(settings.password)"
        let data = Data(cred.utf8).base64EncodedString()
        req.setValue("Basic \(data)", forHTTPHeaderField: "Authorization")
        return req
    }

    private var remoteURL: URL? {
        settings.baseURL?.appendingPathComponent("\(databaseName).upw")
    }
    private var remoteKeyURL: URL? {
        settings.baseURL?.appendingPathComponent("\(databaseName).upwkey")
    }

    public func testConnection() async throws {
        guard let base = settings.baseURL else { throw SyncError.badUrl }
        // PROPFIND the folder
        var req = request(method: "PROPFIND", url: base)
        req.setValue("0", forHTTPHeaderField: "Depth")
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw SyncError.badUrl }
        guard http.statusCode != 401 else { throw SyncError.http(401) }
        guard (200..<300).contains(http.statusCode) || http.statusCode == 404 else {
            throw SyncError.http(http.statusCode)
        }
        if http.statusCode == 404 {
            // create the folder (MKCOL)
            let mk = request(method: "MKCOL", url: base)
            let (_, r2) = try await URLSession.shared.data(for: mk)
            if let h2 = r2 as? HTTPURLResponse {
                guard (200..<300).contains(h2.statusCode) || h2.statusCode == 405 || h2.statusCode == 301 else {
                    throw SyncError.http(h2.statusCode)
                }
            }
        }
    }

    public func download() async throws -> Data? {
        guard let url = remoteURL else { throw SyncError.badUrl }
        let req = request(method: "GET", url: url)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw SyncError.badUrl }
        if http.statusCode == 404 {
            // 上传失败恢复路径:当前件缺失时尝试备份件(.upw.old)
            guard let backup = settings.baseURL?
                .appendingPathComponent("\(databaseName).upw.old") else { return nil }
            let oldReq = request(method: "GET", url: backup)
            let (oldData, oldResp) = try await URLSession.shared.data(for: oldReq)
            guard let oldHttp = oldResp as? HTTPURLResponse,
                  (200..<300).contains(oldHttp.statusCode) else { return nil }
            Log.info("sync", "webdav: current file missing — recovered from .upw.old (\(oldData.count)B)")
            return oldData
        }
        guard (200..<300).contains(http.statusCode) else { throw SyncError.http(http.statusCode) }
        return data
    }

    /// 上传备份:远端当前件 MOVE 改名为 .upw.old;服务器不支持 MOVE 时
    /// 降级为"下载旧件→上传为 .old"的拷贝语义;当前件不存在则跳过(恢复路径)。
    public func backupRemoteForUpload() async throws {
        guard let base = settings.baseURL else { throw SyncError.badUrl }
        let src = base.appendingPathComponent("\(databaseName).upw")
        let dest = base.appendingPathComponent("\(databaseName).upw.old")
        var req = request(method: "MOVE", url: src)
        req.setValue(dest.absoluteString, forHTTPHeaderField: "Destination")
        req.setValue("T", forHTTPHeaderField: "Overwrite")
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw SyncError.badUrl }
        if http.statusCode == 404 { return }
        guard (200..<300).contains(http.statusCode) else {
            guard http.statusCode == 405 || http.statusCode == 501 else {
                throw SyncError.http(http.statusCode)
            }
            // MOVE 不支持:拷贝语义兜底(读当前件 → 写 .old)
            guard let current = try await download(), DatabaseCipher.isV2Container(current) else { return }
            var put = request(method: "PUT", url: dest)
            put.httpBody = current
            put.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            let (_, putResp) = try await URLSession.shared.data(for: put)
            guard let putHttp = putResp as? HTTPURLResponse,
                  (200..<300).contains(putHttp.statusCode) else {
                throw SyncError.http((putResp as? HTTPURLResponse)?.statusCode ?? 0)
            }
            Log.debug("sync", "webdav backup via copy fallback (MOVE unsupported)")
            return
        }
        Log.debug("sync", "webdav backup: current renamed to .upw.old")
    }

    /// 库改名后的远端三件套改名(.upw/.upwkey/.upw.old);缺失件跳过。
    public func renameRemoteFiles(to newName: String) async throws {
        guard let base = settings.baseURL else { throw SyncError.badUrl }
        for ext in ["upw", "upwkey", "upw.old"] {
            let src = base.appendingPathComponent("\(databaseName).\(ext)")
            let dest = base.appendingPathComponent("\(newName).\(ext)")
            var req = request(method: "MOVE", url: src)
            req.setValue(dest.absoluteString, forHTTPHeaderField: "Destination")
            req.setValue("F", forHTTPHeaderField: "Overwrite")
            let (_, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw SyncError.badUrl }
            if http.statusCode == 404 { continue }
            guard (200..<300).contains(http.statusCode) else {
                Log.warn("sync", "webdav rename .\(ext) failed: HTTP \(http.statusCode) — next sync will rebuild")
                continue
            }
        }
        Log.info("sync", "webdav remote files renamed \"\(databaseName)\" → \"\(newName)\"")
    }

    public func upload(_ data: Data) async throws {
        guard let url = remoteURL else { throw SyncError.badUrl }
        var req = request(method: "PUT", url: url)
        req.httpBody = data
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SyncError.http((resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    public func downloadKey() async throws -> Data? {
        guard let url = remoteKeyURL else { throw SyncError.badUrl }
        let req = request(method: "GET", url: url)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw SyncError.badUrl }
        if http.statusCode == 404 { return nil }
        guard (200..<300).contains(http.statusCode) else { throw SyncError.http(http.statusCode) }
        return data
    }

    public func uploadKey(_ data: Data) async throws {
        guard let url = remoteKeyURL else { throw SyncError.badUrl }
        var req = request(method: "PUT", url: url)
        req.httpBody = data
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SyncError.http((resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
        Log.debug("sync", "webdav wrote envelope \(data.count)B for \"\(databaseName)\"")
    }

    public func listDatabases() async throws -> [String] {
        guard let base = settings.baseURL else { throw SyncError.badUrl }
        var req = request(method: "PROPFIND", url: base)
        req.setValue("1", forHTTPHeaderField: "Depth")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw SyncError.badUrl }
        if http.statusCode == 404 { return [] }   // 目录尚未创建:云端还没有任何数据库
        guard (200..<300).contains(http.statusCode) else { throw SyncError.http(http.statusCode) }
        return Self.databaseNames(propfindBody: String(data: data, encoding: .utf8) ?? "")
    }

    /// 从 PROPFIND multistatus XML 提取 `.upw` 数据库文件名(去后缀、去重、排序)。
    /// href 可能是完整 URL 或相对路径、元素前缀(D:/d:)因服务器而异,统一宽松解析。
    public static func databaseNames(propfindBody: String) -> [String] {
        var names = Set<String>()
        let regex = try? NSRegularExpression(pattern: "<[^<>]*href[^<>]*>([^<>]+)</", options: [.caseInsensitive])
        let full = NSRange(propfindBody.startIndex..., in: propfindBody)
        for match in regex?.matches(in: propfindBody, options: [], range: full) ?? [] {
            guard let r = Range(match.range(at: 1), in: propfindBody) else { continue }
            let raw = String(propfindBody[r])
            let decoded = raw.removingPercentEncoding ?? raw
            guard let last = decoded.split(separator: "/").last else { continue }
            let name = String(last)
            if name.hasSuffix(".upw") {
                names.insert(String(name.dropLast(4)))
            }
        }
        return names.sorted()
    }
}

// 方法签名与 CloudDriver 一致,直接声明遵循。
extension WebDavDriver: CloudDriver {}

/// iCloud Drive driver: the encrypted container lives in the user's iCloud
/// Drive (`UPasswords/` folder); the system CloudDocs daemon transfers it to
/// every Mac signed into the same Apple ID, so no iCloud entitlement or
/// special signing is needed — **for non-sandboxed builds**. Sandboxed builds
/// cannot see the real CloudDocs root (no ubiquity entitlement) and must go
/// through the user-picked folder (`iCloudFolder:` init, security-scoped
/// bookmark). All file access goes through NSFileCoordinator to avoid racing
/// the daemon's downloads/uploads.
public final class ICloudDriver: CloudDriver {
    public let databaseName: String
    /// iCloud 云盘根目录(CloudDocs);单元测试可注入临时目录替代。
    public let cloudRoot: URL
    /// 注入测试根目录/显式目录时跳过账号可用性检查。
    private let skipAccountCheck: Bool
    /// 显式容器目录:直接作为同步容器,不再叠加 "UPasswords" 子目录。iOS 沙盒
    /// 访问不到 CloudDocs 根,只能经安全作用域书签解析出云盘里的 UPasswords
    /// 文件夹(与 macOS 版同一个目录)注入,访问权限由调用方 start/stop 管理。
    private let explicitFolder: URL?

    /// - Parameter cloudRoot: 覆盖 iCloud Drive 根目录,仅供单元测试使用。
    public init(databaseName: String, cloudRoot: URL? = nil) {
        self.databaseName = databaseName
        // NSHomeDirectory() 跨 macOS/iOS 可用(homeDirectoryForCurrentUser 仅 macOS)
        self.cloudRoot = cloudRoot ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        skipAccountCheck = cloudRoot != nil
        explicitFolder = nil
    }

    /// - Parameter iCloudFolder: 直接指定的云端容器目录(已含安全作用域访问权,
    ///   通常为云盘里的 UPasswords 文件夹)。
    public init(databaseName: String, iCloudFolder: URL) {
        self.databaseName = databaseName
        self.cloudRoot = iCloudFolder
        skipAccountCheck = true
        explicitFolder = iCloudFolder
    }

    /// 容器目录(与 WebDAV 默认远端路径同名)。
    private var folderURL: URL {
        explicitFolder ?? cloudRoot.appendingPathComponent("UPasswords", isDirectory: true)
    }

    /// 远端容器文件:`<数据库名>.upw`。
    private var remoteURL: URL {
        folderURL.appendingPathComponent("\(databaseName).upw")
    }

    public func testConnection() async throws {
        if !skipAccountCheck {
            guard FileManager.default.ubiquityIdentityToken != nil else {
                Log.warn("sync", "icloud unavailable: no iCloud account or iCloud Drive off")
                throw SyncError.icloudUnavailable
            }
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cloudRoot.path, isDirectory: &isDir), isDir.boolValue else {
            let sandboxed = Self.isSandboxedProcess
            Log.warn("sync", "icloud unavailable: CloudDocs root missing at \(cloudRoot.path) (sandboxed=\(sandboxed))")
            throw Self.missingCloudDocsRootError(sandboxed: sandboxed)
        }
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        Log.debug("sync", "icloud folder ready: \(folderURL.path)")
    }

    /// 进程是否沙盒化:沙盒容器的 home 下没有 CloudDocs(除非带 ubiquity
    /// entitlement,本应用不带),直读路径必然失败,须走文件夹选择授权。
    static let isSandboxedProcess: Bool =
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil

    /// CloudDocs 根缺失时的错误映射:沙盒 → 引导选文件夹授权;
    /// 非沙盒缺目录多为 iCloud Drive 未开启 → 沿用「登录/开启」提示。
    /// internal 供 PersistenceTests 验证映射。
    static func missingCloudDocsRootError(sandboxed: Bool) -> SyncError {
        sandboxed ? .icloudFolderInaccessible : .icloudUnavailable
    }

    public func download() async throws -> Data? {
        if let data = try await readContainer(remoteURL) { return data }
        // 上传失败恢复路径:当前件缺失时尝试备份件(.upw.old)
        guard let backup = try await readContainer(remoteBackupURL) else { return nil }
        Log.info("sync", "icloud: current file missing — recovered from .upw.old (\(backup.count)B)")
        return backup
    }

    /// 远端备份件:`<数据库名>.upw.old`(上代留档,只保留一代)。
    private var remoteBackupURL: URL {
        folderURL.appendingPathComponent("\(databaseName).upw.old")
    }

    /// 读取并校验一个 v2 容器文件(处理占位符物化);文件与占位符都不存在返回 nil。
    private func readContainer(_ url: URL) async throws -> Data? {
        guard let data = try await readRemoteFile(url) else { return nil }
        // 防御:读到的不是 v2 容器(占位符残体/下载半截),
        // 按未就绪处理而非交给上层误判为「解不开」
        guard DatabaseCipher.isV2Container(data) else {
            Log.warn("sync", "icloud read \"\(url.lastPathComponent)\" got \(data.count)B without UPWDB magic — treating as not-ready")
            throw SyncError.notDownloaded
        }
        Log.debug("sync", "icloud read \(data.count)B from \"\(url.lastPathComponent)\"")
        return data
    }

    /// 读取 iCloud 上的一个文件:dataless 占位符先触发下载并等待物化;
    /// 文件与占位符都不存在返回 nil(远端确无此文件)。
    private func readRemoteFile(_ url: URL) async throws -> Data? {
        let fm = FileManager.default
        var placeholder: URL? = nil
        if !fm.fileExists(atPath: url.path) {
            let candidate = folderURL.appendingPathComponent(".\(url.lastPathComponent).icloud")
            guard fm.fileExists(atPath: candidate.path) else { return nil }
            placeholder = candidate
            Log.info("sync", "icloud \"\(url.lastPathComponent)\" is dataless — requesting download")
            try? fm.startDownloadingUbiquitousItem(at: candidate)
        }
        try await ensureMaterialized(url, placeholder: placeholder)
        return try coordinatedRead(url)
    }

    /// 上传备份:iCloud 无原子改名保障(占位符/未物化),用拷贝语义:
    /// 读当前件 → 写 .old(与下一句 upload 新内容构成两步替换)。
    public func backupRemoteForUpload() async throws {
        guard let current = try await readContainer(remoteURL) else { return }
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try coordinatedWrite(current, to: remoteBackupURL)
        Log.debug("sync", "icloud backup: current copied to .upw.old (\(current.count)B)")
    }

    /// 库改名后的远端三件套改名;仅移动已物化的实体文件
    /// (占位符不动,残留旧名文件由下轮同步自愈重建)。
    public func renameRemoteFiles(to newName: String) async throws {
        let fm = FileManager.default
        try? fm.createDirectory(at: folderURL, withIntermediateDirectories: true)
        for ext in ["upw", "upwkey", "upw.old"] {
            let src = folderURL.appendingPathComponent("\(databaseName).\(ext)")
            let dest = folderURL.appendingPathComponent("\(newName).\(ext)")
            guard fm.fileExists(atPath: src.path) else { continue }
            if fm.fileExists(atPath: dest.path) {
                try? fm.removeItem(at: dest)
            }
            do {
                try coordinatedMove(from: src, to: dest)
            } catch {
                Log.warn("sync", "icloud rename .\(ext) failed: \(error) — next sync will rebuild")
            }
        }
        Log.info("sync", "icloud remote files renamed \"\(databaseName)\" → \"\(newName)\"")
    }

    /// 经文件协调的移动(与 CloudDocs 守护进程互不竞争)。
    private func coordinatedMove(from src: URL, to dest: URL) throws {
        var coordError: NSError?
        var moveError: Error?
        NSFileCoordinator().coordinate(readingItemAt: src, writingItemAt: dest,
                                       error: &coordError) { readURL, writeURL in
            do {
                try FileManager.default.moveItem(at: readURL, to: writeURL)
            } catch {
                moveError = error
            }
        }
        if let moveError { throw moveError }
        if let coordError { throw coordError }
    }

    /// 等待 iCloud 文件物化完成(占位符 → 实体)。轮询 ubiquitous 下载状态,
    /// 超时抛错让上层走失败路径(而不是读到占位符残体误判密码)。
    /// 等待 iCloud 文件物化完成(占位符 → 实体)。关键点:dataless 项的**真实路径
    /// 在下载完成前并不存在**,资源值查询必须落在占位符 URL 上;物化完成的标志
    /// 是真实路径出现。本地路径(测试的假云端)与已下载文件直接放行——
    /// 陈旧性由上层复检护栏负责。
    private func ensureMaterialized(_ url: URL, placeholder: URL?, timeout: TimeInterval = 120) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        var logged = false
        var ticks = 0
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) { return }
            guard let placeholder, url.path.contains("/Mobile Documents/") else { return }
            ticks += 1
            if let values = try? placeholder.resourceValues(forKeys: [.ubiquitousItemDownloadingErrorKey]),
               let err = values.ubiquitousItemDownloadingError {
                throw SyncError.downloadFailed(err.localizedDescription)
            }
            if !logged {
                Log.info("sync", "icloud waiting for \"\(url.lastPathComponent)\" to materialize…")
                logged = true
            }
            // 长等待时每 10s 补一次下载触发(首拉慢网/请求丢失的兜底)
            if ticks % 20 == 0 {
                try? FileManager.default.startDownloadingUbiquitousItem(at: placeholder)
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw SyncError.notDownloaded
    }

    public func upload(_ data: Data) async throws {
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try coordinatedWrite(data, to: remoteURL)
        Log.debug("sync", "icloud wrote \(data.count)B to \"\(remoteURL.lastPathComponent)\"")
    }

    private var remoteKeyURL: URL {
        folderURL.appendingPathComponent("\(databaseName).upwkey")
    }

    public func downloadKey() async throws -> Data? {
        // 与本体同等待遇:信封是 dataless 占位符时先触发物化并等待,
        // 否则新装设备上永远拿到 nil(误判为「远端无信封」)
        guard let data = try await readRemoteFile(remoteKeyURL) else { return nil }
        // 防御:读到的不是 UPWKEY 信封(占位符残体/下载半截),按未就绪处理
        guard DatabaseCipher.envelopeChangedAt(data) != nil else {
            Log.warn("sync", "icloud read envelope \"\(remoteKeyURL.lastPathComponent)\" got \(data.count)B without UPWKEY magic — treating as not-ready")
            throw SyncError.notDownloaded
        }
        Log.debug("sync", "icloud read envelope \(data.count)B from \"\(remoteKeyURL.lastPathComponent)\"")
        return data
    }

    public func uploadKey(_ data: Data) async throws {
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try coordinatedWrite(data, to: remoteKeyURL)
        Log.debug("sync", "icloud wrote envelope \(data.count)B for \"\(databaseName)\"")
    }

    public func listDatabases() async throws -> [String] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: folderURL.path) else { return [] }
        let files = try fm.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil)
        // 未下载到本地的云端文件以 `.名.upw.icloud` 占位(前导点、内容未物化):
        // 触发按需下载,否则读取/同步拿不到实体文件
        for placeholder in files where placeholder.lastPathComponent.hasSuffix(".icloud") {
            try? fm.startDownloadingUbiquitousItem(at: placeholder)
            Log.debug("sync", "icloud placeholder -> start download \"\(placeholder.lastPathComponent)\"")
        }
        let names = files
            .map { $0.lastPathComponent }
            // `.upw.icloud` 是未下载完的占位文件(CloudDocs dataless),同样计入
            .filter { $0.hasSuffix(".upw") || $0.hasSuffix(".upw.icloud") }
            .map { $0.hasSuffix(".icloud") ? String($0.dropLast(7)) : $0 }
            .map { String($0.dropLast(4)) }
            // 占位文件名带前导点,剥掉才是真实库名
            .map { $0.hasPrefix(".") ? String($0.dropFirst()) : $0 }
        // iCloud 冲突副本「名 N.upw」(双端近乎同时写入时系统保留双方):
        // 同名主文件存在时过滤,不作为可恢复库列出(同步也只写主文件名)
        let baseNames = Set(names)
        return names
            .filter { name in
                guard let range = name.range(of: #" \d+$"#, options: .regularExpression) else { return true }
                let base = String(name[..<range.lowerBound])
                guard baseNames.contains(base) else { return true }
                Log.warn("sync", "icloud conflict copy filtered from listing: \"\(name).upw\"")
                return false
            }
            .sorted()
    }

    /// 经文件协调读取:数据未同步到本机时由系统按需物化,并避免与守护进程竞争。
    private func coordinatedRead(_ url: URL) throws -> Data {
        var coordError: NSError?
        var loadResult: Result<Data, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, error: &coordError) { readURL in
            loadResult = Result { try Data(contentsOf: readURL) }
        }
        if let coordError { throw coordError }
        guard let loadResult else {
            // 逻辑保证:无协调错误时协调器必调用回调,此分支仅为编译完备
            throw SyncError.icloudUnavailable
        }
        return try loadResult.get()
    }

    /// 经文件协调原子写入,CloudDocs 以写入完成后的内容为上传版本。
    private func coordinatedWrite(_ data: Data, to url: URL) throws {
        var coordError: NSError?
        var saveError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordError) { writeURL in
            do {
                try data.write(to: writeURL, options: .atomic)
            } catch {
                saveError = error
            }
        }
        if let saveError { throw saveError }
        if let coordError { throw coordError }
    }
}
