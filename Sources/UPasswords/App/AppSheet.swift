import Foundation

/// Sheets catalog — one case per original *SheetController; associated values
/// carry targets (label id, card id, field draft…).
/// 视图映射见 Views/Sheets/SheetFactory.swift。
enum AppSheet: Identifiable, Hashable {
    case addCard            // SelectTemplateSheetController (添加项目)
    case addNote            // 添加笔记
    case addLabel           // AddLabelSheetController
    case editCardLabel(id: Int) // rename_label_title
    case selectColorCardLabel(id: Int) // SelectColorViewController for labels
    case addTemplate        // save_as_template (存为模板)
    case sorting            // SortingSheetController
    case generator          // PasswordOptionsSheetController
    case labels(cardId: Int) // SetLabelsSheetController
    case addField           // AddFieldSheetController
    case editField          // EditFieldSheetController
    case selectSymbol       // SelectSymbolViewController
    case selectColor        // SelectColorViewController (cards)
    case selectTexture      // SelectTextureSheetController
    case selectTemplate     // template picker inside edit-card
    case history            // HistorySheetController (recent)
    case passwordHistory    // password_history_command
    case exportAs           // ExportAsSheetController
    case importData         // ImportSheetController + ImportSourceViewController
    case databaseInfo       // DatabaseInfoSheetController
    case compromised        // CompromisedPasswordsSheetController
    case changePassword     // SetPasswordSheetController
    case configureCloud     // ConfigureCloudSheetController
    case eraseData          // 擦除数据 confirm
    case manageDatabases    // ManageDatabasesViewController
    case selectDatabase     // SelectDatabaseSheetController
    case preferences        // 设置 window
    case about              // AboutWindowController
    case whatsNew           // WhatsNewSheetController
    case premium            // PremiumSheetController
    case setupPlan          // SetupPlanViewController
    case enterPassword      // EnterPasswordSheetController (unlock)
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
}
