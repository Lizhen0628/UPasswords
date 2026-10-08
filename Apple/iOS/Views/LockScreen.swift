import SwiftUI

import UPasswordsCore

// MARK: - 锁屏 / 首次创建主密码(含 iCloud 云端库恢复)

struct LockScreen: View {
    @EnvironmentObject var vault: Vault

    @State private var password = ""
    @State private var confirm = ""
    @State private var enableFaceID = true
    @State private var shake = false
    @State private var errorText: String? = nil
    @State private var selectedCloudDB = ""
    @State private var restoreFailed = false
    @State private var lockImage: UIImage? = nil

    private var isSetup: Bool { !vault.hasVault }
    private var theme: (name: String, colors: [Color]) {
        Vault.themes[max(0, min(Vault.themes.count - 1, vault.themeIndex))]
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
            if isSetup {
                Task { await vault.checkCloudDatabases() }
            } else {
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
            // iCloud 恢复完成 → 转入解锁界面,同样尝试带出钥匙串密码
            if hasVault, password.isEmpty, let stored = vault.storedMasterPassword() {
                password = stored
            }
        }
    }

    @ViewBuilder
    private var inputArea: some View {
        VStack(spacing: 12) {
            if isSetup {
                // iCloud 云端已有加密库:先提供恢复入口,再提供新建
                if !vault.cloudDatabases.isEmpty {
                    cloudRestoreCard
                    Text(L10n.t("ios_or_create_new_hint"))
                        .font(.footnote)
                        .foregroundStyle(Brand.muted)
                        .padding(.vertical, 4)
                } else if vault.cloudChecking {
                    HStack(spacing: 8) {
                        ProgressView().tint(Brand.muted)
                        Text(L10n.t("ios_cloud_checking_text"))
                            .font(.footnote)
                            .foregroundStyle(Brand.muted)
                    }
                    .frame(height: 36)
                }
                createFields
            } else {
                unlockFields
            }
        }
    }

    // MARK: iCloud 恢复

    private var cloudRestoreCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(String(format: L10n.t("ios_cloud_restore_hint_fmt"), vault.cloudDatabases.count),
                  systemImage: "icloud")
                .font(.footnote.weight(.medium))
                .foregroundStyle(Brand.fg)
            Picker(L10n.t("ios_cloud_db_picker"), selection: $selectedCloudDB) {
                ForEach(vault.cloudDatabases, id: \.self) { name in
                    Text("\(name).upw").tag(name)
                }
            }
            .pickerStyle(.menu)
            .tint(Brand.accent)
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                guard !selectedCloudDB.isEmpty else { return }
                Task {
                    let ok = await vault.importCloudDatabase(name: selectedCloudDB)
                    if !ok { restoreFailed = true }
                }
            } label: {
                HStack(spacing: 8) {
                    if vault.importingCloud {
                        ProgressView().tint(Brand.onAccent)
                    }
                    Text(vault.importingCloud ? L10n.t("ios_cloud_restoring_text") : L10n.t("ios_cloud_restore_button"))
                }
                .primaryButtonStyle()
            }
            .disabled(selectedCloudDB.isEmpty || vault.importingCloud)
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(Brand.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .alert(L10n.t("ios_cloud_restore_failed_title"), isPresented: $restoreFailed) {
            Button(L10n.t("ios_ok_button"), role: .cancel) {}
        } message: {
            Text(L10n.t("ios_cloud_restore_failed_message"))
        }
        .onAppear {
            if selectedCloudDB.isEmpty { selectedCloudDB = vault.cloudDatabases.first ?? "" }
        }
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
        if vault.unlock(with: password) {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } else {
            fail(L10n.t("ios_wrong_password_error"))
        }
    }

    private func create() {
        guard password.count >= 4 else { fail(L10n.t("ios_password_too_short_error")); return }
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
