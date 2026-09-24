import SwiftUI

/// Detail pane: title block with a large circular icon (star badge at its
/// bottom-left corner), form-style field rows (caption label above, value over
/// a hairline underline, type icon at the right end), and a bottom action bar
/// (编辑 / 设置标签 / 用于自动填充 / share).
struct CardDetailView: View {
    @EnvironmentObject var ctx: AppContext
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        Group {
            if let card = currentCard {
                detail(card)
            } else {
                // 空状态:纯深色空白,仅底部操作栏可见(按钮置灰)。
                Color.appBackground
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .safeAreaInset(edge: .bottom) {
            bottomBar(currentCard)
        }
    }

    private var currentCard: Card? {
        guard let id = ctx.selectedCardId else { return nil }
        return ctx.database.card(id: id)
    }

    private func detail(_ card: Card) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(card)
                if !card.fields.isEmpty { fieldsSection(card) }
                if card.hasNotes { notesSection(card) }
                if card.hasImages { imagesSection(card) }
                if card.hasFiles { filesSection(card) }
                footer(card)
                if card.trashed || card.archived {
                    trashActions(card)
                }
            }
            .padding(24)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    // MARK: Header — 左侧大标题+标签名(次要色),右侧独立星标 + 卡片图标
    // (图标无额外徽章,星标在图标左侧;无「设置标签」链接——在底部栏)

    private func header(_ card: Card) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(card.title.isEmpty ? "—" : card.title)
                    .font(.system(size: 22, weight: .bold))
                    .lineLimit(2)
                let names = labelNames(card)
                if !names.isEmpty {
                    Text(names)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                warnings(card)
            }
            Spacer(minLength: 12)
            Button {
                ctx.toggleFavorite(card.id)
            } label: {
                Image(systemName: card.favorite ? "star.fill" : "star")
                    .font(.system(size: 16))
                    .foregroundStyle(card.favorite ? .yellow : .secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            CardIconView(symbol: card.symbol, color: card.color, size: 64,
                         creditCardNumber: card.fields.first { $0.type == .number }?.value,
                         card: card)
        }
    }

    private func labelNames(_ card: Card) -> String {
        card.labelIds.compactMap { ctx.database.label(id: $0)?.name }.joined(separator: ", ")
    }

    @ViewBuilder
    private func warnings(_ card: Card) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if card.isExpired {
                Label(L10n.t("card_expired_warning"), systemImage: "clock.badge.exclamationmark")
                    .foregroundStyle(.red).font(.caption)
            } else if card.isExpiring {
                Label("\(L10n.t("card_expiring_warning")) \(card.expiringInDays)", systemImage: "hourglass")
                    .foregroundStyle(.orange).font(.caption)
            }
            if card.hasWeakPasswords {
                Label(L10n.t("weak_password_message"), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).font(.caption)
            }
            if card.compromised {
                Label(L10n.t("compromised_password_message"), systemImage: "exclamationmark.shield.fill")
                    .foregroundStyle(.red).font(.caption)
            }
        }
    }

    // MARK: Fields — form rows: caption label, value, hairline underline, type icon

    private func fieldsSection(_ card: Card) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(card.fields) { field in
                FieldRowView(card: card, field: field)
            }
            if !card.isTemplate {
                Menu {
                    ForEach(Templates.all) { spec in
                        Button(L10n.db(spec.titleKey)) {
                            addMissingFields(from: spec, to: card)
                        }
                    }
                } label: {
                    Label(L10n.t("add_field_button"), systemImage: "plus.circle")
                        .font(.caption)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }

    @MainActor private func addMissingFields(from spec: Templates.Spec, to card: Card) {
        guard let i = ctx.database.cards.firstIndex(where: { $0.id == card.id }) else { return }
        var c = ctx.database.cards[i]
        for f in spec.fields {
            let name = L10n.db(f.nameKey)
            if !c.fields.contains(where: { $0.name == name }) {
                c.fields.append(Field(name: name, type: f.type, value: "", autofill: f.autofill))
            }
        }
        c.modified = Date().millis
        ctx.database.cards[i] = c
        ctx.saveDebounced()
    }

    // MARK: Notes / images / files / footer

    private func notesSection(_ card: Card) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(L10n.t("notes_tab"))
            // 笔记里的 Markdown 标记(链接/加粗/斜体/删除线)渲染后展示,链接可直接点击
            Text(AttributedString(NotesMarkdown.render(card.notes)))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func imagesSection(_ card: Card) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(L10n.db("images_label"))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(card.images) { img in
                        if let ns = NSImage(data: img.data) {
                            Image(nsImage: ns)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 96, height: 96)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .contextMenu {
                                    Button(L10n.t("copy_command")) {
                                        ClipboardModel.shared.copy(img.data.base64EncodedString())
                                    }
                                }
                        }
                    }
                }
            }
        }
    }

    private func filesSection(_ card: Card) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(L10n.db("files_label"))
            ForEach(card.files) { file in
                HStack {
                    Image(systemName: "doc")
                    Text(file.name)
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: Int64(file.length), countStyle: .file))
                        .foregroundStyle(.secondary).font(.caption)
                    Button(L10n.t("save_button")) { saveAttachment(file) }
                        .buttonStyle(.link)
                }
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    @MainActor private func saveAttachment(_ file: Attachment) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.name
        if panel.runModal() == .OK, let url = panel.url {
            try? file.data.write(to: url)
            AppToast.shared.show(L10n.t("file_saved_message") + " " + url.lastPathComponent)
        }
    }

    /// 详情页脚:右对齐两行「修改时间：」「已创建：」(无字节数、无图标)
    private func footer(_ card: Card) -> some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text("\(L10n.t("modified_prompt")) \(fullDate(card.modified))")
            Text("\(L10n.t("created_prompt")) \(fullDate(card.created))")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func fullDate(_ millis: TimeInterval) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy/MM/dd, HH:mm:ss"
        return f.string(from: millis.date)
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s).font(.caption.bold()).foregroundStyle(.secondary)
    }

    private func trashActions(_ card: Card) -> some View {
        HStack {
            if card.trashed {
                Button(L10n.t("restore_card_command")) { ctx.restoreCard(card.id) }
                Button(L10n.t("delete_button"), role: .destructive) { ctx.deleteCardPermanently(card.id) }
            } else if card.archived {
                Button(L10n.t("unarchive_command")) { ctx.unarchiveCard(card.id) }
            }
            Spacer()
        }
    }

    /// Bottom action bar — 编辑 50.5×23.5、设置标签 86.5×23.5、
    /// 分享 40.5×23.5,深灰圆角填充,无边框线;无选中卡片时整栏置灰。
    /// 窄窗口下详情栏放不完整行,ViewThatFits 降级为「仅复选框」,
    /// 避免 Toggle 被挤压后渲染错位(复选框飘出底栏)。
    private func bottomBar(_ card: Card?) -> some View {
        ViewThatFits(in: .horizontal) {
            bottomBarRow(card, showAutofillLabel: true)
            bottomBarRow(card, showAutofillLabel: false)
        }
    }

    private func bottomBarRow(_ card: Card?, showAutofillLabel: Bool) -> some View {
        HStack(spacing: 13.5) {
            capsuleButton(L10n.t("edit_button"), enabled: card != nil) {
                if let card { ctx.editDraft = EditCardModel(card: card) }
            }
            .disabled(card == nil)
            capsuleButton(L10n.t("set_labels_button"), enabled: card != nil) {
                if let card { ctx.activeSheet = .labels(cardId: card.id) }
            }
            .disabled(card == nil)

            if let card {
                autofillToggle(card, showLabel: showAutofillLabel)
            }

            Spacer(minLength: 8)

            Group {
                if let card {
                    ShareLink(item: card.asPlainText()) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .help(L10n.t("share_menu"))
                } else {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 13, weight: .medium))
                }
            }
            .foregroundStyle(Color.white.opacity(card == nil ? 0.28 : 0.55))
            .frame(width: 40.5, height: 23.5)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.045)))
        }
        .padding(.leading, 17.5)
        .padding(.trailing, 21)
        .padding(.bottom, 12)
        .background(Color.appBackground)
    }

    /// 用于自动填充切换:fixedSize 保证不被压缩(macOS 26 复选框被压宽度时
    /// 会整体渲染到栏外);紧凑档隐藏文字标签,悬浮提示兜底可发现性。
    @ViewBuilder
    private func autofillToggle(_ card: Card, showLabel: Bool) -> some View {
        let base = Toggle(L10n.t("use_for_autofill_button"), isOn: Binding(
            get: { ctx.database.card(id: card.id)?.autofillEnabled ?? false },
            set: { on in ctx.setCardAutofill(card.id, on: on) }
        ))
        .toggleStyle(.checkbox)
        .font(.system(size: 12))
        .fixedSize()
        if showLabel {
            base
        } else {
            base
                .labelsHidden()
                .help(L10n.t("use_for_autofill_button"))
        }
    }

    private func capsuleButton(_ title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(Color.white.opacity(enabled ? 0.85 : 0.28))
                .lineLimit(1)
                .fixedSize()   // 窄窗口下不折行(竖排字)
                .padding(.horizontal, 12)
                .frame(height: 23.5)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.045)))
        }
        .buttonStyle(.plain)
    }
}

/// 字段行 + 密码行 + 一次性代码行布局:
/// 上方小字字段名,下方值,细分隔线;右侧仅一个上下文图标(密码→眼睛,网址→地球),
/// 复制/历史移到右键菜单。
struct FieldRowView: View {
    @EnvironmentObject var ctx: AppContext
    @EnvironmentObject var settings: AppSettings
    let card: Card
    let field: Field

    @State private var revealed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(field.name)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            HStack(alignment: .center) {
                if field.type.isOneTimePassword {
                    OTPView(rawValue: field.value)
                } else {
                    valueView
                }
                Spacer(minLength: 12)
                trailing
            }
            .padding(.bottom, 4)
            Divider()
        }
        .contentShape(Rectangle())
        .contextMenu {
            if field.hasValue {
                Button(L10n.t("copy_command")) { ClipboardModel.shared.copy(field.value) }
            }
            if field.hasHistory {
                Menu(L10n.t("history_title")) {
                    ForEach(field.history.sorted { $0.time > $1.time }) { e in
                        Text("\(e.value) — \(e.time.date.formatted(date: .abbreviated, time: .shortened))")
                    }
                }
            }
        }
    }

    /// 行尾唯一图标:隐藏类字段→眼睛(显示/隐藏),网址→地球(打开),其余无。
    @ViewBuilder
    private var trailing: some View {
        if field.type.isHidden && field.hasValue {
            Button {
                revealed.toggle()
            } label: {
                Image(systemName: revealed ? "eye.slash" : "eye")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(L10n.t(revealed ? "hide_password_button" : "show_password_button"))
        } else if field.type == .website, !field.value.isEmpty {
            Button {
                let s = field.value.hasPrefix("http") ? field.value : "https://\(field.value)"
                if let url = URL(string: s) { NSWorkspace.shared.open(url) }
            } label: {
                Image(systemName: "globe")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
    }

    @ViewBuilder
    private var valueView: some View {
        if field.type.isHidden && !revealed && settings.hidePasswords {
            // 密码行:圆点 + 强度条 + 「破解所需时间：」
            VStack(alignment: .leading, spacing: 6) {
                Text(String(repeating: "•", count: max(6, min(field.value.count, 16))))
                    .font(.callout)
                if field.type == .password, !field.value.isEmpty {
                    StrengthIndicatorView(strength: PasswordStrength.score(field.value))
                        .frame(maxWidth: 280)
                }
            }
        } else if field.type.isHidden {
            VStack(alignment: .leading, spacing: 6) {
                Text(field.value)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                if field.type == .password, !field.value.isEmpty {
                    StrengthIndicatorView(strength: PasswordStrength.score(field.value))
                        .frame(maxWidth: 280)
                }
            }
        } else {
            Text(field.value)
                .font(.callout)
                .textSelection(.enabled)
        }
    }
}

/// ViewCardOneTimePasswordCell — live RFC 6238 code with rollover progress.
struct OTPView: View {
    let rawValue: String

    @State private var code: String? = nil
    @State private var remaining: Int = 0
    @State private var error: String? = nil

    var body: some View {
        HStack(spacing: 8) {
            if let code {
                Text(code)
                    .font(.system(.title3, design: .monospaced).bold())
                    .foregroundStyle(.tint)
                Button {
                    ClipboardModel.shared.copyOTP(code)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                Text("(\(remaining)s)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(remaining <= 5 ? .red : .secondary)
            } else if let error {
                Text(error).font(.caption).foregroundStyle(.secondary)
            } else {
                Text("—").foregroundStyle(.secondary)
            }
        }
        .onAppear(perform: tick)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in tick() }
    }

    private func tick() {
        guard !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            code = nil
            error = nil
            return
        }
        guard let cfg = try? TOTP.parse(rawValue) else {
            error = L10n.t("invalid_value_text")
            code = nil
            return
        }
        code = try? TOTP.code(config: cfg)
        remaining = TOTP.remainingSeconds(period: cfg.period)
    }
}
