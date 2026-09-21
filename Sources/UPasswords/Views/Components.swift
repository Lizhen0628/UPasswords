import SwiftUI

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

    static func color(named name: String?) -> Color {
        guard let name, let c = CardColor(rawValue: name) else { return .accentColor }
        return c.color
    }
}

/// Mirrors `CardIcon` + `SymbolView` — renders a card's icon: custom symbol
/// (SF Symbol mapping via SymbolModel), website favicon placeholder, or the
/// credit-card brand symbol auto-detected from the number.
struct CardIconView: View {
    let symbol: String?
    let color: String?
    var size: CGFloat = 32
    var creditCardNumber: String? = nil

    var body: some View {
        let sym = resolvedSymbol
        let base = CardColor.color(named: color)
        Circle()
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

/// Toast overlay used by all windows (text_copied_message etc.).
struct ToastOverlay: View {
    @EnvironmentObject var toast: AppToast

    var body: some View {
        VStack {
            Spacer()
            if let msg = toast.message {
                Text(msg)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .shadow(radius: 4)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.25), value: toast.message)
        .padding(.bottom, 24)
        .allowsHitTesting(false)
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

    func body(content: Content) -> some View {
        content
            .onTapGesture { ctx.touch() }
            .onMoveCommand { _ in ctx.touch() }
    }
}

/// Standard chrome for the original's *SheetController dialogs: title bar,
/// content, cancel/OK row (keyboard-wired), optional search field.
struct SheetShell<Content: View>: View {
    let title: String
    var minWidth: CGFloat = 400
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
        .frame(minWidth: minWidth, minHeight: 120)
        .background(.regularMaterial)
        .onAppear { onAppearBody?() }
    }
}


/// NSVisualEffectView with the sidebar material — the authentic source-list
/// backdrop (replaces iOS-only `ShapeStyle.sidebar`).
struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .sidebar
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
