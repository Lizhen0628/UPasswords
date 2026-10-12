import CryptoKit
import Foundation
import UPasswordsCore

/// 同步失败错误域(文案走字符串表)。
public enum SyncError: LocalizedError, Equatable {
    case notConfigured
    case wrongPassword
    case databaseNotFound
    case localNameConflict

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
