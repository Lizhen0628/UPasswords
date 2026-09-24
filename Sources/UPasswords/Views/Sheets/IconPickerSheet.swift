import SwiftUI
import AppKit

/// 应用到卡片的图标选择结果（编辑表单的 draft 只补丁这些字段,不动其他编辑内容）。
struct CardIconPatch: Equatable {
    var iconSource: String?
    var iconData: Data?
    var useWebsiteIcon: Bool
    /// 选择符号时一并写入的经典符号名;nil = 不改动当前符号。
    var symbolName: String? = nil
}

/// 图标选择器（编辑表单表头图标按钮弹出）,单一图标入口:
/// - 使用默认图标（符号/颜色圆底）/ 经典符号网格（内嵌,分组切换）
/// - 获取网站图标:立即抓取预览;失败落内置品牌兜底,保存后仍可再补抓
/// - 内置品牌图标网格（支付宝/微信/GitHub/Telegram…,BrandIcons 目录）
/// - 上传图片（≤128px 归一化）/ 使用图片 URL
/// 结果经 onApply 写回编辑草稿,随「保存并关闭」upsertCard 入库持久化。
struct IconPickerSheet: View {
    @Environment(\.dismiss) var dismiss
    let initial: Card
    let onApply: (CardIconPatch) -> Void

    enum Selection: Equatable {
        case `default`
        case symbol(String)
        case website
        case builtin(key: String)
        case image(data: Data, source: String)
    }

    @State private var selection: Selection = .default
    @State private var urlDraft = ""
    @State private var loadingURL = false
    @State private var fetchingWebsite = false
    @State private var fetchedWebsiteData: Data? = nil
    @State private var symbolGroup = "internet_group"

    var body: some View {
        SheetShell(
            title: L10n.t("icons_prompt"),
            minWidth: 480,
            minHeight: 480,
            okDisabled: loadingURL || fetchingWebsite,
            onAppearBody: {
                selection = Self.initialSelection(for: initial)
                if case .symbol(let name) = selection,
                   let g = SymbolModel.shared.group(ofSymbol: name) {
                    symbolGroup = g
                }
            },
            onCancel: { dismiss() },
            onOk: {
                let patch = makePatch()
                Log.info("ui", "icon picker apply cardId=\(initial.id) source=\(patch.iconSource ?? "nil") data.len=\(patch.iconData?.count ?? 0) symbol=\(patch.symbolName ?? "-")")
                onApply(patch)
                dismiss()
            },
            content: { content }
        )
    }

    // MARK: 布局

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                preview
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Button(L10n.t("icon_fetch_button", fallback: "获取网站图标")) {
                            selection = .website
                            Task { await fetchWebsitePreview() }
                        }
                        .disabled(IconService.host(fromWebsite: initial.website) == nil || fetchingWebsite)
                        Button(L10n.t("use_default_icon_button", fallback: "使用默认图标")) {
                            selection = .default
                        }
                    }
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Divider()

            Text(L10n.t("icon_builtin_section", fallback: "内置图标"))
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 46), spacing: 6)], spacing: 6) {
                    ForEach(BrandIcons.all) { entry in
                        Button {
                            selection = .builtin(key: entry.key)
                        } label: {
                            BrandIconTileView(entry: entry, size: 38)
                                .padding(3)
                                .background(
                                    RoundedRectangle(cornerRadius: 8).fill(
                                        selection == .builtin(key: entry.key)
                                            ? Color.accentColor.opacity(0.35)
                                            : Color.clear)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 11).strokeBorder(
                                        selection == .builtin(key: entry.key)
                                            ? Color.accentColor
                                            : Color.clear,
                                        lineWidth: 2)
                                )
                        }
                        .buttonStyle(.plain)
                        .help(entry.key)
                    }
                }
                .padding(2)
            }
            .frame(height: 112)

            Divider()

            Text(L10n.t("icon_symbol_section", fallback: "符号"))
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Picker("", selection: $symbolGroup) {
                    ForEach(SymbolModel.shared.groupNames, id: \.self) { g in
                        Text(SymbolModel.shared.groupName(g)).tag(g)
                    }
                }
                .pickerStyle(.menu)
                Spacer()
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 56), spacing: 6)], spacing: 6) {
                    ForEach(SymbolModel.shared.names(forGroup: symbolGroup), id: \.self) { name in
                        symbolCell(name)
                    }
                }
                .padding(2)
            }
            .frame(height: 140)

            Divider()

            HStack(spacing: 10) {
                Button(L10n.t("icon_upload_button", fallback: "选择图片…")) {
                    pickImage()
                }
                if loadingURL {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                HStack(spacing: 6) {
                    TextField(L10n.t("icon_url_placeholder", fallback: "图片 URL"), text: $urlDraft)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                    Button(L10n.t("icon_load_url_button", fallback: "载入")) {
                        loadURL()
                    }
                    .disabled(urlDraft.isEmpty || loadingURL)
                }
            }
        }
    }

    /// 经典符号单元格:与 SelectSymbolSheet 同一数据源（SymbolModel 分组目录）。
    private func symbolCell(_ name: String) -> some View {
        let selected = selection == .symbol(name)
        return Button {
            selection = .symbol(name)
        } label: {
            VStack(spacing: 3) {
                Image(systemName: SymbolModel.shared.sfSymbol(for: name))
                    .font(.system(size: 16, weight: .medium))
                    .frame(height: 19)
                Text(name)
                    .font(.system(size: 9))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7).fill(
                    selected ? Color.accentColor.opacity(0.35) : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: 预览

    @ViewBuilder private var preview: some View {
        switch selection {
        case .default:
            CardIconView(symbol: initial.symbol, color: initial.color, size: 64,
                         creditCardNumber: initial.fields.first { $0.type == .number }?.value)
        case .symbol(let name):
            CardIconView(symbol: name, color: initial.color, size: 64,
                         creditCardNumber: initial.fields.first { $0.type == .number }?.value)
        case .website:
            if fetchingWebsite {
                ProgressView()
                    .frame(width: 64, height: 64)
            } else if let data = fetchedWebsiteData {
                imageCircle(data)
            } else if let entry = BrandIcons.match(host: IconService.host(fromWebsite: initial.website),
                                                   title: initial.title) {
                BrandIconTileView(entry: entry, size: 64)
            } else {
                CardIconView(symbol: initial.symbol, color: initial.color, size: 64,
                             creditCardNumber: initial.fields.first { $0.type == .number }?.value)
            }
        case .builtin(let key):
            if let art = BrandIcons.bundledImage(for: key) {
                Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
            } else if let entry = BrandIcons.entry(for: key) {
                BrandIconTileView(entry: entry, size: 64)
            }
        case .image(let data, _):
            imageCircle(data)
        }
    }

    private func imageCircle(_ data: Data) -> some View {
        Group {
            if let img = IconService.cachedImage(forData: data) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "questionmark.square.dashed")
            }
        }
        .frame(width: 64, height: 64)
        .background(Circle().fill(Color(nsColor: .controlBackgroundColor)))
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.white.opacity(0.15), lineWidth: 1))
    }

    private var hint: String {
        switch selection {
        case .default:
            return L10n.t("icon_hint_default", fallback: "使用符号与颜色绘制的默认图标。")
        case .symbol:
            return L10n.t("icon_hint_symbol", fallback: "使用选定的经典符号图标。")
        case .website:
            if IconService.host(fromWebsite: initial.website) == nil {
                return L10n.t("icon_hint_no_website", fallback: "该条目没有可用的网址字段。")
            }
            return L10n.t("icon_hint_website", fallback: "从网站地址抓取图标,失败时用内置品牌图标兜底。")
        case .builtin(let key):
            return L10n.t("icon_hint_builtin", fallback: "内置品牌图标,随应用分发。")
                + " (\(key))"
        case .image:
            return L10n.t("icon_hint_custom", fallback: "自定义图片已就绪,保存后随数据库持久化。")
        }
    }

    // MARK: 动作

    static func initialSelection(for card: Card) -> Selection {
        if let data = card.iconData, !data.isEmpty {
            return .image(data: data, source: card.iconSource ?? IconService.sourceCustom)
        }
        if let key = card.iconBuiltinKey { return .builtin(key: key) }
        if card.iconIsFromWebsite || card.useWebsiteIcon { return .website }
        if let s = card.symbol { return .symbol(s) }
        return .default
    }

    private func makePatch() -> CardIconPatch {
        switch selection {
        case .default:
            return CardIconPatch(iconSource: nil, iconData: nil, useWebsiteIcon: false)
        case .symbol(let name):
            // 选符号 = 清掉图标覆盖,回到底色 + 该符号
            return CardIconPatch(iconSource: nil, iconData: nil, useWebsiteIcon: false, symbolName: name)
        case .website:
            return CardIconPatch(iconSource: IconService.sourceWebsite,
                                 iconData: fetchedWebsiteData ?? initial.iconData,
                                 useWebsiteIcon: true)
        case .builtin(let key):
            return CardIconPatch(iconSource: IconService.sourceBuiltinPrefix + key,
                                 iconData: nil, useWebsiteIcon: true)
        case .image(let data, let source):
            return CardIconPatch(iconSource: source, iconData: data, useWebsiteIcon: true)
        }
    }

    /// 「获取网站图标」即时抓取预览;失败时品牌兜底已在预览中体现,无兜底则提示。
    private func fetchWebsitePreview() async {
        guard let host = IconService.host(fromWebsite: initial.website) else { return }
        fetchingWebsite = true
        defer { fetchingWebsite = false }
        do {
            let data = try await IconService.fetchFavicon(host: host)
            fetchedWebsiteData = data
            Log.info("ui", "icon preview fetched cardId=\(initial.id) host=\(host) bytes=\(data.count)")
        } catch {
            Log.warn("ui", "icon preview fetch failed cardId=\(initial.id) host=\(host): \(String(describing: error))")
            if BrandIcons.match(host: host, title: initial.title) == nil {
                AppToast.shared.show(L10n.t("icon_fetch_failed", fallback: "无法获取网站图标。"))
            }
        }
    }

    @MainActor private func pickImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let raw = try? Data(contentsOf: url) else {
            AppToast.shared.show(L10n.t("custom_icon_format_error"))
            return
        }
        Task {
            if let png = await IconService.normalizedIconData(raw) {
                selection = .image(data: png, source: IconService.sourceCustom)
                Log.info("ui", "icon upload ready cardId=\(initial.id) bytes=\(png.count)")
            } else {
                Log.warn("ui", "icon upload rejected cardId=\(initial.id) (not decodable)")
                AppToast.shared.show(L10n.t("custom_icon_format_error"))
            }
        }
    }

    private func loadURL() {
        let trimmed = urlDraft.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: trimmed), url.scheme != nil, url.host != nil else {
            AppToast.shared.show(L10n.t("icon_url_invalid", fallback: "图片 URL 无效。"))
            return
        }
        loadingURL = true
        Task {
            defer { loadingURL = false }
            do {
                let png = try await IconService.fetchImage(at: url)
                selection = .image(data: png, source: IconService.sourceURLPrefix + trimmed)
            } catch {
                Log.warn("ui", "icon URL load failed cardId=\(initial.id): \(String(describing: error))")
                AppToast.shared.show(error.localizedDescription)
            }
        }
    }
}
