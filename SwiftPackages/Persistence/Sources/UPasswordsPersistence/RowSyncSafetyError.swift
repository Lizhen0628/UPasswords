import Foundation
import UPasswordsCore

/// 同步尚无法安全收敛时的保护性失败；调用方保留原库和配套同步状态。
public enum RowSyncSafetyError: LocalizedError, Equatable {
    case invalidResponse
    case unreadableItem
    case unsupportedItemFormat
    case quarantineUnavailable
    case conflictNeedsResolution
    case remoteDeletionNeedsRecovery
    case localDataNeedsRecovery
    case incompleteSnapshot
    case baselineUnavailable
    case attachmentContentUnavailable
    case attachmentReferencesUnavailable
    case attachmentKeyMigrationUnavailable

    /// 面向用户的保护原因，不包含条目内容、主密码或密钥。
    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return L10n.t("sync_invalid_response", fallback: "同步响应不完整，已保留本机数据。")
        case .unreadableItem:
            return L10n.t("sync_unreadable_item", fallback: "无法读取云端条目，已保留本机数据。")
        case .unsupportedItemFormat:
            return L10n.t("sync_unsupported_item_format", fallback: "云端条目格式暂不兼容，原始记录已隔离保留。")
        case .quarantineUnavailable:
            return L10n.t("sync_quarantine_unavailable", fallback: "无法安全保存异常云端记录，已暂停同步并保留本机数据。")
        case .conflictNeedsResolution:
            return L10n.t("sync_conflict_protected", fallback: "检测到并发修改，已保留双方内容并暂停同步。")
        case .remoteDeletionNeedsRecovery:
            return L10n.t("sync_deleted_edit_protected", fallback: "云端已删除的条目仍有本机修改，已保留本机数据。")
        case .localDataNeedsRecovery:
            return L10n.t("sync_rebuild_protected", fallback: "本机数据需要先保护和处理，暂未替换为云端快照。")
        case .incompleteSnapshot:
            return L10n.t("sync_incomplete_snapshot", fallback: "未取得完整云端快照，已保留本机数据。")
        case .baselineUnavailable:
            return L10n.t("sync_baseline_unavailable", fallback: "同步基线无法验证，已保留本机数据并暂停同步。")
        case .attachmentContentUnavailable:
            return L10n.t(
                "sync_attachment_content_unavailable",
                fallback: "附件内容尚未在本机就绪，已暂停此条目同步并保留本机数据。")
        case .attachmentReferencesUnavailable:
            return L10n.t(
                "sync_attachment_references_unavailable",
                fallback: "无法确认卡片的完整附件清单，已暂停同步并保留本机数据。")
        case .attachmentKeyMigrationUnavailable:
            return L10n.t(
                "sync_attachment_key_migration_unavailable",
                fallback: "旧版附件密钥格式无法安全迁移，密码未完成云端轮换，数据已保留。")
        }
    }
}
