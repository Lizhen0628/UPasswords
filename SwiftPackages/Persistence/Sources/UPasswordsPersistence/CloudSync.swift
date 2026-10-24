import CryptoKit
import Foundation
import UPasswordsCore

/// 同步失败错误域(文案走字符串表)。
public enum SyncError: LocalizedError, Equatable {
    case notConfigured
    case wrongPassword
    case databaseNotFound
    case localNameConflict

    /// 供用户展示的本地化同步错误。
    public var errorDescription: String? {
        switch self {
        case .notConfigured: return L10n.t("not_configured_state")
        case .wrongPassword: return L10n.t("wrong_password_error")
        case .databaseNotFound: return L10n.t("cloud_database_not_found")
        case .localNameConflict: return L10n.t("local_database_exists_error")
        }
    }
}

/// 未决同步冲突的现场:暂存冲突时下载的远端容器(只存密文,解密推迟到
/// 用户裁决时)与双方概览计数,供冲突弹窗展示与裁决使用。
public struct PendingSyncConflict {
    /// 创建等待用户裁决的加密冲突快照。
    ///
    /// - Parameters:
    ///   - remoteData: 尚未解密的远端容器。
    ///   - localCards: 本地卡片数。
    ///   - localLabels: 本地标签数。
    ///   - remoteCards: 远端卡片数。
    ///   - remoteLabels: 远端标签数。
    public init(remoteData: Data, localCards: Int, localLabels: Int, remoteCards: Int, remoteLabels: Int) {
        self.remoteData = remoteData
        self.localCards = localCards
        self.localLabels = localLabels
        self.remoteCards = remoteCards
        self.remoteLabels = remoteLabels
    }

    /// 用户裁决前暂存的远端加密容器。
    public let remoteData: Data
    /// 冲突快照中的本地卡片数。
    public let localCards: Int
    /// 冲突快照中的本地标签数。
    public let localLabels: Int
    /// 冲突快照中的远端卡片数。
    public let remoteCards: Int
    /// 冲突快照中的远端标签数。
    public let remoteLabels: Int
}

/// 同步冲突判定:以上次成功同步记录的基线哈希为参照——本地明文 XML 与
/// 远端明文 XML **双方内容都变化**即判定冲突,交由用户决定覆盖方向;
/// 单侧变化或首次同步(尚无基线)沿用条目级合并。
/// 两侧均在明文内容域比较而非密文字节:容器每次落盘都换随机 nonce,
/// 同内容重传密文哈希必变,会把"对端无意义重传"误判成远端有修改。
/// 哈希仅做变更检测,不含任何敏感数据。
public enum SyncConflict {
    /// 根据两侧内容相对基线的变化决定合并或请求人工裁决。
    public enum Verdict: Equatable {
        case merge      // 非冲突:沿用条目级合并
        case conflict   // 双方都有修改:弹窗让用户选择覆盖方向
    }

    /// 上次成功同步的基线哈希;nil = 首次同步(或从未成功同步过),无从比较。
    public struct Baselines: Equatable {
        /// 创建整库内容比较基线；缺失值表示尚无成功同步基线。
        ///
        /// - Parameters:
        ///   - localXMLHash: 上次成功同步的本地 XML 摘要。
        ///   - remoteXMLHash: 上次成功同步的远端 XML 摘要。
    public init(localXMLHash: String? = nil, remoteXMLHash: String? = nil) {
        self.localXMLHash = localXMLHash
        self.remoteXMLHash = remoteXMLHash
    }

        /// 上次成功同步时本地 XML 内容的 SHA-256。
        public var localXMLHash: String?
        /// 上次成功同步时远端 XML 内容的 SHA-256。
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

    /// 计算字节内容的 SHA-256 十六进制摘要。
    ///
    /// - Parameter data: 需要比较的内容；不会写入日志。
    /// - Returns: 固定 64 字符的小写十六进制字符串。
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
