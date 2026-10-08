import SwiftUI
import AppKit
import UPasswordsCore

/// 快捷键录制控件:点击进入录制态,按下组合键(需含 ⌘/⌃/⌥ 之一)完成录制;
/// Esc 取消本次录制,Delete/退格清空为「无」。key 为按键字符(小写,空 = 无),
/// modifiers 为 NSEvent.ModifierFlags rawValue。
struct ShortcutRecorder: NSViewRepresentable {
    @Binding var key: String
    @Binding var modifiers: Int

    func makeCoordinator() -> Coordinator { Coordinator(key: $key, modifiers: $modifiers) }

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.coordinator = context.coordinator
        view.key = key
        view.modifiers = modifiers
        return view
    }

    func updateNSView(_ nsView: RecorderView, context: Context) {
        nsView.key = key
        nsView.modifiers = modifiers
    }

    @MainActor
    final class Coordinator {
        private let key: Binding<String>
        private let modifiers: Binding<Int>

        init(key: Binding<String>, modifiers: Binding<Int>) {
            self.key = key
            self.modifiers = modifiers
        }

        func apply(key: String, modifiers: Int) {
            guard key != self.key.wrappedValue || modifiers != self.modifiers.wrappedValue else { return }
            self.key.wrappedValue = key
            self.modifiers.wrappedValue = modifiers
            Log.info("ui", "shortcut set key=\(key) mods=\(modifiers)")
        }
    }
}

/// AppKit 录制视图:绘制当前组合;点击进入录制态并捕获 keyDown,
/// 失去第一响应者(点击别处)即取消录制。
@MainActor
final class RecorderView: NSView {
    var coordinator: ShortcutRecorder.Coordinator?
    var key = "" { didSet { needsDisplay = true } }
    var modifiers: Int = 0 { didSet { needsDisplay = true } }
    var recording = false { didSet { needsDisplay = true; if recording { window?.makeFirstResponder(self) } } }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        recording = true
    }

    override func resignFirstResponder() -> Bool {
        recording = false
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { return }
        // Esc 取消本次录制,保持原值
        if event.keyCode == 53 {
            recording = false
            return
        }
        // Delete/退格清空快捷键
        if event.keyCode == 51 || event.keyCode == 117 {
            coordinator?.apply(key: "", modifiers: 0)
            recording = false
            return
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // 必须含 ⌘/⌃/⌥ 之一:纯字母会被文本输入抢走,也无法稳定作用于菜单
        guard !flags.intersection([.command, .control, .option]).isEmpty,
              let chars = event.charactersIgnoringModifiers,
              let first = chars.lowercased().first,
              first.isLetter || first.isNumber else { return }
        coordinator?.apply(
            key: String(first),
            modifiers: Int(flags.intersection([.command, .control, .option, .shift]).rawValue)
        )
        recording = false
    }

    override func draw(_ dirtyRect: NSRect) {
        let inset = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: inset, xRadius: 6, yRadius: 6)
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        NSColor.controlAccentColor.setStroke()
        path.lineWidth = recording ? 2 : 0
        if !recording {
            NSColor.separatorColor.setStroke()
            path.lineWidth = 1
        }
        path.stroke()

        let text = recording
            ? L10n.t("shortcut_recorder_hint")
            : (key.isEmpty ? L10n.t("shortcut_none_text") : Self.comboString(key: key, modifiers: modifiers))
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: recording ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ]
        let string = NSAttributedString(string: text, attributes: attrs)
        let size = string.size()
        string.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }

    /// 组合键显示串(⌃⌥⇧⌘ + 大写键符,系统菜单惯例顺序)。
    static func comboString(key: String, modifiers: Int) -> String {
        let flags = NSEvent.ModifierFlags(rawValue: UInt(modifiers))
        var symbol = ""
        if flags.contains(.control) { symbol += "⌃" }
        if flags.contains(.option) { symbol += "⌥" }
        if flags.contains(.shift) { symbol += "⇧" }
        if flags.contains(.command) { symbol += "⌘" }
        return symbol + key.uppercased()
    }
}
