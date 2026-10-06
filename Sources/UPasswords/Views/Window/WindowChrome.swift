//
//  WindowChrome.swift
//  UPasswords
//
//  主窗口自绘工具栏方案:隐藏系统标题栏 + 全 SwiftUI 自绘。
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

/// 窗口外观模式:锁屏/设置窗是普通标题栏小窗口,主窗口是隐藏标题栏 + 自绘条带。
enum WindowChromeMode {
    case main   // 隐藏标题栏,红绿灯下移 19pt 与 66pt 条带对齐
    case lock   // 普通标题栏,窗口缩至 500×380
    case plain  // 普通标题栏,不动尺寸(首次设置向导)
}

/// 单例管理器:同一窗口在 锁定/解锁 相位间切换时 chrome 需要来回切换;
/// SwiftUI 布局/窗口恢复会偶发把系统标题栏改回来,因此用「通知 + 永久低频
/// 定时器」自愈重应用。三灯容器基准按容器实例缓存,主窗框架随用随记,
/// 避免跨相位重复累加位移、窗口关闭重建后落回默认位置。
@MainActor
final class WindowChromeManager: NSObject {
    static let shared = WindowChromeManager()

    /// 红绿灯下移/右移量:主模式目标为中心 ≈ (23, 26.5)pt —— 与 52pt 工具栏
    /// 中线(26pt)同排(侧栏开关、标题同一水平中心线),并贴近邮件的灯位。
    static let trafficLightShift: CGFloat = 10
    static let trafficLightShiftX: CGFloat = 8
    static let lockWindowSize = NSSize(width: 500, height: 380)
    /// 主窗最小可用尺寸(MainWindowView 的 minWidth/minHeight);更小的 frame
    /// 是过渡期被挤压出来的「中毒」帧,不作为主窗框架记录/恢复。
    static let minMainWidth: CGFloat = 860
    static let minMainHeight: CGFloat = 460

    private weak var window: NSWindow?
    private var mode: WindowChromeMode = .plain
    /// 三灯公共容器的标准位置基准(按容器实例缓存)。
    private var lightContainerBase: [ObjectIdentifier: NSPoint] = [:]
    private var savedMainFrame: NSRect?
    private var observed = false
    private var kvoTokens: [NSKeyValueObservation] = []
    private var fastTimer: Timer?
    private var slowTimer: Timer?
    private var fastTicksRemaining = 0

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
        resizeForMode(window)
        startTimers()
    }

    /// 关闭主窗以外的所有可见标准窗口(如设置窗)——进入锁屏时调用,
    /// 避免它们残留在锁屏界面之上。NSPanel(菜单/状态栏/弹层)不在此列。
    func closeAuxiliaryWindows() {
        guard let main = window else { return }
        for w in NSApp.windows where w !== main {
            guard w.isVisible, !w.isKind(of: NSPanel.self) else { continue }
            Log.info("chrome", "close auxiliary window on lock title=\(w.title)")
            w.performClose(nil)
        }
    }

    private func observe(_ win: NSWindow) {
        guard !observed else { return }
        observed = true
        for name in [NSWindow.didResizeNotification, NSWindow.didBecomeKeyNotification,
                     NSWindow.didBecomeMainNotification, NSWindow.didEndLiveResizeNotification,
                     NSWindow.didMoveNotification, NSWindow.didExitFullScreenNotification,
                     NSWindow.didEnterFullScreenNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(enforceDelayed), name: name, object: win)
        }
        installChromeKVO(win)
    }

    /// SwiftUI 每次 view 更新都会把窗口标题栏外观重设回系统默认
    /// (titlebarAppearsTransparent=false 等),系统标题栏材质带随即画在窗口顶部,
    /// 盖住自绘条带——定时器自愈最多慢 1s,肉眼可见。这里 KVO 抓住每一次改动,
    /// 立刻异步改回,把可见窗口压到一帧以内。
    private func installChromeKVO(_ win: NSWindow) {
        kvoTokens.removeAll()
        kvoTokens.append(win.observe(\.titlebarAppearsTransparent, options: [.new]) { [weak self] _, change in
            guard change.newValue == false else { return }   // true 是我们想要的状态
            self?.chromeTampered(name: "titlebarAppearsTransparent")
        })
        kvoTokens.append(win.observe(\.titleVisibility, options: [.new]) { [weak self] _, change in
            guard change.newValue == .visible else { return }
            self?.chromeTampered(name: "titleVisibility")
        })
        kvoTokens.append(win.observe(\.styleMask, options: []) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, self.mode == .main, let win = self.window else { return }
                if !win.styleMask.contains(.fullSizeContentView) {
                    self.log("kvo: fullSizeContentView removed → re-inserting")
                    self.enforce()
                }
            }
        })
    }

    /// KVO 回调:立即异步纠正(SwiftUI setter 栈内不能同步重入)。
    nonisolated private func chromeTampered(name: String) {
        Task { @MainActor [weak self] in
            guard let self, self.mode == .main else { return }
            self.log("kvo: \(name) flipped → instant re-fix")
            self.enforce()
        }
    }

    /// 立即 + 短延迟各执行一次(SwiftUI 常在本轮 runloop 稍后重置布局)
    @objc private func enforceDelayed() {
        persistMainFrame()
        enforce()
        // 存量 GCD:调用点在主线程,延时复核仍在主队列,无需回主线程
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.enforce() }
    }

    /// 记录用户实际使用中的主窗框架:窗口被关闭后经菜单栏「显示」重建时,
    /// 据此把新窗口放回原位,而不是落在 SwiftUI 的默认尺寸/位置上。
    private func persistMainFrame() {
        guard mode == .main, let win = window else { return }
        guard !win.styleMask.contains(.fullScreen) else { return }
        let f = win.frame
        guard f.width >= Self.minMainWidth, f.height >= Self.minMainHeight else { return }
        if savedMainFrame != f {
            savedMainFrame = f
            log("persist main frame \(f)")
        }
    }

    private func startTimers() {
        fastTimer?.invalidate()
        fastTicksRemaining = 40
        fastTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            // [weak self] 必须写在 Task 的捕获列表里(常量绑定)。在外层闭包
            // 声明的 weak self 是可变捕获,Task(@Sendable)引用它直接编译报错,
            // CI 的 Swift 工具链会拒绝(本地旧工具链只降级为警告,容易漏)。
            Task { @MainActor [weak self] in
                self?.fastTick()
            }
        }
        if slowTimer == nil {
            slowTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.enforce()
                }
            }
        }
    }

    /// 前 10s 高频自愈,之后交给 1s 慢速定时器。
    @MainActor private func fastTick() {
        fastTicksRemaining -= 1
        enforce()
        if fastTicksRemaining <= 0 { fastTimer?.invalidate() }
    }

    /// 幂等应用当前模式的全部 chrome 设置。
    func enforce() {
        guard let win = window else { return }
        if win.toolbar != nil {
            win.toolbar = nil
            log("enforce: cleared non-nil toolbar (system injected?)")
        }
        switch mode {
        case .main:
            if win.titleVisibility != .hidden {
                win.titleVisibility = .hidden
                log("enforce: titleVisibility visible → hidden (someone reset it!)")
            }
            if !win.titlebarAppearsTransparent {
                win.titlebarAppearsTransparent = true
                log("enforce: titlebarAppearsTransparent false → true (someone reset it!)")
            }
            if !win.styleMask.contains(.fullSizeContentView) {
                win.styleMask.insert(.fullSizeContentView)
                log("enforce: fullSizeContentView missing → inserted (someone reset it!)")
            }
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
            // 隐藏标题栏(.windowStyle(.hiddenTitleBar))下,标题条由 PhaseTitleBar
            // 自绘。这里不再翻转 titleVisibility/transparent/fullSizeContentView——
            // 那会和 SwiftUI 的窗口样式维护反向打架;只管可调尺寸与拖动。
            if mode == .lock, win.styleMask.contains(.resizable) { win.styleMask.remove(.resizable) }
            if !win.styleMask.contains(.resizable), mode == .plain { win.styleMask.insert(.resizable) }
            win.isMovableByWindowBackground = true
            if !win.isMovable {
                win.isMovable = true
                log("enforce: \(mode) → isMovable=true (standard drag)")
            }
            shiftLights(win, down: false)
            resizeForMode(win)   // 窗口恢复可能改回尺寸,随自愈一起纠正
        }
    }

    /// 三灯整体下移+右移(NSView 不裁剪子视图,移出 28pt 容器仍可见可点)。
    /// 移动三灯的「公共容器」而非逐个按钮:容器内部的三灯排布(顺序、间距、
    /// Tahoe 悬停聚拢动画)完全交给系统;逐按钮改 frame 会与系统布局互相踩踏,
    /// 出现灯距拉大/顺序错乱/某颗灯不见了的错乱排布。
    /// 全屏由系统全权管理红绿灯(隐藏、悬停显示、独立灯位),不做位移干预。
    private func shiftLights(_ win: NSWindow, down: Bool) {
        if win.styleMask.contains(.fullScreen) {
            Log.debug("chrome", "shiftLights skipped (fullscreen, system-managed)")
            return
        }
        var containers: [ObjectIdentifier: NSView] = [:]
        for type: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            guard let superview = win.standardWindowButton(type)?.superview else { continue }
            containers[ObjectIdentifier(superview)] = superview
        }
        for (id, view) in containers {
            if lightContainerBase[id] == nil {
                lightContainerBase[id] = NSPoint(x: view.frame.origin.x, y: view.frame.origin.y)
            }
            guard let base = lightContainerBase[id] else { continue }
            let target = NSPoint(
                x: down ? base.x + Self.trafficLightShiftX : base.x,
                y: down ? base.y - Self.trafficLightShift : base.y
            )
            if abs(view.frame.origin.x - target.x) > 0.5 || abs(view.frame.origin.y - target.y) > 0.5 {
                view.frame.origin = target
                log("shiftLights container → (\(Int(target.x)), \(Int(target.y))) down=\(down)")
            }
        }
    }

    /// 锁屏用小窗(固定尺寸),解锁恢复原主窗尺寸。
    private func resizeForMode(_ win: NSWindow) {
        switch mode {
        case .lock:
            win.title = L10n.tBranded("app_title")
            // 幂等守卫:已在锁屏尺寸就不再动。定时器/通知/动画期间的重入会反复
            // 走到这里,每次按当前 frame 重算中心会把窗口越推越偏(位置漂移)。
            if abs(win.frame.width - Self.lockWindowSize.width) < 2 { return }
            log("lock-resize: current=\(win.frame) fullSizeCV=\(win.styleMask.contains(.fullSizeContentView))")
            // 直接以锁定态启动时窗口天生就是锁定尺寸——这种框架绝不能存为
            // 「主窗框架」,否则解锁后主界面会被塞进小窗(内容挤压错位)。
            // 解锁使用期间 .main 模式已随移动/缩放持续刷新缓存,这里只在缓存
            // 为空时补记一次,避免把重建窗口落位的默认 frame 覆盖上去。
            if savedMainFrame == nil, win.frame.width >= Self.lockWindowSize.width + 60 {
                savedMainFrame = win.frame
                log("lock-resize: saved=\(win.frame)")
            }
            let center = NSPoint(x: win.frame.midX, y: win.frame.midY)
            win.setContentSize(Self.lockWindowSize)   // 隐藏标题栏:frame 即内容尺寸
            var f = win.frame
            f.origin = NSPoint(x: center.x - f.width / 2, y: center.y - f.height / 2)
            f = Self.clampedToVisible(f, window: win)
            win.setFrame(f, display: true, animate: false)
            log("lock-resize: shrank to \(win.frame)")
        case .main:
            guard let saved = savedMainFrame else { return }
            // 已就位(SwiftUI 高频 updateNSView 反复 attach):只清缓存不再重排,
            // 否则缓存被「恢复→通知→再记录」循环不断补回,每次 attach 都 setFrame
            if abs(win.frame.width - saved.width) < 2, abs(win.frame.height - saved.height) < 2,
               abs(win.frame.origin.x - saved.origin.x) < 2, abs(win.frame.origin.y - saved.origin.y) < 2 {
                savedMainFrame = nil
                return
            }
            log("main-resize: current=\(win.frame) saved=\(saved)")
            savedMainFrame = nil
            // 解锁过渡中 SwiftUI 会先按内容最小尺寸(minWidth 760)把 500 宽的
            // 锁屏窗撑回最小主窗尺寸,若此时 frame 恰好卡在最小宽度,说明是被
            // 过渡挤压出来的「中毒」frame(并已被 SwiftUI 持久化),不是用户
            // 调过的尺寸 → 回退默认尺寸,避免主窗口从此永远是最小尺寸。
            let restore: NSRect
            if saved.width <= Self.minMainWidth + 0.5 {
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
            // 恢复不做动画:窗口从居中的锁屏小窗滑回原位的过渡,会被看成
            // 内容整体向一方漂移(如详情面板偏移);原生解锁也是瞬时就位
            win.setFrame(restore, display: true, animate: false)
            Log.info("chrome", "main frame restored to \(win.frame)")
            // SwiftUI 布局稍后仍可能再改窗口(解锁过渡期会重放恢复的 frame),
            // 复核一次;此后不再干预用户的调整。
            // 存量 GCD:调用点在主线程,延时复核仍在主队列,无需回主线程
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
        /// 挂载重试上限(0.1s 间隔 × 80 次 ≈ 8s)
        private static let maxAttachAttempts = 80
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
            guard attempts < Self.maxAttachAttempts else { return }
            // 存量 GCD:view 生命周期在主线程,重试回调仍在主队列,无需回主线程
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
            // 存量 GCD:推迟到本轮布局完成后再读 frame,回调仍在主队列
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                Log.debug("chrome", "dragArea installed frame=\(self.frame) hidden=\(isHidden) window=\(window != nil)")
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            // 不打日志:hitTest 会被每个鼠标事件调用,逐条写日志反而造成卡顿
            return super.hitTest(point)
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

// MARK: - 「Above all」窗口置顶状态

final class WindowFloatState: ObservableObject {
    static let shared = WindowFloatState()
    @Published var floating = false

    func toggle() {
        floating.toggle()
        NSApp.keyWindow?.level = floating ? .floating : .normal
    }
}

