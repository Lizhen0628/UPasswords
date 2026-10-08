import SwiftUI

import UPasswordsCore
import UPasswordsPersistence

// MARK: - 管理密码库:库清单(原生 List 右滑 删除/切换) + 重命名入口
//
// 行操作用原生 swipeActions:手势由系统 List 滚动栈亲自仲裁,真机手指下
// 远比自绘手势层可靠(此前 SwiftUI DragGesture 与 UIKit 平移桥两种自绘
// 方案在真机上均出现过右滑零响应/按钮不可见)。行内容必须是「非 Button」
// 的裸视图:实测 Button 行的点按手势会吞掉 leading 边滑动手势,右滑完全
// 无响应;点按改由 contentShape + onTapGesture 承担(点按与水平滑动不
// 竞争),行内不得再叠加其他自定义手势修饰符。
// 真机 iOS 27.0.1 上原生 swipeActions 仍不响应(iOS 27.0 模拟器同代码
// UI 测试通过,判定为个别真机环境的手势仲裁问题),故行尾加 Menu 作为
// 不依赖手势的可靠入口,swipeActions 保留。

struct VaultManageSheet: View {
    @EnvironmentObject var vault: Vault
    @Environment(\.dismiss) private var dismiss

    @State private var switchTarget: DatabaseFile? = nil
    @State private var deleteTarget: DatabaseFile? = nil
    @State private var showRename = false
    @State private var showImporter = false
    /// 云端(已配置同步)里存在但本地没有的库。
    @State private var cloudOnlyNames: [String] = []
    @State private var cloudImportTarget: String? = nil

    var body: some View {
        NavigationStack {
            List {
                ForEach(vault.databases, id: \.name) { db in
                    manageRow(db)
                }
                // 云端分区:已配置同步时列出“云上有、本地没有”的库,点按下载
                if !cloudOnlyNames.isEmpty {
                    Section {
                        ForEach(cloudOnlyNames, id: \.self) { name in
                            cloudRow(name)
                        }
                    } header: {
                        Text(L10n.t("ios_cloud_databases_section"))
                    }
                }
                Section {
                    Text(L10n.t("ios_databases_section_footer"))
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
            .navigationTitle(L10n.t("ios_db_manage_button"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("close_button")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    HStack(spacing: 16) {
                        Button {
                            showImporter = true
                        } label: {
                            Image(systemName: "doc.badge.plus")
                        }
                        .accessibilityLabel(L10n.t("ios_import_file_button"))
                        Button {
                            showRename = true
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .accessibilityLabel(L10n.t("ios_db_rename_title"))
                    }
                }
            }
            .onAppear {
                vault.refreshDatabases()
                Task { await loadCloudOnly() }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: Vault.vaultFileTypes) { result in
                // 导入成功后库即切换并锁定,本页随锁屏自动退场
                if case .success(let url) = result {
                    vault.importDatabaseFile(from: url)
                }
            }
            .confirmationDialog(L10n.t("ios_db_import_query"), isPresented: Binding(
                get: { cloudImportTarget != nil },
                set: { if !$0 { cloudImportTarget = nil } }
            ), titleVisibility: .visible, presenting: cloudImportTarget) { name in
                Button(L10n.t("ios_cloud_restore_button")) {
                    Task { _ = await vault.importCloudDatabase(name: name) }
                }
                Button(L10n.t("cancel_button"), role: .cancel) {}
            }
            .sheet(isPresented: $showRename) { DatabaseRenameSheet() }
            .confirmationDialog(L10n.t("ios_db_switch_query"), isPresented: Binding(
                get: { switchTarget != nil },
                set: { if !$0 { switchTarget = nil } }
            ), titleVisibility: .visible, presenting: switchTarget) { target in
                Button(L10n.t("ios_db_switch_button")) { vault.switchDatabase(to: target.name) }
                Button(L10n.t("cancel_button"), role: .cancel) {}
            } message: { _ in
                Text(L10n.t("ios_db_switch_detail"))
            }
            .confirmationDialog(L10n.t("ios_db_delete_query"), isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            ), titleVisibility: .visible, presenting: deleteTarget) { target in
                Button(L10n.t("ios_db_delete_button"), role: .destructive) { vault.deleteDatabase(target.name) }
                Button(L10n.t("cancel_button"), role: .cancel) {}
            } message: { _ in
                Text(L10n.t("ios_db_delete_detail"))
            }
        }
    }

    /// 云端库行:点按弹确认后下载并切换。
    private func cloudRow(_ name: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "icloud")
                .font(.body)
                .foregroundStyle(Brand.accent)
                .frame(width: 26)
            Text(name)
                .font(.body)
                .foregroundStyle(Brand.fg)
            Spacer()
            if vault.importingCloud {
                ProgressView().tint(Brand.accent)
            } else {
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(Brand.accent)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if !vault.importingCloud { cloudImportTarget = name } }
        .listRowBackground(Brand.card)
        .listRowInsets(EdgeInsets(top: 11, leading: 16, bottom: 11, trailing: 16))
    }

    /// 列出云端有而本地没有的库(未配置同步时为空,分区自动隐藏)。
    private func loadCloudOnly() async {
        guard vault.cloud == .icloud || vault.cloud == .webdav else { return }
        let names = await vault.listCloudDatabases()
        let localNames = Set(vault.databases.map(\.name))
        cloudOnlyNames = names.filter { !localNames.contains($0) }
    }

    /// 库行:右滑(leading)揭示 删除/切换;点按非当前库弹切换确认。
    /// 行内容不得是 Button(会吞掉滑动手势),点按走 onTapGesture。
    private func manageRow(_ db: DatabaseFile) -> some View {
        vaultRow(db)
            .contentShape(Rectangle())
            .onTapGesture {
                if db.name != vault.databaseName { switchTarget = db }
            }
            .listRowBackground(Brand.card)
        .listRowInsets(EdgeInsets(top: 11, leading: 16, bottom: 11, trailing: 16))
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                deleteTarget = db
            } label: {
                Label(L10n.t("ios_db_delete_button"), systemImage: "trash")
            }
            .tint(Brand.red)

            Button {
                switchTarget = db
            } label: {
                Label(L10n.t("ios_db_switch_button"), systemImage: "arrow.left.arrow.right")
            }
            .tint(Brand.accent)
            .disabled(db.name == vault.databaseName)
        }
    }

    /// 库行内容(点按走 onTapGesture,滑动由 swipeActions 承担,互不冲突)。
    private func vaultRow(_ db: DatabaseFile) -> some View {
        let isCurrent = db.name == vault.databaseName
        return HStack(spacing: 12) {
            Image(systemName: "externaldrive.fill")
                .font(.body)
                .foregroundStyle(Brand.accent)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(db.name)
                    .font(.body)
                    .foregroundStyle(Brand.fg)
                Text(String(format: L10n.t("ios_db_created_fmt"),
                            db.created.formatted(date: .abbreviated, time: .omitted)))
                    .font(.caption)
                    .foregroundStyle(Brand.muted)
            }
            Spacer()
            if isCurrent {
                Text(L10n.t("ios_db_current_badge"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Brand.accent)
            }
            // 不依赖手势的可靠入口:个别真机(iOS 27.0.1)swipeActions 不响应
            Menu {
                Button {
                    switchTarget = db
                } label: {
                    Label(L10n.t("ios_db_switch_button"), systemImage: "arrow.left.arrow.right")
                }
                .disabled(isCurrent)
                Button(role: .destructive) {
                    deleteTarget = db
                } label: {
                    Label(L10n.t("ios_db_delete_button"), systemImage: "trash")
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
}

// MARK: - 新建 / 重命名 / 从 iCloud 导入弹层

/// 新建数据库:命名 + 主密码(+面容 ID),成功后切换为当前库并解锁。
struct DatabaseCreateSheet: View {
    @EnvironmentObject var vault: Vault
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var password = ""
    @State private var confirm = ""
    @State private var enableBiometric = true
    @State private var error: String? = nil

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L10n.t("ios_db_name_prompt"), text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text(L10n.t("database_name_error"))
                }
                Section {
                    SecureField(L10n.t("ios_master_password_prompt"), text: $password)
                        .textContentType(.newPassword)
                    SecureField(L10n.t("ios_master_password_confirm_prompt"), text: $confirm)
                        .textContentType(.newPassword)
                    if vault.biometricAvailable {
                        Toggle(isOn: $enableBiometric) {
                            Label(L10n.t("ios_enable_faceid_toggle"), systemImage: "faceid")
                        }
                        .tint(Brand.accent)
                    }
                }
                if let error {
                    Section {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(L10n.t("ios_db_create_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.t("cancel_button")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("ios_create_button")) { create() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard password.count >= 4 else { error = L10n.t("ios_password_too_short_error"); return }
        guard password == confirm else { error = L10n.t("ios_password_mismatch_error"); return }
        // 名称非法/已存在等原因由 Vault 经 toast 展示
        if vault.createDatabase(name: trimmed, password: password, biometric: enableBiometric && vault.biometricAvailable) {
            dismiss()
        }
    }
}

/// 重命名当前数据库(解锁态才可用;钥匙串与备份由 DatabaseStore 迁移)。
struct DatabaseRenameSheet: View {
    @EnvironmentObject var vault: Vault
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var error: String? = nil

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L10n.t("ios_db_name_prompt"), text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text(L10n.t("rename_database_on_all_devices_message"))
                }
                if let error {
                    Section {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(L10n.t("ios_db_rename_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.t("cancel_button")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("ios_save_button")) { rename() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { name = vault.databaseName }
        }
        .presentationDetents([.medium])
    }

    private func rename() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if vault.renameCurrentDatabase(to: trimmed) {
            dismiss()
        } else if trimmed == vault.databaseName {
            dismiss()
        }
    }
}

/// 从 iCloud 云端文件夹导入库:列出云端 .upw,选中下载为本地库并锁定待解锁。
/// 首次使用时云端文件夹书签还不存在,就地提供选择入口(而不是只报"没有找到")。
struct DatabaseImportSheet: View {
    @EnvironmentObject var vault: Vault
    @Environment(\.dismiss) private var dismiss

    @State private var names: [String] = []
    @State private var loading = false
    @State private var importing: String? = nil
    @State private var showFolderPicker = false

    var body: some View {
        NavigationStack {
            Form {
                if loading {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView().tint(Brand.accent)
                            Text(L10n.t("ios_cloud_checking_text")).foregroundStyle(Brand.muted)
                        }
                        .frame(height: 40)
                    }
                } else if names.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(vault.hasICloudFolder ? L10n.t("ios_db_import_none")
                                                       : L10n.t("ios_db_import_need_folder"))
                                .font(.subheadline)
                                .foregroundStyle(Brand.muted)
                                .fixedSize(horizontal: false, vertical: true)
                            Button {
                                showFolderPicker = true
                            } label: {
                                Label(L10n.t("ios_icloud_pick_folder_button"), systemImage: "folder")
                            }
                            if vault.hasICloudFolder {
                                // 已选过文件夹仍可能临时列不到(云端元数据未刷新),给一次手动重试
                                Button {
                                    Task { await load() }
                                } label: {
                                    Label(L10n.t("ios_refresh_button"), systemImage: "arrow.clockwise")
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } else {
                    Section {
                        ForEach(names, id: \.self) { name in
                            Button {
                                importDatabase(name)
                            } label: {
                                HStack {
                                    Label(name, systemImage: "externaldrive.badge.icloud")
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    if importing == name {
                                        ProgressView().tint(Brand.accent)
                                    }
                                }
                            }
                            .disabled(importing != nil)
                        }
                    } footer: {
                        Text(L10n.t("ios_db_imported_locked_message"))
                    }
                }
            }
            .navigationTitle(L10n.t("ios_db_import_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("cancel_button")) { dismiss() }
                }
            }
            .task { await load() }
            .sheet(isPresented: $showFolderPicker) {
                FolderPickerView { url in
                    Task {
                        await vault.setICloudFolder(url)
                        await load()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func load() async {
        loading = true
        names = await vault.listCloudDatabases()
        loading = false
    }

    private func importDatabase(_ name: String) {
        importing = name
        Task {
            let ok = await vault.importCloudDatabase(name: name)
            importing = nil
            if ok {
                vault.showToast(L10n.t("ios_db_imported_locked_message"))
                dismiss()
            }
        }
    }
}
