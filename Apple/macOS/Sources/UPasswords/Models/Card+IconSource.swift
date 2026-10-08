import Foundation
import UPasswordsCore

// MARK: - Icon source helpers (Card.iconSource vocabulary)

extension Card {
    /// iconSource="website" — 从卡片网址抓取的站点图标。
    var iconIsFromWebsite: Bool { iconSource == IconService.sourceWebsite }
    /// iconSource="custom" — 用户上传的图片文件。
    var iconIsCustomUpload: Bool { iconSource == IconService.sourceCustom }
    /// iconSource="url:<…>" — 用户提供的图片 URL 下载所得。
    var iconIsFromUserURL: Bool { iconSource?.hasPrefix(IconService.sourceURLPrefix) ?? false }
    /// iconSource="builtin:<key>" — 内置品牌图标目录的 key（无像素数据）。
    var iconBuiltinKey: String? {
        guard let s = iconSource, s.hasPrefix(IconService.sourceBuiltinPrefix) else { return nil }
        return String(s.dropFirst(IconService.sourceBuiltinPrefix.count))
    }

    /// 用户显式指定的图标（上传/URL）始终显示，不受「使用网站图标」开关约束。
    var iconIsUserExplicit: Bool { iconIsCustomUpload || iconIsFromUserURL }
}

extension Field {
    func modifiedOr(_ fallback: TimeInterval) -> TimeInterval { fallback }
}
