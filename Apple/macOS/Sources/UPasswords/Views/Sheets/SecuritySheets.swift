import SwiftUI
import UPasswordsCore
import UPasswordsPersistence

/// 云同步弹窗内容统一列宽:480 弹窗宽 − 左右各 14 内边距。
/// 说明文字钳制到该宽度,避免撑宽弹窗导致单选组位移。
private let cloudSheetContentWidth: CGFloat = 452

// MARK: - Compromised passwords

struct CompromisedSheet: View {
    @EnvironmentObject var ctx: AppContext
    @Environment(\.dismiss) var dismiss

    @State private var running = false
    @State private var compromisedCards: [Card] = []
    @State private var offline = false
    @State private var resultText = ""

    var body: some View {
        SheetShell(
            title: L10n.t("compromised_passwords_title"),
            minWidth: 520,
            minHeight: 400,
            okTitle: L10n.t("close_button"),
            onCancel: { dismiss() },
            onOk: { dismiss() },
            content: {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.t("compromised_passwords_text"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button {
                            Task { await check(online: true) }
                        } label: {
                            if running {
                                ProgressView().controlSize(.small)
                            } else {
                                Label(L10n.t("check_passwords_button"), systemImage: "magnifyingglass")
                            }
                        }
                        .disabled(running)
                        Button(L10n.t("offline_button", fallback: "离线检查")) {
                            Task { await check(online: false) }
                        }
                        .disabled(running)
                        Spacer()
                        if !resultText.isEmpty {
                            Text(resultText).font(.callout)
                        }
                    }
                    List {
                        ForEach(compromisedCards) { card in
                            Button {
                                ctx.selectedCardId = card.id
                                dismiss()
                            } label: {
                                HStack {
                                    CardIconView(symbol: card.symbol, color: card.color, size: 26, card: card)
                                    Text(card.title)
                                    Spacer()
                                    Image(systemName: "exclamationmark.shield.fill").foregroundStyle(.red)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    // 滚动容器需显式高度,否则在 Sheet 里塌缩为 0
                    .frame(height: 200)
                    .overlay {
                        if compromisedCards.isEmpty && !running {
                            Text(L10n.t("compromised_passwords_empty_state"))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: 360)
                                .multilineTextAlignment(.center)
                        }
                    }
                }
            }
        )
    }

    private func check(online: Bool) async {
        running = true
        compromisedCards = []
        let outcome = await ctx.checkCompromisedPasswords(online: online)
        offline = outcome.result.offline
        compromisedCards = outcome.cards
        resultText = "\(L10n.t("compromised_passwords_found_text")) \(compromisedCards.count)" + (offline ? " (offline)" : "")
        running = false
    }
}


// MARK: - Configure cloud

/// 云同步设置弹窗(向导「后续步骤」入口):承载与设置页云面板相同的
/// 账户中继内容——登录/设备管理与自动同步开关。同步通道只有账户中继,
/// 网盘(iCloud/WebDAV)配置已移除。
struct ConfigureCloudSheet: View {
    @Environment(\.dismiss) var dismiss

    var body: some View {
        SheetShell(
            title: L10n.t("cloud_sync_title"),
            minWidth: 480,
            okTitle: L10n.t("ok_button"),
            onCancel: { dismiss() },
            onOk: { dismiss() },
            content: {
                ConfigureCloudSheetContents()
                    .frame(width: cloudSheetContentWidth, alignment: .leading)
            }
        )
    }
}


// MARK: - Sync conflict

/// 同步冲突决策弹窗:本地与云端自上次同步后都有修改时,由用户决定覆盖方向。
/// 「稍后」丢弃暂存现场,下次同步重新检测;两个覆盖动作都不可撤销,故
/// 不设默认按钮(Enter 走「稍后」安全项,两个覆盖必须显式点击)。
struct SyncConflictSheet: View {
    @EnvironmentObject var ctx: AppContext
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Text(L10n.t("sync_conflict_title"))
                .font(.headline)
                .padding(.top, 14).padding(.bottom, 10)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.t("sync_conflict_text"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let conflict = ctx.pendingSyncConflict {
                    Text(String(format: L10n.t("sync_conflict_local_state"), conflict.localCards, conflict.localLabels))
                        .font(.callout)
                    Text(String(format: L10n.t("sync_conflict_remote_state"), conflict.remoteCards, conflict.remoteLabels))
                        .font(.callout)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            HStack {
                Button(L10n.t("sync_conflict_postpone")) {
                    ctx.postponeSyncConflict()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button(L10n.t("sync_conflict_use_remote")) {
                    Task { await ctx.resolveSyncConflict(useLocal: false) }
                    dismiss()
                }
                Button(L10n.t("sync_conflict_use_local")) {
                    Task { await ctx.resolveSyncConflict(useLocal: true) }
                    dismiss()
                }
            }
            .padding(10)
        }
        .frame(minWidth: 440, minHeight: 180)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
