import SwiftUI

import UPasswordsCore
import UPasswordsPersistence

// MARK: - 锁屏 / 首次创建主密码(含服务端账户库恢复)

/// iOS 建库和解锁入口，管理输入草稿及远端恢复的交互状态。
struct LockScreen: View {
    @EnvironmentObject var vault: Vault

    @State private var password = ""
    @State private var previousPassword = ""
    @State private var remotePasswordForAdoption = ""
    @State private var showPreviousPasswordPrompt = false
    @State private var previousPasswordFailed = false
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
    @State private var personalInfoStepPresented = false
    @State private var personalInfo = PersonalInfoDraft()
    @State private var accountEmail = ""
    @State private var accountCode = ""
    @State private var accountBusy = false
    /// 初始化方式(邮箱验证后三选一;nil = 停在选择页,可返回重选)。
    enum SetupChoice {
        case create, importFile, restore
    }
    @State private var setupChoice: SetupChoice? = nil
    @State private var newVaultName = SharedVaultStore.defaultDatabaseName
    @StateObject private var resend = ResendCountdown()

    private var isSetup: Bool { !vault.hasVault }
    private var theme: (name: String, colors: [Color]) {
        Vault.themes[max(0, min(Vault.themes.count - 1, vault.themeIndex))]
    }

    /// 选中即可恢复:行级同步下空库同样合法(信封+0 行 → 空库接管,
    /// 其他设备同步后的条目随后拉取)。
    private var selectedRecord: RelayClient.VaultRecord? {
        serverVaults.first(where: { $0.name == selectedVault })
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
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 48)
            }
            .simultaneousGesture(setupBackSwipe)
        }
        .onAppear {
            lockImage = vault.loadLockImage()
            if !isSetup {
                // 同机重装:钥匙串里还留有主密码时自动填入解锁框
                if password.isEmpty, let stored = vault.storedMasterPassword() {
                    password = stored
                }
                // 面容 ID 仅在"无密码可预填"时自动弹(此时它是唯一通路,
                // 如他机改密清掉钥匙串副本后)。预填在场时自动弹纯属摩擦:
                // 用户取消面容 ID 后照样一键解锁,生物识别没有真正把门——
                // 这种场景下面容 ID 降级为按钮,想用再点。
                if vault.canUnlockWithBiometrics, vault.storedMasterPassword() == nil {
                    Task { await vault.unlockWithBiometrics() }
                }
            }
        }
        .onChange(of: vault.hasVault) { _, hasVault in
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
        .alert(L10n.t("sync_previous_password_title"), isPresented: $showPreviousPasswordPrompt) {
            SecureField(L10n.t("ios_master_password_prompt"), text: $previousPassword)
            Button(L10n.t("unlock_button")) {
                let remotePassword = remotePasswordForAdoption
                let oldPassword = previousPassword
                Task {
                    let result = await vault.adoptRemotePassword(
                        remotePassword, previousPassword: oldPassword)
                    switch result {
                    case .success:
                        remotePasswordForAdoption = ""
                        previousPassword = ""
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                    case .wrongPreviousPassword:
                        previousPassword = ""
                        previousPasswordFailed = true
                        try? await Task.sleep(for: .milliseconds(300))
                        showPreviousPasswordPrompt = true
                    case .wrongPassword:
                        remotePasswordForAdoption = ""
                        previousPassword = ""
                        errorText = L10n.t("sync_adopt_failed_hint")
                    case .previousPasswordRequired:
                        showPreviousPasswordPrompt = true
                    case .protectedData:
                        remotePasswordForAdoption = ""
                        previousPassword = ""
                    }
                }
            }
            .disabled(previousPassword.isEmpty)
            Button(L10n.t("cancel_button"), role: .cancel) {
                remotePasswordForAdoption = ""
                previousPassword = ""
                previousPasswordFailed = false
            }
        } message: {
            Text(previousPasswordFailed
                 ? L10n.t("sync_previous_password_error")
                 : L10n.t("sync_previous_password_message"))
        }
    }

    @ViewBuilder
    private var inputArea: some View {
        VStack(spacing: 12) {
            if isSetup {
                if personalInfoStepPresented {
                    personalInfoCard
                } else if !accountStepDismissed && vault.relayOnboardingNeeded {
                    // 必经第一步:整页仅账户登录,云端恢复/文件导入/新建
                    // 一概后置到验证完成(库就绪后自动补绑云同步)
                    onboardingAccountCard
                } else {
                    setupFlow
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
                selectedVault = records.first?.name ?? ""
            }
        }
    }

    // MARK: 初始化方式选择(三选一分步)

    /// 左缘右滑返回选择页:必须挂在最外层滚动容器上——内容区手势会被
    /// ScrollView 抢占,且内容 28pt 边距使子视图根本覆盖不到屏幕边缘。
    /// 与滚动并存(simultaneous),仅在"初始化步骤页 + 左缘起手 + 横向为主"
    /// 时触发,纵向滚动不受影响。
    private var setupBackSwipe: some Gesture {
        DragGesture(minimumDistance: 20)
            .onEnded { value in
                guard isSetup, setupChoice != nil else { return }
                let nearLeftEdge = value.startLocation.x < 60
                let horizontal = value.translation.width
                let mostlyHorizontal = abs(value.translation.height) * 2 < abs(horizontal)
                if nearLeftEdge, horizontal > 40, mostlyHorizontal {
                    Log.info("ui", "ios setup edge-swipe back to chooser")
                    withAnimation(.easeOut(duration: 0.15)) { setupChoice = nil }
                }
            }
    }

    /// 邮箱验证后的初始化:方式选择页 → 对应步骤页(可返回重选)。
    /// 步骤页支持两种返回:左上角按钮 + 左缘右滑手势(与系统推拉返回同向;
    /// 内容嵌在外层 ScrollView 里用不了系统手势,这里自实现边缘判定)。
    @ViewBuilder
    private var setupFlow: some View {
        if setupChoice != nil {
            VStack(spacing: 12) {
                Button {
                    Log.info("ui", "ios setup back to chooser")
                    withAnimation(.easeOut(duration: 0.15)) { setupChoice = nil }
                } label: {
                    Label(L10n.t("ios_setup_back_button"), systemImage: "chevron.left")
                        .font(.footnote)
                        .foregroundStyle(Brand.accent)
                }
                .frame(maxWidth: 340, alignment: .leading)
                setupChoicePage
            }
        } else {
            setupChooser
        }
    }

    /// 当前所选方式的步骤页内容。
    @ViewBuilder
    private var setupChoicePage: some View {
        switch setupChoice {
        case .restore:
            if serverVaults.isEmpty {
                Text(L10n.t("cloud_restore_empty_hint"))
                    .font(.footnote)
                    .foregroundStyle(Brand.muted)
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)
            } else {
                serverRestoreCard
            }
        case .importFile:
            importCard
        case .create:
            createFields
        case nil:
            EmptyView()
        }
    }

    /// 方式选择页:新建 / 文件导入 / 云端恢复 三选一。
    private var setupChooser: some View {
        VStack(spacing: 12) {
            Text(L10n.t("ios_setup_choose_title"))
                .font(.headline)
                .foregroundStyle(Brand.fg)
            Text(L10n.t("ios_setup_choose_hint"))
                .font(.footnote)
                .foregroundStyle(Brand.muted)
            choiceRow(.create, icon: "plus.circle.fill", titleKey: "ios_setup_create_title", hintKey: "ios_setup_create_hint")
            choiceRow(.importFile, icon: "doc.badge.plus", titleKey: "ios_setup_import_title", hintKey: "ios_setup_import_hint")
            choiceRow(.restore, icon: "person.icloud.fill", titleKey: "ios_setup_restore_title", hintKey: "ios_setup_restore_hint")
        }
    }

    private func choiceRow(_ choice: SetupChoice, icon: String, titleKey: String, hintKey: String) -> some View {
        Button {
            Log.info("ui", "ios setup choice \(String(describing: choice))")
            setupChoice = choice
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundStyle(Brand.accent)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.t(titleKey))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Brand.fg)
                    Text(L10n.t(hintKey))
                        .font(.caption)
                        .foregroundStyle(Brand.muted)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(Brand.muted)
            }
            .padding(14)
            .background(Brand.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// 文件导入步骤页:选择 .upw/.upwkey 文件对(容器校验与配套信封检查
    /// 在 Vault.importDatabaseFile 内完成)。
    private var importCard: some View {
        VStack(spacing: 10) {
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
            Text(L10n.t("local_restore_hint"))
                .font(.caption)
                .foregroundStyle(Brand.muted)
                .multilineTextAlignment(.center)
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
                Button(resend.buttonTitle(L10n.t("relay_send_code_button"))) {
                    Log.info("ui", "ios onboarding code request")
                    accountBusy = true
                    let address = accountEmail.trimmingCharacters(in: .whitespaces)
                    Task {
                        resend.start(await vault.relaySendCode(email: address))
                        accountBusy = false
                    }
                }
                .disabled(!accountEmail.contains("@") || accountBusy || resend.isRunning)
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
                        personalInfo.email = address
                        personalInfoStepPresented = true
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

    private var personalInfoCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L10n.t("personal_info_title"), systemImage: "person.text.rectangle")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Brand.fg)
            Text(L10n.t("personal_info_hint"))
                .font(.footnote)
                .foregroundStyle(Brand.muted)
            Group {
                TextField(L10n.t("personal_info_given_name"), text: $personalInfo.givenName)
                TextField(L10n.t("personal_info_family_name"), text: $personalInfo.familyName)
                TextField(L10n.t("personal_info_email"), text: $personalInfo.email)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField(L10n.t("personal_info_phone"), text: $personalInfo.phone)
                    .keyboardType(.phonePad)
                TextField(L10n.t("personal_info_address_line_1"), text: $personalInfo.addressLine1)
                TextField(L10n.t("personal_info_address_line_2"), text: $personalInfo.addressLine2)
                TextField(L10n.t("personal_info_city"), text: $personalInfo.city)
                TextField(L10n.t("personal_info_region"), text: $personalInfo.region)
                TextField(L10n.t("personal_info_postal_code"), text: $personalInfo.postalCode)
                TextField(L10n.t("personal_info_country"), text: $personalInfo.country)
            }
            .textFieldStyle(.roundedBorder)
            .frame(minHeight: 44)
            Button {
                Log.info("ui", "ios setup: personal info step completed")
                vault.pendingPersonalInfo = personalInfo
                personalInfoStepPresented = false
            } label: {
                Text(L10n.t("continue_button"))
                    .primaryButtonStyle()
            }
            .buttonStyle(.plain)
            Button(L10n.t("skip_button")) {
                Log.info("ui", "ios setup: personal info step skipped")
                vault.pendingPersonalInfo = nil
                personalInfoStepPresented = false
            }
            .font(.footnote)
            .foregroundStyle(Brand.muted)
            .frame(maxWidth: .infinity, minHeight: 44)
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
                        Text(name).tag(name)
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


    // MARK: 创建 / 解锁

    private var createFields: some View {
        VStack(spacing: 12) {
            // 库名可自定义(默认 Main);云端注册与多库管理都以这个名字认领/展示
            TextField(L10n.t("ios_setup_vault_name_placeholder"), text: $newVaultName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.plain)
                .font(.body)
                .padding(.horizontal, 16)
                .frame(height: 50)
                .background(Brand.fg.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
            switch await vault.unlockWithRemoteFallback(with: password) {
            case .unlocked:
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            case .previousPasswordRequired:
                remotePasswordForAdoption = password
                password = ""
                previousPassword = ""
                previousPasswordFailed = false
                showPreviousPasswordPrompt = true
            case .wrongPassword:
                fail(L10n.t("ios_wrong_password_error"))
            case .unavailable:
                fail(L10n.t("unlock_environment_error"))
            }
        }
    }

    private func create() {
        guard password.count >= PasswordPolicy.minimumMasterPasswordLength else { fail(L10n.t("ios_password_too_short_error")); return }
        guard password == confirm else { fail(L10n.t("ios_password_mismatch_error")); return }
        vault.createVault(name: newVaultName, password: password, biometric: enableFaceID && vault.biometricAvailable)
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

/// 用于输入失败提示的水平位移动画几何效果。
struct Shake: GeometryEffect {
    var animatableData: CGFloat
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: -10 * sin(animatableData * .pi * 4), y: 0))
    }
}
