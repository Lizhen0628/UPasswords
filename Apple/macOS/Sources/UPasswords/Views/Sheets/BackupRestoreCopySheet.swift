import SwiftUI
import UPasswordsCore
import UPasswordsPersistence

struct BackupRestoreCopySheet: View {
    @EnvironmentObject private var ctx: AppContext
    @Environment(\.dismiss) private var dismiss

    @State private var databaseName: String
    @State private var sourcePassword = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var errorMessage: String?
    @State private var packageAssessment: BackupPackage.Assessment?
    @State private var isAssessingPackage = false
    @State private var allowIncompleteRestore = false

    let backup: URL

    init(backup: URL, suggestedName: String) {
        self.backup = backup
        _databaseName = State(initialValue: suggestedName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.t("backup_restore_copy_hint"))
                .font(.callout)
                .foregroundStyle(.secondary)

            Form {
                TextField(L10n.t("backup_restore_copy_name"), text: $databaseName)
                    .textFieldStyle(.roundedBorder)
                SecureField(L10n.t("backup_restore_source_password"), text: $sourcePassword)
                    .textFieldStyle(.roundedBorder)
                SecureField(L10n.t("backup_restore_new_password"), text: $newPassword)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.newPassword)
                SecureField(L10n.t("backup_restore_confirm_password"), text: $confirmPassword)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.newPassword)

                if isPackageBackup {
                    Button(action: assessPackage) {
                        if isAssessingPackage {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text(L10n.t("backup_package_review"))
                        }
                    }
                    .disabled(sourcePassword.isEmpty || isAssessingPackage)
                    if let packageAssessment {
                        Text(assessmentText(packageAssessment))
                            .foregroundStyle(
                                packageAssessment.isComplete ? Color.secondary : Color.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(Array(packageAssessment.issues.enumerated()), id: \.offset) { _, issue in
                                    Text(issue.summary)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 100)
                        if !packageAssessment.isComplete {
                            Toggle(
                                L10n.t("backup_package_confirm_incomplete"),
                                isOn: $allowIncompleteRestore)
                        }
                    }
                }
            }
            .formStyle(.columns)
            .onChange(of: sourcePassword) { _, _ in
                packageAssessment = nil
                allowIncompleteRestore = false
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button(L10n.t("cancel_button")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.t("restore_button"), action: restoreCopy)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canRestore)
            }
        }
        .padding(22)
        .frame(width: 440)
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
        errorMessage = ctx.restoreBackupAsCopy(
            backup: backup,
            name: databaseName,
            sourcePassword: sourcePassword,
            newPassword: newPassword,
            expectedPackageVerificationToken: packageAssessment?.verificationToken,
            allowIncompletePackage: allowIncompleteRestore)
        if errorMessage == nil { dismiss() }
    }
}
