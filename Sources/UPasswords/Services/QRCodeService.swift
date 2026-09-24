import AppKit
import CoreImage
import Vision
import ScreenCaptureKit

/// 二维码识别:从屏幕截图或图片文件中提取一次性代码。
/// 负载约定:otpauth:// URI 原样入库;裸 base32 密钥原样入库
/// (TOTP.parse 两者都接受,见 Services/TOTP.swift)。
/// 屏幕捕获需要系统「屏幕录制」权限(首次使用会触发系统授权弹窗)。
enum QRCodeService {

    enum QRError: LocalizedError {
        case noQRCode
        case noOTPCode
        case screenCaptureDenied

        var errorDescription: String? {
            switch self {
            case .noQRCode: return L10n.t("qr_not_found", fallback: "未找到二维码。")
            case .noOTPCode: return L10n.t("qr_no_otp", fallback: "二维码中没有一次性代码。")
            case .screenCaptureDenied:
                return L10n.t("qr_screen_permission", fallback: "请在系统设置中授予屏幕录制权限后重试。")
            }
        }
    }

    // MARK: - 屏幕取码

    /// 截取所有活动屏幕 → Vision 识别二维码 → 解析出第一个可用的一次性代码。
    static func readFromScreen() async throws -> String {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()   // 触发系统授权弹窗
            throw QRError.screenCaptureDenied
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard !content.displays.isEmpty else { throw QRError.noQRCode }

        var payloads: [String] = []
        for display in content.displays {
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            // 2x 采样,保证小尺寸二维码也能被识别
            config.width = display.width * 2
            config.height = display.height * 2
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter,
                                                                   configuration: config)
            payloads += detectPayloads(in: image)
        }
        return try firstOTP(from: payloads)
    }

    // MARK: - 图片识码

    /// 从图片文件识别一次性代码。
    static func readFromImage(at url: URL) async throws -> String {
        guard let image = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw QRError.noQRCode
        }
        return try firstOTP(from: detectPayloads(in: image))
    }

    // MARK: - 识别与解析

    /// Vision 条码识别,返回所有二维码负载。
    static func detectPayloads(in image: CGImage) -> [String] {
        let request = VNDetectBarcodesRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([request])
        return request.results?.compactMap { $0.payloadStringValue } ?? []
    }

    /// 取第一个可用的一次性代码负载:otpauth:// 优先,其次裸 base32 密钥。
    static func firstOTP(from payloads: [String]) throws -> String {
        let trimmed = payloads.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        for p in trimmed where p.lowercased().hasPrefix("otpauth://") {
            return p
        }
        for p in trimmed where isBareBase32Secret(p) {
            if (try? TOTP.parse(p)) != nil { return p }
        }
        if payloads.isEmpty { throw QRError.noQRCode }
        throw QRError.noOTPCode
    }

    /// 裸 base32 密钥形态:仅 base32 字母表(A–Z、2–7、小写、补位 =),
    /// 不含 URL 特征字符(: / . @)——普通网址不会被误判为密钥。
    private static func isBareBase32Secret(_ s: String) -> Bool {
        guard s.count >= 8,
              !s.contains(":"), !s.contains("/"), !s.contains("."), !s.contains("@") else {
            return false
        }
        return s.allSatisfy { ch in
            (ch.isLetter && ch.isASCII) || ("2"..."7").contains(ch) || ch == "="
        }
    }
}
