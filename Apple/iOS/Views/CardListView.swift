import SwiftUI

import UPasswordsCore

// MARK: - 列表筛选器

enum CardFilter: Hashable {
    case all, passkeys, otp, wifi, trash, favorites, finance, notes, expiring, archived
    case label(Int, String)

    var title: String {
        switch self {
        case .all: return L10n.t("ios_tile_all")
        case .passkeys: return L10n.t("ios_tile_passkeys")
        case .otp: return L10n.t("ios_tile_otp")
        case .wifi: return L10n.t("ios_tile_wifi")
        case .trash: return L10n.t("ios_trash_title")
        case .favorites: return L10n.t("ios_cat_favorites")
        case .finance: return L10n.t("ios_cat_finance")
        case .notes: return L10n.t("ios_cat_notes")
        case .expiring: return L10n.t("ios_cat_expiring")
        case .archived: return L10n.t("ios_cat_archived")
        case .label(_, let name): return name
        }
    }

    var isTrash: Bool { self == .trash }

    @MainActor
    func cards(in vault: Vault) -> [Card] {
        switch self {
        case .all: return vault.visibleCards
        case .passkeys: return vault.passkeyCards
        case .otp: return vault.otpCards
        case .wifi: return vault.wifiCards
        case .trash: return vault.trashedCards
        case .favorites: return vault.favoriteCards
        case .finance: return vault.financeCards
        case .notes: return vault.noteCards
        case .expiring: return vault.expiringCards
        case .archived: return vault.archivedCards
        case .label(let id, _): return vault.activeCards.filter { $0.labelIds.contains(id) }
        }
    }
}

// MARK: - 条目行(列表 / 首页最近使用 / 搜索结果共用)

struct CardRowView: View {
    let card: Card

    var body: some View {
        HStack(spacing: 12) {
            CardIconView(card: card, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(card.title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(Brand.fg)
                        .lineLimit(1)
                    if card.favorite {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(Brand.yellow)
                    }
                }
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(Brand.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                if card.compromised {
                    Image(systemName: "exclamationmark.shield.fill")
                        .foregroundStyle(Brand.red)
                } else if card.hasWeakPasswords {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Brand.yellow)
                }
                if card.isExpiring {
                    Text(String(format: L10n.t("ios_days_fmt"), card.expiringInDays))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Brand.yellow)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Brand.yellow.opacity(0.14), in: Capsule())
                }
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Brand.fg.opacity(0.25))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        if !card.login.isEmpty { return card.login }
        if !card.website.isEmpty { return card.website }
        if card.hasNotes { return L10n.t("ios_secure_note_text") }
        return card.fields.first(where: { $0.hasValue })?.value ?? L10n.t("ios_unfilled_text")
    }
}

// MARK: - 条目列表(拼音分组 + 排序 + 收藏置顶 + 长按菜单)

struct CardListView: View {
    @EnvironmentObject var vault: Vault
    let filter: CardFilter

    @State private var showEmptyTrashConfirm = false
    @State private var showTemplatePicker = false
    @State private var editDraft: Card? = nil

    var body: some View {
        let all = filter.cards(in: vault)
        let sorted = vault.sortOrder.sorted(all)
        let favorites = vault.pinFavorites ? sorted.filter { $0.favorite } : []
        let rest = vault.pinFavorites ? sorted.filter { !$0.favorite } : sorted
        let grouped = Dictionary(grouping: rest) { pinyinInitial($0.title) }
        let keys = grouped.keys.sorted { a, b in
            if a == "#" { return false }
            if b == "#" { return true }
            return a < b
        }

        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if all.isEmpty {
                    EmptyStateView(
                        icon: filter.isTrash ? "trash" : "key",
                        title: filter.isTrash ? L10n.t("ios_trash_empty_title") : L10n.t("ios_no_items_title"),
                        detail: filter.isTrash ? L10n.t("ios_trash_empty_detail") : L10n.t("ios_no_items_detail")
                    )
                    .background(Brand.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                } else {
                    if !favorites.isEmpty {
                        sectionView(title: L10n.t("ios_cat_favorites"), cards: favorites)
                    }
                    ForEach(keys, id: \.self) { key in
                        sectionView(title: key, cards: grouped[key] ?? [])
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .background(Brand.bg)
        .navigationTitle(filter.title)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 14) {
                    if filter.isTrash, !all.isEmpty {
                        Button(role: .destructive) { showEmptyTrashConfirm = true } label: {
                            Text(L10n.t("ios_empty_button"))
                        }
                    }
                    // 空态文案指引「右上角 +」,此处必须真实提供;回收站不新建
                    if !filter.isTrash {
                        Button { showTemplatePicker = true } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.title3)
                                .foregroundStyle(Brand.accent)
                        }
                        .accessibilityLabel(L10n.t("ios_new_item_button"))
                    }
                    sortMenu
                }
            }
        }
        .confirmationDialog(L10n.t("ios_empty_trash_query"), isPresented: $showEmptyTrashConfirm, titleVisibility: .visible) {
            Button(L10n.t("ios_purge_all_button"), role: .destructive) { vault.emptyTrash() }
            Button(L10n.t("cancel_button"), role: .cancel) {}
        } message: {
            Text(L10n.t("ios_irreversible_warning"))
        }
        .sheet(isPresented: $showTemplatePicker) {
            // 与首页一致:选模板后先收起选择器再弹编辑页,避免同屏双 sheet 冲突
            TemplatePickerView { card in
                showTemplatePicker = false
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(350))
                    editDraft = card
                }
            }
        }
        .sheet(item: $editDraft) { draft in
            CardEditView(draft: draft, isNew: true)
        }
    }

    private func sectionView(title: String, cards: [Card]) -> some View {
        BrandSection(title: title) {
            ForEach(Array(cards.enumerated()), id: \.element.id) { i, card in
                NavigationLink(value: card) { CardRowView(card: card) }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if filter.isTrash {
                            Button { vault.restore(card) } label: { Label(L10n.t("ios_restore_button"), systemImage: "arrow.uturn.backward") }
                            Button(role: .destructive) { vault.deletePermanently(card) } label: { Label(L10n.t("ios_purge_button"), systemImage: "trash") }
                        } else {
                            Button { vault.toggleFavorite(card) } label: {
                                Label(card.favorite ? L10n.t("ios_unfavorite_button") : L10n.t("ios_cat_favorites"),
                                      systemImage: card.favorite ? "star.slash" : "star")
                            }
                            if let pw = card.passwordField?.value, !pw.isEmpty {
                                Button { vault.copyToClipboard(pw, label: L10n.t("ios_password_copied_message")) } label: {
                                    Label(L10n.t("ios_copy_password_button"), systemImage: "doc.on.doc")
                                }
                            }
                            Button { vault.duplicate(card) } label: { Label(L10n.t("ios_duplicate_button"), systemImage: "plus.square.on.square") }
                            Divider()
                            Button(role: .destructive) { vault.trash(card) } label: { Label(L10n.t("delete_button"), systemImage: "trash") }
                        }
                    }
                if i < cards.count - 1 { InsetDivider(leading: 68) }
            }
        }
    }

    private var sortMenu: some View {
        Menu {
            Toggle(isOn: Binding(get: { vault.pinFavorites }, set: { vault.pinFavorites = $0 })) {
                Label(L10n.t("ios_pin_favorites_toggle"), systemImage: "star")
            }
            Divider()
            Picker(L10n.t("ios_sort_picker_title"), selection: Binding(get: { vault.sortOrder }, set: { vault.sortOrder = $0 })) {
                ForEach(SortOrder.allCases) { order in
                    Text(order.name).tag(order)
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down.circle")
                .font(.title3)
                .foregroundStyle(Brand.accent)
        }
        .accessibilityLabel(L10n.t("ios_sort_a11y"))
    }
}
