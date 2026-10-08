import SwiftUI

import UPasswordsCore

// MARK: - 品牌色板（iOS 主 App 与 AutoFill 扩展共用；不入 macOS target）

enum Brand {
    static let bg      = Color(hex: 0x222221)   // 页面底
    static let surface = Color(hex: 0x252523)   // 分组容器底
    static let card    = Color(hex: 0x2F2F2C)   // 卡面 / 列表行
    static let elev    = Color(hex: 0x393A37)   // 弹层 / 按压
    static let fg      = Color(hex: 0xF2F2EF)   // 主文字
    static let muted   = Color(hex: 0x8E8E89)   // 次要文字
    static let accent  = Color(hex: 0x4C8FD9)   // 蓝钥匙 — 唯一强调色
    static let green   = Color(hex: 0x57C84B)   // 绿钥匙 — 成功 / TOTP
    static let yellow  = Color(hex: 0xF2B84B)   // 黄钥匙 — 弱密码 / 提醒
    static let red     = Color(hex: 0xFF375F)   // 泄露 / 错误
    static let onAccent = Color(hex: 0x10131A)  // 强调色上的文字

    /// 条目颜色词表 → 色板。
    static func tileColor(_ name: String?) -> Color {
        switch name {
        case "blue": return accent
        case "green": return green
        case "yellow": return yellow
        case "red": return red
        case "purple": return Color(hex: 0x9B7EDE)
        case "teal": return Color(hex: 0x4FB8B0)
        default: return Color(hex: 0x6F6F69) // gray
        }
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}

// MARK: - 三钥匙品牌标识（黄左、绿中、蓝右）

struct BrandLogo: View {
    var size: CGFloat = 92

    var body: some View {
        Canvas { ctx, canvasSize in
            let s = canvasSize.width / 100
            let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
            let keys: [(angle: Double, color: Color)] = [
                (-.pi / 7, Brand.yellow),
                (0, Brand.green),
                (.pi / 7, Brand.accent),
            ]
            for (angle, color) in keys {
                var c = ctx
                c.translateBy(x: center.x, y: center.y + 6 * s)
                c.rotate(by: .radians(angle))
                // 钥匙环
                let ring = Path(ellipseIn: CGRect(x: -15 * s, y: -52 * s, width: 30 * s, height: 30 * s))
                c.stroke(ring, with: .color(color), lineWidth: 6.5 * s)
                // 钥匙杆 + 齿
                var stem = Path()
                stem.move(to: CGPoint(x: 0, y: -22 * s))
                stem.addLine(to: CGPoint(x: 0, y: 34 * s))
                stem.move(to: CGPoint(x: 0, y: 14 * s))
                stem.addLine(to: CGPoint(x: 10 * s, y: 14 * s))
                stem.move(to: CGPoint(x: 0, y: 26 * s))
                stem.addLine(to: CGPoint(x: 10 * s, y: 26 * s))
                c.stroke(stem, with: .color(color), style: StrokeStyle(lineWidth: 6.5 * s, lineCap: .round))
            }
        }
        .frame(width: size, height: size * 0.92)
        .accessibilityLabel(L10n.t("ios_brand_logo_a11y"))
    }
}

// MARK: - 通用组件

/// 条目图标：加密库里有归一化图标数据（网站 favicon 等）优先展示,
/// 否则 SF Symbol,再否则首字符单色方块（不伪造第三方 logo）。
struct CardIconView: View {
    let card: Card
    var size: CGFloat = 40

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
    }

    var body: some View {
        if let data = card.iconData, let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .background(shape.fill(Color(UIColor.tertiarySystemFill)))
                .clipShape(shape)
        } else {
            let tint = Brand.tileColor(card.color)
            shape
                .fill(tint.opacity(0.16))
                .frame(width: size, height: size)
                .overlay(
                    Group {
                        if let symbol = card.symbol, !symbol.isEmpty {
                            Image(systemName: symbol)
                                .font(.system(size: size * 0.46, weight: .medium))
                                .foregroundStyle(tint)
                        } else {
                            Text(card.title.prefix(1))
                                .font(.system(size: size * 0.44, weight: .semibold, design: .rounded))
                                .foregroundStyle(tint)
                        }
                    }
                )
        }
    }
}

/// 空态。
struct EmptyStateView: View {
    let icon: String
    let title: String
    var detail: String? = nil

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Brand.muted)
            Text(title)
                .font(.headline)
                .foregroundStyle(Brand.fg)
            if let detail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(Brand.muted)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .padding(.horizontal, 32)
    }
}

/// 密码强度条（0…4）。
struct StrengthBar: View {
    let score: Int

    private var color: Color {
        switch score {
        case 0: return Brand.red
        case 1: return Brand.red
        case 2: return Brand.yellow
        case 3: return Brand.green
        default: return Brand.green
        }
    }
    private var label: String {
        [L10n.t("ios_strength_very_weak"), L10n.t("ios_strength_weak"), L10n.t("ios_strength_fair"),
         L10n.t("ios_strength_strong"), L10n.t("ios_strength_very_strong")][max(0, min(4, score))]
    }

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 3) {
                ForEach(0..<4, id: \.self) { i in
                    Capsule()
                        .fill(i < score ? color : Brand.fg.opacity(0.12))
                        .frame(width: 26, height: 5)
                }
            }
            Text(label)
                .font(.caption)
                .foregroundStyle(color)
        }
        .accessibilityLabel(String(format: L10n.t("ios_strength_a11y_fmt"), label))
    }
}

/// 分组卡片容器（深色 inset grouped 风格）。
struct BrandSection<Content: View>: View {
    var title: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Brand.muted)
                    .textCase(nil)
                    .padding(.horizontal, 16)
            }
            VStack(spacing: 0) { content }
                .background(Brand.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

/// 行分隔线（与图标缩进对齐）。
struct InsetDivider: View {
    var leading: CGFloat = 16
    var body: some View {
        Rectangle()
            .fill(Brand.fg.opacity(0.08))
            .frame(height: 0.5)
            .padding(.leading, leading)
    }
}
