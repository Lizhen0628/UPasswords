import CoreImage
import UIKit

import UPasswordsCore

/// 二维码:生成（OTP/网址分享）与相机扫码。
/// 负载约定与 macOS 一致:otpauth:// URI 原样入库;裸 base32 密钥原样入库
/// （TOTP.parse 两者都接受）。
enum QRCodeService {

    enum QRError: LocalizedError {
        case noQRCode
        case noOTPCode
        case generationFailed
        case cameraUnavailable

        var errorDescription: String? {
            switch self {
            case .noQRCode: return L10n.t("qr_not_found", fallback: "未找到二维码。")
            case .noOTPCode: return L10n.t("qr_no_otp", fallback: "二维码中没有一次性代码。")
            case .generationFailed: return L10n.t("qr_generate_failed", fallback: "二维码生成失败。")
            case .cameraUnavailable: return L10n.t("ios_camera_permission_error", fallback: "相机不可用，请检查相机权限设置。")
            }
        }
    }

    // MARK: - 生成

    /// 文本 → 二维码 UIImage（黑白高对比,静区由展示层留白）。
    static func generate(_ payload: String) throws -> UIImage {
        let filter = CIFilter(name: "CIQRCodeGenerator")
        guard let filter else { throw QRError.generationFailed }
        filter.setValue(Data(payload.utf8), forKey: "message")
        filter.setValue("M", forKey: "errorCorrection")
        guard let output = filter.outputImage else { throw QRError.generationFailed }
        // 模块放大 8x,避免展示层拉伸模糊
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let context = CIContext()
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else {
            throw QRError.generationFailed
        }
        return UIImage(cgImage: cg)
    }

    /// OTP 字段值 → 展示用负载:otpauth:// 原样;裸密钥补全为标准 TOTP URI。
    static func otpPayload(secret: String, title: String) -> String {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("otpauth://") { return trimmed }
        return "otpauth://totp/\(title)?secret=\(trimmed)"
    }

    // MARK: - 识别与解析（与 macOS QRCodeService 同规则）

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

    /// 裸 base32 密钥形态:仅 base32 字母表（A–Z、2–7、小写、补位 =）,
    /// 不含 URL 特征字符(: / . @)——普通网址不会被误判为密钥。
    static func isBareBase32Secret(_ s: String) -> Bool {
        guard s.count >= 8,
              !s.contains(":"), !s.contains("/"), !s.contains("."), !s.contains("@") else {
            return false
        }
        return s.allSatisfy { ch in
            (ch.isLetter && ch.isASCII) || ("2"..."7").contains(ch) || ch == "="
        }
    }
}
