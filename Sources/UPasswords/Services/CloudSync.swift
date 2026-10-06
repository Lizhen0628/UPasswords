import CryptoKit
import Foundation

/// Cloud sync drivers. The WebDAV driver talks PUT/GET to any WebDAV server;
/// the iCloud driver reads/writes the encrypted container in the user's
/// iCloud Drive, where the system CloudDocs daemon performs the transfer.
/// Google Drive / Dropbox / OneDrive require vendor OAuth credentials; those
/// cloud entries remain visible in the UI but report `not_configured_state`.
struct WebDavSettings: Codable, Equatable {
    var host: String = ""
    var port: Int = 443
    var useHTTPS: Bool = true
    var user: String = ""
    var password: String = ""
    var path: String = "/UPasswords/"

    var baseURL: URL? {
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
enum CloudType: String, CaseIterable, Identifiable {
    case none, webdav, gdrive, dropbox, onedrive, icloud
    var id: String { rawValue }

    var name: String {
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
    var functional: Bool { self == .none || self == .webdav || self == .icloud }
}

/// 同步失败错误域(文案走字符串表)。
enum SyncError: LocalizedError {
    case badUrl
    case http(Int)
    case notConfigured
    case wrongPassword
    case icloudUnavailable
    case databaseNotFound
    case localNameConflict

    var errorDescription: String? {
        switch self {
        case .badUrl: return L10n.t("invalid_address_text")
        case .http(let code):
            if code == 401 { return L10n.t("webdav_401_error") }
            if code == 405 { return L10n.t("webdav_405_error") }
            return "\(L10n.t("sync_error")) (\(code))"
        case .notConfigured: return L10n.t("not_configured_state")
        case .wrongPassword: return L10n.t("wrong_password_error")
        case .icloudUnavailable: return L10n.t("icloud_account_error")
        case .databaseNotFound: return L10n.t("cloud_database_not_found")
        case .localNameConflict: return L10n.t("local_database_exists_error")
        }
    }
}

/// 未决同步冲突的现场:暂存冲突时下载的远端容器(只存密文,解密推迟到
/// 用户裁决时)与双方概览计数,供冲突弹窗展示与裁决使用。
struct PendingSyncConflict {
    let remoteData: Data
    let localCards: Int
    let localLabels: Int
    let remoteCards: Int
    let remoteLabels: Int
}

/// 同步冲突判定:以上次成功同步记录的基线哈希为参照——本地明文 XML 与
/// 远端容器字节**双方都变化**即判定冲突,交由用户决定覆盖方向;
/// 单侧变化或首次同步(尚无基线)沿用条目级合并。
/// 哈希仅做变更检测,不含任何敏感数据。
enum SyncConflict {
    enum Verdict: Equatable {
        case merge      // 非冲突:沿用条目级合并
        case conflict   // 双方都有修改:弹窗让用户选择覆盖方向
    }

    /// 上次成功同步的基线哈希;nil = 首次同步(或从未成功同步过),无从比较。
    struct Baselines: Equatable {
        var localXMLHash: String?
        var remoteDataHash: String?
    }

    /// - Parameters:
    ///   - localXMLHash: 当前本地明文 XML 的 SHA-256。
    ///   - remoteDataHash: 当前远端容器字节的 SHA-256;nil = 云端还没有文件。
    static func evaluate(localXMLHash: String, remoteDataHash: String?, baselines: Baselines) -> Verdict {
        guard let remoteDataHash else { return .merge }
        guard let baseLocal = baselines.localXMLHash, let baseRemote = baselines.remoteDataHash else { return .merge }
        let localChanged = localXMLHash != baseLocal
        let remoteChanged = remoteDataHash != baseRemote
        return localChanged && remoteChanged ? .conflict : .merge
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// 云同步驱动的统一接口:sync() 以相同的 test/download/upload 流程驱动各实现;
/// listDatabases 供云端恢复流程枚举远端数据库。
protocol CloudDriver {
    func testConnection() async throws
    func download() async throws -> Data?
    func upload(_ data: Data) async throws
    func listDatabases() async throws -> [String]
}

/// WebDAV driver: PUT/GET of the encrypted database container, with an
/// item-level merge when both sides changed (XDatabase.mergeWithDatabase).
final class WebDavDriver {
    let settings: WebDavSettings
    let databaseName: String

    init(settings: WebDavSettings, databaseName: String) {
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

    func testConnection() async throws {
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

    func download() async throws -> Data? {
        guard let url = remoteURL else { throw SyncError.badUrl }
        let req = request(method: "GET", url: url)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw SyncError.badUrl }
        if http.statusCode == 404 { return nil }
        guard (200..<300).contains(http.statusCode) else { throw SyncError.http(http.statusCode) }
        return data
    }

    func upload(_ data: Data) async throws {
        guard let url = remoteURL else { throw SyncError.badUrl }
        var req = request(method: "PUT", url: url)
        req.httpBody = data
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SyncError.http((resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    func listDatabases() async throws -> [String] {
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
    static func databaseNames(propfindBody: String) -> [String] {
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
/// special signing is needed. All file access goes through NSFileCoordinator
/// to avoid racing the daemon's downloads/uploads.
final class ICloudDriver: CloudDriver {
    let databaseName: String
    /// iCloud 云盘根目录(CloudDocs);单元测试可注入临时目录替代。
    let cloudRoot: URL
    /// 注入测试根目录时没有 iCloud 账号环境,跳过账号可用性检查。
    private let skipAccountCheck: Bool

    /// - Parameter cloudRoot: 覆盖 iCloud Drive 根目录,仅供单元测试使用。
    init(databaseName: String, cloudRoot: URL? = nil) {
        self.databaseName = databaseName
        self.cloudRoot = cloudRoot ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        skipAccountCheck = cloudRoot != nil
    }

    /// 容器目录(与 WebDAV 默认远端路径同名)。
    private var folderURL: URL {
        cloudRoot.appendingPathComponent("UPasswords", isDirectory: true)
    }

    /// 远端容器文件:`<数据库名>.upw`。
    private var remoteURL: URL {
        folderURL.appendingPathComponent("\(databaseName).upw")
    }

    func testConnection() async throws {
        if !skipAccountCheck {
            guard FileManager.default.ubiquityIdentityToken != nil else {
                Log.warn("sync", "icloud unavailable: no iCloud account or iCloud Drive off")
                throw SyncError.icloudUnavailable
            }
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cloudRoot.path, isDirectory: &isDir), isDir.boolValue else {
            Log.warn("sync", "icloud unavailable: CloudDocs root missing at \(cloudRoot.path)")
            throw SyncError.icloudUnavailable
        }
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        Log.debug("sync", "icloud folder ready: \(folderURL.path)")
    }

    func download() async throws -> Data? {
        guard FileManager.default.fileExists(atPath: remoteURL.path) else { return nil }
        let data = try coordinatedRead(remoteURL)
        Log.debug("sync", "icloud read \(data.count)B from \"\(remoteURL.lastPathComponent)\"")
        return data
    }

    func upload(_ data: Data) async throws {
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try coordinatedWrite(data, to: remoteURL)
        Log.debug("sync", "icloud wrote \(data.count)B to \"\(remoteURL.lastPathComponent)\"")
    }

    func listDatabases() async throws -> [String] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: folderURL.path) else { return [] }
        let files = try fm.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil)
        return files
            .map { $0.lastPathComponent }
            // `.upw.icloud` 是未下载完的占位文件(CloudDocs dataless),同样计入
            .filter { $0.hasSuffix(".upw") || $0.hasSuffix(".upw.icloud") }
            .map { $0.hasSuffix(".icloud") ? String($0.dropLast(7)) : $0 }
            .map { String($0.dropLast(4)) }
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
