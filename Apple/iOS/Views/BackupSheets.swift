import SwiftUI
import UniformTypeIdentifiers

import UPasswordsCore
import UPasswordsPersistence

// MARK: - 备份管理弹层:当前库的备份清单(原生 List 右滑 恢复 / 删除)
//
// 行操作用原生 swipeActions(手势由系统 List 滚动栈仲裁,自绘手势层在
// 真机上不可靠)。行内容必须是「非 Button」的裸视图:实测 Button 行的
// 点按手势会吞掉 leading 边滑动手势,右滑完全无响应;点按改由
// contentShape + onTapGesture 承担(点按与水平滑动不竞争),行内不得
// 再叠加其他自定义手势修饰符。
// 真机 iOS 27.0.1 上原生 swipeActions 仍不响应(iOS 27.0 模拟器同代码
// UI 测试通过,判定为个别真机环境的手势仲裁问题),故行尾加 Menu 作为
// 不依赖手势的可靠入口,swipeActions 保留。

/// 展示当前库的加密备份，并将恢复与删除动作交由会话层执行。
struct BackupListSheet: View {
    @EnvironmentObject var vault: Vault
    @Environment(\.dismiss) private var dismiss

    @State private var backups: [URL] = []
    @State private var restoreTarget: URL? = nil
    @State private var activeBackupSheet: BackupSheet?
    @State private var showBackupImporter = false
    @State private var exportingBackup: URL?
    @State private var externalRestoreURL: URL?
    @State private var externalRestoreAccessStarted = false
    @State private var temporaryShareURL: URL?

    private enum BackupSheet: Identifiable {
        case restore(URL)
        case share(URL)

        var id: String {
            switch self {
            case .restore(let url): "restore:\(url.absoluteString)"
            case .share(let url): "share:\(url.absoluteString)"
            }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if backups.isEmpty {
                    Text(L10n.t("ios_backup_empty"))
                        .font(.subheadline)
                        .foregroundStyle(Brand.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .listRowBackground(Brand.card)
                        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                } else {
                    ForEach(backups, id: \.self) { url in
                        backupSwipeRow(url)
                    }
                }
                Section {
                    Text(L10n.t("ios_backup_list_footer"))
                        .font(.footnote)
                        .foregroundStyle(Brand.muted)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 0, trailing: 16))
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Brand.bg)
            .navigationTitle(L10n.t("backup_command"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("close_button")) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showBackupImporter = true
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                    .accessibilityLabel(L10n.t("backup_import_portable"))
                }
            }
            .onAppear { reload() }
            .fileImporter(
                isPresented: $showBackupImporter,
                allowedContentTypes: [UTType(filenameExtension: BackupPackage.fileExtension) ?? .data]
            ) { result in
                importPortableBackup(result)
            }
            .confirmationDialog(L10n.t("ios_backup_restore_query"), isPresented: Binding(
                get: { restoreTarget != nil },
                set: { if !$0 { restoreTarget = nil } }
            ), titleVisibility: .visible, presenting: restoreTarget) { url in
                Button(L10n.t("restore_command")) { activeBackupSheet = .restore(url) }
                    .disabled(!isRestorable(url))
                Button(L10n.t("cancel_button"), role: .cancel) {}
            } message: { _ in
                Text(L10n.t("ios_backup_restore_detail"))
            }
            .sheet(item: $activeBackupSheet, onDismiss: cleanupBackupSheet) { sheet in
                switch sheet {
                case .restore(let restoreCopyTarget):
                    BackupRestoreCopySheet(
                        backup: restoreCopyTarget,
                        suggestedName: "\(vault.databaseName)Copy") { backup, name, sourcePassword, newPassword, token, allowIncomplete in
                            vault.restoreBackupAsCopy(
                                backup,
                                name: name,
                                sourcePassword: sourcePassword,
                                newPassword: newPassword,
                                expectedPackageVerificationToken: token,
                                allowIncompletePackage: allowIncomplete)
                        }
                case .share(let archive):
                    PortableBackupShareSheet(url: archive)
                }
            }
        }
        .presentationDetents([.medium])
    }

    /// 备份行:右滑(leading)揭示 恢复/删除,点按弹恢复确认。
    /// 行内容不得是 Button(会吞掉滑动手势),点按走 onTapGesture。
    private func backupSwipeRow(_ url: URL) -> some View {
        backupRow(url)
            .contentShape(Rectangle())
            .onTapGesture {
                guard isRestorable(url) else { return }
                restoreTarget = url
            }
            .listRowBackground(Brand.card)
        .listRowInsets(EdgeInsets(top: 11, leading: 16, bottom: 11, trailing: 16))
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                restoreTarget = url
            } label: {
                Label(L10n.t("restore_command"), systemImage: "clock.arrow.circlepath")
            }
            .tint(Brand.accent)
            .disabled(!isRestorable(url))

            Button(role: .destructive) {
                vault.deleteBackup(url)
                reload()
            } label: {
                Label(L10n.t("delete_button"), systemImage: "trash")
            }
            .tint(Brand.red)
        }
    }

    private func backupRow(_ url: URL) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "externaldrive.badge.timemachine")
                .foregroundStyle(Brand.accent)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(backupTitle(url))
                    .font(.subheadline)
                    .foregroundStyle(Brand.fg)
                Text(byteText((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0))
                    .font(.caption)
                    .foregroundStyle(Brand.muted)
                if url.pathExtension == BackupPackage.fileExtension {
                    Text(packageStatus(url))
                        .font(.caption2)
                        .foregroundStyle(packageStatusColor(url))
                }
            }
            Spacer()
            // 不依赖手势的可靠入口:个别真机(iOS 27.0.1)swipeActions 不响应
            Menu {
                Button {
                    restoreTarget = url
                } label: {
                    Label(L10n.t("restore_command"), systemImage: "clock.arrow.circlepath")
                }
                .disabled(!isRestorable(url))
                if isPortablePackageDirectory(url) {
                    Button {
                        exportPortableBackup(url)
                    } label: {
                        Label(L10n.t("backup_export_portable"), systemImage: "square.and.arrow.up")
                    }
                    .disabled(exportingBackup != nil)
                }
                Button(role: .destructive) {
                    vault.deleteBackup(url)
                    reload()
                } label: {
                    Label(L10n.t("delete_button"), systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.body)
                    .foregroundStyle(Brand.muted)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(L10n.t("actions_button"))
        }
    }

    /// 快照文件名为 yyyyMMdd-HHmmss,还原成可读时间展示。
    private func backupTitle(_ url: URL) -> String {
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            return url.deletingPathExtension().lastPathComponent
        }
        let stamp = url.deletingPathExtension().lastPathComponent
        guard let date = DatabaseStore.backupStampFormatter.date(from: stamp) else { return stamp }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func reload() {
        backups = vault.backups()
    }

    private func isRestorable(_ url: URL) -> Bool {
        guard url.pathExtension == BackupPackage.fileExtension else { return true }
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        return isDirectory
            ? BackupPackage.hasValidStructure(at: url)
            : (try? BackupPackage.readInfo(at: url)) != nil
    }

    private func isPortablePackageDirectory(_ url: URL) -> Bool {
        url.pathExtension == BackupPackage.fileExtension
            && (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            && BackupPackage.hasValidStructure(at: url)
    }

    private func exportPortableBackup(_ package: URL) {
        guard exportingBackup == nil else { return }
        exportingBackup = package
        Task {
            let archive = await vault.makePortableBackupArchive(from: package)
            exportingBackup = nil
            guard let archive else { return }
            temporaryShareURL = archive
            activeBackupSheet = .share(archive)
        }
    }

    private func importPortableBackup(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            externalRestoreURL = url
            externalRestoreAccessStarted = url.startAccessingSecurityScopedResource()
            activeBackupSheet = .restore(url)
            Log.info("backup", "ios portable archive selected for restore: \(url.lastPathComponent)")
        case .failure(let error):
            if (error as? CocoaError)?.code == .userCancelled {
                Log.info("backup", "ios portable archive import cancelled")
            } else {
                Log.error("backup", "ios portable archive import failed: \(error)")
                vault.showToast(L10n.t("backup_package_assessment_failed"))
            }
        }
    }

    private func cleanupBackupSheet() {
        if externalRestoreAccessStarted, let externalRestoreURL {
            externalRestoreURL.stopAccessingSecurityScopedResource()
        }
        externalRestoreURL = nil
        externalRestoreAccessStarted = false
        if let temporaryShareURL {
            try? FileManager.default.removeItem(at: temporaryShareURL)
        }
        temporaryShareURL = nil
    }

    private func packageStatus(_ url: URL) -> String {
        guard isRestorable(url), let info = try? BackupPackage.readInfo(at: url) else {
            return L10n.t("backup_package_damaged")
        }
        return info.isComplete
            ? L10n.t("backup_package_complete")
            : String(format: L10n.t("backup_package_incomplete_fmt"), info.issueCount)
    }

    private func packageStatusColor(_ url: URL) -> Color {
        guard isRestorable(url), let info = try? BackupPackage.readInfo(at: url) else {
            return Brand.red
        }
        return info.isComplete ? Brand.muted : .orange
    }

    private func byteText(_ n: Int) -> String {
        if n < 1024 { return "\(n) B" }
        return String(format: "%.1f KB", Double(n) / 1024)
    }
}

private struct PortableBackupShareSheet: View {
    @Environment(\.dismiss) private var dismiss

    let url: URL

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text(L10n.t("backup_archive_ready"))
                    .font(.body)
                    .foregroundStyle(Brand.fg)
                    .multilineTextAlignment(.center)
                ShareLink(item: url) {
                    Label(L10n.t("backup_archive_share"), systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(24)
            .navigationTitle(L10n.t("backup_command"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("close_button")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
