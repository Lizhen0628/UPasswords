import Foundation

import UPasswordsCore
import UPasswordsPersistence

/// 把当前库的加密容器字节推进 App Group,供 Safari 扩展原生桥只读解密。
/// 推送的始终是密文(.upw 容器),隐私红线不破;未配置 App Group
/// entitlement 的本地构建静默跳过(扩展回退直读活库文件,见 handler)。
enum SafariSnapshotBridge {
    private static let appGroup = "group.com.upasswords.shared"

    /// 推送当前库快照 + current 活跃标记。失败只记日志,不打扰主流程。
    /// - Parameters:
    ///   - name: 当前库名
    ///   - store: 库文件存储(源文件本身即加密容器)
    static func push(databaseName name: String, store: DatabaseStore) {
        guard let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else {
            Log.debug("chrome", "safari snapshot skipped: app group unavailable")
            return
        }
        let dir = group.appendingPathComponent("Safari", isDirectory: true)
        let source = store.url(for: name)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try Data(contentsOf: source)
            try data.write(to: dir.appendingPathComponent("\(name).upw"), options: .atomic)
            // v2 库须连同信封一起推,扩展侧才能用主密码解出库密钥
            if let envelope = store.envelopeData(for: name) {
                try envelope.write(to: dir.appendingPathComponent("\(name).upwkey"), options: .atomic)
            }
            try Data(name.utf8).write(to: dir.appendingPathComponent("current"), options: .atomic)
            Log.debug("chrome", "safari snapshot pushed: \(name) (\(data.count)B)")
        } catch {
            Log.warn("chrome", "safari snapshot push failed for \(name): \(error)")
        }
    }
}
