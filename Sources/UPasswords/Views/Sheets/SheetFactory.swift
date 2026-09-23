import SwiftUI

// MARK: - SheetFactory

enum SheetFactory {
    @ViewBuilder
    static func view(for sheet: AppSheet) -> some View {
        switch sheet {
        case .addCard: AddCardSheet()
        case .addNote: AddNoteSheet()
        case .addLabel: AddLabelSheet()
        case .editCardLabel(let id): EditLabelSheet(labelId: id)
        case .selectColorCardLabel(let id): SelectColorLabelSheet(labelId: id)
        case .sorting: SortingSheet()
        case .generator: GeneratorSheet()
        case .labels(let cardId): SetLabelsSheet(cardId: cardId)
        case .selectSymbol: SelectSymbolSheet()
        case .selectColor: SelectColorSheet()
        case .selectTexture: SelectTextureSheet()
        case .selectTemplate: SelectTemplateSheet()
        case .exportAs: ExportAsSheet()
        case .importData: ImportSheet()
        case .databaseInfo: DatabaseInfoSheet()
        case .compromised: CompromisedSheet()
        case .changePassword: ChangePasswordSheet()
        case .configureCloud: ConfigureCloudSheet()
        case .eraseData: EraseDataSheet()
        case .manageDatabases: ManageDatabasesSheet()
        case .selectDatabase: SelectDatabaseSheet()
        case .about: AboutSheet()
        case .whatsNew: WhatsNewSheet()
        case .premium: PremiumSheet()
        case .setupPlan: SetupPlanSheet()
        case .expiredCards: ExpiredCardsSheet()
        case .restoreTemplates: RestoreTemplatesSheet()
        case .passwordHistory: PasswordHistorySheet()
        case .addField, .editField:
            // handled locally inside EditCardSheet
            EmptyView()
        case .preferences:
            PreferencesSheet()
        case .history, .addTemplate, .enterPassword:
            EmptyView() // history = recent sidebar label
        }
    }
}


/// Wraps the full tabbed PreferencesView for menu/setup-plan presentation
/// when the Settings scene is not reachable directly.
struct PreferencesSheet: View {
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 0) {
            PreferencesView()
            Divider()
            HStack {
                Spacer()
                Button(L10n.t("close_button")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(10)
        }
        .frame(minWidth: 560, minHeight: 430)
        .background(.regularMaterial)
    }
}
