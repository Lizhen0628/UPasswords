import Foundation

import UPasswordsCore
import UPasswordsPersistence

// MARK: - 主 App 与 AutoFill 扩展共享的库容器（App Group）
//
// 加密数据库(.upw)落在 App Group 共享容器,DatabaseStore 以注入 root 的方式
// 指向该容器;钥匙串(PasswordStore)在同 Team 下跨主 App/扩展共享。
// 未配置 App Group entitlement 时回退到本进程 Application Support——
// 此时扩展读不到主 App 的库(界面会引导先开主 App),但不影响各自运行。

enum SharedVaultStore {
    /// 默认库名(首次创建时的初始名;多库管理下可由用户新建/切换)。
    static let defaultDatabaseName = "Main"

    /// 共享 UserDefaults:设置与泄露清单等跨进程读取。
    static let defaults = UserDefaults(suiteName: SharedAppInfo.appGroupID) ?? .standard

    /// 共享容器根目录;不可用时回退到本进程 Application Support。
    static var storeRoot: URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedAppInfo.appGroupID)
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    }

    /// 库存取实例(值语义操作经由 Vault/AutoFillModel 进入,不直接在视图中使用)。
    static let store = DatabaseStore(root: storeRoot)

    /// 当前库指针(共享 defaults):主 App 切库时写入,AutoFill 扩展跟随同一指针。
    /// 不用 DatabaseStore.mainDatabaseName(它走 UserDefaults.standard,扩展进程读不到)。
    static var currentDatabaseName: String? {
        get { defaults.string(forKey: "db.current") }
        set { defaults.set(newValue, forKey: "db.current") }
    }

    /// 当前可用的主库(优先共享指针;指针失效时回退列表第一个)。
    static func mainDatabase() -> DatabaseFile? {
        let list = store.list()
        if let current = currentDatabaseName, list.contains(where: { $0.name == current }) {
            return list.first { $0.name == current }
        }
        return list.first { $0.isMain } ?? list.first
    }
}
