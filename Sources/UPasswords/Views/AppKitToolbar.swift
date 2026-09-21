//
//  AppKitToolbar.swift
//  UPasswords
//
//  Safe 工具栏的源码级 1:1 复刻 —— 最终方案:隐藏系统标题栏 + 全 SwiftUI 自绘。
//
//  调研结论(macOS 26 Tahoe 实测):
//  1. SwiftUI .toolbar:无法控制条带高度,ToolbarItemGroup 附加溢出胶囊;
//  2. AppKit NSToolbar 自定义 item:约束尺寸有效,但 Tahoe 会给尾随 item 群
//     绘制 Liquid Glass 胶囊背景(悬垂出条带),无公开 API 关闭;
//  3. 因此唯一像素级可控的做法:titlebarAppearsTransparent + 隐藏标题 +
//     自绘 66pt 条带,并把红绿灯按钮下移 19pt(NSView 默认不裁剪子视图,
//     按钮移出其 28pt 容器仍正常渲染与响应),使三灯在条带内垂直居中;
//  4. 锁屏/解锁相位切换与窗口恢复会偶发重置 chrome → WindowChromeManager
//     以通知 + 永久低频定时器幂等重应用(自愈)。
//

import SwiftUI
import AppKit

// MARK: - 窗口 chrome 管理(标题栏模式 + 红绿灯位置,自愈式)

/// 窗口外观模式:Safe 的锁屏/设置窗是普通标题栏小窗口,主窗口是隐藏标题栏 + 自绘条带。
enum WindowChromeMode {
    case main   // 隐藏标题栏,红绿灯下移 19pt 与 66pt 条带对齐
    case lock   // 普通标题栏,窗口缩至 500×380
    case plain  // 普通标题栏,不动尺寸(首次设置向导)
}

/// 单例管理器:同一窗口在 锁定/解锁 相位间切换时 chrome 需要来回切换;
/// SwiftUI 布局/窗口恢复会偶发把系统标题栏改回来,因此用「通知 + 永久低频
/// 定时器」自愈重应用。originalY 按按钮实例全局缓存,避免跨相位重复累加位移。
@MainActor
final class WindowChromeManager: NSObject {
    static let shared = WindowChromeManager()

    /// 红绿灯默认中心距窗口顶 ~14pt,Safe 66pt 条带中心为 33pt → 下移 19pt
    static let trafficLightShift: CGFloat = 19
    static let lockWindowSize = NSSize(width: 500, height: 380)

    private weak var window: NSWindow?
    private var mode: WindowChromeMode = .plain
    private var originalY: [ObjectIdentifier: CGFloat] = [:]
    private var savedMainFrame: NSRect?
    private var observed = false
    private var fastTimer: Timer?
    private var slowTimer: Timer?

    func attach(window: NSWindow, mode: WindowChromeMode) {
        let isNewWindow = self.window !== window
        self.window = window
        self.mode = mode
        if isNewWindow {
            observed = false
            fastTimer?.invalidate()
            observe(window)
        }
        enforce()
        resizeForMode(window, animated: !isNewWindow)
        startTimers()
    }

    func setMode(_ mode: WindowChromeMode) {
        guard let win = window else { return }
        self.mode = mode
        enforce()
        resizeForMode(win, animated: true)
    }

    private func observe(_ win: NSWindow) {
        guard !observed else { return }
        observed = true
        for name in [NSWindow.didResizeNotification, NSWindow.didBecomeKeyNotification,
                     NSWindow.didBecomeMainNotification, NSWindow.didExitFullScreenNotification,
                     NSWindow.didEnterFullScreenNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(enforceDelayed), name: name, object: win)
        }
    }

    /// 立即 + 短延迟各执行一次(SwiftUI 常在本轮 runloop 稍后重置布局)
    @objc private func enforceDelayed() {
        enforce()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.enforce() }
    }

    private func startTimers() {
        fastTimer?.invalidate()
        var ticks = 0
        fastTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] timer in
            ticks += 1
            Task { @MainActor in self?.enforce() }
            if ticks >= 40 { timer.invalidate() }   // 前 10s 高频
        }
        if slowTimer == nil {
            // 之后 1s 永久低频自愈,代价可忽略
            slowTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.enforce() }
            }
        }
    }

    /// 幂等应用当前模式的全部 chrome 设置。
    func enforce() {
        guard let win = window else { return }
        if win.toolbar != nil { win.toolbar = nil }
        switch mode {
        case .main:
            if win.titleVisibility != .hidden { win.titleVisibility = .hidden }
            if !win.titlebarAppearsTransparent { win.titlebarAppearsTransparent = true }
            if !win.styleMask.contains(.fullSizeContentView) { win.styleMask.insert(.fullSizeContentView) }
            if !win.styleMask.contains(.resizable) { win.styleMask.insert(.resizable) }
            win.isMovableByWindowBackground = false   // 仅自绘条可拖动
            shiftLights(win, down: true)
        case .lock, .plain:
            if win.titleVisibility != .visible { win.titleVisibility = .visible }
            if win.titlebarAppearsTransparent { win.titlebarAppearsTransparent = false }
            if win.styleMask.contains(.fullSizeContentView) { win.styleMask.remove(.fullSizeContentView) }
            if mode == .lock, win.styleMask.contains(.resizable) { win.styleMask.remove(.resizable) }
            if !win.styleMask.contains(.resizable), mode == .plain { win.styleMask.insert(.resizable) }
            win.isMovableByWindowBackground = true
            shiftLights(win, down: false)
            resizeForMode(win, animated: false)   // 窗口恢复可能改回尺寸,随自愈一起纠正
        }
    }

    /// 三灯在容器内下移(NSView 不裁剪子视图,移出 28pt 容器仍可见可点)。
    private func shiftLights(_ win: NSWindow, down: Bool) {
        for type: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = win.standardWindowButton(type) else { continue }
            let id = ObjectIdentifier(button)
            if originalY[id] == nil { originalY[id] = button.frame.origin.y }
            if let base = originalY[id] {
                let target = down ? base - Self.trafficLightShift : base
                if abs(button.frame.origin.y - target) > 0.5 {
                    button.frame.origin.y = target
                }
            }
        }
    }

    /// 锁屏用小窗(固定尺寸),解锁恢复原主窗尺寸。
    private func resizeForMode(_ win: NSWindow, animated: Bool) {
        switch mode {
        case .lock:
            win.title = L10n.tBranded("app_title")
            guard abs(win.frame.width - Self.lockWindowSize.width) > 4
                    || abs(win.frame.height - Self.lockWindowSize.height - 28) > 4 else { return }
            savedMainFrame = win.frame   // 无条件保存,解锁时恢复
            let center = NSPoint(x: win.frame.midX, y: win.frame.midY)
            win.setContentSize(Self.lockWindowSize)   // frame 由标题栏高度自动加出
            var f = win.frame
            f.origin = NSPoint(x: center.x - f.width / 2, y: center.y - f.height / 2)
            win.setFrame(f, display: true, animate: animated)
        case .main:
            // 仅当当前还停留在锁屏小窗尺寸时恢复,不覆盖用户手动调整
            if let f = savedMainFrame, abs(win.frame.width - Self.lockWindowSize.width) < 8 {
                savedMainFrame = nil
                // 延迟到 SwiftUI 布局落定后再恢复,否则会被中间态覆盖
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    win.setFrame(f, display: true, animate: animated)
                }
            }
        case .plain:
            win.title = L10n.tBranded("app_title")
        }
    }
}

/// 挂载到窗口即把 chrome 托管给 WindowChromeManager;view 随相位切换销毁时
/// 不影响管理器(下一次 attach 会重新接管同一窗口)。
struct WindowChromeConfigurator: NSViewRepresentable {
    let mode: WindowChromeMode

    /// 挂载到窗口时主动回调,避免 updateNSView 早于窗口挂载的竞态
    final class ConfigView: NSView {
        var onWindow: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let w = window { onWindow?(w) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(mode: mode) }

    func makeNSView(context: Context) -> NSView {
        let view = ConfigView()
        view.onWindow = { win in
            context.coordinator.attach(window: win)
        }
        context.coordinator.retryAttach(from: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.mode = mode
        context.coordinator.retryAttach(from: nsView)
    }

    @MainActor
    final class Coordinator {
        var mode: WindowChromeMode
        private weak var sourceView: NSView?
        private var attempts = 0

        init(mode: WindowChromeMode) { self.mode = mode }

        func attach(window: NSWindow) {
            WindowChromeManager.shared.attach(window: window, mode: mode)
        }

        /// 窗口可能尚未挂载:短间隔重试,直到拿到窗口为止(最多 ~8s)
        func retryAttach(from view: NSView) {
            sourceView = view
            attempts = 0
            tryAttach()
        }

        private func tryAttach() {
            if let win = sourceView?.window {
                WindowChromeManager.shared.attach(window: win, mode: mode)
                return
            }
            attempts += 1
            guard attempts < 80 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.tryAttach()
            }
        }
    }
}

// MARK: - 空白处可拖拽窗口

struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}

// MARK: - 自绘工具栏条带(Safe 布局:红绿灯区 | 侧栏开关+标题 | 8 圆钮)

struct SafeTitleBarView: View {
    @EnvironmentObject var ctx: AppContext
    @Binding var columnVisibility: NavigationSplitViewVisibility

    private let specs: [SafeToolbarButtonSpec] = [
        .add, .delete, .lock, .sync, .generator, .sorting, .aboveAll, .preferences,
    ]

    var body: some View {
        HStack(spacing: 0) {
            Spacer().frame(width: 76) // 红绿灯占位

            Button {
                withAnimation {
                    columnVisibility = columnVisibility == .all ? .doubleColumn : .all
                }
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text(ctx.databaseName.isEmpty ? L10n.tBranded("app_title") : ctx.databaseName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .padding(.leading, 6)

            Spacer(minLength: 0)

            HStack(spacing: 18) {
                ForEach(specs, id: \.labelKey) { spec in
                    SafeToolbarButton(spec: spec, ctx: ctx)
                }
            }
            .padding(.top, 4)
            .padding(.trailing, 12)
        }
        .frame(height: 66)
        .background(WindowDragArea())
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - 「Above all」窗口置顶状态

final class WindowFloatState: ObservableObject {
    static let shared = WindowFloatState()
    @Published var floating = false

    func toggle() {
        floating.toggle()
        NSApp.keyWindow?.level = floating ? .floating : .normal
    }
}

// MARK: - 按钮描述(8 项,与原应用工具栏一一对应)

struct SafeToolbarButtonSpec {
    let labelKey: String
    let helpKey: String
    let symbol: @MainActor () -> String
    let isActive: @MainActor (AppContext) -> Bool
    let isEnabled: @MainActor (AppContext) -> Bool
    let action: @MainActor (AppContext) -> Void

    static let add = SafeToolbarButtonSpec(
        labelKey: "add_button", helpKey: "add_card_command", symbol: { "plus" },
        isActive: { _ in false }, isEnabled: { _ in true },
        action: { $0.activeSheet = .addCard })
    static let delete = SafeToolbarButtonSpec(
        labelKey: "delete_button", helpKey: "delete_command", symbol: { "trash" },
        isActive: { _ in false }, isEnabled: { $0.selectedCardId != nil },
        action: { if let id = $0.selectedCardId { $0.trashCard(id) } })
    static let lock = SafeToolbarButtonSpec(
        labelKey: "lock_button", helpKey: "lock_command", symbol: { "lock.fill" },
        isActive: { _ in false }, isEnabled: { _ in true },
        action: { $0.lock() })
    static let sync = SafeToolbarButtonSpec(
        labelKey: "sync_button", helpKey: "sync_command",
        symbol: { "arrow.triangle.2.circlepath" },
        isActive: { _ in false }, isEnabled: { _ in true },
        action: { ctx in Task { await ctx.sync() } })
    static let generator = SafeToolbarButtonSpec(
        labelKey: "generator_button", helpKey: "generator_command", symbol: { "key.fill" },
        isActive: { _ in false }, isEnabled: { _ in true },
        action: { $0.activeSheet = .generator })
    static let sorting = SafeToolbarButtonSpec(
        labelKey: "sorting_button", helpKey: "sorting_command",
        symbol: { "arrow.up.arrow.down" },
        isActive: { _ in false }, isEnabled: { _ in true },
        action: { $0.activeSheet = .sorting })
    static let aboveAll = SafeToolbarButtonSpec(
        labelKey: "above_all_button", helpKey: "above_all_button",
        symbol: { WindowFloatState.shared.floating ? "pin.fill" : "pin" },
        isActive: { _ in WindowFloatState.shared.floating }, isEnabled: { _ in true },
        action: { _ in WindowFloatState.shared.toggle() })
    static let preferences = SafeToolbarButtonSpec(
        labelKey: "preferences_button", helpKey: "preferences_command", symbol: { "gearshape" },
        isActive: { _ in false }, isEnabled: { _ in true },
        action: { $0.activeSheet = .preferences })

    private init(labelKey: String, helpKey: String,
                 symbol: @MainActor @escaping () -> String,
                 isActive: @MainActor @escaping (AppContext) -> Bool,
                 isEnabled: @MainActor @escaping (AppContext) -> Bool,
                 action: @MainActor @escaping (AppContext) -> Void) {
        self.labelKey = labelKey
        self.helpKey = helpKey
        self.symbol = symbol
        self.isActive = isActive
        self.isEnabled = isEnabled
        self.action = action
    }
}

// MARK: - 圆钮:32pt 白色描边圆环 + 13pt 字形 + 9pt caption

struct SafeToolbarButton: View {
    let spec: SafeToolbarButtonSpec
    @ObservedObject var ctx: AppContext
    @ObservedObject private var floatState = WindowFloatState.shared

    var body: some View {
        let active = spec.isActive(ctx)
        let enabled = spec.isEnabled(ctx)
        Button {
            spec.action(ctx)
        } label: {
            VStack(spacing: 4) {
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(active ? 1 : 0.75), lineWidth: 1.2)
                    Image(systemName: spec.symbol())
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(active ? Color.accentColor : .white)
                }
                .frame(width: 32, height: 32)
                Text(L10n.t(spec.labelKey))
                    .font(.system(size: 9))
                    .foregroundStyle(active ? Color.accentColor : .secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .frame(minWidth: 42)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .help(L10n.t(spec.helpKey))
    }
}
