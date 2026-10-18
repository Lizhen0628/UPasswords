import SwiftUI
import UPasswordsCore

/// 发送验证码后的重发倒计时:服务端冷却 60s(429 时按 Retry-After),
/// 期间按钮禁用并显示"重发 (Ns)"。按钮所在视图各持一份实例。
@MainActor
final class ResendCountdown: ObservableObject {
    @Published private(set) var secondsLeft = 0
    private var task: Task<Void, Never>? = nil

    var isRunning: Bool { secondsLeft > 0 }

    /// 按钮文案:倒计时中显示剩余秒数,否则原标签。
    func buttonTitle(_ normal: String) -> String {
        isRunning ? String(format: L10n.t("relay_resend_fmt"), secondsLeft) : normal
    }

    func start(_ seconds: Int) {
        task?.cancel()
        guard seconds > 0 else {
            secondsLeft = 0
            return
        }
        secondsLeft = seconds
        task = Task { [weak self] in
            while let self, self.secondsLeft > 0 {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self.secondsLeft -= 1
            }
        }
    }
}
