import SwiftUI
import AppKit

/// shadcn/ui 设计语言的 SwiftUI 移植:zinc 中性色板(自适应明暗)、
/// 细描边 + 小圆角、muted 语义色、default/secondary/outline/ghost 按钮
/// 与 Badge 徽章。原生控件外观不变,仅对自绘 UI 生效。
enum Shadcn {
    // MARK: - 圆角(shadcn --radius: 0.5rem ≈ 8pt)

    static let radiusSm: CGFloat = 6
    static let radiusMd: CGFloat = 8
    static let radiusLg: CGFloat = 10

    // MARK: - 自适应色板(zinc)

    private static func dynamic(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }))
    }

    private static func srgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
    }

    /// 面板/卡片底色:亮白、暗 = 窗口底色上叠 3.5% 白。
    static let card = dynamic(.white, srgb(255, 255, 255, 0.035))

    /// 浮层(toast/popover)底色,需不透明。
    static let popover = dynamic(.white, srgb(39, 39, 42))   // dark: zinc-800

    /// 细描边。亮: zinc-200 / 暗: 10% 白。
    static let border = dynamic(srgb(228, 228, 231), srgb(255, 255, 255, 0.10))

    /// 输入框描边(暗色下略强)。
    static let inputBorder = dynamic(srgb(228, 228, 231), srgb(255, 255, 255, 0.15))

    /// 悬浮/选中填充(accent)。亮: zinc-100 / 暗: 8% 白。
    static let accentFill = dynamic(srgb(244, 244, 245), srgb(255, 255, 255, 0.08))

    /// 次级填充(secondary 按钮、徽章)。
    static let secondaryFill = dynamic(srgb(244, 244, 245), srgb(255, 255, 255, 0.06))

    /// 主按钮底。亮: zinc-900 / 暗: zinc-50。
    static let primary = dynamic(srgb(24, 24, 27), srgb(250, 250, 250))

    /// 主按钮文字。
    static let primaryForeground = dynamic(srgb(250, 250, 250), srgb(24, 24, 27))

    /// 次要文字(muted-foreground)。亮: zinc-500 / 暗: zinc-400。
    static let mutedForeground = dynamic(srgb(113, 113, 122), srgb(161, 161, 170))

    /// destructive。亮: red-600 / 暗: red-500。
    static let destructive = dynamic(srgb(220, 38, 38), srgb(239, 68, 68))

    /// warning。亮: amber-600 / 暗: amber-400。
    static let warning = dynamic(srgb(217, 119, 6), srgb(251, 191, 36))
}

// MARK: - 卡片容器(bg-card + border + radius-lg)

extension View {
    /// shadcn Card 容器:面板底色 + 1pt 细描边 + 10pt 连续圆角。
    func shadcnCard(cornerRadius: CGFloat = Shadcn.radiusLg) -> some View {
        background(
            Shadcn.card,
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Shadcn.border, lineWidth: 1)
        )
    }

    /// shadcn Input 容器:底色 + 输入描边 + 8pt 圆角。
    func shadcnField(cornerRadius: CGFloat = Shadcn.radiusMd) -> some View {
        background(
            Shadcn.card,
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Shadcn.inputBorder, lineWidth: 1)
        )
    }
}

// MARK: - 按钮(default / secondary / outline / ghost / destructive × md / sm / icon)

struct ShadcnButtonStyle: ButtonStyle {
    enum Variant { case `default`, secondary, outline, ghost, destructive }
    enum Size { case md, sm, icon }

    var variant: Variant = .default
    var size: Size = .md

    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: fontSize, weight: .medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, horizontalPadding)
            .frame(minHeight: height)
            .background(background(pressed: configuration.isPressed))
            .clipShape(RoundedRectangle(cornerRadius: Shadcn.radiusSm, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Shadcn.radiusSm, style: .continuous)
                    .stroke(border, lineWidth: variant == .outline ? 1 : 0)
            )
            .contentShape(RoundedRectangle(cornerRadius: Shadcn.radiusSm, style: .continuous))
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    private var fontSize: CGFloat { size == .md ? 13 : 12 }
    private var height: CGFloat {
        switch size { case .md: return 28; case .sm: return 24; case .icon: return 28 }
    }
    private var horizontalPadding: CGFloat {
        switch size { case .md: return 14; case .sm: return 10; case .icon: return 0 }
    }

    private var foreground: Color {
        switch variant {
        case .default: return Shadcn.primaryForeground
        case .destructive: return .white
        default: return .primary
        }
    }

    private var border: Color {
        variant == .outline ? Shadcn.inputBorder : .clear
    }

    private func background(pressed: Bool) -> Color {
        let base: Color
        switch variant {
        case .default: base = Shadcn.primary
        case .secondary: base = Shadcn.secondaryFill
        case .outline: base = hovering ? Shadcn.accentFill : Shadcn.card
        case .ghost: base = hovering ? Shadcn.accentFill : .clear
        case .destructive: base = Shadcn.destructive
        }
        if pressed { return base.opacity(variant == .outline || variant == .ghost ? 0.7 : 0.8) }
        if hovering, variant == .default { return base.opacity(0.88) }
        if hovering, variant == .destructive { return base.opacity(0.88) }
        return base
    }
}

extension ButtonStyle where Self == ShadcnButtonStyle {
    static func shadcn(_ variant: ShadcnButtonStyle.Variant = .default,
                       size: ShadcnButtonStyle.Size = .md) -> ShadcnButtonStyle {
        ShadcnButtonStyle(variant: variant, size: size)
    }
}

// MARK: - 徽章(default / secondary / outline / destructive / warning)

struct ShadcnBadge: View {
    enum Variant { case `default`, secondary, outline, destructive, warning }

    let text: String
    var systemImage: String? = nil
    var variant: Variant = .default

    init(_ text: String, systemImage: String? = nil, variant: Variant = .default) {
        self.text = text
        self.systemImage = systemImage
        self.variant = variant
    }

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 10, weight: .semibold))
            }
            Text(text).font(.system(size: 11, weight: .medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2.5)
        .foregroundStyle(foreground)
        .background(background, in: RoundedRectangle(cornerRadius: Shadcn.radiusSm, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Shadcn.radiusSm, style: .continuous)
                .stroke(border, lineWidth: 1)
        )
    }

    private var foreground: Color {
        switch variant {
        case .default: return Shadcn.primaryForeground
        case .secondary: return .primary
        case .outline: return .primary
        case .destructive: return Shadcn.destructive
        case .warning: return Shadcn.warning
        }
    }

    private var background: Color {
        switch variant {
        case .default: return Shadcn.primary
        case .secondary: return Shadcn.secondaryFill
        case .outline: return .clear
        case .destructive: return Shadcn.destructive.opacity(0.12)
        case .warning: return Shadcn.warning.opacity(0.12)
        }
    }

    private var border: Color {
        switch variant {
        case .outline: return Shadcn.inputBorder
        case .destructive: return Shadcn.destructive.opacity(0.35)
        case .warning: return Shadcn.warning.opacity(0.35)
        default: return .clear
        }
    }
}
