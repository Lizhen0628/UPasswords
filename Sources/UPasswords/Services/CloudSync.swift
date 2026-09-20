import Foundation

/// Mirrors `CloudDriver` / `WebDavDriver` / `WebDavSettings` (Services/) and
/// `SyncTask` / `DatabaseSynchronizer`. Only the WebDAV driver is functional in
/// this replica — Google Drive / Dropbox / OneDrive require vendor OAuth apps
/// that cannot be provisioned here; those cloud entries remain visible in the
/// UI (ConfigureCloudSheetController) but report `not_configured_state`.
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

    /// Whether this replica can actually synchronize through this cloud.
    var functional: Bool { self == .none || self == .webdav }
}

enum SyncError: LocalizedError {
    case badUrl
    case http(Int)
    case notConfigured
    case wrongPassword

    var errorDescription: String? {
        switch self {
        case .badUrl: return L10n.t("invalid_address_text")
        case .http(let code):
            if code == 401 { return L10n.t("webdav_401_error") }
            if code == 405 { return L10n.t("webdav_405_error") }
            return "\(L10n.t("sync_error")) (\(code))"
        case .notConfigured: return L10n.t("not_configured_state")
        case .wrongPassword: return L10n.t("wrong_password_error")
        }
    }
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
}
