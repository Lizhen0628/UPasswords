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

    /// 红绿灯默认中心距窗口顶 ~14pt、距左 ~15pt(fullSizeContentView 模式);
    /// 参考图红绿灯中心 (25.75, 25.75)pt → 下移 12pt、右移 11pt。
    static let trafficLightShift: CGFloat = 12
    static let trafficLightShiftX: CGFloat = 11
    static let lockWindowSize = NSSize(width: 500, height: 380)

    private weak var window: NSWindow?
    private var mode: WindowChromeMode = .plain
    private var originalY: [ObjectIdentifier: CGFloat] = [:]
    private var originalX: [ObjectIdentifier: CGFloat] = [:]
    private var savedMainFrame: NSRect?
    private var observed = false
    private var fastTimer: Timer?
    private var slowTimer: Timer?

    private func log(_ s: String) {
        // 开发期排障主通道:写统一日志文件(release dist 也生效),终端可见 stderr。
        Log.debug("chrome", s)
    }

    func attach(window: NSWindow, mode: WindowChromeMode) {
        let isNewWindow = self.window !== window
        self.window = window
        self.mode = mode
        log("attach mode=\(mode) window=\(ObjectIdentifier(window).hashValue) isNewWindow=\(isNewWindow) frame=\(window.frame)")
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
            // 禁用系统拖拽:条带顶部 ~28pt 是系统的「标题栏区」,在圆钮上按下并
            // 轻移会触发原生标题栏拖拽会话,Tahoe 随之绘制玻璃标题栏遮罩,把圆钮
            // 上半截盖住。窗口拖动由 WindowDragArea 的 setFrameOrigin 接管,
            // 不需要 NSWindow.isMovable(程序化移动不受它影响)。
            if win.isMovable {
                win.isMovable = false
                log("enforce: main → isMovable=false (kill system titlebar drag/mask)")
            }
            shiftLights(win, down: true)
        case .lock, .plain:
            if win.titleVisibility != .visible { win.titleVisibility = .visible }
            if win.titlebarAppearsTransparent { win.titlebarAppearsTransparent = false }
            if win.styleMask.contains(.fullSizeContentView) { win.styleMask.remove(.fullSizeContentView) }
            if mode == .lock, win.styleMask.contains(.resizable) { win.styleMask.remove(.resizable) }
            if !win.styleMask.contains(.resizable), mode == .plain { win.styleMask.insert(.resizable) }
            win.isMovableByWindowBackground = true
            if !win.isMovable {
                win.isMovable = true
                log("enforce: \(mode) → isMovable=true (standard titlebar)")
            }
            shiftLights(win, down: false)
            resizeForMode(win, animated: false)   // 窗口恢复可能改回尺寸,随自愈一起纠正
        }
    }

    /// 三灯在容器内下移+右移(NSView 不裁剪子视图,移出 28pt 容器仍可见可点)。
    private func shiftLights(_ win: NSWindow, down: Bool) {
        for type: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = win.standardWindowButton(type) else { continue }
            let id = ObjectIdentifier(button)
            if originalY[id] == nil { originalY[id] = button.frame.origin.y }
            if originalX[id] == nil { originalX[id] = button.frame.origin.x }
            if let base = originalY[id] {
                let target = down ? base - Self.trafficLightShift : base
                if abs(button.frame.origin.y - target) > 0.5 {
                    button.frame.origin.y = target
                }
            }
            if let baseX = originalX[id] {
                let targetX = down ? baseX + Self.trafficLightShiftX : baseX
                if abs(button.frame.origin.x - targetX) > 0.5 {
                    button.frame.origin.x = targetX
                }
            }
        }
    }

    /// 锁屏用小窗(固定尺寸),解锁恢复原主窗尺寸。
    private func resizeForMode(_ win: NSWindow, animated: Bool) {
        switch mode {
        case .lock:
            win.title = L10n.tBranded("app_title")
            // 幂等守卫:已在锁屏尺寸就不再动。定时器/通知/动画期间的重入会反复
            // 走到这里,每次按当前 frame 重算中心会把窗口越推越偏(位置漂移)。
            if abs(win.frame.width - Self.lockWindowSize.width) < 2 { return }
            log("lock-resize: current=\(win.frame) fullSizeCV=\(win.styleMask.contains(.fullSizeContentView))")
            // 直接以锁定态启动时窗口天生就是锁定尺寸——这种框架绝不能存为
            // 「主窗框架」,否则解锁后主界面会被塞进小窗(内容挤压错位)。
            if win.frame.width >= Self.lockWindowSize.width + 60 {
                savedMainFrame = win.frame
                log("lock-resize: saved=\(win.frame)")
            }
            let center = NSPoint(x: win.frame.midX, y: win.frame.midY)
            win.setContentSize(Self.lockWindowSize)   // frame 由标题栏高度自动加出
            var f = win.frame
            f.origin = NSPoint(x: center.x - f.width / 2, y: center.y - f.height / 2)
            f = Self.clampedToVisible(f, window: win)
            win.setFrame(f, display: true, animate: animated)
            log("lock-resize: shrank to \(win.frame)")
        case .main:
            guard let saved = savedMainFrame else { return }
            log("main-resize: current=\(win.frame) saved=\(saved)")
            savedMainFrame = nil
            // 解锁过渡中 SwiftUI 会先按内容最小尺寸(minWidth 760)把 500 宽的
            // 锁屏窗撑回最小主窗尺寸,若此时 frame 恰好卡在最小宽度,说明是被
            // 过渡挤压出来的「中毒」frame(并已被 SwiftUI 持久化),不是用户
            // 调过的尺寸 → 回退默认尺寸,避免主窗口从此永远是最小尺寸。
            let minMainWidth: CGFloat = 760   // MainWindowView.frame(minWidth:)
            let restore: NSRect
            if saved.width <= minMainWidth + 0.5 {
                let visible = win.screen?.visibleFrame
                    ?? NSScreen.main?.visibleFrame
                    ?? NSRect(x: 0, y: 0, width: 970, height: 819)
                let size = CGSize(width: 970, height: 819)
                restore = NSRect(
                    x: visible.midX - size.width / 2,
                    y: visible.midY - size.height / 2,
                    width: size.width,
                    height: size.height
                )
            } else {
                restore = Self.clampedToVisible(saved, window: win)
            }
            // 立即恢复(不再等 0.15s):否则最小尺寸约束先把窗口压小,用户看到
            // 主界面闪缩,SwiftUI 还可能把这个小 frame 持久化下来。
            win.setFrame(restore, display: true, animate: animated)
            log("main-resize: restored now=\(win.frame)")
            // SwiftUI 布局稍后仍可能再改窗口(解锁过渡期会重放恢复的 frame),
            // 复核一次;此后不再干预用户的调整。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self, let win = self.window, self.mode == .main else { return }
                if abs(win.frame.width - restore.width) > 1 {
                    log("main-resize: re-asserting \(restore), now=\(win.frame)")
                    win.setFrame(restore, display: true, animate: false)
                }
            }
        case .plain:
            win.title = L10n.tBranded("app_title")
        }
    }

    /// 把窗口位置钳回可见区域,防止历史漂移的 frame 让窗口大半落在屏幕外。
    private static func clampedToVisible(_ frame: NSRect, window: NSWindow) -> NSRect {
        let visible = window.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1512, height: 948)
        var f = frame
        if f.width < visible.width {
            f.origin.x = min(max(f.origin.x, visible.minX), visible.maxX - f.width)
        }
        if f.height < visible.height {
            f.origin.y = min(max(f.origin.y, visible.minY), visible.maxY - f.height)
        }
        return f
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

    /// 自行计算位移移动窗口(setFrameOrigin),不走 performDrag/系统拖拽会话:
    /// macOS 26 Tahoe 在系统拖拽期间会给 fullSizeContentView 窗口绘制
    /// 玻璃标题栏遮罩,把自绘工具栏条带和标题盖住(用户按住鼠标时复现)。
    final class DragView: NSView {
        private var dragStartMouse: NSPoint?
        private var dragStartWindowOrigin: NSPoint?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                Log.debug("chrome", "dragArea installed frame=\(self.frame) hidden=\(isHidden) window=\(window != nil)")
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            let hit = super.hitTest(point)
            if hit != nil, dragStartMouse == nil {
                Log.debug("chrome", "dragArea hitTest hit at \(point)")
            }
            return hit
        }

        override func mouseDown(with event: NSEvent) {
            dragStartMouse = NSEvent.mouseLocation
            dragStartWindowOrigin = window?.frame.origin
            Log.debug("chrome", "dragArea mouseDown at \(NSEvent.mouseLocation), windowOrigin=\(dragStartWindowOrigin.map { "\($0)" } ?? "nil")")
        }

        override func mouseDragged(with event: NSEvent) {
            guard let win = window,
                  let startMouse = dragStartMouse,
                  let startOrigin = dragStartWindowOrigin else { return }
            let now = NSEvent.mouseLocation
            var newY = startOrigin.y + (now.y - startMouse.y)
            // 与系统拖拽一致:标题栏不允许被拖到菜单栏之上
            if let visible = win.screen?.visibleFrame {
                newY = min(newY, visible.maxY)
            }
            win.setFrameOrigin(NSPoint(
                x: startOrigin.x + (now.x - startMouse.x),
                y: newY
            ))
            Log.debug("chrome", "dragArea dragged to (\(Int(win.frame.origin.x)),\(Int(win.frame.origin.y)))")
        }

        override func mouseUp(with event: NSEvent) {
            if dragStartMouse != nil {
                Log.debug("chrome", "dragArea mouseUp")
            }
            dragStartMouse = nil
            dragStartWindowOrigin = nil
        }
    }
}

// MARK: - 自绘工具栏条带(Safe 布局:红绿灯区 | 数据库名标题 | 8 圆钮,参考图实测)

struct SafeTitleBarView: View {
    @EnvironmentObject var ctx: AppContext

    /// 参考图实测(2x 截图 ÷2):8 个圆钮中心距 574.75…943.75pt,
    /// 相邻间隙(按条目宽 max(35.5, 标签宽) 折算)。
    private let specs: [SafeToolbarButtonSpec] = [
        .add, .delete, .lock, .sync, .generator, .sorting, .aboveAll, .preferences,
    ]
    private let gaps: [CGFloat] = [16.5, 16.5, 8.5, 23.5, 15.5, 16.5, 8.5]

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Spacer().frame(width: 76) // 红绿灯占位

            Text(ctx.databaseName.isEmpty ? L10n.tBranded("app_title") : ctx.databaseName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.92))
                .padding(.leading, 32)
                .padding(.top, 9)

            Spacer(minLength: 0)

            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(specs.enumerated()), id: \.element.labelKey) { index, spec in
                    if index > 0 { Spacer().frame(width: gaps[index - 1]) }
                    SafeToolbarButton(spec: spec, ctx: ctx)
                }
            }
            .padding(.top, 5)
            .padding(.trailing, 8)
        }
        .frame(height: 70)
        .background(WindowDragArea())
        .background(Color.safeBackground)
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
        labelKey: "add_button", helpKey: "add_card_command", symbol: { "plus.circle" },
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
        labelKey: "generator_button", helpKey: "generator_command", symbol: { "key" },
        isActive: { _ in false }, isEnabled: { _ in true },
        action: { $0.activeSheet = .generator })
    static let sorting = SafeToolbarButtonSpec(
        labelKey: "sorting_button", helpKey: "sorting_command",
        symbol: { "arrow.up.arrow.down.square" },
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

// MARK: - 圆钮:35.5pt 白色描边圆环 + 16pt 白字形 + 10pt 灰 caption(参考图实测)

struct SafeToolbarButton: View {
    let spec: SafeToolbarButtonSpec
    @ObservedObject var ctx: AppContext
    @ObservedObject private var floatState = WindowFloatState.shared

    var body: some View {
        let active = spec.isActive(ctx)
        Button {
            spec.action(ctx)
        } label: {
            VStack(spacing: 5) {
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(active ? 0.55 : 0.20), lineWidth: 1)
                    Image(systemName: spec.symbol())
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(active ? Color.accentColor : .white)
                }
                .frame(width: 35.5, height: 35.5)
                Text(L10n.t(spec.labelKey))
                    .font(.system(size: 10))
                    .foregroundStyle(active ? Color.accentColor : Color.white.opacity(0.62))
                    .lineLimit(1)
                    .fixedSize()
            }
            .frame(minWidth: 35.5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 原应用工具栏按钮不做置灰(删除无选中时为安全空操作),与参考图亮度一致
        .help(L10n.t(spec.helpKey))
    }
}
