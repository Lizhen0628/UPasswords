import SwiftUI

import UPasswordsCore
import UPasswordsPersistence

// MARK: - 设置 › 云同步

/// 云同步子页:云类型选择、WebDAV/iCloud 配置、自动同步与立即同步状态。
struct SyncSettingsView: View {
    @EnvironmentObject var vault: Vault

    @State private var showOverwriteConfirm = false
    @State private var showAdoptPrompt = false
    @State private var adoptPassword = ""
    @State private var adoptFailed = false
    @State private var relayEmail = ""
    @State private var relayCode = ""
    @State private var relayBusy = false
    @State private var relayDevices: [RelayClient.DeviceSession] = []
    @State private var showRelayDevices = false
    @State private var relayCodePrompt: RelayCodePrompt? = nil
    @State private var relayCodeInput = ""
    @State private var showRelayTransfer = false

    /// 需要敏感验证码确认的操作(解绑库 / 注销账户)。
    enum RelayCodePrompt {
        case unbind, deregister
    }

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
            // 网盘(iCloud/WebDAV)配置入口已隐藏:同步默认走 relay API;
            // 网盘代码保留作老库迁移兜底,已配置用户的存量设置不受影响
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
                relayAccountSection
            } footer: {
                Text(L10n.t("relay_account_footer"))
            }
            Section {
                syncNowRow
            } footer: {
                Text(L10n.t("cloud_sync_text"))
            }
        }
        .navigationTitle(L10n.t("cloud_sync_title"))
        .alert(L10n.t("relay_sensitive_code_title"), isPresented: Binding(
            get: { relayCodePrompt != nil },
            set: { if !$0 { relayCodePrompt = nil } }
        )) {
            TextField(L10n.t("relay_code_placeholder"), text: $relayCodeInput)
                .keyboardType(.numberPad)
            Button(L10n.t("ok_button")) {
                let code = relayCodeInput
                let prompt = relayCodePrompt
                relayCodeInput = ""
                relayCodePrompt = nil
                guard let prompt else { return }
                Task {
                    if prompt == .unbind {
                        await vault.relayUnbindVault(code: code)
                    } else {
                        await vault.relayDeregisterAccount(code: code)
                    }
                }
            }
            Button(L10n.t("cancel_button"), role: .cancel) {
                relayCodePrompt = nil
            }
        } message: {
            Text(relayCodePrompt == .deregister
                 ? L10n.t("relay_deregister_message") : L10n.t("relay_sensitive_code_sent"))
        }
        .sheet(isPresented: $showRelayTransfer) {
            RelayTransferSheet()
        }
    }

    /// UPasswords 云同步账户:未登录=邮箱+验证码登录(登录即为当前库启用);
    /// 已登录=账户邮箱 + 登出/设备管理/解绑/注销。登录需库处于解锁态(要上传本地信封)。
    @ViewBuilder
    private var relayAccountSection: some View {
        if let email = vault.relayAccountEmail, vault.relayBound {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Brand.green)
                    Text(email)
                    Spacer()
                    Button(L10n.t("relay_logout_button")) {
                        Log.info("ui", "ios relay logout from settings")
                        Task { await vault.relayLogout() }
                    }
                    .buttonStyle(.borderless)
                }
                Text(L10n.t("relay_enabled_label"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                HStack(spacing: 16) {
                    Button {
                        Log.info("ui", "ios relay devices toggle from settings")
                        Task {
                            relayDevices = await vault.relaySessions()
                            showRelayDevices.toggle()
                        }
                    } label: {
                        Label(L10n.t("relay_devices_button"), systemImage: "laptopcomputer.and.iphone")
                    }
                    .buttonStyle(.borderless)
                    Button(L10n.t("relay_transfer_button")) {
                        Log.info("ui", "ios relay transfer sheet from settings")
                        showRelayTransfer = true
                    }
                    .buttonStyle(.borderless)
                    Button(L10n.t("relay_unbind_button")) {
                        Log.info("ui", "ios relay unbind prompt from settings")
                        Task {
                            await vault.relayRequestSensitiveCode()
                            relayCodeInput = ""
                            relayCodePrompt = .unbind
                        }
                    }
                    .buttonStyle(.borderless)
                    Button(L10n.t("relay_deregister_button"), role: .destructive) {
                        Log.info("ui", "ios relay deregister prompt from settings")
                        Task {
                            await vault.relayRequestSensitiveCode()
                            relayCodeInput = ""
                            relayCodePrompt = .deregister
                        }
                    }
                    .buttonStyle(.borderless)
                }
                .font(.footnote)
                if showRelayDevices {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(relayDevices) { device in
                            HStack(spacing: 8) {
                                Image(systemName: "iphone")
                                Text(device.deviceName.isEmpty
                                     ? String(device.id.prefix(8)) + "…" : device.deviceName)
                                Spacer()
                                Button(L10n.t("relay_revoke_button"), role: .destructive) {
                                    Log.info("ui", "ios relay session revoke from settings")
                                    Task {
                                        await vault.relayRevokeSession(id: device.id)
                                        relayDevices = await vault.relaySessions()
                                    }
                                }
                                .buttonStyle(.borderless)
                            }
                            .font(.footnote)
                        }
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    TextField(L10n.t("relay_email_placeholder"), text: $relayEmail)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                    Button(L10n.t("relay_send_code_button")) {
                        let email = relayEmail.trimmingCharacters(in: .whitespaces)
                        guard email.contains("@"), email.contains(".") else {
                            vault.showToast(L10n.t("invalid_email_error"))
                            return
                        }
                        relayBusy = true
                        Log.info("ui", "ios relay code request from settings")
                        Task {
                            await vault.relaySendCode(email: email)
                            relayBusy = false
                        }
                    }
                    .disabled(relayBusy)
                    if relayBusy { ProgressView().controlSize(.small) }
                }
                HStack(spacing: 8) {
                    TextField(L10n.t("relay_code_placeholder"), text: $relayCode)
                        .keyboardType(.numberPad)
                        .textFieldStyle(.roundedBorder)
                    Button(L10n.t("relay_login_button")) {
                        relayBusy = true
                        Log.info("ui", "ios relay login from settings")
                        let email = relayEmail.trimmingCharacters(in: .whitespaces)
                        let code = relayCode
                        relayCode = ""
                        Task {
                            await vault.relayLoginAndEnable(email: email, code: code)
                            relayBusy = false
                        }
                    }
                    .disabled(relayEmail.isEmpty || relayCode.count < 6 || vault.locked)
                }
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
                    let result = await vault.adoptRemotePassword(pw)
                    if result != .success {
                        // 原地重试:重开弹窗并带错误文案(空库残骸时文案引导覆盖)
                        adoptFailed = true
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        showAdoptPrompt = true
                    }
                }
            }
            .disabled(adoptPassword.isEmpty)
            Button(L10n.t("cancel_button"), role: .cancel) {}
        } message: {
            Text(adoptFailed ? L10n.t("sync_adopt_failed_hint") : L10n.t("ios_sync_adopt_password_message"))
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

/// 换绑邮箱表单:当前主密码(本地验证) + 新邮箱(收敏感码) + 验证码 →
/// 注册表记录迁移到新邮箱名下,云端同步结构随之换主。
struct RelayTransferSheet: View {
    @EnvironmentObject var vault: Vault
    @Environment(\.dismiss) private var dismiss

    @State private var masterPassword = ""
    @State private var newEmail = ""
    @State private var code = ""
    @State private var busy = false
    @State private var sending = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(L10n.t("relay_transfer_hint"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section {
                    SecureField(L10n.t("relay_transfer_master_password"), text: $masterPassword)
                    TextField(L10n.t("relay_transfer_new_email"), text: $newEmail)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    HStack {
                        SecureField(L10n.t("relay_code_placeholder"), text: $code)
                            .keyboardType(.numberPad)
                        Button(L10n.t("relay_send_code_button")) {
                            Log.info("ui", "ios relay transfer code request")
                            sending = true
                            let email = newEmail.trimmingCharacters(in: .whitespaces)
                            Task {
                                await vault.relaySendSensitiveCode(to: email)
                                sending = false
                            }
                        }
                        .disabled(!newEmail.contains("@") || sending)
                        .buttonStyle(.borderless)
                    }
                } footer: {
                    if sending { ProgressView().controlSize(.small) }
                }
            }
            .navigationTitle(L10n.t("relay_transfer_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("cancel_button")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("relay_transfer_button")) {
                        busy = true
                        let pw = masterPassword
                        masterPassword = ""
                        let email = newEmail.trimmingCharacters(in: .whitespaces)
                        let entered = code
                        code = ""
                        Task {
                            if await vault.relayTransferVault(masterPassword: pw, newEmail: email, code: entered) {
                                dismiss()
                            }
                            busy = false
                        }
                    }
                    .disabled(masterPassword.isEmpty || !newEmail.contains("@") || code.count < 6 || busy)
                }
            }
        }
    }
}
