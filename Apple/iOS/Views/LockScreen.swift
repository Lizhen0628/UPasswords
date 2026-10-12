import SwiftUI

import UPasswordsCore
import UPasswordsPersistence

// MARK: - 锁屏 / 首次创建主密码(含服务端账户库恢复)

struct LockScreen: View {
    @EnvironmentObject var vault: Vault

    @State private var password = ""
    @State private var confirm = ""
    @State private var enableFaceID = true
    @State private var shake = false
    @State private var errorText: String? = nil
    @State private var serverVaults: [RelayClient.VaultRecord] = []
    @State private var selectedVault = ""
    @State private var restorePassword = ""
    @State private var restoreBusy = false
    @State private var lockImage: UIImage? = nil
    @State private var showFileImporter = false
    @State private var accountStepDismissed = false
    @State private var accountEmail = ""
    @State private var accountCode = ""
    @State private var accountBusy = false

    private var isSetup: Bool { !vault.hasVault }
    private var theme: (name: String, colors: [Color]) {
        Vault.themes[max(0, min(Vault.themes.count - 1, vault.themeIndex))]
    }

    /// 选中且有服务端库体镜像的库才可恢复(镜像在绑定/每轮同步时推送)。
    private var selectedRecord: RelayClient.VaultRecord? {
        guard let record = serverVaults.first(where: { $0.name == selectedVault }),
              record.bodyUpdatedAt != nil else { return nil }
        return record
    }

    var body: some View {
        ZStack {
            if let lockImage {
                // 自定图片(设置 → 外观):铺满 + 压暗保证前景可读
                Image(uiImage: lockImage)
                    .resizable()
                    .scaledToFill()
                    .ignoresSafeArea()
                    .overlay(Color.black.opacity(0.38))
            } else {
                LinearGradient(colors: theme.colors, startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
            }

            ScrollView {
                VStack(spacing: 0) {
                    BrandLogo(size: 88)
                        .padding(.top, 48)
                    Text(L10n.t("app_title"))
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(Brand.fg)
                        .padding(.top, 14)
                    Text(isSetup ? L10n.t("ios_lock_setup_hint") : L10n.t("ios_lock_unlock_hint"))
                        .font(.subheadline)
                        .foregroundStyle(Brand.muted)
                        .padding(.top, 6)

                    inputArea
                        .frame(maxWidth: 340)
                        .padding(.top, 34)
                        .modifier(Shake(animatableData: shake ? 1 : 0))

                    if let errorText {
                        Text(errorText)
                            .font(.footnote)
                            .foregroundStyle(Brand.red)
                            .padding(.top, 10)
                    }

                    if !isSetup, vault.canUnlockWithBiometrics {
                        Button {
                            Task {
                                switch await vault.unlockWithBiometrics() {
                                case .success:
                                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                                case .notSetUp:
                                    fail(L10n.t("ios_faceid_not_setup_message"))
                                case .failed:
                                    fail(L10n.t("ios_faceid_failed_message"))
                                }
                            }
                        } label: {
                            VStack(spacing: 8) {
                                Image(systemName: "faceid")
                                    .font(.system(size: 30))
                                Text(L10n.t("ios_use_faceid_button"))
                                    .font(.footnote)
                            }
                            .foregroundStyle(Brand.accent)
                        }
                        .padding(.top, 28)
                    } else {
                        Text(L10n.t("ios_local_only_hint"))
                            .font(.footnote)
                            .foregroundStyle(Brand.muted)
                            .padding(.top, 28)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 48)
            }
        }
        .onAppear {
            lockImage = vault.loadLockImage()
            if !isSetup {
                // 同机重装:钥匙串里还留有主密码时自动填入解锁框
                if password.isEmpty, let stored = vault.storedMasterPassword() {
                    password = stored
                }
                if vault.canUnlockWithBiometrics {
                    Task { await vault.unlockWithBiometrics() }
                }
            }
        }
        .onChange(of: vault.hasVault) { hasVault in
            // 服务端恢复完成 → 转入解锁界面,同样尝试带出钥匙串密码
            if hasVault, password.isEmpty, let stored = vault.storedMasterPassword() {
                password = stored
            }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: Vault.vaultFileTypes) { result in
            switch result {
            case .success(let url):
                vault.importDatabaseFile(from: url)
            case .failure(let error):
                Log.warn("db", "ios import file picker failed: \(error)")
            }
        }
    }

    @ViewBuilder
    private var inputArea: some View {
        VStack(spacing: 12) {
            if isSetup {
                if !accountStepDismissed && vault.relayOnboardingNeeded {
                    // 必经第一步:整页仅账户登录,云端恢复/文件导入/新建
                    // 一概后置到验证完成(库就绪后自动补绑云同步)
                    onboardingAccountCard
                } else {
                    serverRestoreCard
                    Button {
                        showFileImporter = true
                    } label: {
                        Label(L10n.t("ios_import_file_button"), systemImage: "doc.badge.plus")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Brand.accent)
                            .frame(maxWidth: .infinity)
                            .frame(height: 46)
                            .background(Brand.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    Text(L10n.t("ios_or_create_new_hint"))
                        .font(.footnote)
                        .foregroundStyle(Brand.muted)
                        .padding(.vertical, 4)
                    createFields
                }
            } else {
                unlockFields
            }
        }
        .task(id: accountStepDismissed) {
            // 账户登录完成后(或曾登录过的设备)从注册表取回账户名下的库清单;
            // 引导登录在先的场景靠 task(id:) 在登录态翻转后重拉一次
            guard isSetup else { return }
            if let records = await vault.relayVaultsForRestore() {
                serverVaults = records
                selectedVault = records.first { $0.bodyUpdatedAt != nil }?.name ?? ""
            }
        }
    }

    // MARK: 新装引导 · 账户登录

    /// 新装引导第一步卡片:邮箱 + 验证码登录(先于创建/恢复库完成)。
    private var onboardingAccountCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(L10n.t("relay_onboarding_title"), systemImage: "person.crop.circle.badge.checkmark")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Brand.fg)
            Text(L10n.t("relay_onboarding_hint"))
                .font(.footnote)
                .foregroundStyle(Brand.muted)
            TextField(L10n.t("relay_email_placeholder"), text: $accountEmail)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 10) {
                SecureField(L10n.t("relay_code_placeholder"), text: $accountCode)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                Button(L10n.t("relay_send_code_button")) {
                    Log.info("ui", "ios onboarding code request")
                    accountBusy = true
                    let address = accountEmail.trimmingCharacters(in: .whitespaces)
                    Task {
                        await vault.relaySendCode(email: address)
                        accountBusy = false
                    }
                }
                .disabled(!accountEmail.contains("@") || accountBusy)
                .buttonStyle(.borderless)
            }
            Button {
                Log.info("ui", "ios onboarding login")
                accountBusy = true
                let address = accountEmail.trimmingCharacters(in: .whitespaces)
                let entered = accountCode
                accountCode = ""
                Task {
                    if await vault.relayLoginOnly(email: address, code: entered) {
                        accountStepDismissed = true
                    }
                    accountBusy = false
                }
            } label: {
                HStack(spacing: 8) {
                    if accountBusy { ProgressView().tint(Brand.onAccent) }
                    Text(L10n.t("relay_login_button"))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .background(Brand.accent, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .disabled(accountEmail.isEmpty || accountCode.count < RelayClient.verificationCodeLength || accountBusy)
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(Brand.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: 服务端恢复

    /// 账户名下的库恢复卡片:选库 + 输入该库主密码 → 服务端信封+库体镜像
    /// 解密落库并直接解锁。无库/未登录/拉取失败时整卡隐藏,只留导入与新建。
    @ViewBuilder
    private var serverRestoreCard: some View {
        if !serverVaults.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Label(String(format: L10n.t("ios_cloud_restore_hint_fmt"), serverVaults.count),
                      systemImage: "person.icloud")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Brand.fg)
                Picker(L10n.t("ios_cloud_db_picker"), selection: $selectedVault) {
                    ForEach(serverVaults.map(\.name), id: \.self) { name in
                        Text(rowLabel(name)).tag(name)
                    }
                }
                .pickerStyle(.menu)
                .tint(Brand.accent)
                .frame(maxWidth: .infinity, alignment: .leading)
                SecureField(L10n.t("ios_master_password_prompt"), text: $restorePassword)
                    .textContentType(.password)
                    .textFieldStyle(.roundedBorder)
                Button {
                    guard let record = selectedRecord else { return }
                    Log.info("ui", "ios online restore: restore \"\(record.name)\"")
                    restoreBusy = true
                    let pw = restorePassword
                    restorePassword = ""
                    Task {
                        _ = await vault.restoreFromRelay(record: record, password: pw)
                        restoreBusy = false
                    }
                } label: {
                    HStack(spacing: 8) {
                        if vault.restoringFromRelay { ProgressView().tint(Brand.onAccent) }
                        Text(vault.restoringFromRelay ? L10n.t("ios_cloud_restoring_text") : L10n.t("ios_cloud_restore_button"))
                    }
                    .primaryButtonStyle()
                }
                .disabled(selectedRecord == nil || restorePassword.isEmpty || vault.restoringFromRelay)
                .buttonStyle(.plain)
                Text(L10n.t("cloud_restore_server_list_hint"))
                    .font(.caption2)
                    .foregroundStyle(Brand.muted)
            }
            .padding(14)
            .background(Brand.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    /// 单行标签:尚无服务端库体镜像的库标注(在原设备同步一次后即可恢复)。
    private func rowLabel(_ n: String) -> String {
        guard let record = serverVaults.first(where: { $0.name == n }),
              record.bodyUpdatedAt == nil else { return n }
        return n + L10n.t("cloud_restore_no_mirror_suffix")
    }

    // MARK: 创建 / 解锁

    private var createFields: some View {
        VStack(spacing: 12) {
            SecureField(L10n.t("ios_master_password_prompt"), text: $password)
                .textContentType(.newPassword)
                .textFieldStyle(.plain)
                .font(.body)
                .padding(.horizontal, 16)
                .frame(height: 50)
                .background(Brand.fg.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .submitLabel(.next)
                .onSubmit(create)

            SecureField(L10n.t("ios_master_password_confirm_prompt"), text: $confirm)
                .textContentType(.newPassword)
                .textFieldStyle(.plain)
                .font(.body)
                .padding(.horizontal, 16)
                .frame(height: 50)
                .background(Brand.fg.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .submitLabel(.go)
                .onSubmit(create)

            if vault.biometricAvailable {
                Toggle(isOn: $enableFaceID) {
                    Label(L10n.t("ios_enable_faceid_toggle"), systemImage: "faceid")
                        .font(.subheadline)
                        .foregroundStyle(Brand.fg)
                }
                .tint(Brand.accent)
                .padding(.horizontal, 4)
            }

            Button(action: create) {
                Text(L10n.t("ios_create_unlock_button"))
                    .primaryButtonStyle()
            }
        }
    }

    private var unlockFields: some View {
        VStack(spacing: 12) {
            SecureField(L10n.t("ios_master_password_prompt"), text: $password)
                .textContentType(.password)
                .textFieldStyle(.plain)
                .font(.body)
                .padding(.horizontal, 16)
                .frame(height: 50)
                .background(Brand.fg.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .submitLabel(.go)
                .onSubmit(unlock)

            Button(action: unlock) {
                Text(L10n.t("ios_unlock_button"))
                    .primaryButtonStyle()
            }
        }
    }

    private func unlock() {
        Task { @MainActor in
            // 远端兜底:他机改密轮换后本地本体过期,需拉远端收敛(见 Vault 注释)
            if await vault.unlockWithRemoteFallback(with: password) {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } else {
                fail(L10n.t("ios_wrong_password_error"))
            }
        }
    }

    private func create() {
        guard password.count >= PasswordPolicy.minimumMasterPasswordLength else { fail(L10n.t("ios_password_too_short_error")); return }
        guard password == confirm else { fail(L10n.t("ios_password_mismatch_error")); return }
        vault.createVault(password: password, biometric: enableFaceID && vault.biometricAvailable)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func fail(_ message: String) {
        errorText = message
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        withAnimation(.default) { shake = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { shake = false }
    }
}

// MARK: - 主按钮样式 & 抖动

extension View {
    func primaryButtonStyle() -> some View {
        font(.body.weight(.semibold))
            .foregroundStyle(Brand.onAccent)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(Brand.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct Shake: GeometryEffect {
    var animatableData: CGFloat
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: -10 * sin(animatableData * .pi * 4), y: 0))
    }
}
