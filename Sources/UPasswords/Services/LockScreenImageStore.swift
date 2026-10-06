import AppKit

/// 锁屏自定背景图片的存储:所选图片拷贝进
/// `~/Library/Application Support/UPasswords/LockScreen/`,设置里只记文件名。
enum LockScreenImageStore {
    /// 系统应用支持目录,逻辑保证存在(DatabaseStore/Log 同款取法)。
    static var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("UPasswords/LockScreen", isDirectory: true)
    }

    /// 读取已安装的锁屏图片(未设置或文件缺失返回 nil,调用方回退质感渐变)。
    static func image(named name: String) -> NSImage? {
        guard !name.isEmpty else { return nil }
        return NSImage(contentsOfFile: dir.appendingPathComponent(name).path)
    }

    /// 拷贝所选图片进存储目录,固定命名 `background.<原扩展名>`(换图先清理旧文件)。
    /// - Returns: 安装后的文件名(写入 AppSettings.lockBackgroundImageName)。
    static func install(from source: URL) throws -> String {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        removeAll()
        let ext = source.pathExtension.isEmpty ? "jpg" : source.pathExtension
        let name = "background.\(ext)"
        try fm.copyItem(at: source, to: dir.appendingPathComponent(name))
        return name
    }

    /// 删除已安装的锁屏图片(恢复默认时调用)。
    static func removeAll() {
        let fm = FileManager.default
        let existing = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for file in existing where file.lastPathComponent.hasPrefix("background.") {
            try? fm.removeItem(at: file)
        }
    }
}
