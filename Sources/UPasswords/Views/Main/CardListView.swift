import SwiftUI

// MARK: - Card list (search field inside the pane top, generator + sync
// buttons at the right, 48pt rows)

struct CardListView: View {
    @EnvironmentObject var ctx: AppContext
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            list
        }
        .background(Color.appBackground)
        .overlay {
            if cards.isEmpty {
                emptyState
            }
        }
    }

    private var cards: [Card] {
        ctx.cards(for: ctx.selection, search: ctx.searchText)
    }

    /// Search row:搜索框 25.5pt 高、同底色 + 极淡描边;右侧
    /// 「盾牌 + 云朵」全黄连体胶囊 59.5×27.5pt(生成器 / 云同步)。
    private var header: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.45))
                TextField(L10n.t("search_text"), text: $ctx.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                if !ctx.searchText.isEmpty {
                    Button {
                        ctx.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.white.opacity(0.45))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 25.5)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.012)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.05), lineWidth: 1))

            syncCapsule
                .padding(.leading, 8)
        }
        .padding(.leading, 8.5)
        .padding(.trailing, 6.5)
        .padding(.top, 6)
        .padding(.bottom, 6)
    }

    /// 黄色胶囊:仅云同步菜单(密码生成器已上移到顶部工具栏)。
    /// 黄底尺寸随内容自适应;搜索框用 maxWidth:.infinity 自动占满剩余宽度。
    private var syncCapsule: some View {
        Menu {
            Button(L10n.t("sync_command")) { Task { await ctx.sync() } }
            Divider()
            Button(L10n.t("manage_databases_command")) { ctx.activeSheet = .manageDatabases }
            Button(L10n.t("configure_cloud_command")) {
                ctx.activeSheet = .configureCloud
            }
        } label: {
            Image(systemName: "icloud.fill")
                .font(.system(size: 15))
                .foregroundStyle(.white)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        // 正圆样式:图标居中,四周留白相等(直径 26,图标 15,四周各 5.5pt)
        .frame(width: 26, height: 26)
        .background(Color(red: 0.30, green: 0.66, blue: 0.96))   // 天蓝色
        .clipShape(Circle())
        .help(L10n.t("sync_command"))
    }

    private var list: some View {
        List(selection: $ctx.selectedCardId) {
            ForEach(cards) { card in
                CardListCellView(card: card, preview: ctx.searchText.isEmpty ? nil : ctx.searchPreview(for: card, word: String(ctx.searchText.lowercased().split(separator: " ").first ?? "")))
                    .tag(card.id)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    .frame(height: 48)
                    .contextMenu {
                        cardContextMenu(card)
                    }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .onAppear {
            // 进入主界面后始终有选中项
            if ctx.selectedCardId == nil { ctx.selectedCardId = cards.first?.id }
        }
        .onChange(of: ctx.selectedCardId) { _, id in
            if let id {
                ctx.pushRecent(id)
                ctx.touch()
            }
        }
    }

    /// 列表右键菜单。
    @ViewBuilder
    private func cardContextMenu(_ card: Card) -> some View {
        Button(L10n.t("add_card_command")) { ctx.activeSheet = .addCard }
        Button(L10n.t("add_note_command")) { ctx.activeSheet = .addNote }
        Button(L10n.t("add_template_command")) { ctx.activeSheet = .addCard }
        Divider()
        Button(L10n.t("edit_command")) { ctx.editDraft = EditCardModel(card: card) }
        Button(L10n.t("delete_command")) { ctx.trashCard(card.id) }
        Button(L10n.t("move_command")) { ctx.activeSheet = .labels(cardId: card.id) }
        Button(L10n.t("duplicate_command")) { ctx.duplicateCard(card.id) }
        Button(L10n.t("merge_command")) {}
        Button(L10n.t("save_as_template_command")) {
            var t = card
            t.template = true
            t.id = ctx.newCardId()
            ctx.database.cards.append(t)
        }
        if card.archived {
            Button(L10n.t("unarchive_command")) { ctx.unarchiveCard(card.id) }
        } else {
            Button(L10n.t("archive_command")) { ctx.archiveCard(card.id) }
        }
        if card.trashed {
            Button(L10n.t("restore_card_command")) { ctx.restoreCard(card.id) }
        }
        Divider()
        Button(L10n.t("copy_as_text_command")) {
            ClipboardModel.shared.copy(card.asPlainText())
        }
        Menu(L10n.t("share_menu")) {
            Button(L10n.t("export_command")) { ctx.activeSheet = .exportAs }
        }
        Divider()
        Button(L10n.t("set_labels_command")) { ctx.activeSheet = .labels(cardId: card.id) }
        Button(L10n.t("use_website_icon_command")) {
            ctx.toggleUseWebsiteIcon(cardId: card.id)
        }
        Button(L10n.t("select_symbol_command")) { ctx.activeSheet = .selectSymbol }
        Button(L10n.t("select_color_command")) { ctx.activeSheet = .selectColor }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text(emptyStateText)
                .font(.system(size: 13))
                .foregroundStyle(Color.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 280)
        }
        .padding()
    }

    private var emptyStateText: String {
        switch ctx.selection {
        case .special(let sp): return sp.emptyState
        case .label: return L10n.t("user_empty_state")
        }
    }
}

/// CardListCell — 35pt circular icon at (7,7); title over subtitle at x=52
/// (single centered title when there is no subtitle); blue one-time-password
/// icon and star button at the right edge.
struct CardListCellView: View {
    @EnvironmentObject var ctx: AppContext
    @EnvironmentObject var settings: AppSettings
    let card: Card
    let preview: String?

    var body: some View {
        HStack(spacing: 0) {
            CardIconView(symbol: card.symbol, color: card.color, size: 35,
                         creditCardNumber: card.fields.first { $0.type == .number }?.value,
                         card: card)
                .padding(.leading, 7)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(card.title.isEmpty ? "—" : card.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if card.isExpired {
                        Image(systemName: "clock.badge.exclamationmark").font(.caption2).foregroundStyle(.red)
                    } else if card.isExpiring {
                        Image(systemName: "hourglass").font(.caption2).foregroundStyle(.orange)
                    }
                    if card.hasWeakPasswords {
                        Image(systemName: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.red)
                    }
                }
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.leading, 10)
            .frame(maxHeight: .infinity, alignment: subtitle.isEmpty ? .center : .top)
            .padding(.top, subtitle.isEmpty ? 0 : 7)
            Spacer(minLength: 8)
            if card.fields.contains(where: { $0.type == .oneTimePassword }) {
                Image(systemName: "timer")
                    .font(.system(size: 14))
                    .foregroundStyle(.blue)
                    .frame(width: 32, height: 32)
            }
            Button {
                ctx.toggleFavorite(card.id)
            } label: {
                Image(systemName: card.favorite ? "star.fill" : "star")
                    .font(.system(size: 14))
                    .foregroundStyle(card.favorite ? .yellow : .secondary.opacity(0.4))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 4)
        }
        .frame(height: 48)
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        if let preview { return preview }
        if card.login.isEmpty {
            return card.fields.first(where: { $0.hasValue })?.value ?? ""
        }
        return card.login
    }
}

