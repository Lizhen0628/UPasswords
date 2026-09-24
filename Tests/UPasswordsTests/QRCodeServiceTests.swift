import XCTest
import AppKit
import CoreImage
@testable import UPasswords

final class QRCodeServiceTests: XCTestCase {

    /// 用 CoreImage 生成二维码,再走识别 → 解析链路,应还原原始 otpauth 负载。
    func testQRDetectionRoundTrip() throws {
        let payload = "otpauth://totp/Test:me?secret=JBSWY3DPEHPK3PXP&issuer=Test"
        let payloads = try XCTUnwrap(QRCodeService.detectPayloads(in: qrImage(payload: payload)))
        XCTAssertEqual(payloads.first, payload)

        let otp = try QRCodeService.firstOTP(from: payloads)
        XCTAssertEqual(otp, payload)
        XCTAssertNoThrow(try TOTP.parse(otp), "识别出的 otpauth 负载必须可被 TOTP 解析")
    }

    /// 裸 base32 密钥二维码同样可用。
    func testBareBase32SecretAccepted() throws {
        let payloads = try XCTUnwrap(QRCodeService.detectPayloads(in: qrImage(payload: "JBSWY3DPEHPK3PXP")))
        let otp = try QRCodeService.firstOTP(from: payloads)
        XCTAssertEqual(otp, "JBSWY3DPEHPK3PXP")
    }

    /// 非一次性代码的二维码(普通网址)必须被拒绝。
    func testNonOTPPayloadRejected() {
        XCTAssertThrowsError(try QRCodeService.firstOTP(from: ["https://example.com/page"]))
        XCTAssertThrowsError(try QRCodeService.firstOTP(from: [])) { error in
            XCTAssertTrue("\(error)".contains("二维码") || "\(error)".contains("QR"))
        }
    }

    // MARK: - 生成测试用二维码

    private func qrImage(payload: String) -> CGImage {
        let filter = CIFilter(name: "CIQRCodeGenerator")!
        filter.setValue(Data(payload.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        let ci = filter.outputImage!.transformed(by: CGAffineTransform(scaleX: 6, y: 6))
        let rep = NSCIImageRep(ciImage: ci)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    }
}
