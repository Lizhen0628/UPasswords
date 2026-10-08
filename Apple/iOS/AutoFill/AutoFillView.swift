import SwiftUI

import UPasswordsCore

// MARK: - AutoFill 扩展界面(品牌深色体系,复用共享组件)

struct AutoFillRootView: View {
    @ObservedObject var model: AutoFillModel

    var body: some View {
        ZStack {
            Brand.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                switch model.stage {
                case .noVault: noVaultView
                case .locked: lockedView
                case .unlocked:
                    if model.flow == .passkeyRegistration { registerView } else { listView }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: 顶栏

    private var header: some View {
        HStack(spacing: 10) {
            BrandLogo(size: 30)
            Text(L10n.t("app_title"))
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Brand.fg)
            Spacer()
            Button(L10n.t("cancel_button")) { model.cancel() }
                .font(.system(size: 16))
                .foregroundStyle(Brand.accent)
                .frame(minWidth: 44, minHeight: 44)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Brand.surface)
    }

    // MARK: 未建库

    private var noVaultView: some View {
        VStack(spacing: 18) {
            Spacer()
            BrandLogo(size: 92)
            Text(L10n.t("ios_af_no_vault_title"))
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Brand.fg)
            Text(L10n.t("ios_af_no_vault_detail"))
                .font(.system(size: 15))
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .foregroundStyle(Brand.muted)
            Spacer()
        }
        .padding(.horizontal, 32)
    }

    // MARK: 解锁

    private var lockedView: some View {
        VStack(spacing: 0) {
            Spacer()
            BrandLogo(size: 92)
                .padding(.bottom, 14)
            Text(L10n.t("ios_af_unlock_title"))
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Brand.fg)
            if let host = model.serviceHostLabel {
                Text(host)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Brand.muted)
                    .padding(.top, 4)
            }
            // 主密码输入
            HStack(spacing: 10) {
                Image(systemName: "lock.fill")
                    .foregroundStyle(Brand.muted)
                    .frame(width: 20)
                SecureField(L10n.t("ios_master_password_prompt"), text: $model.masterInput)
                    .font(.system(size: 16))
                    .foregroundStyle(Brand.fg)
                    .textContentType(.password)
                    .submitLabel(.go)
                    .onSubmit { model.unlock() }
                if !model.masterInput.isEmpty {
                    Button { model.unlock() } label: {
                        Image(systemName: "arrow.right.circle.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(Brand.accent)
                    }
                    .frame(width: 44, height: 44)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 48)
            .background(Brand.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 28)
            .padding(.top, 22)

            if model.showUnlockError {
                Text(L10n.t("ios_af_wrong_password_text"))
                    .font(.system(size: 13))
                    .foregroundStyle(Brand.red)
                    .padding(.top, 10)
            }

            if model.showBiometricButton {
                Button { Task { await model.unlockWithBiometrics() } } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "faceid")
                            .font(.system(size: 30))
                        Text(L10n.t("ios_af_faceid_button"))
                            .font(.system(size: 12))
                    }
                    .foregroundStyle(Brand.accent)
                    .frame(width: 88, height: 72)
                }
                .disabled(model.biometricWorking)
                .padding(.top, 24)
            }
            Spacer()
        }
    }

    // MARK: 通行密钥注册

    private var registerView: some View {
        VStack(spacing: 18) {
            Spacer()
            BrandLogo(size: 72)
            if let info = model.registrationInfo {
                Text(L10n.t("ios_af_passkey_create_title"))
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Brand.fg)
                Text(String(format: L10n.t("ios_af_passkey_for_fmt"), info.relyingParty))
                    .font(.system(size: 15))
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .foregroundStyle(Brand.muted)
                HStack(spacing: 10) {
                    Image(systemName: "person.fill")
                        .foregroundStyle(Brand.accent)
                    Text(info.userName)
                        .font(.system(size: 15))
                        .foregroundStyle(Brand.fg)
                        .lineLimit(1)
                }
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(Brand.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            if model.registerError {
                Text(L10n.t("ios_af_passkey_save_error"))
                    .font(.system(size: 13))
                    .foregroundStyle(Brand.red)
            }
            Button { model.registerPasskey() } label: {
                Text(L10n.t("ios_create_button"))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Brand.accent)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(Brand.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            Spacer()
        }
        .padding(.horizontal, 28)
    }

    // MARK: 凭证列表

    private var listView: some View {
        VStack(spacing: 0) {
            // 搜索框
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Brand.muted)
                TextField(L10n.t("ios_af_search_prompt"), text: $model.query)
                    .font(.system(size: 16))
                    .foregroundStyle(Brand.fg)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                if !model.query.isEmpty {
                    Button { model.query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Brand.muted)
                    }
                    .frame(width: 30, height: 30)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(Brand.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18, pinnedViews: []) {
                    if !model.suggested.isEmpty {
                        group(title: model.serviceHostLabel.map { String(format: L10n.t("ios_af_matched_host_fmt"), $0) }
                              ?? L10n.t("ios_af_suggested_title"),
                              cards: model.suggested)
                    }
                    if !model.others.isEmpty {
                        group(title: model.suggested.isEmpty ? L10n.t("ios_af_all_items_title") : L10n.t("ios_af_other_items_title"),
                              cards: model.others)
                    }
                    if model.suggested.isEmpty && model.others.isEmpty {
                        Text(emptyListText)
                            .font(.system(size: 15))
                            .foregroundStyle(Brand.muted)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 60)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
    }

    /// 列表为空的提示文案(按流区分)。
    private var emptyListText: String {
        if !model.query.isEmpty { return String(format: L10n.t("ios_af_no_match_fmt"), model.query) }
        if model.flow == .passkey { return L10n.t("ios_af_no_passkeys_text") }
        return L10n.t("ios_af_no_fillable_text")
    }

    private func group(title: String, cards: [Card]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Brand.muted)
                .padding(.leading, 12)
            VStack(spacing: 0) {
                ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                    row(card)
                    if index < cards.count - 1 {
                        Divider()
                            .background(Brand.elev)
                            .padding(.leading, 66)
                    }
                }
            }
            .background(Brand.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func row(_ card: Card) -> some View {
        Button { model.pick(card) } label: {
            HStack(spacing: 12) {
                CardIconView(card: card, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.title)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Brand.fg)
                        .lineLimit(1)
                    // 通行密钥显示凭据用户名;验证码条目可能没有登录名,退而显示站点
                    let subtitle: String = {
                        if model.flow == .passkey { return card.passkey?.userName ?? "" }
                        return !card.login.isEmpty ? card.login : card.website
                    }()
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 13))
                            .foregroundStyle(Brand.muted)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if model.flow == .oneTimeCode {
                    otpCode(card)
                }
                if model.pickedID == card.id {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(Brand.green)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 13)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.3), value: model.pickedID)
    }

    /// 验证码流行尾:实时 TOTP(每秒刷新,3 位分组便于燈抄)。
    @ViewBuilder
    private func otpCode(_ card: Card) -> some View {
        if let field = card.fields.first(where: { $0.type.isOneTimePassword }),
           let config = try? TOTP.parse(field.value) {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(groupedCode((try? TOTP.code(config: config, at: ctx.date)) ?? "——————"))
                    .font(.system(size: 15, design: .monospaced).weight(.semibold))
                    .foregroundStyle(Brand.green)
            }
        }
    }

    /// 6/8 位验证码按 3 位分组显示。
    private func groupedCode(_ code: String) -> String {
        var rest = Array(code.filter { $0 != " " })
        var groups: [String] = []
        while !rest.isEmpty {
            groups.append(String(rest.prefix(3)))
            rest.removeFirst(min(3, rest.count))
        }
        return groups.joined(separator: " ")
    }
}
