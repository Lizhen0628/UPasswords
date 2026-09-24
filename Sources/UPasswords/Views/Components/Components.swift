import SwiftUI

/// 统一窗口底色(标题栏/侧栏/列表/详情一致,比系统 windowBackgroundColor 略暖)。
extension Color {
    static let appBackground = Color(red: 35.0/255.0, green: 34.0/255.0, blue: 32.0/255.0)
}

/// Card color palette resolution (XML `color` attribute → SwiftUI color).
extension CardColor {
    var color: Color {
        switch self {
        case .gray: return Color(nsColor: .systemGray)
        case .blue: return .blue
        case .red: return .red
        case .green: return .green
        case .yellow: return .yellow
        case .purple: return .purple
        case .orange: return .orange
        case .cyan: return .cyan
        case .pink: return .pink
        case .brown: return .brown
        case .white: return Color(nsColor: .white)
        case .black: return Color(nsColor: .darkGray)
        }
    }

    /// 无颜色时的默认卡片图标色:中性灰,而不是主题蓝。
    static func color(named name: String?) -> Color {
        guard let name, let c = CardColor(rawValue: name) else { return Color(nsColor: .systemGray) }
        return c.color
    }
}

/// Renders a card's icon. Resolution order
/// (with `card` provided): ① Card.iconData（抓取/上传/URL 的 PNG）→ 圆形裁切;
/// ② iconSource=builtin:<key> → 品牌方砖;③ 「使用网站图标」开启时按域名/标题
/// 实时匹配品牌方砖（离线、即时,作为抓取失败的兜底）;④ 默认:符号+颜色圆形。
struct CardIconView: View {
    let symbol: String?
    let color: String?
    var size: CGFloat = 32
    var creditCardNumber: String? = nil
    /// 完整卡片上下文;模板行等无卡场景保持 nil,走符号圆底。
    var card: Card? = nil

    var body: some View {
        if let card, let resolved = resolve(card) {
            resolved
                .frame(width: size, height: size)
        } else {
            symbolCircle
        }
    }

    // MARK: 解析

    private enum Resolved {
        case image(NSImage)
        case brand(BrandIcons.Entry)
    }

    private func resolve(_ card: Card) -> AnyView? {
        // ① 持久化的图标像素（website 抓取 / custom 上传 / url 下载）
        if let data = card.iconData, !data.isEmpty, let img = IconService.cachedImage(forData: data) {
            return AnyView(
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .background(Circle().fill(Color.white.opacity(0.9)))   // 透明底 favicon 在深色背景上可辨
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            )
        }
        // ② 内置品牌:优先 Bundle 内同名 PNG 图稿,否则程序绘制方砖
        if let key = card.iconBuiltinKey {
            if let art = BrandIcons.bundledImage(for: key) {
                return AnyView(Image(nsImage: art).resizable().aspectRatio(contentMode: .fill))
            }
            if let entry = BrandIcons.entry(for: key) {
                return AnyView(BrandIconTileView(entry: entry, size: size))
            }
        }
        // ③ 网站图标模式:域名/标题实时匹配品牌方砖（含抓取中/失败的品牌兜底展示）
        let settingsUse = AppSettings.shared.useWebsiteIcons
        if settingsUse, card.useWebsiteIcon || card.iconIsFromWebsite,
           let entry = BrandIcons.match(host: IconService.host(fromWebsite: card.website), title: card.title) {
            return AnyView(BrandIconTileView(entry: entry, size: size))
        }
        return nil
    }

    private var symbolCircle: some View {
        let sym = resolvedSymbol
        let base = CardColor.color(named: color)
        return Circle()
            .fill(base)
            .overlay(
                Image(systemName: SymbolModel.shared.sfSymbol(for: sym))
                    .font(.system(size: size * 0.5, weight: .medium))
                    .foregroundStyle(base == Color(nsColor: .white) ? Color.primary : Color.white)
            )
            .frame(width: size, height: size)
    }

    private var resolvedSymbol: String {
        guard let symbol else { return "custom" }
        if symbol == "credit_card", let number = creditCardNumber, !number.isEmpty {
            return SymbolModel.shared.creditCardSymbol(forNumber: number)
        }
        return symbol
    }
}

/// 品牌图标方砖:品牌色圆角矩形 + 白色 SF Symbol / 字母花押。
/// （与 SymbolModel 同约定,不附带原厂商标图;图稿可经 BrandIcons.bundledImage 覆盖。）
struct BrandIconTileView: View {
    let entry: BrandIcons.Entry
    var size: CGFloat = 32

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(Color(hex: entry.hex))
            .overlay { glyph.padding(size * 0.18) }
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
            )
            .frame(width: size, height: size)
    }

    @ViewBuilder private var glyph: some View {
        switch entry.glyph {
        case .sf(let name):
            Image(systemName: name)
                .font(.system(size: size * 0.52, weight: .semibold))
                .foregroundStyle(.white)
        case .monogram(let text):
            Text(text)
                .font(.system(size: size * (text.count > 1 ? 0.34 : 0.5), weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}

/// StrengthIndicator (Services/StrengthIndicator.h): 0–4 segments + crack time.
struct StrengthIndicatorView: View {
    let strength: PasswordStrength

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 3) {
                ForEach(0..<4, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(i < strength.score + (strength.score == 0 ? 1 : 0) ? color(for: strength.score) : Color(nsColor: .quaternaryLabelColor))
                        .frame(height: 4)
                }
            }
            Text("\(L10n.t("crack_time_prompt")) \(strength.crackTimeText)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func color(for score: Int) -> Color {
        switch score {
        case 0: return .red
        case 1: return .orange
        case 2: return .yellow
        case 3: return .green
        default: return .green
        }
    }
}

extension View {
    /// Places the toast overlay + click-activity tracking on any root view.
    func withToastAndActivity() -> some View {
        modifier(ToastActivityModifier())
    }
}

private struct ToastActivityModifier: ViewModifier {
    @EnvironmentObject var ctx: AppContext
    @EnvironmentObject var toast: AppToast

    func body(content: Content) -> some View {
        content
            .onTapGesture { ctx.touch() }
            .onMoveCommand { _ in ctx.touch() }
            .overlay(alignment: .top) {
                if let message = toast.message {
                    ToastHud(text: message)
                }
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.82), value: toast.message)
    }
}

/// Apple 风格 HUD 提示:窗口顶部居中的悬浮胶囊——毛玻璃材质 + 白字 +
/// 勾图标,带描边与投影,缩放淡入;悬浮于内容之上,不挤压布局,
/// 且允许点击穿透(不挡下方控件)。约 2s 后自动消失(见 AppToast.show)。
private struct ToastHud: View {
    let text: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14, weight: .medium))
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 15)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 14, y: 5)
        .padding(.top, 8)
        .allowsHitTesting(false)
        .transition(.move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.86, anchor: .top)))
    }
}

/// Standard chrome for sheet dialogs: title bar,
/// content, cancel/OK row (keyboard-wired), optional search field.
struct SheetShell<Content: View>: View {
    let title: String
    var minWidth: CGFloat = 400
    /// 弹窗最小高度:含 List/滚动区的内容必须给足高度,
    /// 否则滚动容器理想高度为 0,弹窗塌缩成只剩进度条/按钮。
    var minHeight: CGFloat = 120
    var okTitle: String? = nil
    var okDisabled: Bool = false
    var search: Binding<String>? = nil
    var onAppearBody: (() -> Void)? = nil
    let onCancel: () -> Void
    let onOk: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            Text(title).font(.headline).padding(.top, 14).padding(.bottom, 10)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(14)
            Divider()
            HStack {
                if let s = search {
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField(L10n.t("search_text"), text: s)
                            .textFieldStyle(.plain)
                    }
                    .padding(5)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                Spacer()
                Button(L10n.t("cancel_button"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(okTitle ?? L10n.t("ok_button"), action: onOk)
                    .keyboardShortcut(.defaultAction)
                    .disabled(okDisabled)
            }
            .padding(10)
        }
        .frame(minWidth: minWidth, minHeight: minHeight)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { onAppearBody?() }
    }
}


/// NSVisualEffectView matching the window background — the sidebar uses the
/// same flat dark tone as the content panes (no translucent material).
struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .windowBackground
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - 表单行(标签左对齐 110pt,内容填满)

/// 设置/表单通用的「标签 + 内容」行。
struct LabeledRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack {
            Text(label).frame(width: 110, alignment: .leading)
            content.frame(maxWidth: .infinity)
        }
    }
}
