import SwiftUI

import UPasswordsCore
import UPasswordsPersistence

// MARK: - 设置 › 云同步

/// 云同步子页:云类型选择、WebDAV/iCloud 配置、自动同步与立即同步状态。
struct SyncSettingsView: View {
    @EnvironmentObject var vault: Vault

    @State private var showFolderPicker = false
    @State private var showOverwriteConfirm = false
    @State private var showAdoptPrompt = false
    @State private var adoptPassword = ""
    @State private var adoptFailed = false

    /// 自动同步间隔档位(与 macOS ConfigureCloudSheet 一致)。
    private let autoSyncChoices: [(String, Int)] = [
        ("30" + L10n.t("seconds_abbr_text"), 30),
        ("1" + L10n.t("minutes_abbr_text"), 60),
        ("5" + L10n.t("minutes_abbr_text"), 300),
        ("15" + L10n.t("minutes_abbr_text"), 900),
        ("1" + L10n.t("hours_text"), 3600),
    ]

    var body: some View {
        Form {
            Section {
                Picker(L10n.t("cloud_prompt"), selection: Binding(
                    get: { vault.cloud },
                    set: { vault.cloudTypeRaw = $0.rawValue }
                )) {
                    ForEach(CloudType.allCases.filter { $0.functional }, id: \.self) { type in
                        Text(type.name).tag(type)
                    }
                }
                if vault.cloud == .webdav {
                    NavigationLink(L10n.t("ios_webdav_config_title")) { WebDavConfigSheet() }
                }
                if vault.cloud == .icloud {
                    Text(L10n.t("ios_icloud_sync_info"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    // iOS 沙盒访问不到云盘根,经安全作用域书签选定云端 UPasswords 文件夹
                    // (与 macOS 版同一个目录),书签持久化后自动同步即可无感运行
                    Button { showFolderPicker = true } label: {
                        Label(vault.hasICloudFolder ? L10n.t("ios_icloud_repick_folder_button")
                                                    : L10n.t("ios_icloud_pick_folder_button"),
                              systemImage: "folder")
                            .foregroundStyle(.primary)
                    }
                    if vault.hasICloudFolder {
                        Label(String(format: L10n.t("ios_icloud_selected_folder_fmt"),
                                     vault.icloudFolderName.isEmpty ? "UPasswords" : vault.icloudFolderName),
                              systemImage: "checkmark.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(Brand.green)
                        Text(String(format: L10n.t("ios_icloud_sync_db_fmt"), vault.databaseName))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if vault.cloud != .none {
                Section {
                    Toggle(L10n.t("auto_sync_setting"), isOn: $vault.autoSyncEnabled)
                        .tint(Brand.accent)
                    if vault.autoSyncEnabled {
                        Picker(L10n.t("auto_sync_interval_setting"), selection: $vault.autoSyncSeconds) {
                            ForEach(autoSyncChoices, id: \.1) { label, seconds in
                                Text(label).tag(seconds)
                            }
                        }
                    }
                }
                Section {
                    syncNowRow
                } footer: {
                    Text(L10n.t("cloud_sync_text"))
                }
            } else {
                Section {
                } footer: {
                    Text(L10n.t("cloud_sync_text"))
                }
            }
        }
        .navigationTitle(L10n.t("cloud_sync_title"))
        .sheet(isPresented: $showFolderPicker) {
            FolderPickerView { url in
                Task { await vault.setICloudFolder(url) }
            }
        }
    }

    /// 立即同步 + 状态行(进行中/上次成功/失败原因)。
    private var syncNowRow: some View {
        VStack(spacing: 10) {
            Button {
                Task { await vault.sync() }
            } label: {
                HStack(spacing: 8) {
                    if vault.syncState == .syncing {
                        ProgressView().tint(Brand.onAccent)
                        Text(L10n.t("ios_syncing_text"))
                    } else {
                        Text(L10n.t("sync_button"))
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .background(Brand.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .disabled(vault.syncState == .syncing
                      || (vault.cloud == .icloud && !vault.hasICloudFolder))
            .buttonStyle(.plain)
            statusLine
            // 远端解不开时两条路:密码被其他设备改过 → 输入新密码接管;
            // 否则以本地覆盖云端
            if vault.syncRemoteUnreadable {
                Button {
                    adoptPassword = ""
                    adoptFailed = false
                    showAdoptPrompt = true
                } label: {
                    Label(L10n.t("ios_sync_adopt_password_button"), systemImage: "key")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Brand.accent)
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .background(Brand.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                Button {
                    showOverwriteConfirm = true
                } label: {
                    Label(L10n.t("ios_sync_overwrite_cloud_button"), systemImage: "arrow.up.doc")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Brand.red)
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .background(Brand.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
        .confirmationDialog(L10n.t("ios_sync_overwrite_cloud_query"), isPresented: $showOverwriteConfirm, titleVisibility: .visible) {
            Button(L10n.t("ios_sync_overwrite_cloud_button"), role: .destructive) {
                Task { await vault.overwriteUnreadableRemote() }
            }
            Button(L10n.t("cancel_button"), role: .cancel) {}
        }
        .alert(L10n.t("ios_sync_adopt_password_title"), isPresented: $showAdoptPrompt) {
            SecureField("", text: $adoptPassword)
            Button(L10n.t("unlock_button")) {
                let pw = adoptPassword
                Log.info("sync", "ios adopt remote password attempt")
                Task {
                    let ok = await vault.adoptRemotePassword(pw)
                    if !ok {
                        // 原地重试:重开弹窗并带错误文案
                        adoptFailed = true
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        showAdoptPrompt = true
                    }
                }
            }
            .disabled(adoptPassword.isEmpty)
            Button(L10n.t("cancel_button"), role: .cancel) {}
        } message: {
            Text(adoptFailed ? L10n.t("wrong_password_error") : L10n.t("ios_sync_adopt_password_message"))
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if case .failed(let message) = vault.syncState {
            Text("\(L10n.t("last_sync_failed_prompt")) — \(message)")
                .font(.caption)
                .foregroundStyle(Brand.red)
        } else if let last = vault.lastSync {
            Text(L10n.t("last_sync_completed_prompt") + " " + last.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
