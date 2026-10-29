import SwiftUI

import UPasswordsCore
import UPasswordsPersistence

struct BackupRestoreCopySheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var databaseName: String
    @State private var sourcePassword = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var errorMessage: String?
    @State private var packageAssessment: BackupPackage.Assessment?
    @State private var isAssessingPackage = false
    @State private var allowIncompleteRestore = false

    private let backup: URL
    private let restore: (URL, String, String, String, String?, Bool) -> String?

    init(
        backup: URL,
        suggestedName: String,
        restore: @escaping (URL, String, String, String, String?, Bool) -> String?
    ) {
        self.backup = backup
        self.restore = restore
        _databaseName = State(initialValue: suggestedName)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(L10n.t("backup_restore_copy_hint"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    TextField(L10n.t("backup_restore_copy_name"), text: $databaseName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField(L10n.t("backup_restore_source_password"), text: $sourcePassword)
                        .textContentType(.password)
                }

                Section {
                    SecureField(L10n.t("backup_restore_new_password"), text: $newPassword)
                        .textContentType(.newPassword)
                    SecureField(L10n.t("backup_restore_confirm_password"), text: $confirmPassword)
                        .textContentType(.newPassword)
                }

                if isPackageBackup {
                    Section {
                        Button(action: assessPackage) {
                            if isAssessingPackage {
                                ProgressView()
                                    .frame(maxWidth: .infinity)
                            } else {
                                Text(L10n.t("backup_package_review"))
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .disabled(sourcePassword.isEmpty || isAssessingPackage)

                        if let packageAssessment {
                            Text(assessmentText(packageAssessment))
                                .font(.footnote)
                                .foregroundStyle(
                                    packageAssessment.isComplete ? Color.primary : Color.orange)
                            ForEach(Array(packageAssessment.issues.enumerated()), id: \.offset) { _, issue in
                                Text(issue.summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            if !packageAssessment.isComplete {
                                Toggle(
                                    L10n.t("backup_package_confirm_incomplete"),
                                    isOn: $allowIncompleteRestore)
                            }
                        }
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(L10n.t("backup_restore_copy_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("cancel_button")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("restore_button"), action: restoreCopy)
                        .disabled(!canRestore)
                }
            }
            .onChange(of: sourcePassword) { _, _ in
                packageAssessment = nil
                allowIncompleteRestore = false
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var canRestore: Bool {
        !databaseName.isEmpty
            && !sourcePassword.isEmpty
            && newPassword.count >= PasswordPolicy.minimumMasterPasswordLength
            && newPassword == confirmPassword
            && (!isPackageBackup || (packageAssessment != nil
                && (packageAssessment?.isComplete == true || allowIncompleteRestore)))
    }

    private var isPackageBackup: Bool {
        backup.pathExtension == BackupPackage.fileExtension
    }

    private func assessmentText(_ assessment: BackupPackage.Assessment) -> String {
        let key = assessment.isComplete
            ? "backup_package_assessment_complete_fmt"
            : "backup_package_assessment_incomplete_fmt"
        return String(
            format: L10n.t(key),
            assessment.cardCount,
            assessment.attachmentVersionCount,
            assessment.conflictCount,
            assessment.isComplete ? assessment.conflictCandidateCount : assessment.issues.count)
    }

    private func assessPackage() {
        let backup = backup
        let sourcePassword = sourcePassword
        isAssessingPackage = true
        errorMessage = nil
        Task {
            do {
                let assessment = try await Task.detached(priority: .userInitiated) {
                    try BackupPackage.assess(at: backup, sourcePassword: sourcePassword)
                }.value
                packageAssessment = assessment
                allowIncompleteRestore = false
            } catch {
                packageAssessment = nil
                errorMessage = error.localizedDescription.isEmpty
                    ? L10n.t("backup_package_assessment_failed")
                    : error.localizedDescription
            }
            isAssessingPackage = false
        }
    }

    private func restoreCopy() {
        errorMessage = restore(
            backup,
            databaseName,
            sourcePassword,
            newPassword,
            packageAssessment?.verificationToken,
            allowIncompleteRestore)
        if errorMessage == nil { dismiss() }
    }
}
