import Foundation

/// iOS / macOS 两个 App target 共用的产品信息。
/// 品牌名等可见文案仍走 `L10n`（UPasswordsCore），此处只放非文案常量。
enum SharedAppInfo {
    /// 统一的产品标识（bundle 显示名、日志前缀）。
    static let displayName = "UPasswords"
    /// 加密数据库容器扩展名。
    static let databaseFileExtension = "upw"
    /// App Group（iOS 扩展与主 App 共享数据的候选容器）。
    static let appGroupID = "group.com.upasswords.shared"
}
