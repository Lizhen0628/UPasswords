import SwiftUI
import AppKit

/// Mirrors `EditCardModel` (Models/EditCardModel.h) — a working copy of the
/// card plus per-target sub-state for the symbol/color/template pickers.
struct EditCardModel: Identifiable {
    var id: Int { card.id }
    var card: Card
    var isNew: Bool = false
}

/// EditCardWindowController — tabbed editor (EditCardFieldsTab / NotesTab /
/// ImagesTab / FilesTab) presented as a sheet over the main window.
struct EditCardSheet: View {
    @EnvironmentObject var ctx: AppContext
    @Binding var draft: EditCardModel?

    @State private var tab: EditTab = .fields

    enum EditTab: String, CaseIterable, Identifiable {
        case fields, notes, images, files
        var id: String { rawValue }
        var name: String {
            switch self {
            case .fields: return L10n.t("fields_tab")
            case .notes: return L10n.t("notes_tab")
            case .images: return L10n.t("images_tab")
            case .files: return L10n.t("files_tab")
            }
        }
    }

    /// 编辑窗背景:参考原版实测 RGB(35,35,33),比系统 windowBackgroundColor 更深;
    /// 浅色外观下跟随系统背景。
    static var windowBackground: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(calibratedRed: 35 / 255, green: 35 / 255, blue: 33 / 255, alpha: 1)
                : .windowBackgroundColor
        })
    }

    var body: some View {
        if let current = draft {
            EditCardBody(draft: stableBinding(current), tab: $tab) { draft = nil }
        } else {
            Color.clear.frame(minWidth: 560, minHeight: 480)
        }
    }

    /// 无强制解包的编辑绑定。关闭动画中 draft 已为 nil:
    /// get 回退到捕获值(内容保持稳定,不触发 ForceUnwrapping 崩溃),
    /// set 直接丢弃(关闭中的写穿不可能发生,杜绝表单自行重新弹出)。
    private func stableBinding(_ fallback: EditCardModel) -> Binding<EditCardModel> {
        Binding(
            get: { draft ?? fallback },
            set: { newValue in
                guard draft != nil else {
                    Log.info("ui", "edit sheet write ignored (closed) cardId=\(fallback.card.id)")
                    return
                }
                draft = newValue
            }
        )
    }
}

private struct EditCardBody: View {
    @EnvironmentObject var ctx: AppContext
    @Binding var draft: EditCardModel
    @Binding var tab: EditCardSheet.EditTab
    @State private var fieldEditor: FieldEditorState? = nil
    // 标题/收藏的本地编辑态:ctx.editDraft 不再逐键广播,
    // 文本类控件持有本地状态才能即时回显(写入仍静默同步回 draft)
    @State private var titleDraft: String
    @State private var favoriteDraft: Bool
    @FocusState private var titleFocused: Bool
    /// 关闭表单(清掉 ctx.editDraft);保存路径先 upsert 再关闭
    var onClose: () -> Void = {}

    init(draft: Binding<EditCardModel>, tab: Binding<EditCardSheet.EditTab>, onClose: @escaping () -> Void) {
        self._draft = draft
        self._tab = tab
        self.onClose = onClose
        self._titleDraft = State(initialValue: draft.wrappedValue.card.title)
        self._favoriteDraft = State(initialValue: draft.wrappedValue.card.favorite)
    }

    private var cardBinding: Binding<Card> {
        Binding(get: { draft.card }, set: { draft.card = $0 })
    }
    private var titleBinding: Binding<String> {
        Binding(
            get: { titleDraft },
            set: {
                titleDraft = $0
                draft.card.title = $0
            }
        )
    }
    private var favoriteBinding: Binding<Bool> {
        Binding(
            get: { favoriteDraft },
            set: {
                favoriteDraft = $0
                draft.card.favorite = $0
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header(cardBinding)
            Divider()
            EditTabBar(tab: $tab)
                .padding(.vertical, 10)
            Group {
                switch tab {
                case .fields: FieldsTab(card: cardBinding, fieldEditor: $fieldEditor)
                case .notes: NotesTab(card: cardBinding)
                case .images: ImagesTab(card: cardBinding)
                case .files: FilesTab(card: cardBinding)
                }
            }
            .frame(maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(minWidth: 560, minHeight: 480)
        .background(EditCardSheet.windowBackground)
        .sheet(item: $fieldEditor) { state in
            FieldEditorSheet(state: state) { field in
                if let i = draft.card.fields.firstIndex(where: { $0.id == field.id }) {
                    draft.card.fields[i] = field
                } else {
                    draft.card.fields.append(field)
                }
            }
            .environmentObject(ctx)
        }
    }

    // MARK: Header (title / symbol / color / template / favorite)

    private func header(_ card: Binding<Card>) -> some View {
        HStack(spacing: 12) {
            Button {
                ctx.activeSheet = .selectSymbol
            } label: {
                CardIconView(symbol: card.wrappedValue.symbol,
                             color: card.wrappedValue.color, size: 38)
            }
            .buttonStyle(.plain)
            .help(L10n.t("select_symbol_command"))

            Button {
                ctx.activeSheet = .selectColor
            } label: {
                Circle()
                    .fill(CardColor.color(named: card.wrappedValue.color))
                    .frame(width: 16, height: 16)
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help(L10n.t("select_color_command"))

            TextField(L10n.t("title_hint"), text: titleBinding)
                .textFieldStyle(.plain)
                .font(.title3.weight(.semibold))
                .focused($titleFocused)
                .editFieldChrome(focused: titleFocused, height: 32, radius: 8)

            Button {
                ctx.activeSheet = .selectTemplate
            } label: {
                Label(L10n.db("templates_label"), systemImage: "square.stack.3d.up")
                    .font(.system(size: 13))
            }
            .buttonStyle(PanelButtonStyle())
            .help(L10n.t("select_template_title"))

            Button {
                favoriteBinding.wrappedValue.toggle()
            } label: {
                Image(systemName: favoriteDraft ? "star.fill" : "star")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(favoriteDraft ? Color.yellow : Color.secondary)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(PanelButtonStyle(padding: 0))
            .help(L10n.t("favorites_label"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if !draft.isNew {
                Button(L10n.t("save_as_template_button")) {
                    var t = draft.card
                    t.template = true
                    t.id = ctx.newCardId()
                    ctx.database.cards.append(t)
                    AppToast.shared.show(L10n.t("template_saved_message"))
                    ctx.editDraft = nil
                }
                .buttonStyle(PanelButtonStyle())
            }
            Spacer()
            Button(L10n.t("cancel_button")) {
                Log.info("ui", "edit sheet cancel cardId=\(draft.card.id)")
                ctx.editDraft = nil
            }
            .buttonStyle(PanelButtonStyle())
            .keyboardShortcut(.cancelAction)
            Button(L10n.t("save_and_close_button")) {
                Log.info("ui", "edit sheet save cardId=\(draft.card.id) isNew=\(draft.isNew) fields=\(draft.card.fields.count) notes.len=\(draft.card.notes.count)")
                ctx.upsertCard(draft.card)
                ctx.editDraft = nil
            }
            .buttonStyle(AccentButtonStyle())
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

// MARK: - 参考图样式的面板按钮(圆角矩形 + 细描边)

/// 次级按钮:半透明面板底 + 细描边(模板/取消/存为模板/收藏)。
fileprivate struct PanelButtonStyle: ButtonStyle {
    var padding: CGFloat = 14
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, padding)
            .frame(minHeight: 32)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(configuration.isPressed ? 0.12 : 0.07)))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.white.opacity(0.13), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// 主操作按钮:强调色实底 + 白色半粗文字(保存并关闭)。
fileprivate struct AccentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 16)
            .frame(minHeight: 32)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(Color.accentColor.opacity(configuration.isPressed ? 0.8 : 1)))
            .foregroundStyle(.white)
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// 参考图的分段选项卡:居中胶囊容器,选中段强调色圆角块 + 白字,
/// 未选中相邻段之间有细分隔线。仅替换视觉,选中状态仍走同一个 tab 绑定。
fileprivate struct EditTabBar: View {
    @Binding var tab: EditCardSheet.EditTab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(EditCardSheet.EditTab.allCases.indices, id: \.self) { i in
                let t = EditCardSheet.EditTab.allCases[i]
                if i > 0, EditCardSheet.EditTab.allCases[i - 1] != tab, t != tab {
                    Divider()
                        .frame(height: 14)
                        .opacity(0.25)
                }
                segment(t)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.25)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        .frame(maxWidth: .infinity)
    }

    private func segment(_ t: EditCardSheet.EditTab) -> some View {
        let selected = tab == t
        return Button {
            tab = t
        } label: {
            Text(t.name)
                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.white : Color.primary.opacity(0.7))
                .padding(.horizontal, 22)
                .frame(height: 26)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 6).fill(Color.accentColor)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Fields tab (条目详情卡片 + 字段行)

private struct FieldsTab: View {
    @EnvironmentObject var ctx: AppContext
    @Binding var card: Card
    @Binding var fieldEditor: FieldEditorState?

    var body: some View {
        ScrollView {
            sectionCard
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
    }

    /// 「条目详情」圆角卡片:区块头 + 字段行 + 虚线添加按钮
    private var sectionCard: some View {
        VStack(spacing: 0) {
            sectionHeader
            Divider()
            ForEach(Array($card.fields.enumerated()), id: \.element.id) { index, $field in
                FieldEditRow(
                    field: $field,
                    canMoveUp: index > 0,
                    canMoveDown: index < card.fields.count - 1,
                    onEdit: { fieldEditor = FieldEditorState(field: field) },
                    onDelete: { card.fields.removeAll { $0.id == field.id } },
                    onMove: { offset in moveField(field, offset: offset) }
                )
                if index < card.fields.count - 1 {
                    Divider().padding(.leading, 14)
                }
            }
            addMoreFields
                .padding(10)
        }
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.09), lineWidth: 1))
    }

    private var sectionHeader: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 9)
                .fill(Color.white.opacity(0.08))
                .frame(width: 34, height: 34)
                .overlay(Image(systemName: "doc.text")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary))
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.t("entry_details_title"))
                    .font(.system(size: 14, weight: .semibold))
                Text(L10n.t("entry_details_subtitle"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 5) {
                Image(systemName: "folder")
                    .font(.system(size: 12))
                Text(L10n.t("organize_fields_button"))
                    .font(.system(size: 12))
            }
            .foregroundStyle(.secondary)
        }
        .padding(14)
    }

    /// 虚线框「添加更多字段」:点击打开字段编辑弹窗(与原添加按钮同一行为)
    private var addMoreFields: some View {
        Button {
            fieldEditor = FieldEditorState(field: Field(name: ""))
        } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(Color.white.opacity(0.10))
                    .frame(width: 24, height: 24)
                    .overlay(Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold)))
                Text(L10n.t("add_more_fields_button"))
                    .font(.system(size: 13))
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.03)))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.white.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private func moveField(_ field: Field, offset: Int) {
        guard let i = card.fields.firstIndex(where: { $0.id == field.id }) else { return }
        let j = i + offset
        guard card.fields.indices.contains(j) else { return }
        card.fields.swapAt(i, j)
    }
}

/// AddFieldSheetController / EditFieldSheetController state (name/type/autofill).
struct FieldEditorState: Identifiable {
    let id = UUID()
    var field: Field
}

struct FieldEditorSheet: View {
    @Environment(\.dismiss) var dismiss
    let state: FieldEditorState
    let onSave: (Field) -> Void
    @State private var name = ""
    @State private var type: FieldType = .text
    @State private var autofill: Autofill = .off

    var body: some View {
        SheetShell(
            title: state.field.name.isEmpty ? L10n.t("add_field_title") : L10n.t("edit_field_title"),
            okDisabled: name.isEmpty,
            onAppearBody: {
                name = state.field.name
                type = state.field.type
                autofill = state.field.autofill
            },
            onCancel: { dismiss() },
            onOk: {
                var f = state.field
                f.name = name
                f.type = type
                f.autofill = autofill
                onSave(f)
                dismiss()
            },
            content: {
                VStack(alignment: .leading, spacing: 10) {
                    LabeledRow(label: L10n.t("field_name_prompt")) {
                        TextField("", text: $name).textFieldStyle(.roundedBorder)
                    }
                    LabeledRow(label: L10n.t("type_prompt")) {
                        Picker("", selection: $type) {
                            ForEach(FieldType.allCases) { t in
                                Text(t.localizedName).tag(t)
                            }
                        }
                    }
                    LabeledRow(label: L10n.t("autofill_title", fallback: "自动填充")) {
                        Picker("", selection: $autofill) {
                            ForEach(Autofill.allCases) { a in
                                Text(a.localizedName).tag(a)
                            }
                        }
                    }
                }
            }
        )
    }
}

/// 编辑表单字段框统一样式:plain 输入 + 自绘边框(聚焦高亮)。
/// 系统 roundedBorder 的聚焦圈(Tahoe)每次聚焦都要创建/销毁
/// _NSKeyboardFocusClipView 并做整树布局,点击时有可感知顿挫;
/// 自绘描边由 @FocusState 直接驱动,瞬时响应。
extension View {
    fileprivate func editFieldChrome(focused: Bool, height: CGFloat = 30, radius: CGFloat = 7) -> some View {
        self
            .padding(.horizontal, 8)
            .frame(height: height)
            .overlay(
                RoundedRectangle(cornerRadius: radius)
                    .stroke(focused ? Color.accentColor.opacity(0.85) : Color.white.opacity(0.14),
                            lineWidth: focused ? 2 : 1)
                    .background(RoundedRectangle(cornerRadius: radius).fill(Color.black.opacity(0.22)))
                    // 装饰层必须放行点击,否则会挡住输入框的聚焦与编辑
                    .allowsHitTesting(false)
            )
    }
}

private struct FieldEditRow: View {
    @EnvironmentObject var ctx: AppContext
    @Binding var field: Field
    var canMoveUp: Bool
    var canMoveDown: Bool
    var onEdit: () -> Void
    var onDelete: () -> Void
    /// 上移(-1)/下移(+1),替代原 List 拖拽排序
    var onMove: (Int) -> Void
    @State private var revealed = false
    @FocusState private var valueFocused: Bool
    @FocusState private var nameFocused: Bool
    // 本地编辑草稿:打字即时回显(行内重渲染),并静默写回 field 绑定。
    // 行按 Field.id(UUID)标识,外部整体替换 fields 时行会重建,草稿自然刷新。
    @State private var nameDraft: String
    @State private var valueDraft: String

    init(field: Binding<Field>, canMoveUp: Bool, canMoveDown: Bool,
         onEdit: @escaping () -> Void, onDelete: @escaping () -> Void,
         onMove: @escaping (Int) -> Void) {
        self._field = field
        self.canMoveUp = canMoveUp
        self.canMoveDown = canMoveDown
        self.onEdit = onEdit
        self.onDelete = onDelete
        self.onMove = onMove
        self._nameDraft = State(initialValue: field.wrappedValue.name)
        self._valueDraft = State(initialValue: field.wrappedValue.value)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            // 参考图:类型圆形图标底
            Circle()
                .fill(Color.white.opacity(0.09))
                .frame(width: 32, height: 32)
                .overlay(Image(systemName: field.type.systemImage)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary))

            // 字段名:无框文本样式,聚焦时才出现描边(仍可内联改名)
            TextField(L10n.t("field_name_prompt"), text: $nameDraft)
                .onChange(of: nameDraft) { field.name = nameDraft }
                .onChange(of: field.name) { if field.name != nameDraft { nameDraft = field.name } }
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($nameFocused)
                .padding(.horizontal, 6)
                .frame(width: 88, height: 28)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(Color.black.opacity(nameFocused ? 0.22 : 0)))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(nameFocused ? Color.accentColor.opacity(0.85) : .clear, lineWidth: 1)
                    .allowsHitTesting(false))

            valueArea

            // 复制按钮(参考图行内 doc.on.doc 面板按钮)
            Button {
                ClipboardModel.shared.copy(valueDraft)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 12))
                    .frame(width: 30, height: 28)
            }
            .buttonStyle(PanelButtonStyle(padding: 0))
            .disabled(valueDraft.isEmpty)
            .help(L10n.t("copy_command"))

            moreMenu
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// 字段值区:自绘描边盒 + 行内按钮(眼睛/生成器在盒内,同参考图);
    /// 密码字段在盒下保留强度指示,TOTP 在盒内行尾显示当前验证码。
    @ViewBuilder
    private var valueArea: some View {
        VStack(alignment: .leading, spacing: 5) {
            valueBox
            if field.type == .password && !valueDraft.isEmpty {
                StrengthIndicatorView(strength: PasswordStrength.score(valueDraft))
                    .frame(maxWidth: 200, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var valueBox: some View {
        HStack(spacing: 6) {
            input

            if field.type.isHidden && !valueDraft.isEmpty {
                Button { revealed.toggle() } label: {
                    Image(systemName: revealed ? "eye.slash" : "eye")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L10n.t(revealed ? "hide_password_button" : "show_password_button",
                             fallback: revealed ? "隐藏" : "显示"))
            }

            if field.type == .password {
                Menu {
                    ForEach(0..<4) { t in
                        let name = [L10n.t("random_text"), L10n.t("memorable_text"),
                                    L10n.t("letters_and_numbers_text"), L10n.t("numbers_only_text")][t]
                        Button(name) {
                            field.value = PasswordGenerator.instance.password(
                                length: PasswordSettings.shared.passwordLength, type: t)
                            valueDraft = field.value
                            PasswordGenerator.instance.addPasswordToHistory(field.value)
                        }
                    }
                } label: {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(L10n.t("generate_password_title"))
            }

            if field.type.isOneTimePassword,
               let cfg = try? TOTP.parse(field.value),
               let code = try? TOTP.code(config: cfg) {
                Text(code)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.tint)
                    .padding(.trailing, 2)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .frame(minHeight: 30)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.black.opacity(0.22)))
        .overlay(RoundedRectangle(cornerRadius: 7)
            .strokeBorder(valueFocused ? Color.accentColor.opacity(0.85) : Color.white.opacity(0.14),
                          lineWidth: valueFocused ? 2 : 1)
            .allowsHitTesting(false))
    }

    /// 值输入本体:隐藏类字段默认掩码(SecureField),revealed 时切换明文
    @ViewBuilder
    private var input: some View {
        Group {
            if field.type.isHidden && !revealed {
                SecureField(L10n.t("field_value_prompt"), text: $valueDraft)
            } else {
                TextField(L10n.t("field_value_prompt"), text: $valueDraft)
            }
        }
        .onChange(of: valueDraft) { field.value = valueDraft }
        .textFieldStyle(.plain)
        .font(field.type.isHidden ? .system(size: 13, design: .monospaced) : .system(size: 13))
        .focused($valueFocused)
        .frame(maxWidth: .infinity)
    }

    private var moreMenu: some View {
        Menu {
            Button(L10n.t("edit_field_title")) { onEdit() }
            Button(L10n.t("move_up_command", fallback: "上移")) { onMove(-1) }
                .disabled(!canMoveUp)
            Button(L10n.t("move_down_command", fallback: "下移")) { onMove(+1) }
                .disabled(!canMoveDown)
            Divider()
            if field.hasHistory {
                ForEach(field.history.sorted { $0.time > $1.time }) { h in
                    Button("\(h.value)") {
                        field.value = h.value
                        valueDraft = h.value
                    }
                }
                Divider()
            }
            Button(L10n.t("delete_button"), role: .destructive) {
                onDelete()
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

// MARK: - Notes tab (EditCardNotesTab) — 参考图卡片:标题头 + 工具条 + 编辑区 + 字数

private struct NotesTab: View {
    @Binding var card: Card
    private let limit = 2000
    // 本地编辑草稿:editDraft 不逐键广播,占位文案/字数要靠它才能即时刷新
    // (写入仍静默同步回 card.notes,保存路径不变)。
    // 链接以 Markdown [文字](URL) 形式持久化在平文笔记里,编辑器内渲染为可点击链接。
    @State private var notesDraft: String
    @State private var editorFocused = false

    init(card: Binding<Card>) {
        self._card = card
        self._notesDraft = State(initialValue: card.wrappedValue.notes)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header
                innerBox
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.045)))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.09), lineWidth: 1))
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        // 本地草稿 → card.notes 静默写回(保存路径不变);外部改动(模板/重开)反向同步
        .onChange(of: notesDraft) { card.notes = notesDraft }
        .onChange(of: card.notes) {
            if card.notes != notesDraft { notesDraft = card.notes }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 9)
                .fill(Color.white.opacity(0.08))
                .frame(width: 34, height: 34)
                .overlay(Image(systemName: "square.and.pencil")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary))
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.t("notes_tab"))
                    .font(.system(size: 14, weight: .semibold))
                Text(L10n.t("notes_subtitle", fallback: "记录与该条目相关的任何备注信息、使用说明或重要事项"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
    }

    /// 内嵌框:格式工具条 + 分割线 + 编辑区 + 字数(同参考图)
    private var innerBox: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            editor
            HStack {
                Spacer()
                Text(verbatim: "\(NotesMarkdown.visibleLength(notesDraft)) / \(limit)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.14)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
    }

    private var toolbar: some View {
        HStack(spacing: 16) {
            // B / I / U / S:对选中文本做即时字体变换(纯文本存储,格式不持久化)
            glyphButton("B") { toggleFontTrait(.boldFontMask) }
                .font(.system(size: 14, weight: .bold))
            glyphButton("I") { toggleFontTrait(.italicFontMask) }
                .font(.system(size: 14, weight: .medium)).italic()
            glyphButton("U") { toggleUnderline() }
                .font(.system(size: 14, weight: .medium)).underline()
            glyphButton("S") { toggleStrikethrough() }
                .font(.system(size: 14, weight: .medium)).strikethrough()

            toolbarDivider

            iconButton("list.bullet", help: L10n.t("bulleted_list_tooltip", fallback: "无序列表")) {
                toggleList(.bullet)
            }
            .font(.system(size: 13))
            iconButton("list.number", help: L10n.t("numbered_list_tooltip", fallback: "有序列表")) {
                toggleList(.ordered)
            }
            .font(.system(size: 13))

            toolbarDivider

            iconButton("link", help: L10n.t("add_link_tooltip", fallback: "添加链接")) {
                addLink()
            }
            .font(.system(size: 13))

            Spacer()

            iconButton("arrow.uturn.backward", help: L10n.t("undo_command", fallback: "撤销")) { sendTextAction("undo:") }
                .font(.system(size: 13))
            iconButton("arrow.uturn.forward", help: L10n.t("redo_command", fallback: "重做")) { sendTextAction("redo:") }
                .font(.system(size: 13))
        }
        .foregroundStyle(.primary.opacity(0.85))
        .padding(.horizontal, 12)
        .frame(height: 40)
    }

    private var toolbarDivider: some View {
        Divider().frame(height: 16).opacity(0.4)
    }

    /// 文字字形按钮(B / I / U / S)
    private func glyphButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// SF Symbol 图标按钮(列表/链接/撤销/重做)
    private func iconButton(_ systemName: String, help: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            // 聚焦(光标闪烁)或已有内容时,占位都要消失
            if notesDraft.isEmpty && !editorFocused {
                Text(L10n.t("notes_placeholder", fallback: "在这里输入您的笔记..."))
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 10)
                    .padding(.top, 8)
                    // 占位层必须放行点击,否则会挡住文本框聚焦
                    .allowsHitTesting(false)
            }
            NotesTextEditor(text: $notesDraft, onFocusChange: { editorFocused = $0 })
        }
        .frame(minHeight: 200)
        .padding(4)
    }

    // MARK: 工具条动作(作用于当前焦点 NSTextView;笔记为纯文本,格式即时生效但不入库)

    private var focusedTextView: NSTextView? {
        NSApp.keyWindow?.firstResponder as? NSTextView
    }

    private func toggleFontTrait(_ trait: NSFontTraitMask) {
        guard let tv = focusedTextView, let storage = tv.textStorage else { return }
        let fm = NSFontManager.shared
        let range = tv.selectedRange
        let convert = { (font: NSFont) -> NSFont in
            fm.traits(of: font).contains(trait)
                ? fm.convert(font, toNotHaveTrait: trait)
                : fm.convert(font, toHaveTrait: trait)
        }
        if range.length == 0 {
            let font = tv.typingAttributes[.font] as? NSFont ?? .systemFont(ofSize: 13)
            tv.typingAttributes[.font] = convert(font)
        } else {
            storage.beginEditing()
            storage.enumerateAttribute(.font, in: range, options: []) { value, subRange, _ in
                storage.addAttribute(.font, value: convert(value as? NSFont ?? .systemFont(ofSize: 13)),
                                     range: subRange)
            }
            storage.endEditing()
        }
    }

    private func toggleUnderline() {
        guard let tv = focusedTextView, let storage = tv.textStorage else { return }
        let range = tv.selectedRange
        let isOn = range.length > 0
            && (storage.attribute(.underlineStyle, at: range.location, effectiveRange: nil) as? Int ?? 0) != 0
        let style = isOn ? 0 : NSUnderlineStyle.single.rawValue
        if range.length == 0 {
            tv.typingAttributes[.underlineStyle] = style
        } else {
            storage.addAttribute(.underlineStyle, value: style, range: range)
        }
    }

    private func toggleStrikethrough() {
        guard let tv = focusedTextView, let storage = tv.textStorage else { return }
        let range = tv.selectedRange
        let isOn = range.length > 0
            && (storage.attribute(.strikethroughStyle, at: range.location, effectiveRange: nil) as? Int ?? 0) != 0
        let style = isOn ? 0 : NSUnderlineStyle.single.rawValue
        if range.length == 0 {
            tv.typingAttributes[.strikethroughStyle] = style
        } else {
            storage.addAttribute(.strikethroughStyle, value: style, range: range)
        }
    }

    /// 撤销/重做:沿响应者链投递给文本视图自身的 undoManager
    private func sendTextAction(_ selector: String) {
        NSApp.sendAction(Selector(selector), to: nil, from: nil)
    }

    // MARK: 列表与链接(作用于选区覆盖的段落;格式即时生效,随纯文本保存不持久化)

    private enum ListKind { case bullet, ordered }

    /// 行首标记长度:•\t 或 "12.\t",用于剥旧标记与判断当前状态
    private static func markerLength(of line: String) -> Int? {
        if line.hasPrefix("•\t") { return 2 }
        if let r = line.range(of: "^\\d+\\.\\t", options: .regularExpression) {
            return line.distance(from: line.startIndex, to: r.upperBound)
        }
        return nil
    }

    private func toggleList(_ kind: ListKind) {
        guard let tv = focusedTextView, let storage = tv.textStorage else { return }
        let ns = tv.string as NSString
        let selRange = tv.selectedRange
        let clamped = NSRange(location: min(selRange.location, ns.length), length: 0)
        let pRange = ns.paragraphRange(for: selRange.length > 0 ? selRange : clamped)
        let lines = ns.substring(with: pRange).components(separatedBy: "\n")

        // 首行已带任意标记 → 本次为移除;否则按所选类型编号/加圆点
        let first = lines.first ?? ""
        let removing = Self.markerLength(of: first) != nil

        // 自后向前改,前面行偏移不受影响。
        // 必须走 shouldChangeText → 改 storage → didChangeText 的编辑约定,
        // 否则文本视图与 SwiftUI 绑定不同步,改动会被丢弃。
        var offset = pRange.location
        var edits: [(at: Int, removeLen: Int, insert: String)] = []
        var n = 1
        for line in lines {
            let oldLen = Self.markerLength(of: line) ?? 0
            var insert = ""
            if !removing {
                switch kind {
                case .bullet: insert = "•\t"
                case .ordered: insert = "\(n).\t"; n += 1
                }
            }
            edits.append((offset, oldLen, insert))
            offset += (line as NSString).length + 1   // +1: 换行符
        }

        storage.beginEditing()
        for e in edits.reversed() {
            let range = NSRange(location: e.at, length: e.removeLen)
            guard tv.shouldChangeText(in: range, replacementString: e.insert) else { continue }
            if e.removeLen > 0 {
                storage.replaceCharacters(in: range, with: "")
            }
            if !e.insert.isEmpty {
                storage.insert(NSAttributedString(string: e.insert, attributes: tv.typingAttributes),
                               at: e.at)
            }
        }
        storage.endEditing()
        tv.didChangeText()
        Log.info("ui", "notes list \(removing ? "remove" : "apply") paragraphs=\(lines.count)")
    }

    /// 链接:弹窗取 URL,给选中文字加 .link 属性(Cmd+点击可打开)
    @MainActor private func addLink() {
        guard let tv = focusedTextView else { return }
        let range = tv.selectedRange
        guard range.length > 0 else {
            AppToast.shared.show(L10n.t("link_select_hint", fallback: "请先选中要添加链接的文字"))
            return
        }
        let alert = NSAlert()
        alert.messageText = L10n.t("add_link_tooltip", fallback: "添加链接")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.placeholderString = "https://"
        alert.accessoryView = input
        alert.addButton(withTitle: L10n.t("ok_button"))
        alert.addButton(withTitle: L10n.t("cancel_button"))
        alert.window.initialFirstResponder = input
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let url = URL(string: input.stringValue.trimmingCharacters(in: .whitespaces)),
              input.stringValue.contains(".") else {
            AppToast.shared.show(L10n.t("link_invalid_hint", fallback: "链接格式无效"))
            return
        }
        tv.textStorage?.addAttribute(.link, value: url, range: range)
        tv.didChangeText()
    }
}

// MARK: - Images tab (EditCardImagesTab + EditCardImageCell)

private struct ImagesTab: View {
    @Binding var card: Card
    @State private var dropped = false

    var body: some View {
        VStack {
            if card.images.isEmpty {
                Text(L10n.t("attach_image_warning"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
                    .padding()
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))], spacing: 12) {
                    ForEach(card.images) { img in
                        VStack(spacing: 4) {
                            if let ns = NSImage(data: img.data) {
                                Image(nsImage: ns)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 110, height: 110)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            Button(role: .destructive) {
                                card.images.removeAll { $0.id == img.id }
                            } label: {
                                Label(L10n.t("delete_button"), systemImage: "trash")
                                    .font(.caption)
                            }
                            .buttonStyle(.link)
                        }
                    }
                }
                .padding(12)
            }
            HStack {
                Button {
                    pickImage()
                } label: {
                    Label(L10n.t("attach_image_button"), systemImage: "photo.badge.plus")
                }
                Spacer()
            }
            .padding(12)
        }
    }

    @MainActor private func pickImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            for url in panel.urls {
                if let data = try? Data(contentsOf: url) {
                    // 150 KB image budget matches the original's guidance
                    card.images.append(Attachment(name: url.lastPathComponent, data: data))
                }
            }
        }
    }
}

// MARK: - Files tab (EditCardFilesTab + EditCardFileCell)

private struct FilesTab: View {
    @Binding var card: Card

    private let maxFileBytes = 150 * 1024

    var body: some View {
        VStack {
            if card.files.isEmpty {
                Text(L10n.t("attach_file_warning"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
                    .padding()
            }
            List {
                ForEach(card.files) { file in
                    HStack {
                        Image(systemName: "doc")
                        Text(file.name)
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: Int64(file.length), countStyle: .file))
                            .font(.caption).foregroundStyle(.secondary)
                        Button(role: .destructive) {
                            card.files.removeAll { $0.id == file.id }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            HStack {
                Button {
                    pickFile()
                } label: {
                    Label(L10n.t("attach_file_button"), systemImage: "paperclip.badge.plus")
                }
                Spacer()
            }
            .padding(12)
        }
    }

    @MainActor private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            for url in panel.urls {
                guard let data = try? Data(contentsOf: url) else { continue }
                if data.count > maxFileBytes {
                    AppToast.shared.show(L10n.t("attach_file_error"))
                    continue
                }
                card.files.append(Attachment(name: url.lastPathComponent, data: data))
            }
        }
    }
}

// MARK: - 笔记编辑器(NSTextView 封装 + 链接 Markdown 往返)

/// 笔记以平文入库,链接持久化为 Markdown `[文字](URL)`;
/// 编辑器内渲染成可点击链接(普通点击即在浏览器打开),保存重开后仍在。
/// B/I/U/S 与列表按钮作用于本视图;字体格式为会话级,不写入平文笔记。
fileprivate struct NotesTextEditor: NSViewRepresentable {
    @Binding var text: String   // markdown 平文(与 card.notes 同步)
    var onFocusChange: (Bool) -> Void = { _ in }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = NotesTextView()
        tv.delegate = context.coordinator
        tv.font = .systemFont(ofSize: 13)
        tv.textColor = .labelColor
        tv.drawsBackground = false
        tv.isRichText = true
        tv.allowsUndo = true
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainerInset = NSSize(width: 6, height: 6)
        tv.typingAttributes = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.textColor,
        ]
        context.coordinator.display(markdown: text, in: tv)
        let scroll = NSScrollView()
        scroll.documentView = tv
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onFocusChange = onFocusChange
        guard let tv = nsView.documentView as? NotesTextView else { return }
        // 绑定值与上次序列化结果不同 → 外部改动(重开表单/模板),整体重渲染;
        // 自己打字引起的差异已在 textDidChange 里同步,不动视图避免光标跳转
        if text != context.coordinator.lastSerialized {
            context.coordinator.display(markdown: text, in: tv)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onFocusChange: onFocusChange)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var onFocusChange: (Bool) -> Void
        /// 当前渲染所用的 markdown,用于区分「外部改动」与「内部打字」
        var lastSerialized: String

        init(text: Binding<String>, onFocusChange: @escaping (Bool) -> Void) {
            self.text = text
            self.onFocusChange = onFocusChange
            self.lastSerialized = text.wrappedValue
        }

        func display(markdown: String, in tv: NotesTextView) {
            lastSerialized = markdown
            tv.textStorage?.setAttributedString(NotesMarkdown.render(markdown))
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NotesTextView else { return }
            let md = NotesMarkdown.serialize(tv.textStorage ?? NSTextStorage())
            lastSerialized = md
            if text.wrappedValue != md {
                text.wrappedValue = md
            }
        }

        func textDidBeginEditing(_ notification: Notification) { onFocusChange(true) }
        func textDidEndEditing(_ notification: Notification) { onFocusChange(false) }
    }
}

/// 普通点击命中链接即在浏览器打开(编辑态默认要 Cmd+点击,这里放宽)
final class NotesTextView: NSTextView {
    var onOpenLink: (URL) -> Void = { NSWorkspace.shared.open($0) }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let layoutManager, let container = textContainer else { return super.mouseDown(with: event) }
        let index = layoutManager.characterIndex(for: point, in: container,
                                                 fractionOfDistanceBetweenInsertionPoints: nil)
        if index != NSNotFound, index < (textStorage?.length ?? 0),
           let url = textStorage?.attribute(.link, at: index, effectiveRange: nil) as? URL {
            onOpenLink(url)
            return
        }
        super.mouseDown(with: event)
    }
}

