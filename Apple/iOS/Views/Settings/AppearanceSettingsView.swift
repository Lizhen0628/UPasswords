import PhotosUI
import SwiftUI

import UPasswordsCore
import UPasswordsPersistence

// MARK: - 设置 › 外观

/// 外观子页:主题、密码掩码与自定义锁屏图片。
struct AppearanceSettingsView: View {
    @EnvironmentObject var vault: Vault

    @State private var lockPhotoItem: PhotosPickerItem? = nil

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.t("ios_theme_label")).font(.body)
                    HStack(spacing: 12) {
                        ForEach(0..<Vault.themes.count, id: \.self) { i in
                            let theme = Vault.themes[i]
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(LinearGradient(colors: theme.colors, startPoint: .top, endPoint: .bottom))
                                .frame(width: 40, height: 40)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(Brand.accent, lineWidth: vault.themeIndex == i ? 2.5 : 0)
                                )
                                .overlay(alignment: .bottom) {
                                    if vault.themeIndex == i {
                                        Image(systemName: "checkmark")
                                            .font(.caption2.weight(.bold))
                                            .foregroundStyle(.white)
                                            .padding(.bottom, 4)
                                    }
                                }
                                .onTapGesture { vault.themeIndex = i }
                                .accessibilityLabel(theme.name)
                        }
                    }
                    Text(Vault.themes[max(0, min(Vault.themes.count - 1, vault.themeIndex))].name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            Section {
                Toggle(isOn: $vault.maskPasswords) {
                    Label(L10n.t("ios_mask_passwords_toggle"), systemImage: "eye.slash")
                }
                .tint(Brand.accent)
            }
            Section {
                // 自定锁屏图片:存在即优先生效,可移除回质感渐变
                let hasLockImage = vault.hasLockImage
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label(L10n.t("ios_lock_photo_button"), systemImage: "photo")
                        Spacer()
                        if hasLockImage {
                            Button(role: .destructive) {
                                vault.clearLockImage()
                                lockPhotoItem = nil
                            } label: {
                                Text(L10n.t("ios_lock_photo_clear"))
                                    .font(.subheadline)
                            }
                        }
                    }
                    PhotosPicker(selection: $lockPhotoItem, matching: .images) {
                        Text(hasLockImage ? L10n.t("ios_lock_photo_replace") : L10n.t("ios_lock_photo_pick"))
                            .font(.subheadline)
                            .frame(maxWidth: .infinity)
                            .frame(height: 38)
                            .background(Brand.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .navigationTitle(L10n.t("ios_appearance_section"))
        .onChange(of: lockPhotoItem) { item in
            loadLockPhoto(item)
        }
    }

    /// 选取的照片保存为锁屏背景(长边压到 2048px JPEG)。
    @MainActor
    private func loadLockPhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }
        lockPhotoItem = nil
        Task {
            guard let data = (try? await item.loadTransferable(type: Data.self)) ?? nil,
                  let image = UIImage(data: data) else {
                Log.warn("app", "ios lock photo load failed")
                return
            }
            vault.saveLockImage(image)
            vault.showToast(L10n.t("ios_lock_photo_set_message"))
        }
    }
}
