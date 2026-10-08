import SwiftUI

import UPasswordsCore

// MARK: - 首页(密码 Tab):搜索 + 六宫格 + 类别 + 标签 + 最近使用

struct HomeView: View {
    @EnvironmentObject var vault: Vault
    @Binding var selectedTab: Int

    @State private var searchText = ""
    /// 防抖后真正参与过滤的搜索词(与 macOS 同一套 SearchInputDebouncer,
    /// 逐键只记录文本,停顿 500ms 后一次性应用,清空立即恢复)。
    @State private var searchQuery = ""
    @State private var searchDebouncer: SearchInputDebouncer? = nil
    @State private var showTemplatePicker = false
    @State private var editDraft: Card? = nil
    @State private var labelEditor: CardLabel? = nil
    @State private var labelPendingDelete: CardLabel? = nil
    @State private var showNewLabel = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if searchQuery.isEmpty {
                    gridSection
                    categorySection
                    labelSection
                    recentSection
                } else {
                    searchResults
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .background(Brand.bg)
        .navigationTitle(L10n.t("ios_tab_passwords"))
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: L10n.t("ios_search_prompt"))
        .onChange(of: searchText) { newText in
            searchDebouncer?.textChanged(newText)
        }
        .onAppear {
            if searchDebouncer == nil {
                searchDebouncer = SearchInputDebouncer(interval: .milliseconds(500)) { text in
                    searchQuery = text
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showTemplatePicker = true } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Brand.accent)
                }
                .accessibilityLabel(L10n.t("ios_new_item_button"))
            }
        }
        .sheet(isPresented: $showTemplatePicker) {
            TemplatePickerView { card in
                showTemplatePicker = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { editDraft = card }
            }
        }
        .sheet(item: $editDraft) { draft in
            CardEditView(draft: draft, isNew: true)
        }
        .sheet(isPresented: $showNewLabel) { LabelEditorSheet(label: nil) }
        .sheet(item: $labelEditor) { label in
            LabelEditorSheet(label: label)
        }
        .confirmationDialog(L10n.t("delete_label_query"), isPresented: Binding(
            get: { labelPendingDelete != nil },
            set: { if !$0 { labelPendingDelete = nil } }
        ), titleVisibility: .visible) {
            Button(L10n.t("delete_button"), role: .destructive) {
                if let label = labelPendingDelete {
                    vault.deleteLabel(label)
                    vault.showToast(L10n.t("ios_label_deleted_message"))
                }
                labelPendingDelete = nil
            }
            Button(L10n.t("cancel_button"), role: .cancel) { labelPendingDelete = nil }
        }
        .navigationDestination(for: CardFilter.self) { filter in
            CardListView(filter: filter)
        }
        .navigationDestination(for: Card.self) { card in
            CardDetailView(cardID: card.id)
        }
    }

    // MARK: 六宫格

    private var gridSection: some View {
        let tiles: [(icon: String, tint: Color, title: String, count: Int, filter: CardFilter?)] = [
            ("key.fill", Brand.accent, L10n.t("ios_tile_all"), vault.visibleCards.count, .all),
            ("person.badge.key.fill", Brand.accent, L10n.t("ios_tile_passkeys"), vault.passkeyCards.count, .passkeys),
            ("timer.circle.fill", Brand.green, L10n.t("ios_tile_otp"), vault.otpCards.count, .otp),
            ("wifi", Brand.accent, L10n.t("ios_tile_wifi"), vault.wifiCards.count, .wifi),
            ("shield.lefthalf.filled", Brand.red, L10n.t("ios_tile_security"),
             vault.weakCards.count + vault.compromisedCards.count + vault.reusedCards.count, nil),
            ("trash.fill", Brand.muted, L10n.t("ios_tile_trash"), vault.trashedCards.count, .trash),
        ]
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            ForEach(0..<tiles.count, id: \.self) { i in
                let t = tiles[i]
                Group {
                    if let filter = t.filter {
                        NavigationLink(value: filter) { tile(icon: t.icon, tint: t.tint, title: t.title, count: t.count) }
                            .buttonStyle(.plain)
                    } else {
                        Button { selectedTab = 1 } label: { tile(icon: t.icon, tint: t.tint, title: t.title, count: t.count) }
                            .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func tile(icon: String, tint: Color, title: String, count: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(tint)
            Spacer()
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Brand.fg)
            Text("\(count)")
                .font(.footnote)
                .foregroundStyle(Brand.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 92)
        .padding(14)
        .background(Brand.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: 类别

    private var categorySection: some View {
        let rows: [(icon: String, tint: Color, title: String, count: Int, filter: CardFilter)] = [
            ("star.fill", Brand.yellow, L10n.t("ios_cat_favorites"), vault.favoriteCards.count, .favorites),
            ("creditcard.fill", Brand.accent, L10n.t("ios_cat_finance"), vault.financeCards.count, .finance),
            ("doc.plaintext.fill", Brand.accent, L10n.t("ios_cat_notes"), vault.noteCards.count, .notes),
            ("hourglass", Brand.yellow, L10n.t("ios_cat_expiring"), vault.expiringCards.count, .expiring),
            ("archivebox.fill", Brand.muted, L10n.t("ios_cat_archived"), vault.archivedCards.count, .archived),
        ]
        return BrandSection(title: L10n.t("ios_cat_section_title")) {
            ForEach(0..<rows.count, id: \.self) { i in
                let r = rows[i]
                NavigationLink(value: r.filter) {
                    HStack(spacing: 12) {
                        Image(systemName: r.icon)
                            .font(.body)
                            .foregroundStyle(r.tint)
                            .frame(width: 26)
                        Text(r.title).foregroundStyle(Brand.fg)
                        Spacer()
                        Text("\(r.count)").foregroundStyle(Brand.muted)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Brand.fg.opacity(0.25))
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 46)
                }
                .buttonStyle(.plain)
                if i < rows.count - 1 { InsetDivider(leading: 54) }
            }
        }
    }

    // MARK: 标签

    private var labelSection: some View {
        BrandSection(title: L10n.t("ios_labels_section_title")) {
            VStack(alignment: .leading, spacing: 0) {
                FlowChips {
                    ForEach(vault.labels) { label in
                        NavigationLink(value: CardFilter.label(label.id, label.name)) {
                            labelChip(label)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button { labelEditor = label } label: {
                                Label(L10n.t("ios_edit_label_title"), systemImage: "pencil")
                            }
                            Button(role: .destructive) { labelPendingDelete = label } label: {
                                Label(L10n.t("delete_button"), systemImage: "trash")
                            }
                        }
                    }
                    Button { showNewLabel = true } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "plus")
                            Text(L10n.t("ios_new_label_button"))
                        }
                        .font(.subheadline)
                        .foregroundStyle(Brand.accent)
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .background(Brand.accent.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(16)
            }
        }
    }

    private func labelChip(_ label: CardLabel) -> some View {
        let tint = Brand.tileColor(label.color)
        let count = vault.activeCards.filter { $0.labelIds.contains(label.id) }.count
        return HStack(spacing: 6) {
            Circle().fill(tint).frame(width: 8, height: 8)
            Text(label.name)
            Text("\(count)").foregroundStyle(Brand.muted)
        }
        .font(.subheadline)
        .foregroundStyle(Brand.fg)
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(Brand.fg.opacity(0.07), in: Capsule())
    }

    // MARK: 最近使用

    @ViewBuilder
    private var recentSection: some View {
        BrandSection(title: L10n.t("ios_recent_section_title")) {
            let recents = vault.recentCards
            if recents.isEmpty {
                Text(L10n.t("ios_recent_empty"))
                    .font(.subheadline)
                    .foregroundStyle(Brand.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            } else {
                ForEach(Array(recents.enumerated()), id: \.element.id) { i, card in
                    NavigationLink(value: card) { CardRowView(card: card) }
                        .buttonStyle(.plain)
                    if i < recents.count - 1 { InsetDivider(leading: 68) }
                }
            }
        }
    }

    // MARK: 搜索结果(防抖后的查询)

    private var searchResults: some View {
        let results = vault.search(searchQuery)
        return BrandSection(title: String(format: L10n.t("ios_search_results_fmt"), results.count)) {
            if results.isEmpty {
                VStack(spacing: 6) {
                    Text(String(format: L10n.t("ios_search_not_found_fmt"), searchQuery))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Brand.fg)
                    Text(L10n.t("ios_search_not_found_hint"))
                        .font(.footnote)
                        .foregroundStyle(Brand.muted)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 36)
            } else {
                ForEach(Array(results.enumerated()), id: \.element.id) { i, card in
                    NavigationLink(value: card) { CardRowView(card: card) }
                        .buttonStyle(.plain)
                    if i < results.count - 1 { InsetDivider(leading: 68) }
                }
            }
        }
    }
}

// MARK: - 新建 / 编辑标签弹层

struct LabelEditorSheet: View {
    @EnvironmentObject var vault: Vault
    @Environment(\.dismiss) private var dismiss

    /// nil = 新建;非 nil = 编辑既有标签(重命名/改色)。
    let label: CardLabel?

    @State private var name = ""
    @State private var color = "blue"

    private let colors = ["blue", "green", "yellow", "red", "purple", "teal", "gray"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L10n.t("ios_label_name_prompt"), text: $name)
                }
                Section(L10n.t("ios_label_color_section")) {
                    HStack(spacing: 14) {
                        ForEach(colors, id: \.self) { c in
                            Circle()
                                .fill(Brand.tileColor(c))
                                .frame(width: 30, height: 30)
                                .overlay(
                                    Circle()
                                        .strokeBorder(Brand.fg, lineWidth: color == c ? 2 : 0)
                                        .padding(-4)
                                )
                                .onTapGesture { color = c }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle(label == nil ? L10n.t("ios_new_label_title") : L10n.t("ios_edit_label_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.t("cancel_button")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("ios_save_button")) { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                if let label {
                    name = label.name
                    color = label.color ?? "blue"
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if var existing = label {
            existing.name = trimmed
            existing.color = color
            vault.updateLabel(existing)
        } else {
            _ = vault.addLabel(name: trimmed, color: color)
        }
        dismiss()
    }
}

// MARK: - 自适应 chips 流式容器

struct FlowChips<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: Content

    var body: some View {
        FlowLayout(spacing: spacing) { content }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > maxWidth, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
        return CGSize(width: maxWidth, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}
