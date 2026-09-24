import Foundation

/// Sheets catalog — one case per sheet; associated values
/// carry targets (label id, card id, field draft…).
/// 视图映射见 Views/Sheets/SheetFactory.swift。
enum AppSheet: Identifiable, Hashable {
    case addCard            // 添加项目
    case addNote            // 添加笔记
    case addLabel
    case editCardLabel(id: Int) // rename_label_title
    case selectColorCardLabel(id: Int) // 标签颜色选择
    case addTemplate        // save_as_template (存为模板)
    case sorting
    case generator
    case labels(cardId: Int)
    case addField
    case editField
    case selectSymbol
    case selectColor        // 卡片颜色选择
    case selectTexture
    case selectTemplate     // template picker inside edit-card
    case history            // 最近历史
    case passwordHistory    // password_history_command
    case exportAs
    case importData
    case databaseInfo
    case compromised
    case changePassword
    case configureCloud
    case eraseData          // 擦除数据 confirm
    case manageDatabases
    case selectDatabase
    case preferences        // 设置 window
    case about
    case whatsNew
    case premium
    case setupPlan
    case enterPassword      // 解锁
    case expiredCards       // expiring_cards_warning prompt
    case restoreTemplates   // restore_templates_query

    var id: String {
        switch self {
        case .addCard: return "addCard"
        case .addNote: return "addNote"
        case .addLabel: return "addLabel"
        case .editCardLabel(let id): return "editLabel:\(id)"
        case .selectColorCardLabel(let id): return "selectColorLabel:\(id)"
        case .addTemplate: return "addTemplate"
        case .sorting: return "sorting"
        case .generator: return "generator"
        case .labels(let id): return "labels:\(id)"
        case .addField: return "addField"
        case .editField: return "editField"
        case .selectSymbol: return "selectSymbol"
        case .selectColor: return "selectColor"
        case .selectTexture: return "selectTexture"
        case .selectTemplate: return "selectTemplate"
        case .history: return "history"
        case .passwordHistory: return "passwordHistory"
        case .exportAs: return "exportAs"
        case .importData: return "importData"
        case .databaseInfo: return "databaseInfo"
        case .compromised: return "compromised"
        case .changePassword: return "changePassword"
        case .configureCloud: return "configureCloud"
        case .eraseData: return "eraseData"
        case .manageDatabases: return "manageDatabases"
        case .selectDatabase: return "selectDatabase"
        case .preferences: return "preferences"
        case .about: return "about"
        case .whatsNew: return "whatsNew"
        case .premium: return "premium"
        case .setupPlan: return "setupPlan"
        case .enterPassword: return "enterPassword"
        case .expiredCards: return "expiredCards"
        case .restoreTemplates: return "restoreTemplates"
        }
    }

    /// 由编辑表单内打开、编辑表单关闭时应当一并关闭的弹层
    /// (否则会残留成孤儿弹层,其 OK 还可能错写下一个打开的编辑草稿)
    var isEditSheetContext: Bool {
        switch self {
        case .selectColor, .selectSymbol, .selectTemplate:
            return true
        default:
            return false
        }
    }
}
