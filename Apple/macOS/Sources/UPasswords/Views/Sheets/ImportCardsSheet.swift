import SwiftUI

import UPasswordsCore
import UPasswordsPersistence

/// Reviews and imports complete cards from another local database.
struct ImportCardsSheet: View {
    @EnvironmentObject private var ctx: AppContext
    @Environment(\.dismiss) private var dismiss

    let sourceName: String
    let destinationName: String

    @State private var sourcePassword = ""
    @State private var source: CrossDatabaseCardImporter.SourceSnapshot?
    @State private var assessments: [CrossDatabaseCardImporter.Assessment] = []
    @State private var selectedCardIDs = Set<UUID>()
    @State private var errorMessage: String?

    private var eligibleCardIDs: Set<UUID> {
        Set(assessments.filter(\.isEligible).map(\.id))
    }

    var body: some View {
        SheetShell(
            title: L10n.t("database_card_import_title"),
            minWidth: 560,
            minHeight: 460,
            okTitle: source == nil
                ? L10n.t("database_card_import_inspect")
                : L10n.t("database_card_import_action"),
            okDisabled: source == nil ? sourcePassword.isEmpty : selectedCardIDs.isEmpty,
            onCancel: { dismiss() },
            onOk: { source == nil ? inspectSource() : importSelection() },
            content: {
                VStack(alignment: .leading, spacing: 12) {
                    Text(String(format: L10n.t("database_card_import_source_fmt"), sourceName))
                        .font(.headline)
                    Text(String(format: L10n.t("database_card_import_destination_fmt"), destinationName))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(L10n.t("database_card_import_notice"))
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    if source == nil {
                        LabeledRow(label: L10n.t("database_card_import_source_password")) {
                            SecureField("", text: $sourcePassword)
                                .textFieldStyle(.roundedBorder)
                        }
                    } else {
                        selectionControls
                        Button(L10n.t("database_card_import_review_again")) { clearSource() }
                        if assessments.isEmpty {
                            Text(L10n.t("database_card_import_no_cards"))
                                .foregroundStyle(.secondary)
                        }
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(assessments) { assessment in
                                    cardRow(assessment)
                                    HairlineDivider(horizontal: true)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(minHeight: 170)
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.callout)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        )
        .onChange(of: ctx.syncSessionID) { _, _ in
            clearSource()
            dismiss()
        }
        .onDisappear { clearSource() }
    }

    private var selectionControls: some View {
        HStack {
            Text(String(format: L10n.t("database_card_import_selected_fmt"), selectedCardIDs.count))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button(L10n.t("database_card_import_select_ready")) {
                selectedCardIDs = eligibleCardIDs
            }
            .disabled(eligibleCardIDs.isEmpty)
            Button(L10n.t("database_card_import_clear_selection")) {
                selectedCardIDs.removeAll()
            }
            .disabled(selectedCardIDs.isEmpty)
        }
    }

    private func cardRow(_ assessment: CrossDatabaseCardImporter.Assessment) -> some View {
        Toggle(isOn: selectionBinding(for: assessment)) {
            VStack(alignment: .leading, spacing: 3) {
                Text(assessment.card.title.isEmpty
                     ? L10n.t("untitled_card_text")
                     : assessment.card.title)
                    .lineLimit(1)
                if !assessment.rejections.isEmpty {
                    Text(rejectionText(assessment.rejections))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 5)
        }
        .toggleStyle(.checkbox)
        .disabled(!assessment.isEligible)
        .padding(.horizontal, 4)
    }

    private func clearSource() {
        sourcePassword = ""
        source = nil
        assessments.removeAll()
        selectedCardIDs.removeAll()
    }

    private func selectionBinding(for assessment: CrossDatabaseCardImporter.Assessment) -> Binding<Bool> {
        Binding(
            get: { selectedCardIDs.contains(assessment.id) },
            set: { isSelected in
                if isSelected {
                    selectedCardIDs.insert(assessment.id)
                } else {
                    selectedCardIDs.remove(assessment.id)
                }
            })
    }

    @MainActor private func inspectSource() {
        errorMessage = nil
        do {
            let snapshot = try ctx.store.loadCardImportSource(name: sourceName, password: sourcePassword)
            assessments = try CrossDatabaseCardImporter.assess(
                source: snapshot,
                syncState: ctx.rowSync)
            source = snapshot
            selectedCardIDs.removeAll()
            Log.info("db", "card import review opened source=\"\(sourceName)\" candidates=\(assessments.count)")
        } catch {
            errorMessage = error.localizedDescription
            Log.error("db", "card import source verification failed source=\"\(sourceName)\": \(error)")
        }
    }

    @MainActor private func importSelection() {
        guard let source else { return }
        errorMessage = nil
        do {
            let plan = try ctx.importCards(
                from: sourceName,
                sourcePassword: sourcePassword,
                sourceFingerprint: source.fingerprint,
                into: destinationName,
                selecting: selectedCardIDs)
            AppToast.shared.show(String(format: L10n.t("database_card_import_complete_fmt"),
                                        plan.importedCardIDs.count,
                                        plan.alreadyImportedCount,
                                        plan.createdLabelCount))
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            Log.error("db", "card import failed source=\"\(sourceName)\": \(error)")
        }
    }

    private func rejectionText(_ reasons: Set<CrossDatabaseCardImporter.Rejection>) -> String {
        let messages = reasons.map { reason -> String in
            switch reason {
            case .alreadyImported: return L10n.t("database_card_import_already_imported")
            case .template: return L10n.t("database_card_import_template")
            case .trashed: return L10n.t("database_card_import_trashed")
            case .missingLabel: return L10n.t("database_card_import_missing_label")
            case .unavailableAttachment: return L10n.t("database_card_import_unavailable_attachment")
            case .attachmentTooLarge: return L10n.t("database_card_import_attachment_too_large")
            }
        }
        return messages.sorted().joined(separator: ", ")
    }
}
