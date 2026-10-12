import Foundation

/// 主密码策略(双端共用):UI 入口校验与模型侧校验同源,防「UI 放行、模型拒绝」漂移。
public enum PasswordPolicy {
    /// 主密码最短长度
    public static let minimumMasterPasswordLength = 4
}
