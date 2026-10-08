import AppKit
import SwiftUI

import UPasswordsCore

/// Clipboard copy with auto-clear.
@MainActor
final class ClipboardModel: ObservableObject {
    static let shared = ClipboardModel()

    /// empty_clipboard_setting seconds; 0 = off.
    var clearSeconds: Int {
        UserDefaults.standard.integer(forKey: "clipboard.clearSeconds")
    }

    private var clearTask: Task<Void, Never>? = nil
    private var changeCountAtCopy = 0

    func copy(_ text: String, alert: Bool = true) {
        let pb = NSPasteboard.general
        pb.declareTypes([.string], owner: nil)
        pb.setString(text, forType: .string)
        changeCountAtCopy = pb.changeCount
        if alert {
            AppToast.shared.show(L10n.t("text_copied_message"))
        }
        clearTask?.cancel()
        let secs = clearSeconds
        guard secs > 0 else { return }
        clearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(secs) * 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            let pb = NSPasteboard.general
            if pb.changeCount == self.changeCountAtCopy {
                pb.clearContents()
            }
        }
    }

    /// Copies an OTP code with the dedicated message (otp_copied_message).
    func copyOTP(_ code: String) {
        copy(code, alert: false)
        AppToast.shared.show(L10n.t("otp_copied_message"))
    }
}

/// Lightweight toast surface shared by all windows.
@MainActor
final class AppToast: ObservableObject {
    static let shared = AppToast()
    @Published var message: String? = nil
    private var dismissTask: Task<Void, Never>? = nil

    func show(_ text: String) {
        message = text
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self?.message = nil
        }
    }
}
