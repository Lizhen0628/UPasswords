import SwiftUI

import UPasswordsCore
import UPasswordsPersistence

/// Reviews and imports complete cards from another local database.
struct ImportCardsSheet: View {
    @EnvironmentObject private var vault: Vault
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

    private var actionTitle: String {
        source == nil
            ? L10n.t("database_card_import_inspect")
            : L10n.t("database_card_import_action")
    }

    private var actionDisabled: Bool {
        source == nil ? sourcePassword.isEmpty : selectedCardIDs.isEmpty
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(String(format: L10n.t("database_card_import_source_fmt"), sourceName))
                    Text(String(format: L10n.t("database_card_import_destination_fmt"), destinationName))
                        .foregroundStyle(.secondary)
                    Text(L10n.t("database_card_import_notice"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if source == nil {
                    Section {
                        SecureField(L10n.t("database_card_import_source_password"), text: $sourcePassword)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                } else {
                    Section {
                        HStack {
                            Text(String(format: L10n.t("database_card_import_selected_fmt"), selectedCardIDs.count))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button(L10n.t("database_card_import_select_ready")) {
                                selectedCardIDs = eligibleCardIDs
                            }
                            .disabled(eligibleCardIDs.isEmpty)
                        }
                        Button(L10n.t("database_card_import_clear_selection")) {
                            selectedCardIDs.removeAll()
                        }
                        .disabled(selectedCardIDs.isEmpty)
                    }

                    Section {
                        Button(L10n.t("database_card_import_review_again")) { clearSource() }
                        if assessments.isEmpty {
                            Text(L10n.t("database_card_import_no_cards"))
                                .foregroundStyle(.secondary)
                        }
                        ForEach(assessments) { assessment in
                            Toggle(isOn: selectionBinding(for: assessment)) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(assessment.card.title.isEmpty
                                         ? L10n.t("untitled_card_text")
                                         : assessment.card.title)
                                    if !assessment.rejections.isEmpty {
                                        Text(rejectionText(assessment.rejections))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                            .disabled(!assessment.isEligible)
                        }
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .navigationTitle(L10n.t("database_card_import_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("cancel_button")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(actionTitle, action: source == nil ? inspectSource : importSelection)
                        .disabled(actionDisabled)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onChange(of: vault.syncSessionID) { _, _ in
            clearSource()
            dismiss()
        }
        .onDisappear { clearSource() }
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
            let snapshot = try vault.store.loadCardImportSource(name: sourceName, password: sourcePassword)
            assessments = try CrossDatabaseCardImporter.assess(
                source: snapshot,
                syncState: vault.rowSync)
            source = snapshot
            selectedCardIDs.removeAll()
            Log.info("db", "ios card import review opened source=\"\(sourceName)\" candidates=\(assessments.count)")
        } catch {
            errorMessage = error.localizedDescription
            Log.error("db", "ios card import source verification failed source=\"\(sourceName)\": \(error)")
        }
    }

    @MainActor private func importSelection() {
        guard let source else { return }
        errorMessage = nil
        do {
            let plan = try vault.importCards(
                from: sourceName,
                sourcePassword: sourcePassword,
                sourceFingerprint: source.fingerprint,
                into: destinationName,
                selecting: selectedCardIDs)
            vault.showToast(String(format: L10n.t("database_card_import_complete_fmt"),
                                   plan.importedCardIDs.count,
                                   plan.alreadyImportedCount,
                                   plan.createdLabelCount))
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            Log.error("db", "ios card import failed source=\"\(sourceName)\": \(error)")
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
