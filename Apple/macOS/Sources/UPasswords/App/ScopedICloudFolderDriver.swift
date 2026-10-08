import Foundation
import AppKit

import UPasswordsCore
import UPasswordsPersistence

/// 沙盒下访问用户选定的 iCloud 云盘文件夹:解析安全作用域书签并持有访问权,
/// deinit 释放。内部转发 ICloudDriver 的全部操作,调用方无感。
/// 书签由设置页「选择文件夹」写入 AppSettings(NSOpenPanel 授权)。
final class ScopedICloudFolderDriver: CloudDriver {
    private let base: ICloudDriver
    private let folder: URL

    /// - Parameters:
    ///   - bookmark: AppSettings 里的安全作用域书签(主 actor 读取后注入)
    ///   - mode: explicit = 文件夹本身是容器;root = 容器取其下 UPasswords/
    ///   - onRefreshBookmark: 书签过期续期后的回写(主 actor)
    @MainActor
    init?(databaseName: String, bookmark: Data?, mode: String,
          onRefreshBookmark: @MainActor (Data) -> Void) {
        guard let bookmark else { return nil }
        var stale = false
        guard let folder = try? URL(resolvingBookmarkData: bookmark,
                                    options: [.withSecurityScope],
                                    relativeTo: nil,
                                    bookmarkDataIsStale: &stale),
              folder.startAccessingSecurityScopedResource() else {
            Log.warn("sync", "macOS icloud bookmark resolve/access failed — re-pick folder in preferences")
            return nil
        }
        if stale, let refreshed = try? folder.bookmarkData(options: [.withSecurityScope],
                                                           includingResourceValuesForKeys: nil,
                                                           relativeTo: nil) {
            // 书签过期(系统刷新路径):尽力续期,失败不影响本次同步
            onRefreshBookmark(refreshed)
            Log.debug("sync", "macOS icloud bookmark refreshed")
        }
        self.folder = folder
        if mode == "root" {
            base = ICloudDriver(databaseName: databaseName, cloudRoot: folder)
        } else {
            base = ICloudDriver(databaseName: databaseName, iCloudFolder: folder)
        }
    }

    deinit { folder.stopAccessingSecurityScopedResource() }

    func testConnection() async throws { try await base.testConnection() }
    func download() async throws -> Data? { try await base.download() }
    func upload(_ data: Data) async throws { try await base.upload(data) }
    func listDatabases() async throws -> [String] { try await base.listDatabases() }
}

extension AppContext {
    /// 设置页「选择 iCloud 文件夹」:NSOpenPanel 授权后存安全作用域书签。
    /// 选中目录里已有 .upw(或目录名就是 UPasswords)视为同步容器本体,
    /// 否则视为云盘根(容器取其下 UPasswords/,首次同步自动创建)。
    func pickICloudFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.t("ios_icloud_pick_folder_button")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        guard let bookmark = try? url.bookmarkData(options: [.withSecurityScope],
                                                   includingResourceValuesForKeys: nil,
                                                   relativeTo: nil) else {
            Log.warn("sync", "macOS icloud bookmark create failed for \"\(url.lastPathComponent)\"")
            AppToast.shared.show(L10n.t("ios_icloud_folder_error"))
            return
        }
        settings.icloudBookmark = bookmark
        settings.icloudFolderName = url.lastPathComponent
        // 默认按容器本体处理;异步探测后可能修正为 root 模式
        settings.icloudFolderMode = "explicit"
        Log.info("sync", "macOS icloud folder picked: \"\(url.lastPathComponent)\"")
        Task { await refineICloudFolderMode(url) }
    }

    /// 异步探测所选目录内容:目录名是 UPasswords 或已有 .upw → 容器本体;
    /// 否则视为云盘根(容器取其下 UPasswords/,首次同步自动创建)。
    private func refineICloudFolderMode(_ url: URL) async {
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        let probe = ICloudDriver(databaseName: databaseName, iCloudFolder: url)
        let names = (try? await probe.listDatabases()) ?? []
        let isContainer = url.lastPathComponent == "UPasswords" || !names.isEmpty
        settings.icloudFolderMode = isContainer ? "explicit" : "root"
        Log.info("sync", "macOS icloud folder mode=\(isContainer ? "explicit" : "root"), cloud dbs=\(names.count)")
    }
}
