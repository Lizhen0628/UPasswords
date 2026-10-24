import Foundation
import UPasswordsCore

/// A pluggable family of password-manager importers. Each format converts raw
/// text into `[Card]`.
public protocol ImportFormat {
    /// 导入源的稳定机器标识，不随显示语言变化。
    var id: String { get }
    /// 导入源在格式选择列表中的展示名称。
    var title: String { get }
    /// 文件选择器建议的扩展名；识别内容仍以实际解析为准。
    var fileExtension: String { get }
    /// 快速探测文本是否可能符合此格式，不保证完整解析一定成功。
    ///
    /// - Parameter text: 待探测的导入明文。
    /// - Returns: 是否存在该格式的特征。
    func canParse(_ text: String) -> Bool
    /// 将文本中的有效记录追加或合并到调用方数据库。
    ///
    /// - Parameters:
    ///   - text: 导入明文，不能写入日志。
    ///   - db: 接收数据的工作副本；调用方负责持久化和失败回滚。
    ///   - now: 新记录使用的统一时间。
    /// - Returns: 导入器报告的记录数，具体合并规则见实现。
    /// - Throws: 格式无法识别、结构损坏或底层解析失败。
    func parse(_ text: String, into db: inout PasswordDatabase, now: Date) throws -> Int
}

/// 导入失败错误域(全部导入器共用),文案走字符串表 wrong_database_format_error。
public enum ImportError: LocalizedError {
    case cannotParse
    /// 共用的本地化导入格式错误消息。
    public var errorDescription: String? { L10n.t("wrong_database_format_error") }
}
