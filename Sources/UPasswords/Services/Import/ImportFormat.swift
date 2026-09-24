import Foundation

/// A pluggable family of password-manager importers. Each format converts raw
/// text into `[Card]`.
protocol ImportFormat {
    var id: String { get }
    var title: String { get }
    var fileExtension: String { get }
    func canParse(_ text: String) -> Bool
    func parse(_ text: String, into db: inout PasswordDatabase, now: Date) throws -> Int
}

/// 导入失败错误域(全部导入器共用),文案走字符串表 wrong_database_format_error。
enum ImportError: LocalizedError {
    case cannotParse
    var errorDescription: String? { L10n.t("wrong_database_format_error") }
}
