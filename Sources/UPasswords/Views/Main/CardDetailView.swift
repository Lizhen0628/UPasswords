import SwiftUI

/// Detail pane, grouped-card style: centered header (large icon with a
/// category badge at its bottom-right + bold title below), one rounded card of
/// label-left / value-right rows (fields, labels, modified/created dates,
/// notes), standalone security warning cards underneath, and the bottom action
/// bar (编辑 / 设置标签 / 用于自动填充 / 收藏 / share).
struct CardDetailView: View {
    @EnvironmentObject var ctx: AppContext

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
            VStack(spacing: 18) {
                header(card)
                fieldsCard(card)
                if !card.isTemplate { addFieldMenu(card) }
                warningCards(card)
                if card.hasImages { imagesSection(card) }
                if card.hasFiles { filesSection(card) }
                if card.trashed || card.archived {
                    trashActions(card)
                }
            }
            .padding(24)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Header — 居中大图标(右下角类别徽章)+ 下方加粗标题

    private func header(_ card: Card) -> some View {
        VStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                CardIconView(symbol: card.symbol, color: card.color, size: 84,
                             creditCardNumber: card.fields.first { $0.type == .number }?.value,
                             card: card)
                categoryBadge(card)
                    .offset(x: 4, y: 4)
            }
            .padding(.trailing, 4)
            Text(card.title.isEmpty ? "—" : card.title)
                .font(.system(size: 22, weight: .bold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity)
    }

    /// 图标右下角的小圆徽章:登录类显示人形,其余按卡片符号。
    private func categoryBadge(_ card: Card) -> some View {
        Image(systemName: badgeSymbol(card))
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Color.appBackground)
            .frame(width: 28, height: 28)
            .background(Circle().fill(Color(nsColor: .systemGray)))
            .overlay(Circle().strokeBorder(Color.appBackground, lineWidth: 3))
    }

    private func badgeSymbol(_ card: Card) -> String {
        if card.fields.contains(where: { $0.type == .password || $0.type.isLogin }) { return "person.fill" }
        if card.symbol == "credit_card" { return "creditcard.fill" }
        return SymbolModel.shared.sfSymbol(for: card.symbol ?? "custom")
    }

    // MARK: Fields card — 单张圆角卡片内的「标签居左 / 值居右」行

    private func fieldsCard(_ card: Card) -> some View {
        VStack(spacing: 0) {
            ForEach(card.fields) { field in
                FieldRowView(card: card, field: field)
                Divider()
            }
            if !card.labelIds.isEmpty {
                metaRow(label: L10n.t("labels_text"), value: labelNames(card))
                Divider()
            }
            if card.hasNotes {
                notesRow(card)
                Divider()
            }
            metaRow(label: L10n.t("modified_date_text"), value: localizedDate(card.modified))
            Divider()
            metaRow(label: L10n.t("created_date_text"), value: localizedDate(card.created))
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05)))
    }

    private func labelNames(_ card: Card) -> String {
        card.labelIds.compactMap { ctx.database.label(id: $0)?.name }.joined(separator: ", ")
    }

    /// 非交互信息行:标签居左加粗,值居右;点击值即复制。
    private func metaRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 24)
            Text(value)
                .font(.system(size: 13))
                .foregroundStyle(Color.white.opacity(0.87))
                .multilineTextAlignment(.trailing)
                .onTapGesture {
                    guard !value.isEmpty else { return }
                    Log.info("ui", "detail copy meta \"\(label)\" len=\(value.utf8.count)")
                    ClipboardModel.shared.copy(value)
                }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    /// 备注行:Markdown 渲染(链接/加粗/斜体/删除线),长文本在值列内左对齐换行。
    private func notesRow(_ card: Card) -> some View {
        HStack(alignment: .top) {
            Text(L10n.t("notes_tab"))
                .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 24)
            Text(AttributedString(NotesMarkdown.render(card.notes)))
                .font(.system(size: 13))
                .foregroundStyle(Color.white.opacity(0.87))
                .multilineTextAlignment(.leading)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private func localizedDate(_ millis: TimeInterval) -> String {
        millis.date.formatted(date: .long, time: .omitted)
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
        Log.info("ui", "detail add fields cardId=\(card.id) template=\(spec.titleKey) fields=\(c.fields.count)")
    }

    /// 「添加其它条目」菜单:卡片下方独立的小按钮,不挤占分组行。
    private func addFieldMenu(_ card: Card) -> some View {
        Menu {
            ForEach(Templates.all) { spec in
                Button(L10n.db(spec.titleKey)) {
                    addMissingFields(from: spec, to: card)
                }
            }
        } label: {
            Label(L10n.t("add_field_button"), systemImage: "plus.circle")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Security warnings — 字段卡片下方的独立警告卡片

    @ViewBuilder
    private func warningCards(_ card: Card) -> some View {
        if card.compromised || isReusedPassword(card) || card.hasWeakPasswords
            || card.isExpired || card.isExpiring {
            VStack(spacing: 10) {
                if card.compromised {
                    warningCard(icon: "exclamationmark.circle.fill", tint: .red,
                                title: L10n.t("compromised_passwords_title"),
                                message: L10n.t("compromised_password_message"))
                }
                if isReusedPassword(card) {
                    warningCard(icon: "exclamationmark.circle.fill", tint: .yellow,
                                title: L10n.t("reused_password_warning_title"),
                                message: L10n.t("reused_password_warning_body"))
                }
                if card.hasWeakPasswords {
                    warningCard(icon: "exclamationmark.circle.fill", tint: .yellow,
                                title: L10n.t("weak_passwords_title"),
                                message: L10n.t("weak_password_message"))
                }
                if card.isExpired {
                    warningCard(icon: "clock.badge.exclamationmark", tint: .red,
                                title: L10n.t("card_expired_warning"), message: nil)
                } else if card.isExpiring {
                    warningCard(icon: "hourglass", tint: .orange,
                                title: "\(L10n.t("card_expiring_warning")) \(card.expiringInDays)",
                                message: nil)
                }
            }
        }
    }

    private func warningCard(icon: String, tint: Color, title: String, message: String?) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 26))
                .foregroundStyle(tint)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                if let message {
                    Text(message)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.white.opacity(0.6))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05)))
    }

    /// 此卡密码是否与其他条目重复(SamePasswordsService 分组里含本卡)。
    private func isReusedPassword(_ card: Card) -> Bool {
        let groups = SamePasswordsService.groups(cards: ctx.database.activeCards)
        return groups.values.contains { $0.contains(card.id) }
    }

    // MARK: Images / files / footer

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
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05)))
        }
    }

    private func filesSection(_ card: Card) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(L10n.db("files_label"))
            VStack(spacing: 0) {
                ForEach(Array(card.files.enumerated()), id: \.element.id) { i, file in
                    fileRow(file)
                    if i < card.files.count - 1 { Divider() }
                }
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05)))
        }
    }

    private func fileRow(_ file: Attachment) -> some View {
        HStack {
            Image(systemName: "doc")
            Text(file.name)
                .lineLimit(1)
            Spacer()
            Text(ByteCountFormatter.string(fromByteCount: Int64(file.length), countStyle: .file))
                .foregroundStyle(.secondary).font(.caption)
            Button(L10n.t("save_button")) { saveAttachment(file) }
                .buttonStyle(.link)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @MainActor private func saveAttachment(_ file: Attachment) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.name
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try file.data.write(to: url)
                Log.info("ui", "detail save attachment cardId ok name.len=\(url.lastPathComponent.count) bytes=\(file.length)")
                AppToast.shared.show(L10n.t("file_saved_message") + " " + url.lastPathComponent)
            } catch {
                Log.error("ui", "detail save attachment failed: \(error)")
                AppToast.shared.show(L10n.t("file_saved_message") + " ✗")
            }
        }
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

            if let card {
                Button {
                    ctx.toggleFavorite(card.id)
                } label: {
                    Image(systemName: card.favorite ? "star.fill" : "star")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(card.favorite ? Color.yellow : Color.white.opacity(0.55))
                        .frame(width: 40.5, height: 23.5)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.045)))
                }
                .buttonStyle(.plain)
                .help(L10n.t("favorites_label"))
            }

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

/// 字段行 + 密码行 + 一次性代码行布局(分组卡片内):
/// 标签居左加粗,值居右;点击值即复制到剪贴板;行尾图标(网址→地球)悬浮行时才出现,
/// 复制/历史移到右键菜单。
/// 密码默认「前三位+•••+后三位」,悬停值上方显示全部;≤6 位全打点不泄露内容。
struct FieldRowView: View {
    @EnvironmentObject var settings: AppSettings
    let card: Card
    let field: Field

    @State private var hovering = false
    @State private var valueHovering = false

    /// 密码部分显示的最小长度:≤ 此长度时全打点(短密码会大面积泄露内容)
    static let partialRevealMinLength = 6
    /// 全掩码时使用的固定圆点数(固定长度,不泄露真实密码长度)
    static let maskedDotCount = 8

    var body: some View {
        HStack(spacing: 12) {
            Text(field.name)
                .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 24)
            valueArea
            hoverControls
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            if field.hasValue {
                Button(L10n.t("copy_command")) {
                    copyValue()
                }
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

    /// 行尾图标:网址→地球(打开);悬浮行时可见。
    @ViewBuilder
    private var hoverControls: some View {
        if showGlobe {
            Button {
                openWebsite()
            } label: {
                Image(systemName: "globe")
            }
            .buttonStyle(.plain)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .help(L10n.t("open_website_help"))
        }
    }

    private var showGlobe: Bool {
        field.type == .website && field.hasValue && hovering
    }

    private func openWebsite() {
        let s = field.value.hasPrefix("http") ? field.value : "https://\(field.value)"
        guard let url = URL(string: s) else { return }
        Log.info("ui", "detail open website cardId=\(card.id)")
        NSWorkspace.shared.open(url)
    }

    /// 点击值即复制真实内容(与掩码显示状态无关),并记录操作日志。
    private func copyValue() {
        guard field.hasValue else { return }
        Log.info("ui", "detail copy field cardId=\(card.id) type=\(field.type.rawValue) len=\(field.value.utf8.count)")
        ClipboardModel.shared.copy(field.value)
    }

    /// 密码展示掩码:悬停值上方时显示全部;否则长度 > 6 显示「前三位•••后三位」,
    /// 更短的密码全打点(固定点数,不泄露真实长度)。
    private func maskedDisplay(revealFull: Bool) -> String {
        guard !revealFull else { return field.value }
        guard field.value.count > Self.partialRevealMinLength else {
            return String(repeating: "•", count: Self.maskedDotCount)
        }
        return "\(field.value.prefix(3))•••\(field.value.suffix(3))"
    }

    @ViewBuilder
    private var valueArea: some View {
        if field.type.isOneTimePassword {
            OTPView(rawValue: field.value)
        } else if field.type.isHidden && settings.hidePasswords {
            // 密码行:默认部分掩码,悬停值上方显示全部;点击复制真实密码
            if field.hasValue {
                Text(maskedDisplay(revealFull: valueHovering))
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(valueHovering ? Color.white.opacity(0.87) : Color.white.opacity(0.5))
                    .onHover { valueHovering = $0 }
                    .onTapGesture { copyValue() }
            } else {
                Text("—").foregroundStyle(Color.white.opacity(0.3))
            }
        } else if field.hasValue {
            Text(field.value)
                .font(.system(size: 13, design: field.type.isHidden ? .monospaced : .default))
                .foregroundStyle(Color.white.opacity(0.87))
                .multilineTextAlignment(.trailing)
                .onTapGesture { copyValue() }
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
                    .onTapGesture {
                        Log.info("ui", "detail copy otp")
                        ClipboardModel.shared.copyOTP(code)
                    }
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
