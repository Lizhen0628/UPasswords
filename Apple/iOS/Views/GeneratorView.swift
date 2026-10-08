import SwiftUI

import UPasswordsCore

// MARK: - 密码生成器 Tab

struct GeneratorView: View {
    @EnvironmentObject var vault: Vault
    @ObservedObject private var settings = PasswordSettings.shared

    @State private var current: String = ""
    @State private var historyRefresh = false

    private var modes: [String] {
        [L10n.t("ios_gen_mode_random"), L10n.t("ios_gen_mode_memorable"),
         L10n.t("ios_gen_mode_alphanumeric"), L10n.t("ios_gen_mode_digits")]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                outputCard
                modeSection
                optionsSection
                historySection
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .background(Brand.bg)
        .navigationTitle(L10n.t("ios_tab_generator"))
        // 仅在首次进入时生成:onAppear 每次 regenerate 会往历史里灌噪音条目
        .onAppear { if current.isEmpty { regenerate() } }
    }

    // MARK: 输出卡片

    private var outputCard: some View {
        VStack(spacing: 14) {
            Text(current)
                .font(.system(.title3, design: .monospaced).weight(.semibold))
                .foregroundStyle(Brand.fg)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
            StrengthBar(score: PasswordStrength.score(current).score)
            HStack(spacing: 12) {
                Button { vault.copyToClipboard(current, label: L10n.t("ios_password_copied_message")) } label: {
                    Label(L10n.t("copy_command"), systemImage: "doc.on.doc")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Brand.accent)
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .background(Brand.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                Button(action: regenerate) {
                    Label(L10n.t("ios_refresh_button"), systemImage: "arrow.clockwise")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Brand.fg)
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .background(Brand.fg.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }
        .padding(16)
        .background(Brand.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: 模式

    private var modeSection: some View {
        BrandSection(title: L10n.t("ios_gen_type_section")) {
            Picker(L10n.t("ios_gen_type_section"), selection: $settings.passwordType) {
                ForEach(0..<4, id: \.self) { Text(modes[$0]).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(12)
            .onChange(of: settings.passwordType) { _ in regenerate() }
        }
    }

    // MARK: 选项

    private var optionsSection: some View {
        BrandSection(title: L10n.t("ios_gen_options_section")) {
            optionRow {
                Text(L10n.t("ios_gen_length_label")).foregroundStyle(Brand.fg)
                Slider(value: Binding(
                    get: { Double(settings.passwordLength) },
                    set: { settings.passwordLength = Int($0) }
                ), in: 4...64, step: 1)
                .tint(Brand.accent)
                Text("\(settings.passwordLength)")
                    .font(.body.monospaced())
                    .foregroundStyle(Brand.muted)
                    .frame(width: 30, alignment: .trailing)
            }
            .onChange(of: settings.passwordLength) { _ in regenerate() }
            if settings.passwordType == 0 {
                InsetDivider()
                optionRow {
                    Text(L10n.t("ios_gen_symbols_label")).foregroundStyle(Brand.fg)
                    Spacer()
                    TextField("!@#$…", text: $settings.symbolsAlphabet)
                        .font(.body.monospaced())
                        .multilineTextAlignment(.trailing)
                        .frame(width: 160)
                }
                .onChange(of: settings.symbolsAlphabet) { _ in regenerate() }
            }
            if settings.passwordType == 1 {
                InsetDivider()
                optionRow {
                    Text(L10n.t("ios_gen_separator_label")).foregroundStyle(Brand.fg)
                    Spacer()
                    TextField("-_.", text: $settings.separatorAlphabet)
                        .font(.body.monospaced())
                        .multilineTextAlignment(.trailing)
                        .frame(width: 100)
                }
                .onChange(of: settings.separatorAlphabet) { _ in regenerate() }
            }
            InsetDivider()
            optionRow {
                Toggle(L10n.t("ios_gen_exclude_similar_toggle"), isOn: $settings.excludeSimilarCharacters)
                    .foregroundStyle(Brand.fg)
                    .tint(Brand.accent)
            }
            .onChange(of: settings.excludeSimilarCharacters) { _ in regenerate() }
        }
    }

    private func optionRow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 12) { content() }
            .font(.subheadline)
            .padding(.horizontal, 16)
            .frame(minHeight: 46)
    }

    // MARK: 历史

    private var historySection: some View {
        BrandSection(title: L10n.t("ios_gen_history_section")) {
            let history = PasswordGenerator.instance.history
            if history.isEmpty {
                Text(L10n.t("ios_gen_history_empty"))
                    .font(.subheadline)
                    .foregroundStyle(Brand.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            } else {
                ForEach(Array(history.enumerated()), id: \.offset) { i, pw in
                    HStack(spacing: 10) {
                        Text(pw)
                            .font(.subheadline.monospaced())
                            .foregroundStyle(Brand.fg)
                            .lineLimit(1)
                        Spacer()
                        StrengthBar(score: PasswordStrength.score(pw).score)
                        Button { vault.copyToClipboard(pw) } label: {
                            Image(systemName: "doc.on.doc")
                                .foregroundStyle(Brand.muted)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 42)
                    if i < history.count - 1 { InsetDivider() }
                }
                InsetDivider()
                Button(role: .destructive) {
                    PasswordGenerator.instance.clearHistory()
                    historyRefresh.toggle()
                    vault.showToast(L10n.t("ios_gen_history_cleared_message"))
                } label: {
                    Text(L10n.t("ios_gen_clear_history_button"))
                        .font(.subheadline)
                        .foregroundStyle(Brand.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .frame(height: 42)
                }
                .buttonStyle(.plain)
            }
        }
        .id(historyRefresh)
    }

    private func regenerate() {
        let s = PasswordSettings.shared
        current = PasswordGenerator.instance.password(length: s.passwordLength, type: s.passwordType)
        PasswordGenerator.instance.addPasswordToHistory(current)
        historyRefresh.toggle()
    }
}
